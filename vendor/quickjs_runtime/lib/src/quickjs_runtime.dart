/// A high-level QuickJS JavaScript runtime with synchronous host callbacks.
///
/// Wraps the low-level [QuickjsFfi] bindings and manages the lifecycle of the
/// QuickJS runtime/context plus any registered [NativeCallable]s. Host
/// functions registered via [registerHostFunction] are invoked synchronously
/// from JS on the same isolate that owns this runtime.
///
/// This file is VM-only (dart:ffi); never import it from a web-reachable
/// path.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'quickjs_ffi.dart';

/// A QuickJS JavaScript runtime with synchronous host callbacks.
class QuickjsRuntime {
  final QuickjsFfi _ffi;
  Pointer<Void> _runtime;
  Pointer<Void> _context;
  final _callables = <NativeCallable>[];

  /// Whether a successful top-level [eval] automatically drains the
  /// microtask queue (promise reactions). Node and GraalJS both run pending
  /// jobs when a script finishes, so the default mirrors them; pass `false`
  /// for the old strict behavior (drain only via [drainMicrotasks]).
  final bool autoDrainMicrotasks;

  /// Creates a new runtime with a fresh context and an empty host callback
  /// registry.
  QuickjsRuntime({this.autoDrainMicrotasks = true})
      : _ffi = QuickjsFfi(),
        _runtime = nullptr,
        _context = nullptr {
    _ffi.resetCallbacks();
    _runtime = _ffi.createRuntime();
    _context = _ffi.createContext(_runtime);
  }

  /// Evaluates JS [code] and returns the JSON result string.
  ///
  /// Returns `null` on error (and [errMsg] receives the exception text) or
  /// when the result is JS `undefined`.
  String? eval(
    String code, {
    String filename = '<eval>',
    List<String?>? errMsg,
  }) {
    final result = _ffi.eval(_context, code, filename, errMsg);
    // Node/GraalJS parity: promise reactions queued by the script run when
    // the script completes. Capped so a self-re-enqueueing chain cannot
    // hang; a job that throws is reported on stderr and stops the drain.
    // Note: `_ffi.eval` returns null both for a thrown script (errMsg set)
    // and for a JS-undefined completion value (very common for statement
    // lists) — only the error case must skip the drain.
    final failed = errMsg != null && errMsg.isNotEmpty && errMsg.first != null;
    if (!failed && autoDrainMicrotasks) {
      drainMicrotasks();
    }
    return result;
  }

  /// Registers a host function callable from JS.
  ///
  /// [callback] receives a JSON args string and returns a JSON result string
  /// (or `null` for JS `undefined`). It executes synchronously on the same
  /// isolate that owns this runtime. The underlying [NativeCallable] is kept
  /// alive for the lifetime of this runtime.
  void registerHostFunction(
    String name,
    String? Function(String argsJson) callback,
  ) {
    final callable =
        NativeCallable<Pointer<Utf8> Function(Pointer<Utf8>)>.isolateLocal((
      Pointer<Utf8> argsPtr,
    ) {
      try {
        final argsJson = argsPtr.toDartString();
        final result = callback(argsJson);
        if (result == null) return nullptr;
        return result.toNativeUtf8();
      } catch (_) {
        // Pointer-returning NativeCallables cannot declare an
        // exceptionalReturn; a stray exception would otherwise terminate
        // the isolate. Surface it to JS as `undefined`.
        return nullptr;
      }
    });
    _callables.add(callable); // keep alive so it isn't GC'd
    _ffi.registerHostFn(_context, name, callable.nativeFunction);
  }

  /// Registers a BYTES host function callable from JS as `name(typedArray)`.
  ///
  /// The callback receives the name and a zero-copy view of the typed
  /// array's bytes. It executes synchronously on the owning isolate and
  /// the view is only valid for the duration of the call — copy
  /// (`Uint8List.fromList`) if the data must outlive it. Returns false on
  /// libraries built before the bytes export (0.3.4): callers should fall
  /// back to the JSON/base64 path.
  bool registerHostBytesFn(
    String name,
    void Function(String name, Uint8List data) callback,
  ) {
    if (!_ffi.hasBytesFn) return false;
    final callable =
        NativeCallable<Void Function(Pointer<Utf8>, Pointer<Uint8>, Size)>.isolateLocal((
      Pointer<Utf8> namePtr,
      Pointer<Uint8> dataPtr,
      int length,
    ) {
      try {
        callback(namePtr.toDartString(), dataPtr.asTypedList(length));
      } catch (_) {
        // isolateLocal callables cannot throw across the FFI boundary;
        // degrade to a dropped message like the rest of the lane.
      }
    });
    _callables.add(callable); // keep alive so it isn't GC'd
    return _ffi.registerBytesFn(_context, name, callable.nativeFunction) == 0;
  }

  /// Whether this build of the native library supports bytes host
  /// functions — see [registerHostBytesFn].
  bool get hasBytesFn => _ffi.hasBytesFn;

  /// Sets a global variable named [name] from a Dart value (JSON-encoded).
  void setGlobal(String name, Object? value) {
    _ffi.setGlobalJson(_context, name, jsonEncode(value));
  }

  /// Drains pending jobs (promise reactions) queued on this context.
  ///
  /// Mirrors `executePendingJob()` in the flutter_js backend: call it after
  /// every eval that may settle promises so `.then` continuations run.
  int executePendingJobs() => _ffi.executePendingJobs(_context);

  /// Blocks the calling thread for [ms] milliseconds.
  ///
  /// Returns `false` when the loaded library predates `qjs_sleep_ms`; the
  /// node-compat timer pump then degrades to ready-only draining.
  bool sleepMs(int ms) => _ffi.sleepMs(ms);

  /// Drains the microtask queue, executing at most [maxJobs] promise
  /// reactions. The cap exists because a self-re-enqueueing chain
  /// (`function f(){ Promise.resolve().then(f); } f();`) would otherwise
  /// loop forever — [eval]'s auto-drain uses the same guard.
  ///
  /// Returns the number of executed jobs; stops early (returning what ran)
  /// when a job throws — the error is reported on stderr by the C bridge.
  int drainMicrotasks({int maxJobs = 100000}) {
    if (maxJobs <= 0) return 0;
    var executed = 0;
    while (executed < maxJobs) {
      final rc = _ffi.executePendingJobsCapped(_context, maxJobs - executed);
      if (rc <= 0) break; // queue empty, unsupported library, or job error
      executed += rc;
    }
    return executed;
  }

  /// Releases all resources: the registered callbacks, then the QuickJS
  /// context and runtime. Safe to call once; a no-op thereafter.
  void close() {
    for (final c in _callables) {
      c.close();
    }
    _callables.clear();
    if (_context.address != 0 || _runtime.address != 0) {
      _ffi.destroy(_runtime, _context);
      _context = nullptr;
      _runtime = nullptr;
    }
  }
}
