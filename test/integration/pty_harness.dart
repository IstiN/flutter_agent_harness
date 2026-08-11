/// PTY-based integration test harness for the Fa CLI.
///
/// Spawns `dart run bin/fah.dart` as a real subprocess attached to a
/// pseudo-terminal (via package:pty2), feeds every output byte into an xterm
/// terminal emulator (the vendored package:xterm), and exposes keystroke
/// sending plus quiescent-poll output capture.
///
/// pty2 0.5.3 API notes (this file is the canonical reference):
/// - `PseudoTerminal.start(executable, args, workingDirectory:, environment:,
///   raw:)` — no columns/rows parameters; the PTY starts at 80x20 and is
///   sized with `pty.resize(columns, rows)` immediately after start.
/// - `pty.out` is a `Stream<String>` (already UTF-8 decoded,
///   malformed-tolerant) — there is no byte stream.
/// - `pty.write(String)` — keystrokes go in as Dart strings with escapes
///   (`'\r'`, `'\x1b[A'`).
/// - `raw: true` puts the slave into raw mode from the start (no canonical
///   line buffering, no kernel echo, no ISIG), so arrow keys and Ctrl+C
///   reach the CLI as bytes.
/// - The child environment inherits ONLY TERM/LANG/LOGNAME/USER/DISPLAY/
///   LC_TYPE/HOME/PATH from the parent plus whatever `environment:` adds —
///   so `PUB_CACHE` must be passed through explicitly when HOME is
///   overridden (otherwise `dart run` cannot see the pub cache), and API
///   keys from the developer's real environment never leak into tests.
library;

import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

/// Spawns the Fa CLI as a subprocess with a PTY, feeds output to an xterm
/// terminal emulator, and provides keystroke sending + output capture.
final class FaCliHarness {
  FaCliHarness._({
    required this.pty,
    required this.terminal,
    required this.columns,
    required this.rows,
  });

  /// Spawns the Fa CLI with a PTY of fixed size.
  ///
  /// [args] are extra CLI arguments (e.g., `['--model', 'test-model']`).
  /// [extraEnv] overrides env vars (e.g., `{'HOME': tempHome.path}`).
  ///
  /// The output listener starts immediately inside spawn (data arriving
  /// before [startListening] would otherwise be lost on the
  /// single-subscription stream); calling [startListening] afterwards is a
  /// harmless no-op kept for readability at call sites.
  static Future<FaCliHarness> spawn({
    String? workingDirectory,
    Map<String, String>? extraEnv,
    List<String> args = const [],
    int columns = 80,
    int rows = 24,
  }) async {
    final env = <String, String>{
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      // `dart run` resolves packages from the pub cache, which lives under
      // the REAL home; pty2 only forwards a fixed env whitelist, so pass it
      // explicitly. Without this a HOME override breaks package resolution.
      if (Platform.environment['PUB_CACHE'] != null)
        'PUB_CACHE': Platform.environment['PUB_CACHE']!,
      ...?extraEnv,
    };
    final pty = PseudoTerminal.start(
      'dart',
      ['run', 'bin/fah.dart', ...args],
      workingDirectory: workingDirectory ?? Directory.current.path,
      environment: env,
      raw: true,
    );
    // The PTY starts at 80x20 (pty2 default); size it to the requested
    // geometry before the CLI finishes booting.
    pty.resize(columns, rows);
    final terminal = Terminal(maxLines: rows * 4);
    if (columns != 80 || rows != 24) terminal.resize(columns, rows);
    final harness = FaCliHarness._(
      pty: pty,
      terminal: terminal,
      columns: columns,
      rows: rows,
    );
    harness.startListening();
    // Answer the CLI's terminal queries (device attributes etc.) so it
    // does not wait out a response timeout on every boot.
    terminal.onOutput = pty.write;
    return harness;
  }

  /// The pseudo-terminal running the CLI process.
  final PseudoTerminal pty;

  /// The xterm terminal emulator — receives all PTY output.
  final Terminal terminal;

  /// The PTY width in columns.
  final int columns;

  /// The PTY height in rows.
  final int rows;

  /// Accumulated raw output (with ANSI escape sequences).
  final _rawBuffer = StringBuffer();

  var _listening = false;

  /// Starts listening to PTY output, feeding both [_rawBuffer] and
  /// [terminal]. Called automatically by [spawn]; idempotent.
  void startListening() {
    if (_listening) return;
    _listening = true;
    pty.out.listen((text) {
      _rawBuffer.write(text);
      terminal.write(text);
    });
  }

  /// Sends text (arrives as keystrokes on the raw PTY).
  void sendText(String text) => pty.write(text);

  /// Sends Enter (CR — dart_tui maps both CR and LF to 'enter').
  void sendEnter() => pty.write('\r');

  /// Sends Escape.
  void sendEscape() => pty.write('\x1b');

  /// Sends Backspace.
  void sendBackspace() => pty.write('\x7f');

  /// Sends Ctrl+C.
  void sendCtrlC() => pty.write('\x03');

  /// Sends Arrow Up.
  void sendArrowUp() => pty.write('\x1b[A');

  /// Sends Arrow Down.
  void sendArrowDown() => pty.write('\x1b[B');

  /// Waits for the REPL boot to finish: the banner's `[Model]` block is on
  /// screen and the frame redraws have settled.
  ///
  /// NOTE: in TUI mode the input zone renders NO `fa> ` prefix (that prompt
  /// string is line-mode only) — the banner + status line are the reliable
  /// boot markers.
  Future<String> waitForBoot({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final output = await waitForText('[Model]', timeout: timeout);
    // The TUI repaints the full frame once more after its terminal
    // capability queries resolve; let that settle before interacting.
    await waitForOutput(settleMs: 400, timeout: const Duration(seconds: 15));
    return output;
  }

  /// Types [command] and submits it, closing the slash menu first.
  ///
  /// In TUI mode, typing a bare slash command opens the slash-completion
  /// menu, where Enter only ACCEPTS the highlighted item instead of
  /// submitting. Sending Escape first closes the menu so the Enter that
  /// follows always submits the typed text. Commands with arguments
  /// (e.g. `/approval always-ask`) close the menu on their own while
  /// typing; the extra Escape is a harmless no-op then.
  Future<void> runSlashCommand(String command) async {
    sendText(command);
    // Let the slash menu open between the last keystroke and Escape.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    sendEscape();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sendEnter();
  }

  /// Reads output until no new data arrives for [settleMs] milliseconds
  /// twice in a row, or [timeout] expires. Returns the accumulated raw
  /// output.
  Future<String> waitForOutput({
    int settleMs = 200,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var lastLength = -1;
    var stableTurns = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(milliseconds: settleMs));
      if (_rawBuffer.length == lastLength) {
        if (++stableTurns >= 2) break;
      } else {
        stableTurns = 0;
        lastLength = _rawBuffer.length;
      }
    }
    return _rawBuffer.toString();
  }

  /// Waits for [pattern] to appear in the accumulated raw output OR on the
  /// current terminal screen, then returns the raw output. The screen check
  /// catches text whose raw form is interrupted by ANSI styling.
  Future<String> waitForText(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final output = _rawBuffer.toString();
      if (output.contains(pattern) || screenText.contains(pattern)) {
        return output;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
      'Timed out waiting for "$pattern" in output.\n--- screen ---\n'
      '$screenText\n--- raw tail ---\n${_rawTail()}',
      timeout,
    );
  }

  /// The last 2000 characters of raw output, for timeout diagnostics.
  String _rawTail() {
    final raw = _rawBuffer.toString();
    return raw.length <= 2000 ? raw : raw.substring(raw.length - 2000);
  }

  /// Every line of the visible viewport (blank lines kept, trailing
  /// whitespace preserved) — the layout-faithful view for screenshots.
  List<String> get viewportLines {
    final lines = <String>[];
    final buf = terminal.buffer;
    for (var i = buf.scrollBack; i < buf.lines.length; i++) {
      lines.add(buf.lines[i].getText());
    }
    return lines;
  }

  /// The terminal screen as text lines (ANSI-stripped, empty lines dropped).
  List<String> get screenLines => [
    for (final line in viewportLines)
      if (line.trim().isNotEmpty) line,
  ];

  /// The terminal screen as a single string (newline-separated lines).
  String get screenText => screenLines.join('\n');

  /// Kills the CLI process and waits for it to exit.
  Future<void> close() async {
    pty.kill();
    await pty.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }
}
