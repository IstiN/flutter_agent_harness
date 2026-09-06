// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// flutter_js-backed [JsrRuntime] for JS extensions in the Fa app (section 14
/// of the js-extension design): one isolated engine per extension, the
/// `sendMessage` transport (`kExtTransportSendMessageJs` + the shared core),
/// and invoke results routed back over the `__ext_host` channel.
///
/// This file imports `package:flutter_js`, which needs `dart:io`/`dart:ffi` —
/// it must only be reached through the conditional factory in
/// `ext_runtime_factory_io.dart`. Web builds use [WebWorkerExtRuntime] (see
/// `ext_runtime_factory_stub.dart`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_js/flutter_js.dart';

/// flutter_js channel the bootstrap transport posts `jsr.ext.*` bridge calls
/// and adapter invoke replies through (mirrored by the JS side).
const String kExtHostChannel = '__ext_host';

/// Adapter glue evaluated after the shared bootstrap: routes Dart-initiated
/// invocations of [ExtJsGlobals.invoke] back to the host over the
/// `__ext_host` channel (`{invoke: handle, ok, value|error}`), so every call
/// — sync or Promise-returning — settles the same Dart-side completer.
///
/// The shared bootstrap core stays engine-agnostic (parity-fixture surface);
/// only this adapter knows how its host receives invoke results, so wrapping
/// the global here (evaluate now returns `null`, the reply travels the
/// channel) is a documented deviation from the literal wire table in
/// contract section 5.
const String _kInvokeReplyGlueJs = '''
// flutter_js ext adapter: invoke results travel the __ext_host channel.
(function (g) {
  'use strict';
  var raw = g.__extInvoke;
  g.__extInvoke = function (handle, args) {
    var reply = function (ok, v) {
      var msg = ok
        ? { invoke: handle, ok: true, value: v === undefined ? null : v }
        : { invoke: handle, ok: false, error: String(v && v.message ? v.message : v) };
      sendMessage('__ext_host', JSON.stringify(msg));
    };
    try {
      var r = raw(handle, args);
      if (r && typeof r.then === 'function') {
        r.then(function (v) { reply(true, v); }, function (e) { reply(false, e); });
        return null;
      }
      reply(true, r);
    } catch (e) { reply(false, e); }
    return null;
  };
})(globalThis);
''';

/// Prologue the qjs CLI adapter also evaluates (`ExtEngineProcess.composeScript`):
/// extension main.js reports top-level throws through `__extFatal` instead of
/// leaving the engine silently unregistered.
const String _kFatalPrologueJs = '''
globalThis.__extFatal = function (m) {
  sendMessage('__ext_host', JSON.stringify({ fatal: String(m) }));
};
''';

/// Per-extension JS engine on flutter_js. [start] drives bootstrap + main.js,
/// [invoke] awaits the JS-side result over the `__ext_host` channel, and a
/// wedged engine is released (JSC has no script interrupt).
final class FlutterJsExtRuntime implements JsrRuntime {
  /// Creates the engine; throws [ExtEngineUnavailableException] when the
  /// flutter_js native binding cannot load (or on web builds — use the
  /// web-worker runtime there).
  static JavascriptRuntime _create() {
    if (kIsWeb) {
      throw ExtEngineUnavailableException(
        'flutter_js has no engine on web builds; use the web-worker runtime',
      );
    }
    try {
      final runtime = getJavascriptRuntime();
      runtime.enableHandlePromises();
      return runtime;
    } catch (error) {
      throw ExtEngineUnavailableException(
        'flutter_js engine failed to load: $error',
      );
    }
  }

  FlutterJsExtRuntime() : _rt = _create();

  @override
  String get engineId => 'flutter-js';

  final JavascriptRuntime _rt;
  final Map<int, Completer<Object?>> _pending = {};
  ExtBridgeHandler? _bridges;
  bool _disposed = false;

  /// Engine kill-switch applied when a caller gives no [JsrRuntime.invoke]
  /// timeout (the extension host's own future timeouts do not release the
  /// engine; this one does).
  static const Duration defaultCallTimeout = Duration(seconds: 30);

  /// Cap on the pending-job drain after each evaluate (see [_drainJobs]).
  static const int _maxJobKicks = 10000;

  @override
  Future<void> start({
    required String bootstrapJs,
    required String mainJs,
    required ExtBridgeHandler bridges,
  }) async {
    if (_disposed) throw StateError('runtime disposed');
    _bridges = bridges;
    _rt.setupBridge(kExtHostChannel, _onHostMessage);
    _eval(_kFatalPrologueJs);
    _eval(bootstrapJs);
    _eval(_kInvokeReplyGlueJs);
    _eval(
      'try {\n$mainJs\n} catch (e) { __extFatal(String(e && e.message || e)); }',
    );
    final fatal = _takeFatal();
    if (fatal != null) {
      throw ExtProtocolException('extension main.js failed: $fatal');
    }
    // Contract section 4: start resolves only after __extCommit returned the
    // registration payload. The host fetches (and parses) it again.
    await invoke(ExtJsGlobals.commit, const [], timeout: defaultCallTimeout);
  }

  @override
  Future<Object?> invoke(
    String fn,
    List<Object?> args, {
    Duration? timeout,
  }) async {
    if (_disposed) throw StateError('runtime disposed');
    final effectiveTimeout = timeout ?? defaultCallTimeout;
    if (fn == ExtJsGlobals.invoke) {
      return _invokeHandle(args, effectiveTimeout);
    }
    // Plain sync globals (__extCommit, __extPing): evaluate + JSON round-trip
    // (flutter_js stringifies objects differently per backend, so the
    // stringify is done in JS where both backends agree).
    final call = '$fn.apply(null, ${jsonEncode(args)})';
    final result = _eval('JSON.stringify($call)');
    return jsonDecode(result);
  }

  Future<Object?> _invokeHandle(List<Object?> args, Duration timeout) async {
    final handle = args.isNotEmpty ? args.first : null;
    if (handle is! int) {
      throw ArgumentError('__extInvoke requires an integer handle');
    }
    final payload = args.length > 1 ? args[1] : null;
    final completer = Completer<Object?>();
    _pending[handle] = completer;
    try {
      _eval('__extInvoke($handle, ${jsonEncode(payload)})');
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          // JSC has no script interrupt: the only way to stop a wedged engine
          // is to release it. Process-wide safety note — this disposes THIS
          // engine's native context only; sibling engines keep running, and
          // process-wide interruption remains the qjs CLI adapter's job.
          dispose();
          throw TimeoutException(
            'js extension engine did not answer __extInvoke($handle) '
            'within $timeout',
            timeout,
          );
        },
      );
    } finally {
      _pending.remove(handle);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final completer in List.of(_pending.values)) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('runtime disposed'));
      }
    }
    _pending.clear();
    // Release the native engine on the NEXT event-loop turn, after the
    // microtask queue drains (promise-resolve callbacks flutter_js queued are
    // microtasks that may still evaluate into the context). Same recipe as
    // js_widget_runtime's flutter_js backend — releasing synchronously after
    // an evaluate is a native use-after-free (SIGSEGV in the wild).
    await Future<void>.delayed(Duration.zero, () {
      try {
        _rt.executePendingJob();
      } catch (_) {}
      try {
        _rt.dispose();
      } catch (_) {}
    });
  }

  /// Evaluates [js] and returns `stringResult`; drains the job queue. Throws
  /// [ExtProtocolException] when the evaluation itself fails.
  String _eval(String js) {
    final result = _rt.evaluate(js);
    if (result.isError) {
      throw ExtProtocolException('js evaluate failed: ${result.stringResult}');
    }
    _drainJobs();
    return result.stringResult;
  }

  /// Drains the pending JS job queue after an evaluate.
  ///
  /// flutter_js returns 0 from `executePendingJob()` on both bundled backends
  /// (JSC: a noop evaluate that flushes the microtask checkpoint; QuickJS:
  /// `dispatch()` of the job port), so one kick per evaluate is the whole
  /// drain in practice; the loop keeps working if a backend ever reports a
  /// real pending-job count.
  void _drainJobs() {
    for (var i = 0; i < _maxJobKicks; i++) {
      if (_rt.executePendingJob() == 0) break;
    }
  }

  /// Routes one `__ext_host` message. flutter_js hands the decoded JSON over:
  /// `{fatal}` (main.js throw), `{invoke}` (adapter invoke reply), or
  /// `{seq}` (bootstrap bridge request).
  void _onHostMessage(dynamic message) {
    if (message is! Map) return;
    if (message['fatal'] is String) {
      _failAll('extension fatal: ${message['fatal']}');
      return;
    }
    if (message.containsKey('invoke')) {
      _onInvokeReply(message['invoke'], message['ok'] == true, message);
      return;
    }
    if (message['seq'] is int) {
      unawaited(
        _onBridgeRequest(
          message['seq'] as int,
          message['method'],
          message['args'],
        ),
      );
    }
  }

  void _onInvokeReply(dynamic handle, bool ok, Map message) {
    final completer = _pending.remove(handle);
    if (completer == null || completer.isCompleted) return;
    if (ok) {
      completer.complete(message['value']);
    } else {
      completer.completeError(
        StateError('extension invoke failed: ${message['error']}'),
      );
    }
  }

  Future<void> _onBridgeRequest(int seq, dynamic method, dynamic args) async {
    Object? value;
    var ok = true;
    String? error;
    try {
      value = await _bridges!(
        method is String ? method : '',
        args is Map ? Map<String, dynamic>.from(args) : const <String, dynamic>{},
      );
    } catch (caught) {
      ok = false;
      error = '$caught';
    }
    if (_disposed) return;
    final reply = ok
        ? {'seq': seq, 'ok': true, 'value': value}
        : {'seq': seq, 'ok': false, 'error': error};
    // jsonEncode output is a valid JS object literal, so the reply can be
    // interpolated straight into the evaluate.
    final result = _rt.evaluate('__extDeliver(${jsonEncode(reply)})');
    if (!result.isError) _drainJobs();
  }

  String? _fatal;
  String? _takeFatal() {
    final fatal = _fatal;
    _fatal = null;
    return fatal;
  }

  void _failAll(String message) {
    _fatal ??= message;
    for (final completer in List.of(_pending.values)) {
      if (!completer.isCompleted) {
        completer.completeError(ExtProtocolException(message));
      }
    }
    _pending.clear();
  }
}
