/// `dart:io`-backed [JsrRuntime] for JS extensions: runs quickjs-ng (`qjs`)
/// as a subprocess and speaks the line-delimited JSON stdio transport
/// (`kExtTransportStdioJs` + `kExtBootstrapCoreJs`).
///
/// **This library is not web-safe.** It is exported only from `lib/io.dart`;
/// the core library never imports it.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../js_ext/ext_protocol.dart';
import '../js_ext/jsr_runtime.dart';

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
final class QjsProcessRuntime implements JsrRuntime {
  QjsProcessRuntime({
    this.startTimeout = const Duration(seconds: 30),
    String? binary,
  }) : _binaryOverride = binary;

  /// [engineId] reported by `__extPing` parity fixtures.
  static const String kEngineId = 'qjs-process';

  static const String _installHint =
      'install quickjs-ng (qjs) and ensure it is on PATH, or set FA_QJS_BIN';

  static const int _maxStderrLines = 200;

  /// Bound for [start] (spawn + `__extCommit` round trip). Overrun kills the
  /// engine with SIGKILL and surfaces [TimeoutException].
  final Duration startTimeout;

  final String? _binaryOverride;

  Process? _process;
  Directory? _tempDir;
  ExtBridgeHandler? _bridges;
  bool _disposed = false;
  int? _exitCodeValue;
  int _nextInvokeId = 1;
  Map<String, dynamic>? _commit;

  final Map<int, Completer<Object?>> _invokeWaiters = {};
  final Queue<String> _stderrLines = Queue();

  /// Resolves the qjs binary: [binaryOverride], then `FA_QJS_BIN`, then `PATH`.
  static String resolveBinary({String? binaryOverride}) =>
      binaryOverride ?? Platform.environment['FA_QJS_BIN'] ?? 'qjs';

  /// The exact extension script handed to `qjs`: fatal reporter, engine
  /// bootstrap (transport + core), then the extension source guarded so an
  /// evaluation error reaches the host as `{fatal}` instead of dying silently.
  static String composeScript(String bootstrapJs, String mainJs) =>
      'globalThis.__extFatal=function(m){ '
      'print(JSON.stringify({fatal:m})); };\n'
      '$bootstrapJs\n;try{\n$mainJs\n'
      '}catch(e){ __extFatal(String(e && e.message || e)); }\n';

  @override
  String get engineId => kEngineId;

  /// Last [_maxStderrLines] lines of engine stderr (diagnostics buffer).
  String get lastStderr => _stderrLines.join('\n');

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
    if (_process != null) throw StateError('engine already started');
    if (_disposed) throw StateError('engine disposed');
    _bridges = bridges;

    final dir = await Directory.systemTemp.createTemp('fa_ext_');
    _tempDir = dir;
    final script = File('${dir.path}/ext_main.js');
    await script.writeAsString(composeScript(bootstrapJs, mainJs));

    final Process process;
    try {
      process = await Process.start(
        resolveBinary(binaryOverride: _binaryOverride),
        // `--std` exposes the `std` module the stdio transport uses for
        // line-delimited stdin (no stdin API exists without it).
        ['--std', script.path],
        mode: ProcessStartMode.normal,
      );
    } on Object {
      // Binary missing / not executable.
      _tempDir = null;
      try {
        await dir.delete(recursive: true);
      } on Object {
        // Best effort.
      }
      throw ExtEngineUnavailableException(_installHint);
    }
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

  @override
  Future<Object?> invoke(String fn, List<Object?> args, {Duration? timeout}) {
    final exited = _exitCodeValue;
    if (exited != null) {
      throw StateError('engine exited: code $exited');
    }
    if (_process == null) throw StateError('engine not started');

    final id = _nextInvokeId++;
    final completer = Completer<Object?>();
    _invokeWaiters[id] = completer;
    _send(jsonEncode({'invoke': id, 'fn': fn, 'args': args}));

    var future = completer.future;
    if (timeout != null) {
      future = future.timeout(
        timeout,
        onTimeout: () {
          // A stuck JS loop can never answer; the only recovery is a kill.
          _invokeWaiters.remove(id);
          _signal(_process, ProcessSignal.sigkill);
          throw TimeoutException(
            'engine invoke `$fn` timed out after '
            '${timeout.inMilliseconds}ms',
            timeout,
          );
        },
      );
    }
    return future;
  }

  /// SIGTERM, 2s grace, SIGKILL, then deletes the temp script directory.
  /// Idempotent.
  @override
  Future<void> dispose() async {
    final process = _process;
    _process = null;
    _bridges = null;
    _disposed = true;
    if (process != null) {
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
    final dir = _tempDir;
    _tempDir = null;
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } on Object {
        // Best effort.
      }
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
    if (probe.exitCode != 0 || probe.stdout.trim() != '1') {
      throw ExtEngineUnavailableException(
        '`$bin -e "print(1)"` failed (exit ${probe.exitCode}): '
        '${probe.stderr.trim()}',
      );
    }
    try {
      final version = await _run(bin, const ['-v']);
      final text = version.stdout.trim();
      if (version.exitCode == 0 && text.isNotEmpty) return text;
    } on Object {
      // Fall through to the binary path.
    }
    return bin;
  }

  /// [Process.run] bounded for probe usage.
  static Future<ProcessResult> _run(String bin, List<String> args) {
    return Process.run(bin, args).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('`$bin` probe timed out'),
    );
  }

  void _watch(Process process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_noteStderr);
    // Writes to a dead engine surface as ASYNC errors on the stdin sink;
    // listen so they never become unhandled zone errors. The exit watcher
    // fails pending waiters.
    unawaited(process.stdin.done.then((_) {}, onError: (Object _) {}));
    unawaited(
      process.exitCode.then((code) {
        _exitCodeValue ??= code;
        _failAll(StateError('engine exited: code $code'));
      }),
    );
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _noteStderr('<stdout> undecodable: $line');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _noteStderr('<stdout> non-object: $line');
      return;
    }
    if (decoded.containsKey('fatal')) {
      _failAll(ExtProtocolException('engine fatal: ${decoded['fatal']}'));
      return;
    }
    final invokeId = decoded['invoke'];
    if (invokeId is int) {
      _invokeWaiters.remove(invokeId)?.complete(_replyValue(decoded));
      return;
    }
    final seq = decoded['seq'];
    if (seq is int && decoded.containsKey('method')) {
      final method = decoded['method'];
      if (method is String) {
        unawaited(_answerBridge(seq, method, decoded['args']));
        return;
      }
    }
    _noteStderr('<stdout> unrecognized: $line');
  }

  Future<void> _answerBridge(int seq, String method, Object? rawArgs) async {
    final handler = _bridges;
    Object? value;
    var ok = true;
    String? error;
    try {
      if (handler == null) {
        throw StateError('no bridges handler installed');
      }
      value = await handler(
        method,
        rawArgs is Map ? Map<String, dynamic>.from(rawArgs) : const {},
      );
    } on Object catch (e) {
      ok = false;
      error = '$e';
    }
    _send(
      jsonEncode(
        ok
            ? {'seq': seq, 'ok': true, 'value': value}
            : {'seq': seq, 'ok': false, 'error': error},
      ),
    );
  }

  Object? _replyValue(Map<String, dynamic> reply) {
    if (reply['ok'] == true) return reply['value'];
    return throw ExtProtocolException('${reply['error'] ?? 'engine error'}');
  }

  void _failAll(Object error) {
    final waiters = Map<int, Completer<Object?>>.from(_invokeWaiters);
    _invokeWaiters.clear();
    for (final completer in waiters.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void _send(String line) {
    try {
      _process?.stdin.writeln(line);
    } on Object {
      // The exit watcher fails pending waiters.
    }
  }

  void _noteStderr(String line) {
    _stderrLines.addLast(line);
    while (_stderrLines.length > _maxStderrLines) {
      _stderrLines.removeFirst();
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
