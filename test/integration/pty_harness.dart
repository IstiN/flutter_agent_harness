/// PTY-based integration test harness for the Fa CLI.
///
/// Spawns `dart bin/fah.dart` as a real subprocess attached to a
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
/// - `raw: true` (the default) puts the slave into raw mode from the start
///   (no canonical line buffering, no kernel echo, no ISIG), so arrow keys
///   and Ctrl+C reach the CLI as bytes.
/// - `raw: false` keeps the kernel DEFAULT termios — ICRNL stays on, so the
///   line discipline rewrites a master-written CR to LF before the child
///   reads it. This is what real PTY hosts (IDE embedded terminals) do to
///   the wire; the newline-wire suite must run under it too (issue #77).
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

/// The visible viewport with each line's trailing blank cells stripped —
/// the CONTENT-faithful view for cross-frame equality (gh-982).
///
/// The two dart_tui paint paths disagree about row tails
/// (vendor/dart_tui/lib/src/renderer.dart): the scroll fast path ends
/// every painted row with an erase (`_paintRow` → `CSI K`; the emulator's
/// erased cells become empty and vanish from `BufferLine.getText`), while
/// the cell-diff path (`_diffAndEmit`) writes only changed cells and never
/// erases the tail — whatever an earlier full repaint materialized there
/// (explicit space cells) stays. Which history a logical row carries
/// depends on the renderer's frame-shift heuristics, i.e. on platform
/// timing: macOS/fa-m5 and linux produced different histories for the
/// same scenario and the frozen `· older` board row failed a raw list
/// equality despite byte-identical counts. Raw [FaCliHarness.viewportLines]
/// equality is only valid for genuinely full-width rows (the composer
/// rule); compare content frames for everything else.
List<String> frameContentLines(List<String> viewport) =>
    [for (final line in viewport) line.trimRight()];

/// Spawns the Fa CLI as a subprocess with a PTY, feeds output to an xterm
/// terminal emulator, and provides keystroke sending + output capture.
final class FaCliHarness {
  FaCliHarness._(
    this.pty,
    this.terminal,
    this.columns,
    this.rows,
    this._ownedCwd,
  );

  /// The spawn-created default CWD (null when the caller passed
  /// [spawn]'s `workingDirectory` — then nothing is owned or cleaned).
  Directory? _ownedCwd;

  /// Short per-spawn CWD used when the caller does not pin [spawn]'s
  /// workingDirectory. The CLI derives its session slug from the CWD, and on
  /// CI runners the checkout path is so long that the boot banner
  /// (`/Users/.../flutter_agent_harness` + the `.fah/sessions/<slug>` block)
  /// wraps over a dozen rows and floods an 80x24 frame — fa-m5-3's slug
  /// alone ate 6 rows, hiding the credential sheet and half the job board
  /// from the assertions. Suites that need a specific CWD pass it
  /// explicitly; package resolution stays on the repo either way (the
  /// script path is absolute).
  ///
  /// Unique per spawn (issue #931 part 3.1, harness piece): every test gets
  /// its own root, so the in-suite `--concurrency=4` (part 3.3) can never
  /// race two CLIs through one shared git-init/config-write directory (the
  /// #936 incident class). The full session/dir-race program stays in #948.
  static Directory _shortDefaultCwd() {
    final dir = Directory.systemTemp.createTempSync('fa_pty_cwd_');
    // Match the checkout's shape: the CLI's git-root discovery (and the
    // lib/src/cli branches behind it) only runs inside a repository. With a
    // bare tmp dir those paths go unexercised and the cli coverage ratchet
    // (baseline only up) regresses (~0.2pp observed on fa-m5). Fail loudly:
    // a silent bare-dir fallback would quietly degrade every test on the
    // runner instead of one.
    final git = Process.runSync('git', ['init', '-q', dir.path]);
    if (git.exitCode != 0) {
      throw StateError('git init failed for harness cwd ${dir.path}: ${git.stderr}');
    }
    return dir;
  }

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
    int? vmServicePort,
    bool raw = true,
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
    // FA_BIN (test-only seam): run a prebuilt binary (e.g. the AOT bundle
    // from `dart build cli`) instead of JIT `dart bin/fah.dart` — perf
    // probes must measure what install_local.sh actually ships.
    // Own the default CWD when the caller did not pin one, so close()/
    // hardKill() can remove it (review #963: a fresh git-init'd root per
    // spawn must not accumulate across runs on persistent hosts).
    final ownedCwd = workingDirectory == null ? _shortDefaultCwd() : null;
    final faBin = extraEnv?['FA_BIN'];
    final pty = PseudoTerminal.start(
      faBin ?? 'dart',
      // Absolute script path so a non-default [workingDirectory] still
      // resolves the repo's binary (folder-scoping tests launch fa in
      // temp dirs while package resolution stays on the repo).
      [
        if (faBin == null) ...[
          // VM flags go BEFORE the script path.
          if (vmServicePort != null) ...[
            '--disable-service-auth-codes',
            '--observe=$vmServicePort',
          ],
          '${Directory.current.path}/bin/fah.dart',
        ],
        ...args,
      ],
      workingDirectory: ownedCwd?.path ?? workingDirectory,
      environment: env,
      raw: raw,
    );
    // The PTY starts at 80x20 (pty2 default); size it to the requested
    // geometry before the CLI finishes booting.
    pty.resize(columns, rows);
    final terminal = Terminal(maxLines: rows * 4);
    if (columns != 80 || rows != 24) terminal.resize(columns, rows);
    final harness = FaCliHarness._(
      pty,
      terminal,
      columns,
      rows,
      ownedCwd,
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

  /// All raw bytes written by the CLI so far (ANSI escape sequences
  /// preserved), exposed for terminal-reset assertions.
  String get rawOutput => _rawBuffer.toString();

  var _listening = false;
  StreamSubscription<String>? _outputSub;

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

  /// Sends text (arrives as keystrokes on the raw PTY).
  void sendText(String text) => pty.write(text);

  /// Sends Enter (CR — dart_tui maps both CR and LF to 'enter').
  void sendEnter() => pty.write('\r');

  /// Sends Escape.
  void sendEscape() => pty.write('\x1b');

  /// Sends Ctrl+S — the TUI's steer gesture while busy (steers the
  /// queued follow-ups into the running agent).
  void sendCtrlS() => pty.write('\x13');

  /// Sends Backspace.
  void sendBackspace() => pty.write('\x7f');

  /// Kills the CLI with SIGKILL and reaps it — a real crash (no graceful
  /// exit, no boundary work). Use when the test needs the exact
  /// process-death residue (issue #437 phase 2).
  Future<void> hardKill() async {
    pty.kill(ProcessSignal.sigkill);
    await pty.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    await _outputSub?.cancel();
    _releaseOwnedCwd();
  }

  /// Removes the spawn-created default CWD, if any. Best-effort and
  /// idempotent: teardown must never break because a file inside stayed
  /// locked (the CLI or a child agent may still hold an fd); a left-behind
  /// directory is preferable to masking a real test failure.
  void _releaseOwnedCwd() {
    final dir = _ownedCwd;
    if (dir == null) return;
    _ownedCwd = null;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Left behind on purpose.
    }
  }

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

  /// Waits for [pattern] to appear on the CURRENT terminal screen — the
  /// painted viewport, not the raw stream. `waitForText` also matches raw
  /// bytes, which races frame painting on loaded CI runners: the echo hits
  /// the raw buffer first and an immediate `expect(screenText, …)` still
  /// sees the previous frame (#550/#557 flake family). Use this when the
  /// assertion contract is the SCREEN.
  Future<String> waitForScreen(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final screen = screenText;
      if (screen.contains(pattern)) return screen;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
      'Timed out waiting for "$pattern" on screen.\n--- screen ---\n'
      '$screenText\n--- raw tail ---\n${_rawTail()}',
      timeout,
    );
  }

  /// The last 2000 characters of raw output, for timeout diagnostics.
  String get rawTail => _rawTail();

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

  /// [viewportLines] with each line's trailing blank cells stripped —
  /// the CONTENT-faithful view for cross-frame equality (gh-982).
  List<String> get viewportContentLines => frameContentLines(viewportLines);

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
    pty.kill();
    await pty.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    await _outputSub?.cancel();
    _releaseOwnedCwd();
  }
}
