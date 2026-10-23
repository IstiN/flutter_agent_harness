/// dart:ffi bindings to the QuickJS C bridge (`libquickjs_bridge.so`).
///
/// The bridge exposes a flat C ABI with JSON-based marshaling: JS arguments
/// are stringified to JSON in C, passed to a synchronous Dart callback, and
/// the JSON result string is parsed back into a JS value.
///
/// Build the native library with `tool/build_quickjs.sh`, which produces
/// `native/quickjs/libquickjs_bridge.so`.
///
/// This file is VM-only (dart:ffi); never import it from a web-reachable
/// path.
@DefaultAsset('package:quickjs_runtime/src/quickjs_ffi.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Native signature of a host callback: receives a JSON args string and
/// returns a malloc'd JSON result string (or `nullptr` for JS `undefined`).
/// The bridge frees the returned string with `free()`.
typedef _HostCallbackNative = Pointer<Utf8> Function(Pointer<Utf8> argsJson);

/// Bytes-lane host callback: `(name, data, length)`. `data` points into
/// the JS typed array's backing store and is valid only during the call.
typedef _BytesCallbackNative = Void Function(
  Pointer<Utf8> name,
  Pointer<Uint8> data,
  Size length,
);

/// Resolves the absolute path to `libquickjs_bridge.so`.
///
/// Looks in (1) the `JSR_QUICKJS_LIB` env var, (2) this package's checkout
/// as recorded in the current `.dart_tool/package_config.json` (covers
/// `dart run`/`dart test`/`flutter test` in any app that depends on the
/// package), (3) relative to [Platform.script] and (4) the current working
/// directory (source checkouts that vendor the build output). Returns the
/// first existing candidate so the DynamicLibrary.open error carries a
/// recognizable path.
String _resolveLibraryPath() {
  final envOverride = Platform.environment['JSR_QUICKJS_LIB'];
  if (envOverride != null && envOverride.isNotEmpty) return envOverride;

  final candidates = <String>[
    ...?_packageCheckoutPaths(),
    Platform.script.resolve('native/quickjs/libquickjs_bridge.so').toFilePath(),
    '${Directory.current.path}/native/quickjs/libquickjs_bridge.so',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return candidates.first;
}

/// Paths to this package's own checkout(s) from `.dart_tool/package_config.json`,
/// or `null` when no config is readable (e.g. compiled binaries).
List<String>? _packageCheckoutPaths() {
  final config = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  if (!config.existsSync()) return null;
  final roots = <String>[];
  try {
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    for (final pkg in packages.cast<Map>()) {
      final libPath = _packageLibPath(pkg);
      if (libPath != null) roots.add(libPath);
    }
  } catch (_) {
    return null;
  }
  return roots.isEmpty ? null : roots;
}

String? _packageLibPath(Map pkg) {
  if (pkg['name'] != 'quickjs_runtime') return null;
  final root = Uri.parse(pkg['rootUri'] as String);
  if (!root.isScheme('file')) return null;
  var rootPath = Uri.decodeComponent(root.path);
  if (!rootPath.endsWith('/')) rootPath = '$rootPath/';
  return '${rootPath}native/quickjs/libquickjs_bridge.so';
}

const _symRegisterBytesFn = 'qjs_register_bytes_fn';
const _symExecutePendingJobs = 'qjs_execute_pending_jobs';
const _symExecutePendingJobsCapped = 'qjs_execute_pending_jobs_capped';
const _symSleepMs = 'qjs_sleep_ms';

@Native<Pointer<Void> Function()>(symbol: 'qjs_create_runtime')
external Pointer<Void> _nativeCreateRuntime();

@Native<Pointer<Void> Function(Pointer<Void>)>(symbol: 'qjs_create_context')
external Pointer<Void> _nativeCreateContext(Pointer<Void> runtime);

@Native<Void Function(Pointer<Void>, Pointer<Void>)>(symbol: 'qjs_destroy')
external void _nativeDestroy(Pointer<Void> runtime, Pointer<Void> context);

@Native<Void Function()>(symbol: 'qjs_reset_callbacks')
external void _nativeResetCallbacks();

@Native<
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<NativeFunction<_HostCallbackNative>>,
    )>(symbol: 'qjs_register_host_fn')
external int _nativeRegisterHostFn(
  Pointer<Void> context,
  Pointer<Utf8> name,
  Pointer<NativeFunction<_HostCallbackNative>> callback,
);

@Native<
    Pointer<Utf8> Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    )>(symbol: 'qjs_eval')
external Pointer<Utf8> _nativeEval(
  Pointer<Void> context,
  Pointer<Utf8> code,
  Pointer<Utf8> filename,
  Pointer<Pointer<Utf8>> errMsg,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'qjs_set_global_json',
)
external int _nativeSetGlobalJson(
  Pointer<Void> context,
  Pointer<Utf8> name,
  Pointer<Utf8> json,
);

@Native<
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<NativeFunction<_BytesCallbackNative>>,
    )>(symbol: _symRegisterBytesFn)
external int _nativeRegisterBytesFn(
  Pointer<Void> context,
  Pointer<Utf8> name,
  Pointer<NativeFunction<_BytesCallbackNative>> callback,
);

@Native<Int32 Function(Pointer<Void>)>(symbol: _symExecutePendingJobs)
external int _nativeExecutePendingJobs(Pointer<Void> context);

@Native<Int32 Function(Pointer<Void>, Int32)>(
  symbol: _symExecutePendingJobsCapped,
)
external int _nativeExecutePendingJobsCapped(
  Pointer<Void> context,
  int maxJobs,
);

@Native<Int32 Function(Int32)>(symbol: _symSleepMs)
external int _nativeSleepMs(int ms);

/// Low-level QuickJS FFI bindings.
///
/// Prefer [QuickjsRuntime] — this class is an implementation detail. Handles
/// are untyped ([Pointer<Void>]) because the C bridge treats `JSRuntime*` and
/// `JSContext*` as opaque pointers; the caller must pass the correct handle
/// to each function.
class QuickjsFfi {
  /// Path to the shared library, overridable for tests.
  static String libraryPath = _resolveLibraryPath();

  /// True when either the native-assets build hook (`hook/build.dart`) or
  /// a pre-built `libquickjs_bridge.so` is available.
  static bool get isAvailable {
    if (File(libraryPath).existsSync()) return true;
    try {
      _nativeResetCallbacks();
      return true;
    } catch (_) {
      return false;
    }
  }

  late final Pointer<Void> Function() _createRuntime;
  late final Pointer<Void> Function(Pointer<Void> runtime) _createContext;
  late final void Function(Pointer<Void> runtime, Pointer<Void> context)
      _destroy;
  late final void Function() _resetCallbacks;
  late final int Function(
    Pointer<Void> context,
    Pointer<Utf8> name,
    Pointer<NativeFunction<_HostCallbackNative>> callback,
  ) _registerHostFn;
  late final Pointer<Utf8> Function(
    Pointer<Void> context,
    Pointer<Utf8> code,
    Pointer<Utf8> filename,
    Pointer<Pointer<Utf8>> errMsg,
  ) _eval;
  late final int Function(
    Pointer<Void> context,
    Pointer<Utf8> name,
    Pointer<Utf8> json,
  ) _setGlobalJson;
  late final int Function(Pointer<Void> context) _executePendingJobs;
  late final int Function(Pointer<Void> context, int maxJobs)
      _executePendingJobsCapped;
  late final int Function(int ms) _sleepMs;

  /// Bytes-lane host functions (`qjs_register_bytes_fn`, added in 0.3.4).
  /// Older shared libraries do not export it — [hasBytesFn] is false and
  /// [registerBytesFn] degrades to a -1 no-op.
  bool get hasBytesFn => _hasBytesFn;
  bool _hasBytesFn = false;
  late final int Function(
    Pointer<Void> context,
    Pointer<Utf8> name,
    Pointer<NativeFunction<_BytesCallbackNative>> callback,
  ) _registerBytesFn;

  /// Resolves QuickJS C bridge symbols via the native-assets `CodeAsset`
  /// (`hook/build.dart`) when available, or falls back to opening
  /// [libraryPath] (`JSR_QUICKJS_LIB` / `tool/build_quickjs.sh`).
  QuickjsFfi({bool preferDynamicLibrary = false}) {
    final envOverride = Platform.environment['JSR_QUICKJS_LIB'];
    if (!preferDynamicLibrary &&
        (envOverride == null || envOverride.isEmpty)) {
      try {
        _nativeResetCallbacks();
        _bindNativeAsset();
        return;
      } catch (_) {
        // Fall through to DynamicLibrary.open(libraryPath).
      }
    }
    _bindDynamicLibrary(DynamicLibrary.open(libraryPath));
  }

  void _bindNativeAsset() {
    _createRuntime = _nativeCreateRuntime;
    _createContext = _nativeCreateContext;
    _destroy = _nativeDestroy;
    _resetCallbacks = _nativeResetCallbacks;
    _registerHostFn = _nativeRegisterHostFn;
    _eval = _nativeEval;
    _setGlobalJson = _nativeSetGlobalJson;
    _registerBytesFn = _nativeRegisterBytesFn;
    _hasBytesFn = true;
    _executePendingJobs = _nativeExecutePendingJobs;
    _executePendingJobsCapped = _nativeExecutePendingJobsCapped;
    _sleepMs = _nativeSleepMs;
  }

  void _bindDynamicLibrary(DynamicLibrary lib) {
    _createRuntime = lib
        .lookup<NativeFunction<Pointer<Void> Function()>>('qjs_create_runtime')
        .asFunction();
    _createContext = lib
        .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
          'qjs_create_context',
        )
        .asFunction();
    _destroy = lib
        .lookup<NativeFunction<Void Function(Pointer<Void>, Pointer<Void>)>>(
          'qjs_destroy',
        )
        .asFunction();
    _resetCallbacks = lib
        .lookup<NativeFunction<Void Function()>>('qjs_reset_callbacks')
        .asFunction();
    _registerHostFn = lib
        .lookup<
            NativeFunction<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<NativeFunction<_HostCallbackNative>>,
                )>>('qjs_register_host_fn')
        .asFunction();
    _eval = lib
        .lookup<
            NativeFunction<
                Pointer<Utf8> Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Pointer<Utf8>>,
                )>>('qjs_eval')
        .asFunction();
    _setGlobalJson = lib
        .lookup<
            NativeFunction<
                Int32 Function(
                    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)>>(
          'qjs_set_global_json',
        )
        .asFunction();
    _bindOptionalSymbols(lib);
  }

  void _bindOptionalSymbols(DynamicLibrary lib) {
    if (lib.providesSymbol(_symRegisterBytesFn)) {
      _registerBytesFn = lib
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<Void>,
                Pointer<Utf8>,
                Pointer<NativeFunction<_BytesCallbackNative>>,
              )
            >
          >(_symRegisterBytesFn)
          .asFunction();
      _hasBytesFn = true;
    } else {
      _registerBytesFn = (_, __, ___) => -1;
    }
    if (lib.providesSymbol(_symExecutePendingJobs)) {
      _executePendingJobs = lib
          .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
            _symExecutePendingJobs,
          )
          .asFunction();
    } else {
      _executePendingJobs = (_) => 0;
    }
    if (lib.providesSymbol(_symExecutePendingJobsCapped)) {
      _executePendingJobsCapped = lib
          .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
            _symExecutePendingJobsCapped,
          )
          .asFunction();
    } else {
      _executePendingJobsCapped = (context, _) => _executePendingJobs(context);
    }
    if (lib.providesSymbol(_symSleepMs)) {
      _sleepMs = lib
          .lookup<NativeFunction<Int32 Function(Int32)>>(_symSleepMs)
          .asFunction();
    } else {
      _sleepMs = (_) => -1;
    }
  }

  /// Creates a QuickJS runtime handle.
  Pointer<Void> createRuntime() => _createRuntime();

  /// Creates a context from [runtime].
  Pointer<Void> createContext(Pointer<Void> runtime) => _createContext(runtime);

  /// Destroys [context] then [runtime].
  void destroy(Pointer<Void> runtime, Pointer<Void> context) =>
      _destroy(runtime, context);

  /// Resets the global host callback registry.
  void resetCallbacks() => _resetCallbacks();

  /// Registers [callback] as a global JS BYTES function named [name].
  ///
  /// JS calls `name(typedArray)`; the C bridge hands Dart the raw
  /// (name, pointer, length) with no JSON marshal. The data view is only
  /// valid for the duration of the synchronous call — copy if retaining.
  /// No-op returning -1 on libraries without the bytes export.
  int registerBytesFn(
    Pointer<Void> context,
    String name,
    Pointer<NativeFunction<_BytesCallbackNative>> callback,
  ) {
    if (!_hasBytesFn) return -1;
    final namePtr = name.toNativeUtf8();
    final rc = _registerBytesFn(context, namePtr, callback);
    malloc.free(namePtr);
    return rc;
  }

  /// Registers [callback] as a global JS function named [name].
  ///
  /// The callback receives the JSON-encoded arguments and returns the
  /// JSON-encoded result (or `null` for JS `undefined`). It executes
  /// synchronously on the calling thread. [callback] is a raw function
  /// pointer; the caller owns its lifetime — keep the originating
  /// `NativeCallable` alive and `close()` it when done.
  int registerHostFn(
    Pointer<Void> context,
    String name,
    Pointer<NativeFunction<_HostCallbackNative>> callback,
  ) {
    final namePtr = name.toNativeUtf8();
    final rc = _registerHostFn(context, namePtr, callback);
    malloc.free(namePtr);
    return rc;
  }

  /// Evaluates [code]. Returns the JSON result string, or `null` on error or
  /// when the result is JS `undefined`. On error [errMsg] (if non-null)
  /// receives the JS exception message.
  String? eval(
    Pointer<Void> context,
    String code,
    String filename,
    List<String?>? errMsg,
  ) {
    final codePtr = code.toNativeUtf8();
    final filenamePtr = filename.toNativeUtf8();
    final errPtr = malloc<Pointer<Utf8>>();
    errPtr.value = nullptr;

    final resultPtr = _eval(context, codePtr, filenamePtr, errPtr);

    malloc.free(codePtr);
    malloc.free(filenamePtr);

    String? error;
    if (errPtr.value.address != 0) {
      error = errPtr.value.toDartString();
      malloc.free(errPtr.value);
    }
    malloc.free(errPtr);

    if (errMsg != null) {
      errMsg.clear();
      if (error != null) errMsg.add(error);
    }

    if (resultPtr.address == 0) return null;
    final result = resultPtr.toDartString();
    malloc.free(resultPtr);

    // The bridge returns the literal C string "undefined" when the JS result
    // is `undefined`: JS_JSONStringify of undefined yields JS_UNDEFINED, which
    // JS_ToCString renders as "undefined". Map that to Dart null so a host
    // function that returns null round-trips as undefined. A JS string with
    // the value "undefined" would instead be quoted ("\"undefined\""), so this
    // discriminator is unambiguous.
    if (result == 'undefined') return null;
    return result;
  }

  /// Sets a global variable named [name] from [json].
  int setGlobalJson(Pointer<Void> context, String name, String json) {
    final namePtr = name.toNativeUtf8();
    final jsonPtr = json.toNativeUtf8();
    final rc = _setGlobalJson(context, namePtr, jsonPtr);
    malloc.free(namePtr);
    malloc.free(jsonPtr);
    return rc;
  }

  /// Drains pending jobs (promise reactions) queued on [context].
  ///
  /// Returns the number of executed jobs, or `-1` when a job threw. A no-op
  /// when the loaded library predates `qjs_execute_pending_jobs`.
  int executePendingJobs(Pointer<Void> context) => _executePendingJobs(context);

  /// Like [executePendingJobs], but stops after [maxJobs] executed jobs so a
  /// self-re-enqueueing microtask chain (`function f(){ Promise.resolve()
  /// .then(f); } f();`) cannot hang the host thread. Falls back to the
  /// uncapped drain when the loaded library predates the capped symbol.
  int executePendingJobsCapped(Pointer<Void> context, int maxJobs) =>
      _executePendingJobsCapped(context, maxJobs);

  /// Blocks the calling thread for [ms] milliseconds.
  ///
  /// Returns `false` when the loaded library predates `qjs_sleep_ms`
  /// (the timer pump then cannot wait and the caller must degrade to
  /// ready-only draining).
  bool sleepMs(int ms) => _sleepMs(ms) == 0;
}
