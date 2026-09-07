/// Engine seam for JS extensions (section 4 of the js-extension design): the
/// host talks to a JS engine only through [JsrRuntime], so adapters exist for
/// quickjs subprocesses, flutter_js, web workers, and tests ([FakeJsrRuntime]).
library;

import 'dart:async';

/// Host-side dispatch of a `jsr.ext.*` bridge call coming FROM JS (method
/// names: `ExtBridgeMethods`). Throw `ExtBridgeUnavailableException` for
/// capability-not-declared / missing-on-host; any other throw is treated as an
/// extension error and reported to JS as an error result.
typedef ExtBridgeHandler =
    Future<Object?> Function(String method, Map<String, dynamic> args);

/// A running JS engine evaluating one extension. Implementations must be safe
/// to `dispose()` from any state; [invoke] after [dispose] fails.
abstract interface class JsrRuntime {
  /// `'qjs-process'` | `'flutter-js'` | `'web-worker'` | `'qjs-wasm'` |
  /// `'fake'`.
  String get engineId;

  /// Bootstraps the engine: evaluates [bootstrapJs] (engine transport + shared
  /// core, see `ext_bootstrap_js.dart`) then [mainJs] (the extension source),
  /// and must resolve only after `__extCommit()` returned the registration
  /// payload. [bridges] dispatches the extension's `jsr.ext.*` host calls.
  Future<void> start({
    required String bootstrapJs,
    required String mainJs,
    required ExtBridgeHandler bridges,
  });

  /// Invokes the global JS function [fn] with JSON-able [args]; resolves with
  /// a JSON-able result. Implementations enforce [timeout] (kill/dispose on
  /// overrun => `TimeoutException`).
  Future<Object?> invoke(String fn, List<Object?> args, {Duration? timeout});

  /// Releases the engine; idempotent.
  Future<void> dispose();
}

/// The engine binary/runtime this process needs is not available (missing
/// `qjs`, no flutter_js binding, ...).
class ExtEngineUnavailableException implements Exception {
  /// Why the engine cannot be used, e.g. `install quickjs-ng (qjs) or set
  /// FA_QJS_BIN`.
  final String reason;

  ExtEngineUnavailableException(this.reason);

  @override
  String toString() => 'js extension engine unavailable: $reason';
}

/// Deterministic in-Dart [JsrRuntime] for tests: `start` only records its
/// arguments (no engine is driven), `invoke` dispatches to global closures the
/// test registered, and everything is inspectable.
///
/// [defaultTimeoutBehavior]: set to `'timeout'` to make every [invoke] throw
/// `TimeoutException` (simulating engine overrun); any other value is ignored.
final class FakeJsrRuntime implements JsrRuntime {
  FakeJsrRuntime(
    this.engineId, {
    Map<String, Future<Object?> Function(List<Object?> args)>? globals,
    this.defaultTimeoutBehavior,
  }) : _globals = globals == null ? <String, _FakeGlobal>{} : Map.of(globals);

  @override
  final String engineId;

  final String? defaultTimeoutBehavior;
  final Map<String, _FakeGlobal> _globals;

  /// Bridge dispatcher handed to [start]; settable any time.
  ExtBridgeHandler? bridges;

  /// Bootstrap source passed to the last [start].
  String? lastBootstrapJs;

  /// Extension source passed to the last [start].
  String? lastMainJs;

  /// Number of [invoke] calls (including ones that failed).
  int invokeCount = 0;

  /// Set by [dispose]; [start]/[invoke] throw `StateError` afterwards.
  bool disposed = false;

  /// Registers (or replaces) the implementation of global function [fn].
  void onGlobal(
    String fn,
    Future<Object?> Function(List<Object?> args) fnImpl,
  ) {
    _globals[fn] = fnImpl;
  }

  @override
  Future<void> start({
    required String bootstrapJs,
    required String mainJs,
    required ExtBridgeHandler bridges,
  }) async {
    if (disposed) throw StateError('runtime disposed');
    lastBootstrapJs = bootstrapJs;
    lastMainJs = mainJs;
    this.bridges = bridges;
  }

  @override
  Future<Object?> invoke(
    String fn,
    List<Object?> args, {
    Duration? timeout,
  }) async {
    if (disposed) throw StateError('runtime disposed');
    invokeCount += 1;
    if (defaultTimeoutBehavior == 'timeout') {
      throw TimeoutException('fake runtime timeout: $fn', timeout);
    }
    final impl = _globals[fn];
    if (impl == null) throw StateError('no such global: $fn');
    return impl(args);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

typedef _FakeGlobal = Future<Object?> Function(List<Object?> args);
