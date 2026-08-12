/// PTY + real [TerminalView] harness for Fa CLI visual tests.
///
/// Spawns `dart bin/fah.dart` as a real subprocess attached to a
/// pseudo-terminal (via package:pty2), feeds every output byte into an xterm
/// [Terminal], and renders screenshots through the REAL Flutter
/// [TerminalView] widget with the bundled JetBrainsMono font — the same
/// rendering pipeline a Flutter terminal app (e.g. YoLoIT) uses, so the
/// PNGs show exactly what a user sees: real glyphs, real box-drawing, real
/// colors. No hand-rolled rasterizer.
///
/// Async discipline: PTY I/O and wait loops are real-async, so they MUST run
/// inside `tester.runAsync` (flutter_test otherwise freezes timers in the
/// fake zone). Every waiting method of this harness wraps itself via
/// [_live]; widget pumping stays in the normal zone. Test bodies never call
/// `tester.runAsync` directly.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

/// Fa dark terminal palette (matches `lib/src/cli/fa_tui.dart`).
const faTerminalTheme = TerminalTheme(
  cursor: Color(0xFF5EEAD4),
  selection: Color(0x555EEAD4),
  foreground: Color(0xFFE8EEF7),
  background: Color(0xFF070A10),
  black: Color(0xFF000000),
  red: Color(0xFFF87171),
  green: Color(0xFF22C55E),
  yellow: Color(0xFFFACC15),
  blue: Color(0xFF3B82F6),
  magenta: Color(0xFFA855F7),
  cyan: Color(0xFF5EEAD4),
  white: Color(0xFFFFFFFF),
  brightBlack: Color(0xFF64748B),
  brightRed: Color(0xFFFF8A80),
  brightGreen: Color(0xFF34D399),
  brightYellow: Color(0xFFFEBC2E),
  brightBlue: Color(0xFF818CF8),
  brightMagenta: Color(0xFFC084FC),
  brightCyan: Color(0xFF5EEAD4),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFF3B82F6),
  searchHitBackgroundCurrent: Color(0xFF5EEAD4),
  searchHitForeground: Color(0xFF070A10),
);

/// Text style for the terminal surface: the app's bundled JetBrainsMono,
/// loaded by `ensureGoldenFonts()`.
const faTerminalStyle = TerminalStyle(fontFamily: 'JetBrainsMono');

/// The Fa CLI running in a PTY, mirrored into an xterm [Terminal].
final class CliVisualHarness {
  CliVisualHarness._({required this.pty, required this.terminal});

  /// Spawns the Fa CLI with a PTY. The PTY starts at pty2's default size;
  /// [pumpTerminalView] resizes it to the real view size before boot
  /// completes, so the CLI draws its first frame at the final geometry.
  ///
  /// [repoRoot] is the flutter_agent repo root (the CLI's working
  /// directory). [extraEnv] overrides env vars (e.g. `{'HOME': tempHome}`).
  static Future<CliVisualHarness> spawn({
    required String repoRoot,
    Map<String, String>? extraEnv,
    List<String> args = const [],
  }) async {
    final env = <String, String>{
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      // `dart` resolves packages from the pub cache, which lives under the
      // REAL home; pty2 only forwards a fixed env whitelist, so pass it
      // explicitly. Without this a HOME override breaks package resolution.
      if (Platform.environment['PUB_CACHE'] != null)
        'PUB_CACHE': Platform.environment['PUB_CACHE']!,
      ...?extraEnv,
    };
    final pty = PseudoTerminal.start(
      'dart',
      // `dart bin/fah.dart`, NOT `dart run ...`: `dart run` spawns a
      // separate child VM that escapes pty.kill() and keeps the PTY (and
      // the whole test run) alive. Direct execution runs in-process, so
      // kill() in close() actually terminates the CLI.
      ['bin/fah.dart', ...args],
      workingDirectory: repoRoot,
      environment: env,
      raw: true,
    );
    final harness = CliVisualHarness._(
      pty: pty,
      terminal: Terminal(maxLines: 200),
    );
    harness.startListening();
    // Answer the CLI's terminal queries (device attributes etc.) so it
    // does not wait out a response timeout on every boot.
    harness.terminal.onOutput = pty.write;
    return harness;
  }

  /// The pseudo-terminal running the CLI process.
  final PseudoTerminal pty;

  /// The xterm terminal emulator — receives all PTY output.
  final Terminal terminal;

  /// The widget tester driving the [TerminalView]; set by [attach].
  late final WidgetTester _tester;

  final _boundaryKey = GlobalKey();

  /// Accumulated raw output (with ANSI escape sequences).
  final _rawBuffer = StringBuffer();

  var _listening = false;
  StreamSubscription<String>? _outputSub;

  /// Binds the harness to the test's [WidgetTester]. Call once per test,
  /// right after [spawn].
  void attach(WidgetTester tester) => _tester = tester;

  /// Runs [body] in the real-async zone (PTY I/O and timer-based waits
  /// freeze in the widget test's fake zone). runAsync returns T?; every
  /// body here returns a value, so the null case cannot happen.
  Future<T> _live<T>(Future<T> Function() body) async =>
      (await _tester.runAsync(body)) as T;

  /// Starts listening to PTY output, feeding both [_rawBuffer] and
  /// [terminal]. Called automatically by [spawn]; idempotent.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _outputSub = pty.out.listen((text) {
      _rawBuffer.write(text);
      terminal.write(text);
    });
  }

  /// Pumps the [TerminalView] into the test surface and resizes the PTY to
  /// the geometry the view actually computed (autoResize measures the
  /// JetBrainsMono cell size), so the CLI redraws at exactly the size the
  /// screenshots show. Call right after [spawn] — BEFORE [waitForBoot] — so
  /// the CLI's first frame already lands at the final size.
  Future<void> pumpTerminalView() async {
    _tester.view.physicalSize = const Size(1040, 600);
    _tester.view.devicePixelRatio = 1.0;
    addTearDown(_tester.view.reset);
    await _tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: faTerminalTheme.background,
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: RepaintBoundary(
              key: _boundaryKey,
              child: TerminalView(
                terminal,
                theme: faTerminalTheme,
                textStyle: faTerminalStyle,
                readOnly: true,
                // Respect the app's cursor visibility (?25h/?25l): with
                // alwaysShowCursor the view would paint a cursor even where
                // the CLI deliberately hides it (prompt/picker focus).
                // Focus is needed for the cursor to paint at all (idle
                // input), so autofocus stays on.
                autofocus: true,
                hardwareKeyboardOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
    // First pump lays out; the view's autoResize reports the cell-fit size
    // to the terminal on the next frame.
    await _tester.pump();
    await _tester.pump();
    pty.resize(terminal.viewWidth, terminal.viewHeight);
  }

  /// Renders the current terminal screen to `<dir>/<name>.png` (2x pixels)
  /// plus a `<name>.txt` twin with the exact screen text — the xterm buffer
  /// is the source of truth, so the text twin lets anyone verify content
  /// without reading pixels.
  Future<void> screenshot(String dir, String name) async {
    await _live(
      () => waitForOutput(settleMs: 300, timeout: const Duration(seconds: 5)),
    );
    await _tester.pump();
    final bytes = await _live(() async {
      final boundary =
          _boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    File('$dir/$name.png').writeAsBytesSync(bytes!);
    File('$dir/$name.txt').writeAsStringSync(screenText);
  }

  /// Sends text (arrives as keystrokes on the raw PTY).
  void sendText(String text) => pty.write(text);

  /// Sends Enter (CR — dart_tui maps both CR and LF to 'enter').
  void sendEnter() => pty.write('\r');

  /// Sends Escape.
  void sendEscape() => pty.write('\x1b');

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
    final output = await _live(() => waitForText('[Model]', timeout: timeout));
    // The TUI repaints the full frame once more after its terminal
    // capability queries resolve; let that settle before interacting.
    await _live(
      () => waitForOutput(settleMs: 400, timeout: const Duration(seconds: 15)),
    );
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
    await _live(() async {
      sendText(command);
      // Let the slash menu open between the last keystroke and Escape.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      sendEscape();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sendEnter();
    });
  }

  /// Waits for [pattern] (real-async wrapped) — the variant test bodies
  /// must use; plain [waitForText] would freeze in the fake zone.
  Future<String> liveWaitForText(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 10),
  }) => _live(() => waitForText(pattern, timeout: timeout));

  /// Lets pending output settle (real-async wrapped) — the variant test
  /// bodies must use; plain [waitForOutput] would freeze in the fake zone.
  Future<String> settle({
    int settleMs = 200,
    Duration timeout = const Duration(seconds: 10),
  }) => _live(() => waitForOutput(settleMs: settleMs, timeout: timeout));

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

  /// Kills the CLI process, cancels the output subscription (otherwise an
  /// open stream keeps the test runner's event loop alive), and waits for
  /// the process to exit.
  Future<void> close() async {
    await _live(() async {
      pty.kill();
      await pty.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      await _outputSub?.cancel();
    });
  }
}
