part of 'fah.dart';

/// `fa wire-serve` transport host (issue #1103). WS mode: binds the
/// loopback port early (fail fast on an occupied port), and prints the
/// one-time startup line only AFTER the boot — and its lease gate —
/// succeeded ([runWireServe]'s `onReady`), so a parent never reads a
/// startup line for a serve that refuses to boot. stdio mode: NDJSON
/// over stdin/stdout, no startup line. Shutdown triggers: stdin EOF and
/// SIGTERM (routed through [_wireServeSettle]) — BOTH transports race
/// the shutdown trigger, so a signal never strands the teardown; boot,
/// persist, and teardown live in [AgentCli.runWireServe].
Future<int> _runWireServeHost({
  required AgentCli cli,
  required WireServeArgs wireServe,
  required _TerminalCliIO terminalIo,
}) async {
  // --token T is visible in the process list; the env var keeps it out
  // of `ps` for hosts that prefer that (review #1113 r2, suggestion #5).
  final token =
      wireServe.token ??
      () {
        final fromEnv = Platform.environment['FA_WIRE_SERVE_TOKEN'];
        return (fromEnv == null || fromEnv.isEmpty)
            ? wireServeToken()
            : fromEnv;
      }();
  HttpServer? http;
  if (!wireServe.stdio) {
    try {
      // AC20: a port race is a LOUD startup failure naming the port —
      // never a silent fallback.
      http = await bindLoopback(wireServe.port ?? 0);
    } on SocketException catch (error) {
      _fail('wire-serve: cannot bind 127.0.0.1:${wireServe.port ?? 0}: $error');
    }
  }
  final shutdown = Completer<void>();
  _wireServeSettle = () {
    if (!shutdown.isCompleted) shutdown.complete();
  };
  // WS mode: a supervisor closing our stdin pipe also ends the serve
  // (documented in docs/wire-protocol.md §8). The stdio transport owns
  // stdin itself in --stdio mode. A stdin ERROR is transport death, not
  // silence: log it, then end the serve through the same graceful settle
  // (review #1113 r4 — loud, never silent).
  StreamSubscription<void>? stdinSub;
  if (http != null) {
    stdinSub = stdin.listen(
      (_) {},
      onDone: _wireServeSettle!,
      onError: (Object error) {
        stderr.writeln('wire-serve: stdin failed: $error');
        _wireServeSettle!();
      },
    );
  }
  try {
    final code = await cli.runWireServe(
      onReady: http == null
          ? null
          : () => writeStartupLine(
              WireServeStartupLine(port: http!.port, token: token),
            ),
      serve: (server) async {
        if (wireServe.stdio) {
          final done = serveStdio(server);
          // stdin EOF is the natural end; a signal-completed shutdown
          // must ALSO end the serve, or the graceful teardown waits out
          // its full settle window and the persist never runs (review
          // #1113 r2, #3).
          await Future.any([shutdown.future, done]);
          // The race's loser still runs — surface a late transport
          // failure (e.g. EPIPE on stdout mid-teardown) instead of the
          // silent drop a bare `ignore()` would be (review #1113 r4).
          unawaited(
            done.catchError((Object error) {
              stderr.writeln('wire-serve: stdio transport failed: $error');
            }),
          );
          return;
        }
        final listenDone = httpListen(http!, server, token);
        await Future.any([shutdown.future, listenDone]);
        await http!.close(force: true);
      },
      onDiagnostic: (line) => stderr.writeln(line),
    );
    // Resume hint on stderr — stdout is the protocol channel.
    final hint = await cli.sessionResumeHint();
    if (hint != null) stderr.writeln(hint);
    return code;
  } finally {
    _wireServeSettle = null;
    await stdinSub?.cancel();
    await http?.close(force: true);
  }
}

/// The wire-serve CLI io: a silent sink. Every rendered line dies here so
/// nothing TUI-shaped can reach the protocol stream; writeln keeps stderr
/// for diagnostics. Never interactive — the constructor's null ask/secret
/// callbacks are replaced by the wire surfaces at boot.
final class _WireServeSilentCliIO implements CliIO {
  final _interrupts = StreamController<void>.broadcast();

  @override
  Stream<String> get lines => const Stream<String>.empty();

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  bool get isInteractive => false;

  @override
  int get columns => 80;

  @override
  int get rows => 24;

  @override
  void write(String text) {}

  @override
  void writeln(String text) => stderr.writeln(text);
}
