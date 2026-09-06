/// `dart:io`-backed [JsrRuntime] for JS extensions: runs quickjs-ng (`qjs`)
/// as a subprocess and speaks the line-delimited JSON stdio transport
/// (`kExtTransportStdioJs` + `kExtBootstrapCoreJs`).
///
/// **This library is not web-safe.** It is exported only from `lib/io.dart`;
/// the core library never imports it.
///
/// All protocol/bookkeeping logic lives in `ext_engine_protocol.dart` (pure);
/// this file is spawn/kill/pipes only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../js_ext/ext_protocol.dart';
import '../js_ext/jsr_runtime.dart';
import 'ext_engine_protocol.dart';

/// A [JsrRuntime] over a `qjs` subprocess using the stdio wire protocol.
///
/// Engine resolution: explicit `binary` override, then the `FA_QJS_BIN`
/// environment variable, then `qjs` from `PATH`. A missing binary surfaces as
/// [ExtEngineUnavailableException] (spawn `ProcessException`), never a raw
/// crash.
///
/// Wire protocol (host side): one JSON object per `\n` line.
/// - JS→host bridge request `{seq, method, args}` — answered with
///   `{seq, ok, value}` or `{seq, ok: false, error}` via [bridges].
/// - Host→JS invoke `{invoke, fn, args}` — answered with
///   `{invoke, ok, value}` or `{invoke, ok: false, error}`.
/// - `{fatal: m}` — bootstrap/main failure; fails [start] and every pending
///   call with [ExtProtocolException].
final class QjsProcessRuntime implements JsrRuntime, ExtLineSink {
  QjsProcessRuntime({
    this.startTimeout = const Duration(seconds: 30),
    String? binary,
  }) : _binaryOverride = binary;

  /// [engineId] reported by `__extPing` parity fixtures.
  static const String kEngineId = 'qjs-process';

  static const String _installHint =
      'install quickjs-ng (qjs) and ensure it is on PATH, or set FA_QJS_BIN';

  /// Bound for [start] (spawn + `__extCommit` round trip). Overrun kills the
  /// engine with SIGKILL and surfaces [TimeoutException].
  final Duration startTimeout;

  final String? _binaryOverride;

  Process? _process;
  Directory? _tempDir;
  ExtBridgeHandler? _bridges;
  bool _disposed = false;
  int? _exitCodeValue;
  Map<String, dynamic>? _commit;

  final _router = ExtEngineRouter();

  @override
  String get engineId => kEngineId;

  /// Resolves the qjs binary: [binaryOverride], then `FA_QJS_BIN`, then `PATH`.
  static String resolveBinary({String? binaryOverride}) =>
      binaryOverride ?? Platform.environment['FA_QJS_BIN'] ?? 'qjs';

  /// The exact extension script handed to `qjs` (composition defined in
  /// [composeExtScript]).
  static String composeScript(String bootstrapJs, String mainJs) =>
      composeExtScript(bootstrapJs, mainJs);

  /// Last engine diagnostics lines (stderr + stdout notes) — see
  /// [ExtEngineRouter.lastNotes].
  String get lastStderr => _router.lastNotes;

  /// Registration payload returned by `__extCommit`. Fails when [start] has
  /// not completed.
  Future<Map<String, dynamic>> get commitPayload async {
    final commit = _commit;
    if (commit == null) {
      throw StateError('engine not started');
    }
    return commit;
  }

  @override
  Future<void> start({
    required String bootstrapJs,
    required String mainJs,
    required ExtBridgeHandler bridges,
  }) async {
    _checkStartable();
    _bridges = bridges;
    final script = await _writeScript(bootstrapJs, mainJs);
    final process = await _spawn(script);
    _process = process;
    _watch(process);

    try {
      _commit =
          await invoke(ExtJsGlobals.commit, const [], timeout: startTimeout)
              as Map<String, dynamic>;
    } on Object {
      await dispose();
      rethrow;
    }
  }

  void _checkStartable() {
    if (_process != null) throw StateError('engine already started');
    if (_disposed) throw StateError('engine disposed');
  }

  @override
  Future<Object?> invoke(String fn, List<Object?> args, {Duration? timeout}) {
    _checkRunnable();
    final id = _router.beginInvoke(fn, args);
    _send(jsonEncode(_router.invokePayload(id, fn, args)));
    return _router.response(id, fn, timeout, _killStuck);
  }

  /// Throws when the engine cannot accept an invoke right now.
  void _checkRunnable() {
    final exited = _exitCodeValue;
    if (exited != null) throw StateError('engine exited: code $exited');
    if (_process == null) throw StateError('engine not started');
  }

  Future<String> _writeScript(String bootstrapJs, String mainJs) async {
    final dir = await Directory.systemTemp.createTemp('fa_ext_');
    _tempDir = dir;
    final path = '${dir.path}/ext_main.js';
    await File(path).writeAsString(composeScript(bootstrapJs, mainJs));
    return path;
  }

  Future<Process> _spawn(String scriptPath) async {
    try {
      return await Process.start(
        resolveBinary(binaryOverride: _binaryOverride),
        // `--std` exposes the `std` module the stdio transport uses for
        // line-delimited stdin (no stdin API exists without it).
        ['--std', scriptPath],
        mode: ProcessStartMode.normal,
      );
    } on Object {
      // Binary missing / not executable.
      final dir = _tempDir;
      _tempDir = null;
      await _deleteTempDir(dir);
      throw ExtEngineUnavailableException(_installHint);
    }
  }

  /// SIGTERM, 2s grace, SIGKILL, then deletes the temp script directory.
  /// Idempotent.
  @override
  Future<void> dispose() async {
    final process = _process;
    _process = null;
    _bridges = null;
    _disposed = true;
    await _stop(process);
    final dir = _tempDir;
    _tempDir = null;
    await _deleteTempDir(dir);
  }

  /// SIGTERM, 2s grace, then SIGKILL. Null-safe for double dispose.
  Future<void> _stop(Process? process) async {
    if (process == null) return;
    _signal(process, ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          _signal(process, ProcessSignal.sigkill);
          return process.exitCode;
        },
      );
    } on Object {
      // Already gone.
    }
  }

  static Future<void> _deleteTempDir(Directory? dir) async {
    if (dir == null) return;
    try {
      await dir.delete(recursive: true);
    } on Object {
      // Best effort.
    }
  }

  /// Verifies the resolved qjs binary by running `<bin> -e 'print(1)'` and
  /// returns a version string (`<bin> -v`, falling back to the binary path).
  /// Throws [ExtEngineUnavailableException] when the binary is missing or
  /// broken. Used by `fa ext list`.
  static Future<String> engineProbe() async {
    final bin = resolveBinary();
    final ProcessResult probe;
    try {
      probe = await _run(bin, const ['-e', 'print(1)']);
    } on Object {
      throw ExtEngineUnavailableException(_installHint);
    }
    final problem = extProbeProblem(
      bin,
      probe.exitCode,
      probe.stdout,
      probe.stderr,
    );
    if (problem != null) throw ExtEngineUnavailableException(problem);
    return await _engineVersion(bin) ?? bin;
  }

  /// [Process.run] bounded for probe usage.
  static Future<ProcessResult> _run(String bin, List<String> args) {
    return Process.run(bin, args).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('`$bin` probe timed out'),
    );
  }

  static Future<String?> _engineVersion(String bin) async {
    try {
      final version = await _run(bin, const ['-v']);
      return extProbeVersion(version.exitCode, version.stdout);
    } on Object {
      // Fall through to the binary path.
      return null;
    }
  }

  void _watch(Process process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_router.note);
    // Writes to a dead engine surface as ASYNC errors on the stdin sink;
    // listen so they never become unhandled zone errors. The exit watcher
    // fails pending waiters.
    unawaited(process.stdin.done.then((_) {}, onError: (Object _) {}));
    unawaited(
      process.exitCode.then((code) {
        _exitCodeValue ??= code;
        _router.failAll(StateError('engine exited: code $code'));
      }),
    );
  }

  void _handleLine(String line) => _router.onLine(line).runWith(this);

  @override
  void note(String line) => _router.note('<stdout> $line');

  @override
  void answerBridge(int seq, String method, Object? args) =>
      unawaited(_answerBridge(seq, method, args));

  Future<void> _answerBridge(int seq, String method, Object? rawArgs) async {
    _send(jsonEncode(await _bridgeReply(seq, method, rawArgs)));
  }

  Future<Map<String, Object?>> _bridgeReply(
    int seq,
    String method,
    Object? rawArgs,
  ) async {
    final handler = _bridges;
    try {
      if (handler == null) throw StateError('no bridges handler installed');
      return extBridgeOk(seq, await handler(method, extBridgeArgs(rawArgs)));
    } on Object catch (e) {
      return extBridgeError(seq, '$e');
    }
  }

  /// SIGKILL for an invoke that overstayed its budget.
  Future<void> _killStuck() async {
    _signal(_process, ProcessSignal.sigkill);
  }

  void _send(String line) {
    try {
      _process?.stdin.writeln(line);
    } on Object {
      // The exit watcher fails pending waiters.
    }
  }

  static void _signal(Process? process, ProcessSignal signal) {
    if (process == null) return;
    try {
      process.kill(signal);
    } on Object {
      // Already gone.
    }
  }
}
