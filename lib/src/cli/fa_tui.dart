import 'dart:async';
import 'dart:math' as math;
import 'dart:convert' show latin1, utf8;
import 'dart:io'
    show IOSink, Platform, Process, ProcessException, ProcessResult, stdin;

import 'package:dart_tui/dart_tui.dart';

import 'ansi_markdown.dart';
import 'tui_prompt.dart';
import 'tui_repl.dart' show MenuItem, TuiProgramHooks;
import 'system_notice_render.dart';
import 'tui_text_width.dart' show tuiFitWidth, tuiPadRight, tuiTextWidth;

/// Translates the (web-safe) headless test hooks into dart_tui program
/// options: a scripted key byte stream replaces stdin, the rendered frames
/// go to the given byte consumer, and the OS signal handler stays off (the
/// test runner owns the signals). Empty without hooks.
List<ProgramOption> _programHookOptions(TuiProgramHooks? hooks) {
  if (hooks == null) return const [];
  return [
    if (hooks.input != null) withInput(hooks.input),
    if (hooks.output != null) withOutput(IOSink(hooks.output!)),
    withoutSignalHandler(),
  ];
}

/// The site palette (site/styles.css): a teal accent (#5eead4) and an indigo
/// accent-2 (#818cf8) on a dark background. Width math in the view always
/// uses the raw strings — escapes are added only at write time.
String _accent(String s) => '\x1b[1m\x1b[38;2;94;234;212m$s\x1b[0m';
String _accent2(String s) => '\x1b[1m\x1b[38;2;129;140;248m$s\x1b[0m';
String _accent2Plain(String s) => '\x1b[38;2;129;140;248m$s\x1b[0m';
String _dim(String s) => '\x1b[2m$s\x1b[0m';

/// Host callbacks supplied by [AgentCli] to the dart_tui REPL.
final class FaTuiCallbacks {
  const FaTuiCallbacks({
    required this.onSubmit,
    required this.onModelSelected,
    required this.buildSlashMenu,
    required this.buildModelMenu,
    required this.statusLine,
    required this.prompt,
    this.onInterrupt,
    this.isShiftPressed,
    this.opensPicker,
    this.onPickerSelected,
    this.onPickerCancelled,
    this.onSteer,
  });

  /// Called when the user submits a non-empty input line.
  final Future<void> Function(String line) onSubmit;

  /// Called when the user picks a model from the picker.
  final Future<void> Function(String modelId) onModelSelected;

  /// Builds slash-command menu items for the given prefix.
  final List<MenuItem> Function(String prefix) buildSlashMenu;

  /// Builds model-picker menu items for the given filter.
  final List<MenuItem> Function(String filter) buildModelMenu;

  /// One-line status shown above the input line.
  final String Function() statusLine;

  /// The input prompt (e.g. `fa> `).
  final String prompt;

  /// Called on Ctrl-C while the agent is busy.
  final void Function()? onInterrupt;

  /// Host-provided Shift modifier check (e.g. macOS Core Graphics via FFI).
  /// When null, Shift+Enter is not specially handled.
  final bool Function()? isShiftPressed;

  /// Slash commands that open a host-side picker when accepted from the
  /// command menu (e.g. `/sessions`, `/mode`, `/approval`): the command is
  /// submitted immediately instead of being filled into the input.
  final bool Function(String key)? opensPicker;

  /// Called when a generic picker (opened via [FaTuiController.openPicker])
  /// resolves — [pickerId] identifies which picker, [key] the chosen item.
  final Future<void> Function(String pickerId, String key)? onPickerSelected;

  /// Called when a generic picker is dismissed with Esc without a selection
  /// (wizard flows wait on the answer and must not hang). The models picker
  /// never reports here (Esc there is plain "close").
  final void Function(String pickerId)? onPickerCancelled;

  /// Called to steer messages into the RUNNING agent (Ctrl+S while busy,
  /// kimi-cli semantics): each message is injected as a separate user
  /// message mid-turn.
  final Future<void> Function(List<String> messages)? onSteer;
}

/// Message carrying host output into the TUI.
final class OutputMsg extends Msg {
  OutputMsg(this.text, {this.newline = false});

  final String text;
  final bool newline;
}

/// Message replacing the composer text (the `/skills` menu prefills
/// `/skill:<name> ` so the user can add arguments before sending).
final class _SetInputTextMsg extends Msg {
  _SetInputTextMsg(this.text);
  final String text;
}

/// Message asking the model picker to refresh its items.
final class _ModelsRefreshMsg extends Msg {}

/// Message asking the model picker to open.
final class _OpenModelMenuMsg extends Msg {}

/// Message opening a generic host picker (sessions, mode, approval, ...).
final class OpenPickerMsg extends Msg {
  OpenPickerMsg(this.pickerId, this.title, this.items, {this.initialIndex = 0});
  final String pickerId;
  final String title;
  final List<MenuItem> items;

  /// The initially highlighted item (wizard prefills).
  final int initialIndex;
}

/// Message asking the program to quit because the host marked exit.
final class _QuitRequestedMsg extends Msg {}

/// Message toggling the busy ("thinking") indicator while a run streams.
final class BusyMsg extends Msg {
  const BusyMsg(this.busy, {this.phase, this.source});

  /// `true` starts a busy stretch, `false` ends it.
  final bool busy;

  /// Silent post-answer phase label ("Compacting context…"). Non-null on an
  /// ALREADY-busy message means relabel-only: the spinner chain and the
  /// elapsed window stay untouched.
  final String? phase;

  /// Who armed/released the row ('run', 'submit', …) — rendered next to the
  /// label and logged on every transition so a wedged row names its owner.
  final String? source;
}

/// Busy-row forensic sink: the host (agent_cli) points this at its
/// diagnostic log so every arm/release/relabel/drop/watchdog-fire is
/// attributable — the answer to "who left Working… on".
void Function(String line)? faTuiBusyDiagnostics;

/// Internal spinner-frame tick; re-scheduled while the model stays busy.
final class SpinnerTickMsg extends Msg {}

/// Message draining the queued messages (kimi-cli semantics: after a run
/// settles the host takes them one-by-one as separate turns). The model
/// echoes them into the history before clearing.
final class DrainQueueMsg extends Msg {
  DrainQueueMsg(this.completer);
  final Completer<List<String>> completer;
}

/// Message opening the interactive prompt zone (ask/secret/approval).
final class OpenPromptMsg extends Msg {
  OpenPromptMsg(this.spec, this.completer);
  final TuiPromptSpec spec;
  final Completer<TuiPromptAnswer?> completer;
}

/// The braille spinner frames cycled while [FaTuiModel.busy] is set.
const _spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// Memoized markdown+wrap pass over [FaTuiModel.outputLines]. Formatting is
/// O(transcript) (regex-heavy markdown plus ANSI-safe wrapping) and used to
/// run two to four times PER event (update handler, `_stickyActive`, view),
/// which made wheel scrolling and streaming visibly stutter. The result is
/// shared across model copies and recomputed only when the source list
/// (identity — every mutation path builds a new list) or the width changes,
/// so scrolling and re-renders stay O(1) in markdown work. [lineStartRows]
/// maps a raw line index to its first physical row so the sticky echo math
/// is O(1) as well.
final class _WrapCache {
  /// The [FaTuiModel.outputLines] instance the pass ran on.
  List<String>? source;
  int width = -1;
  List<String> rows = const [];

  /// `lineStartRows[i]` = first wrapped row of raw line `i`; the final entry
  /// is the total row count (sentinel for end-of-buffer calculations).
  List<int> lineStartRows = const [0];

  /// The persistent incremental formatter bound to [width]. An append now
  /// costs O(delta) instead of one full markdown+wrap pass over the whole
  /// bounded history on every coalesced streaming flush — measured at
  /// 26.96 ms/pass over a 2000-line history before this (see
  /// docs/performance-cli-tui.md). A width change starts a fresh session;
  /// its rebuild path IS the legacy byte-exact pass.
  TranscriptMarkdown? _tx;
}

/// Physical rows in [s] — identical to `s.split('\n').length`, minus the
/// per-frame `List<String>` allocation. Used by the view assembly for cursor
/// row math on every rendered frame.
int _lineCount(String s) {
  var n = 1;
  var start = 0;
  for (;;) {
    final i = s.indexOf('\n', start);
    if (i < 0) break;
    n++;
    start = i + 1;
  }
  return n;
}

/// Sentinel for nullable copyWith fields (distinguishes "keep" from "set
/// null").
const Object _unset = Object();

/// The dart_tui model backing the Fa interactive REPL.
final class FaTuiModel extends Model {
  FaTuiModel({
    required this.callbacks,
    required this.isExited,
    this.prompt,
    this.outputLines = const [],
    this.inputText = '',
    this.cursor = 0,
    this.scrollOffset = 0,
    this.followTail = true,
    this.menuOpen = false,
    this.menuModelMode = false,
    this.menuSelected = 0,
    this.modelFilter = '',
    this.menuItems = const [],
    this.menuAllItems = const [],
    this.pickerId = '',
    this.pickerTitle = '',
    this.termWidth = 80,
    this.termHeight = 24,
    this.busy = false,
    this.busyStartedAtMs = -1,
    this.busyPhase = '',
    this.busySource = '',
    this.busyLastEventMs = -1,
    this.mouseCapture = true,
    this.spinnerFrame = 0,
    this.stickyLines = const [],
    this.stickyIndex = -1,
    this.stickyEchoLineCount = 0,
    this.queue = const [],
    this.inputHistory = const [],
    this.historyIndex = -1,
    this.historyDraft,
    this.frameNonce = 0,
  });

  final FaTuiCallbacks callbacks;
  final bool Function() isExited;

  /// The interactive prompt zone (ask/secret/approval) rendered in place of
  /// the input zone while the agent needs a decision from the user; null
  /// outside prompt mode.
  final TuiPromptState? prompt;

  /// Completer for the active prompt zone, filled when it resolves so the
  /// host's [FaTuiController.openPrompt] future can complete.
  Completer<TuiPromptAnswer?>? _promptCompleter;

  final List<String> outputLines;
  final String inputText;
  final int cursor;

  /// Persistent viewport scroll offset (0 = top). Snapped to the bottom on
  /// new output while [followTail] holds; kept (clamped) otherwise.
  final int scrollOffset;

  /// Auto-follow latch: new output snaps the viewport to the bottom. Only
  /// USER scrolling changes it (wheel/arrows detach, scrolling back to the
  /// exact bottom re-attaches) — transient viewport shrinkage (picker menu,
  /// busy row, queue) must NOT detach it, which the old per-event
  /// `offset >= bottom` check got wrong: opening a picker broke follow
  /// until the user scrolled to the bottom by hand.
  final bool followTail;
  final bool menuOpen;
  final bool menuModelMode;
  final int menuSelected;
  final String modelFilter;
  final List<MenuItem> menuItems;

  /// The picker's full unfiltered item list — the local type-to-filter base
  /// for generic pickers (the `models` picker rebuilds via
  /// [FaTuiCallbacks.buildModelMenu] instead). Empty outside picker mode.
  final List<MenuItem> menuAllItems;

  /// Identifies the active picker: 'models' for the model picker (typing
  /// filters via [FaTuiCallbacks.buildModelMenu]), anything else for a
  /// generic host picker (static items, selection via
  /// [FaTuiCallbacks.onPickerSelected]). Empty outside picker mode.
  final String pickerId;
  final String pickerTitle;
  final int termWidth;
  final int termHeight;

  /// Whether a run is streaming; drives the animated thinking indicator.
  final bool busy;

  /// When the current busy stretch started (epoch ms; -1 while idle) — the
  /// busy row shows the elapsed seconds so a wedged endpoint is visible
  /// instead of looking like a frozen UI.
  final int busyStartedAtMs;

  /// Post-answer phase label overriding the generic "Working…" while set
  /// ("Compacting context…", "Extracting memory…"); cleared whenever a
  /// busy stretch ends so the next run starts generic.
  final String busyPhase;

  /// Provenance tag of the current busy stretch ('run', 'submit', …).
  final String busySource;

  /// Last activity timestamp while busy (any non-tick message). Feeds the
  /// "quiet Nm" hint and the watchdog.
  final int busyLastEventMs;

  /// Whether the TUI captures the mouse (wheel scrolling) instead of
  /// leaving it to the terminal's native text selection. Default on: the
  /// session lives in the alternate screen with no terminal scrollback, so
  /// without capture a two-finger scroll does nothing. Selection still
  /// works through the bypass modifier (Shift); `FA_TUI_MOUSE=0` opts out.
  final bool mouseCapture;
  final int spinnerFrame;

  /// The last submitted user echo (rule + first input line), pinned to the
  /// top of the viewport while a run streams and the echo itself has
  /// scrolled out of view — Copilot's sticky user message for long answers.
  final List<String> stickyLines;

  /// Index into [outputLines] where the sticky echo starts; -1 when unset.
  final int stickyIndex;

  /// History lines the echo occupies (rule + input lines + trailing blank),
  /// set at submit time; the sticky pins only when these rows have fully
  /// scrolled out of view.
  final int stickyEchoLineCount;

  /// Messages typed while a run streams (kimi-cli's queue): Enter enqueues,
  /// ↑ pops the last one back into the input, Ctrl+S steers them into the
  /// running agent, and the host drains them as separate turns afterwards.
  final List<String> queue;

  /// Submitted non-empty lines, oldest first (shell-style input history).
  /// Slash and bang commands are not recorded — ↑ recalls MESSAGES.
  final List<String> inputHistory;

  /// The browsed history index, or -1 when editing fresh text (not
  /// browsing). Any edit resets it to -1.
  final int historyIndex;

  /// The input stashed when history browsing started, restored when the
  /// user browses back down past the newest entry.
  final String? historyDraft;

  /// Monotonic frame counter, bumped by every `copyWith` (i.e. every model
  /// change). The view mixes it into the cursor line's invisible SGR suffix
  /// so the row carrying the cursor-home escape differs on EVERY content
  /// change — dart_tui's row diff only re-emits the home sequence when that
  /// row changed, and a static suffix stranded the cursor mid-history after
  /// a lone output append while idle (spinner ticks only vary it while
  /// busy).
  final int frameNonce;

  /// Shared markdown+wrap memo (see [_WrapCache]); `copyWith` hands the same
  /// instance to the next model version so unchanged content never
  /// re-formats.
  var _wrapCache = _WrapCache();

  /// Formatted sticky-echo rows: view() runs on every painted frame, and
  /// during streaming that means keystroke-rate forced paints — re-running
  /// markdown formatting over the whole echoed prompt each time made
  /// typing cost O(echo lines). The echo only changes when the user
  /// submits, so the cache is keyed by its content and width.
  List<String> _stickyFmtRows = const [];
  List<String>? _stickyFmtSource;
  int? _stickyFmtWidth;

  List<String> _formattedStickyRows(int width) {
    final src = stickyLines;
    final cached = _stickyFmtRows;
    final cachedSrc = _stickyFmtSource;
    if (_stickyFmtWidth == width &&
        cachedSrc != null &&
        cachedSrc.length == src.length) {
      var same = true;
      for (var i = 0; i < src.length; i++) {
        if (cachedSrc[i] != src[i]) {
          same = false;
          break;
        }
      }
      if (same) return cached;
    }
    final md = AnsiMarkdown(width: width);
    final rows = [for (final line in src) md.formatLine(line)];
    _stickyFmtSource = List.of(src);
    _stickyFmtWidth = width;
    _stickyFmtRows = rows;
    return rows;
  }

  /// The input block's height in PHYSICAL rows: the text soft-wraps to the
  /// terminal width, so a long single line occupies several rows. All
  /// layout math (viewport height, cursor homing) must use this count —
  /// the raw `\n` count lies once a line wraps.
  int get _inputLineCount => _wrappedInput().$1.length;

  /// Truncates [text] to [maxWidth] (default: the terminal width) with an
  /// ellipsis. Every chrome row (status, menu items) must fit on one
  /// terminal row: a soft-wrapped chrome line desyncs the renderer's row
  /// math and smears the frame on every repaint.
  /// Truncates [text] to the terminal width in terminal cells (not UTF-16
  /// units) so wide characters cannot push chrome rows past the width.
  String _fitWidth(String text, [int? maxWidth]) =>
      tuiFitWidth(text, maxWidth ?? termWidth);

  /// Whether the sticky user echo is pinned right now: a run is streaming
  /// and the echo has FULLY scrolled above the visible window. Rows are
  /// counted wrapped (earlier lines may wrap), and the echo counts as out
  /// only once its last row is gone — comparing the offset to the raw
  /// [stickyIndex] line pinned a duplicate while the message was still
  /// visible in the chat.
  bool get _stickyActive {
    if (!busy || stickyLines.isEmpty || stickyIndex < 0) return false;
    // Served from the shared wrap cache (refreshed here when stale): the
    // start row of the line just past the echo IS its end row.
    _wrappedLines();
    final starts = _wrapCache.lineStartRows;
    final echoEndLine = (stickyIndex + stickyEchoLineCount).clamp(
      0,
      starts.length - 1,
    );
    return scrollOffset >= starts[echoEndLine];
  }

  /// The visible window of menu items (start inclusive, end exclusive).
  (int, int) _menuWindow() {
    const maxVisible = 6;
    var start = 0;
    if (menuItems.length > maxVisible) {
      start = (menuSelected - (maxVisible ~/ 2)).clamp(
        0,
        menuItems.length - maxVisible,
      );
    }
    final end = menuItems.length < start + maxVisible
        ? menuItems.length
        : start + maxVisible;
    return (start, end);
  }

  /// Exact number of lines the open menu occupies in the view.
  int get _menuReservedLines {
    if (!menuOpen || menuItems.isEmpty) return 0;
    final (start, end) = _menuWindow();
    var lines = 1 + (end - start); // title + items
    if (start > 0) lines++; // '↑ more'
    if (end < menuItems.length) lines++; // '↓ more'
    return lines;
  }

  /// Applies a user scroll: moves the offset (clamped) and re-evaluates the
  /// follow latch — scrolling up detaches, landing back on the exact bottom
  /// re-attaches.
  FaTuiModel _scrolledTo(int offset) {
    final wrapped = _wrappedLines();
    final next = _clampScroll(offset, wrapped);
    return copyWith(
      scrollOffset: next,
      followTail: next >= _scrollBottom(wrapped),
    );
  }

  int _viewportHeightFor(int width, int height) {
    const progressH = 1;
    // The input zone is framed by a rule above and a rule below it.
    const inputFrameH = 2;
    const statusH = 1;
    final busyH = busy ? 1 : 0;
    final stickyH = _stickyActive ? stickyLines.length : 0;
    final queueH = queue.isEmpty ? 0 : queue.length + 1; // + hint line
    final promptH = prompt != null ? tuiPromptRowCount(prompt!, width) + 2 : 0;
    final used =
        progressH +
        _menuReservedLines +
        busyH +
        stickyH +
        queueH +
        promptH +
        inputFrameH +
        statusH +
        _inputLineCount;
    return (height - used).clamp(3, 9999);
  }

  int get _viewportHeight => _viewportHeightFor(termWidth, termHeight);

  /// The output history formatted and wrapped to physical rows at [width]
  /// (default: the current terminal width). All scroll math happens in
  /// these rows — raw line counts lie once long lines wrap. Memoized in the
  /// shared [_WrapCache]: the O(transcript) markdown+wrap pass re-runs only
  /// when the source list or the width actually changes.
  List<String> _wrappedLines([int? width]) {
    final w = width ?? termWidth;
    final cache = _wrapCache;
    if (identical(cache.source, outputLines) && cache.width == w) {
      return cache.rows; // pure hit: scroll math / key presses pay nothing
    }
    var tx = w == cache.width ? cache._tx : null;
    tx ??= TranscriptMarkdown(width: w);
    cache._tx = tx;
    tx.sync(outputLines); // O(delta) on appends; legacy pass only after a
    // resize/front-trim, where it is byte-identical to formatAll.
    cache
      ..source = outputLines
      ..width = w
      ..rows = tx.wrappedRows
      ..lineStartRows = tx.lineStartRows;
    return tx.wrappedRows;
  }

  /// The scroll offset that puts the last wrapped row at the bottom.
  int _scrollBottom(List<String> wrapped) =>
      (wrapped.length - _viewportHeight).clamp(0, wrapped.length);

  int _clampScroll(int offset, List<String> wrapped) =>
      offset.clamp(0, _scrollBottom(wrapped));

  FaTuiModel copyWith({
    TuiPromptState? prompt,
    bool clearPrompt = false,
    List<String>? outputLines,
    String? inputText,
    int? cursor,
    int? scrollOffset,
    bool? followTail,
    bool? menuOpen,
    bool? menuModelMode,
    int? menuSelected,
    String? modelFilter,
    List<MenuItem>? menuItems,
    List<MenuItem>? menuAllItems,
    String? pickerId,
    String? pickerTitle,
    int? termWidth,
    int? termHeight,
    bool? busy,
    int? busyStartedAtMs,
    String? busyPhase,
    String? busySource,
    int? busyLastEventMs,
    bool? mouseCapture,
    int? spinnerFrame,
    List<String>? stickyLines,
    int? stickyIndex,
    int? stickyEchoLineCount,
    List<String>? queue,
    List<String>? inputHistory,
    int? historyIndex,
    Object? historyDraft = _unset,
  }) {
    final copy = FaTuiModel(
      callbacks: callbacks,
      isExited: isExited,
      prompt: clearPrompt ? null : (prompt ?? this.prompt),
      outputLines: outputLines ?? this.outputLines,
      inputText: inputText ?? this.inputText,
      cursor: cursor ?? this.cursor,
      scrollOffset: scrollOffset ?? this.scrollOffset,
      followTail: followTail ?? this.followTail,
      menuOpen: menuOpen ?? this.menuOpen,
      menuModelMode: menuModelMode ?? this.menuModelMode,
      menuSelected: menuSelected ?? this.menuSelected,
      modelFilter: modelFilter ?? this.modelFilter,
      menuItems: menuItems ?? this.menuItems,
      menuAllItems: menuAllItems ?? this.menuAllItems,
      pickerId: pickerId ?? this.pickerId,
      pickerTitle: pickerTitle ?? this.pickerTitle,
      termWidth: termWidth ?? this.termWidth,
      termHeight: termHeight ?? this.termHeight,
      busy: busy ?? this.busy,
      busyStartedAtMs: busyStartedAtMs ?? this.busyStartedAtMs,
      busyPhase: busyPhase ?? this.busyPhase,
      busySource: busySource ?? this.busySource,
      busyLastEventMs: busyLastEventMs ?? this.busyLastEventMs,
      mouseCapture: mouseCapture ?? this.mouseCapture,
      spinnerFrame: spinnerFrame ?? this.spinnerFrame,
      stickyLines: stickyLines ?? this.stickyLines,
      stickyIndex: stickyIndex ?? this.stickyIndex,
      stickyEchoLineCount: stickyEchoLineCount ?? this.stickyEchoLineCount,
      queue: queue ?? this.queue,
      inputHistory: inputHistory ?? this.inputHistory,
      historyIndex: historyIndex ?? this.historyIndex,
      historyDraft: historyDraft == _unset
          ? this.historyDraft
          : historyDraft as String?,
      // Every copy is a new model state: bump the frame nonce so the view's
      // cursor line always differs after a change (see [frameNonce]).
      frameNonce: frameNonce + 1,
    );
    copy._wrapCache = _wrapCache;
    copy._stickyFmtRows = _stickyFmtRows;
    copy._stickyFmtSource = _stickyFmtSource;
    copy._stickyFmtWidth = _stickyFmtWidth;
    copy._promptCompleter = _promptCompleter;
    return copy;
  }

  @override
  Cmd? init() => null;

  Cmd _scheduleSpinnerTick() {
    return () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return SpinnerTickMsg();
    };
  }

  @override
  (Model, Cmd?) update(Msg msg) {
    // Activity heartbeat for the busy row: any real message while busy
    // (stream deltas, tool rows, key input) proves the stretch is alive;
    // only spinner ticks and busy bookkeeping are excluded.
    final FaTuiModel self = (busy && msg is! SpinnerTickMsg && msg is! BusyMsg)
        ? copyWith(busyLastEventMs: DateTime.now().millisecondsSinceEpoch)
        : this;
    return self._updateWithHeartbeat(msg);
  }

  (Model, Cmd?) _updateWithHeartbeat(Msg msg) {
    // Output is handled before the exit check so trailing writes (e.g. the
    // 'bye' line from /exit) still render before the program quits; the host
    // sends _QuitRequestedMsg once it has marked exit.
    if (msg is OutputMsg) return _handleOutputMsg(msg);
    // Busy/spinner messages are handled before the exit check for the same
    // reason as output: /exit arrives wrapped in sendBusy(true/false) calls,
    // and quitting here would land in the same drained batch as the farewell
    // output and skip its render. The host's delayed _QuitRequestedMsg is
    // the only quit path that matters.
    if (msg is BusyMsg) return _handleBusyMsg(msg);
    if (msg is SpinnerTickMsg) return _handleSpinnerTick();
    if (msg is DrainQueueMsg) return _handleDrainQueue(msg);
    if (msg is OpenPromptMsg) {
      _promptCompleter = msg.completer;
      return (copyWith(prompt: TuiPromptState(msg.spec)), null);
    }
    if (isExited()) return (this, () => quit());
    return _updateAfterExitCheck(msg);
  }

  (Model, Cmd?) _handleOutputMsg(OutputMsg msg) {
    // System-notice blocks render as dim blockquotes, not raw tags.
    final displayText = msg.text.contains('<system-notice>')
        ? renderSystemNoticeLines(msg.text).join('\n')
        : msg.text;
    final newLines = _appendOutput(outputLines, displayText, msg.newline);
    final next = copyWith(outputLines: newLines);
    final nextWrapped = next._wrappedLines();
    // Auto-follow the stream while the latch holds; preserve the scroll
    // position (clamped) when the user scrolled up.
    final nextOffset = followTail
        ? _scrollBottom(nextWrapped)
        : _clampScroll(scrollOffset, nextWrapped);
    return (next.copyWith(scrollOffset: nextOffset), null);
  }

  (Model, Cmd?) _handleBusyMsg(BusyMsg msg) {
    // An in-busy phase relabel (silent post-answer work like
    // auto-compaction or durable-memory extraction) takes priority.
    if (msg.busy && msg.phase != null) return _handlePhaseRelabel(msg);
    // A raw re-start while ALREADY busy (a trigger that bypassed the
    // controller's refcount): keep the elapsed window and the single tick
    // chain instead of stacking another one.
    if (msg.busy && busy) return _ignoreBusyRestart(msg);
    return _applyBusyTransition(msg);
  }

  /// A phase relabel on a BUSY model: swap the label over the SAME elapsed
  /// window and never schedule another tick here — extra chains would
  /// multiply repaint timers.
  (Model, Cmd?) _handlePhaseRelabel(BusyMsg msg) {
    final phase = msg.phase!;
    if (!busy) {
      // A relabel on an IDLE model is a post-run straggler (a compaction
      // finally-branch landing after the bracket released): dropping it is
      // the whole point — re-arming the spinner here wedged a session at
      // "Working… Ns" burning 100% CPU for hours (each chain re-renders
      // the full transcript every 100ms).
      faTuiBusyDiagnostics?.call('busy relabel dropped (idle) phase=$phase');
      return (this, null);
    }
    return (copyWith(busyPhase: phase), null);
  }

  (Model, Cmd?) _ignoreBusyRestart(BusyMsg msg) {
    faTuiBusyDiagnostics?.call(
      'busy re-start ignored (already busy) source=${msg.source}',
    );
    return (this, null);
  }

  /// The busy↔idle bracket itself. Kick the spinner loop when going busy;
  /// the loop stops itself on the first tick that finds the model idle
  /// again. Going idle also unpins the sticky user echo and clears any
  /// phase, so the next run starts as plain "Working…".
  (Model, Cmd?) _applyBusyTransition(BusyMsg msg) {
    faTuiBusyDiagnostics?.call(
      msg.busy
          ? 'busy on source=${msg.source ?? '?'}'
          : 'busy off source=${busySource.isEmpty ? '?' : busySource} '
                'elapsed=${busyStartedAtMs < 0 ? 0 : (DateTime.now().millisecondsSinceEpoch - busyStartedAtMs) ~/ 1000}s',
    );
    return (
      copyWith(
        busy: msg.busy,
        busyStartedAtMs: msg.busy ? DateTime.now().millisecondsSinceEpoch : -1,
        busyPhase: '',
        busySource: msg.busy ? (msg.source ?? '') : '',
        busyLastEventMs: msg.busy ? DateTime.now().millisecondsSinceEpoch : -1,
        spinnerFrame: 0,
        stickyLines: msg.busy ? null : const [],
        stickyIndex: msg.busy ? null : -1,
      ),
      msg.busy ? _scheduleSpinnerTick() : null,
    );
  }

  /// Last-resort busy bracket: a row with zero activity for this long is a
  /// wedge — every arm site has a matching release, so a fire means a bug.
  /// The diagnostic log names the last armer.
  static const busyWatchdogMs = 10 * 60 * 1000;

  (Model, Cmd?) _handleSpinnerTick() {
    if (!busy) return (this, null);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (busyLastEventMs > 0 && now - busyLastEventMs > busyWatchdogMs) {
      faTuiBusyDiagnostics?.call(
        'busy watchdog release source='
        '${busySource.isEmpty ? '?' : busySource} '
        'elapsed=${busyStartedAtMs < 0 ? 0 : (now - busyStartedAtMs) ~/ 1000}s '
        'quiet=${(now - busyLastEventMs) ~/ 1000}s',
      );
      return (
        copyWith(
          busy: false,
          busyStartedAtMs: -1,
          busyPhase: '',
          busySource: '',
          busyLastEventMs: -1,
          stickyLines: const [],
          stickyIndex: -1,
        ),
        null,
      );
    }
    return (copyWith(spinnerFrame: spinnerFrame + 1), _scheduleSpinnerTick());
  }

  (Model, Cmd?) _handleDrainQueue(DrainQueueMsg msg) {
    // The host drains queued messages as separate turns after the run
    // settles; echo them into the history as they are handed out.
    final queued = queue;
    msg.completer.complete(queued);
    if (queued.isEmpty) return (this, null);
    var lines = outputLines;
    for (final message in queued) {
      lines = _echoAppend(lines, message);
    }
    final cleared = copyWith(queue: const [], outputLines: lines);
    final next = cleared.copyWith(
      scrollOffset: cleared._scrollBottom(cleared._wrappedLines()),
      followTail: true,
    );
    return (next, null);
  }

  (Model, Cmd?) _updateAfterExitCheck(Msg msg) {
    if (msg is _ModelsRefreshMsg) return _handleModelsRefresh();
    if (msg is _OpenModelMenuMsg) return _handleOpenModelMenu();
    if (msg is OpenPickerMsg) return _handleOpenPicker(msg);
    if (msg is _SetInputTextMsg) {
      return (
        copyWith(inputText: msg.text, cursor: msg.text.length, menuOpen: false),
        null,
      );
    }
    if (msg is _QuitRequestedMsg) return (this, () => quit());
    return _handleTerminalMsg(msg);
  }

  /// Terminal events: window resizes, mouse wheel scrolling, pastes, and
  /// keys.
  (Model, Cmd?) _handleTerminalMsg(Msg msg) {
    if (msg is WindowSizeMsg) return _handleWindowSize(msg);
    if (msg is MouseWheelMsg) return _handleMouseWheel(msg);
    if (msg is PasteMsg) return _handlePaste(msg);
    return _handleKeyMsg(msg);
  }

  /// Key events: multi-character runes split into individual key events
  /// first, then every key goes through the mode-aware key clusters.
  (Model, Cmd?) _handleKeyMsg(Msg msg) {
    // dart_tui's input decoder groups up to 4 ASCII bytes into a single rune,
    // and the cursor would advance by 1 instead of the inserted text length.
    // Split multi-character runes into individual key events so pasting plain
    // text (or fast typing) does not scramble the input.
    if (msg is KeyPressMsg &&
        msg.keyEvent.code == KeyCode.rune &&
        msg.keyEvent.text.length > 1) {
      return _handleMultiCharRunes(msg);
    }

    if (msg is KeyMsg) return _handleKey(msg);
    return (this, null);
  }

  (Model, Cmd?) _handleModelsRefresh() {
    // Only refresh while the model picker is actually open — the message
    // also arrives when the slash menu (or no menu) is up and must not
    // clobber its items.
    if (_modelPickerOpen) return _refreshedModelMenu();
    return (this, null);
  }

  /// Whether the open menu is the model picker (not the slash menu).
  bool get _modelPickerOpen => menuOpen && menuModelMode;

  /// Rebuilds the open model picker's items, keeping the selection in
  /// bounds.
  (Model, Cmd?) _refreshedModelMenu() {
    final items = callbacks.buildModelMenu(modelFilter);
    final selected = items.isEmpty
        ? 0
        : menuSelected.clamp(0, items.length - 1);
    return (copyWith(menuItems: items, menuSelected: selected), null);
  }

  (Model, Cmd?) _handleOpenModelMenu() {
    final items = callbacks.buildModelMenu('');
    return (
      copyWith(
        menuOpen: true,
        menuModelMode: true,
        modelFilter: '',
        menuItems: items,
        // The models picker rebuilds via buildModelMenu — the generic
        // pickers' local-filter base does not apply here.
        menuAllItems: const [],
        menuSelected: 0,
        pickerId: 'models',
        pickerTitle: '',
      ),
      null,
    );
  }

  (Model, Cmd?) _handleOpenPicker(OpenPickerMsg msg) {
    return (
      copyWith(
        menuOpen: true,
        menuModelMode: true,
        modelFilter: '',
        menuItems: msg.items,
        menuAllItems: msg.items,
        menuSelected: msg.initialIndex.clamp(
          0,
          msg.items.isEmpty ? 0 : msg.items.length - 1,
        ),
        pickerId: msg.pickerId,
        pickerTitle: msg.title,
      ),
      null,
    );
  }

  (Model, Cmd?) _handleWindowSize(WindowSizeMsg msg) {
    // Clamp the scroll offset to the new visible area so resizing cannot
    // leave it out of bounds (which showed >100% progress), then clear
    // the screen so no old frame artifacts survive the relayout. Wrapped
    // rows are recomputed at the NEW width.
    final resized = copyWith(termWidth: msg.width, termHeight: msg.height);
    final wrapped = resized._wrappedLines(msg.width);
    return (
      resized.copyWith(
        scrollOffset: resized._clampScroll(scrollOffset, wrapped),
      ),
      () async => ClearScreenMsg(),
    );
  }

  (Model, Cmd?) _handleMouseWheel(MouseWheelMsg msg) {
    // Mouse wheel scrolls the chat history, like Copilot's transcript pane.
    final delta = switch (msg.mouse.button) {
      MouseButton.wheelUp => -3,
      MouseButton.wheelDown => 3,
      _ => 0,
    };
    if (delta != 0) {
      return (_scrolledTo(scrollOffset + delta), null);
    }
    return (this, null);
  }

  /// dart_tui 2.0.0's bracketed-paste decoder maps every pasted BYTE to a
  /// char code (Latin-1), so pasted non-ASCII text arrives as mojibake
  /// ("ÐÑÐ¸Ð²ÐµÑ" instead of "Привет"). The mis-decode is lossless —
  /// re-encoding as Latin-1 recovers the original bytes — so decode them as
  /// UTF-8 here. ASCII and already-correct input pass through unchanged.
  static String _fixPasteMojibake(String text) {
    try {
      return utf8.decode(latin1.encode(text));
    } on Object {
      return text; // never worse than the input
    }
  }

  (Model, Cmd?) _handlePaste(PasteMsg msg) {
    final content = _fixPasteMojibake(msg.content);
    // Prompt mode: pastes go into the open prompt's buffer (e.g. an API key
    // pasted into the dial/secret prompts), like typed characters do.
    if (prompt != null) {
      final key = PromptPaste(content);
      final (state: next, resolved: answer) = handleTuiPromptKey(prompt!, key);
      if (answer != null) {
        _promptCompleter?.complete(answer);
        _promptCompleter = null;
        return (copyWith(clearPrompt: true), null);
      }
      return (copyWith(prompt: next), null);
    }
    final before = inputText.substring(0, cursor);
    final after = inputText.substring(cursor);
    return (
      copyWith(
        inputText: before + content + after,
        cursor: cursor + content.length,
      ),
      null,
    );
  }

  (Model, Cmd?) _handleMultiCharRunes(KeyPressMsg msg) {
    Model current = this;
    Cmd? lastCmd;
    for (final ch in msg.keyEvent.text.split('')) {
      final result = current.update(
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
      );
      current = result.$1;
      if (result.$2 != null) lastCmd = result.$2;
    }
    return (current, lastCmd);
  }

  (Model, Cmd?) _handleKey(KeyMsg msg) {
    // Prompt mode: route keys to the interactive prompt zone.
    if (prompt != null) return _handlePromptKey(msg);

    // Picker mode: arrows navigate, enter/tab select, esc closes.
    if (menuOpen && menuModelMode) return _handlePickerKey(msg);

    // Slash/menu mode: arrows navigate, enter/tab accept, esc closes, and
    // typing keeps editing the input so `/models` can be typed in full.
    if (menuOpen) return _handleSlashMenuKey(msg);

    // Normal input editing.
    return _handleControlKey(msg) ??
        _handleScrollKey(msg) ??
        _handleCursorNavKey(msg) ??
        _handleEditKey(msg);
  }

  /// Slash/menu mode: arrows navigate, enter/tab accept, esc closes, and
  /// typing keeps editing the input so `/models` can be typed in full.
  (Model, Cmd?) _handleSlashMenuKey(KeyMsg msg) {
    return _handleSlashMenuNavKey(msg) ??
        _handleSlashMenuAcceptKey(msg) ??
        _handleSlashMenuEditKey(msg);
  }

  /// Slash-menu navigation keys (esc/up/down); null when the key belongs to
  /// the accept or edit clusters.
  (Model, Cmd?)? _handleSlashMenuNavKey(KeyMsg msg) {
    switch (msg.key) {
      case 'esc':
        return (copyWith(menuOpen: false), null);
      case 'up':
        return (
          copyWith(menuSelected: menuSelected > 0 ? menuSelected - 1 : 0),
          null,
        );
      case 'down':
        return (
          copyWith(
            menuSelected: menuSelected < menuItems.length - 1
                ? menuSelected + 1
                : menuSelected,
          ),
          null,
        );
      default:
        return null;
    }
  }

  /// Slash-menu accept keys (enter/tab); null for every other key.
  (Model, Cmd?)? _handleSlashMenuAcceptKey(KeyMsg msg) {
    switch (msg.key) {
      case 'enter':
      case 'tab':
        return _acceptSlashMenuItem();
      default:
        return null;
    }
  }

  /// Slash-menu edit keys: backspace and typed characters keep editing the
  /// input so `/models` can be typed in full.
  (Model, Cmd?) _handleSlashMenuEditKey(KeyMsg msg) {
    switch (msg.key) {
      case 'backspace':
        if (cursor > 0 && inputText.isNotEmpty) {
          final nextText =
              inputText.substring(0, cursor - 1) + inputText.substring(cursor);
          final nextCursor = cursor - 1;
          return (
            _updateMenuForInput(
              copyWith(inputText: nextText, cursor: nextCursor),
            ),
            null,
          );
        }
        return (this, null);
      default:
        final text = msg.keyEvent.text;
        if (text.isNotEmpty && text.length == 1) {
          final nextText =
              inputText.substring(0, cursor) +
              text +
              inputText.substring(cursor);
          final nextCursor = cursor + 1;
          return (
            _updateMenuForInput(
              copyWith(inputText: nextText, cursor: nextCursor),
            ),
            null,
          );
        }
        return (this, null);
    }
  }

  /// Slash-menu accept (enter/tab): fills the input with the picked command,
  /// or switches into the models picker, or submits picker-opening commands
  /// (/sessions, /mode, /approval) immediately.
  (Model, Cmd?) _acceptSlashMenuItem() {
    if (menuItems.isEmpty) return (this, null);
    final item = menuItems[menuSelected];
    if (item.key == '/model' || item.key == '/models') {
      return (
        copyWith(
          menuModelMode: true,
          menuItems: callbacks.buildModelMenu(''),
          menuSelected: 0,
          modelFilter: '',
          pickerId: 'models',
          pickerTitle: '',
        ),
        null,
      );
    }
    // Commands that open a host-side picker (/sessions, /mode,
    // /approval) submit immediately instead of filling the input.
    if (callbacks.opensPicker?.call(item.key) ?? false) {
      return (
        copyWith(menuOpen: false, inputText: '', cursor: 0),
        () async {
          await callbacks.onSubmit(item.key);
          return null;
        },
      );
    }
    return (
      copyWith(inputText: item.key, cursor: item.key.length, menuOpen: false),
      null,
    );
  }

  /// Normal-mode control keys (submit/steer/newline/interrupt/abort); null
  /// when the key belongs to another cluster.
  (Model, Cmd?)? _handleControlKey(KeyMsg msg) {
    return _handleSubmitKeys(msg) ?? _handleInterruptKeys(msg);
  }

  /// Normal-mode submit keys (enter/ctrl+s) and the newline-insertion
  /// fallbacks (ctrl+o/ctrl+j); null when the key belongs to another cluster.
  (Model, Cmd?)? _handleSubmitKeys(KeyMsg msg) {
    switch (msg.key) {
      case 'enter':
        return _handleEnterKey();
      case 'ctrl+s':
        if (busy) {
          // Busy Ctrl+S steers the pending input plus every queued message
          // into the running agent (kimi-cli semantics).
          return _steerAll();
        }
        // Ctrl+S always submits, regardless of terminal Shift+Enter support.
        final text = inputText.trim();
        if (text.isEmpty) return (this, null);
        return _submit(text);
      case 'ctrl+o':
      case 'ctrl+j':
        // Fallback newline insertion (modifyOtherKeys Shift+Enter is mapped
        // to Ctrl+O by the input preprocessor on supporting terminals).
        return _insertNewlineAtCursor();
      default:
        return null;
    }
  }

  /// Normal-mode interrupt keys (ctrl+c quits, esc aborts the run); null
  /// when the key belongs to another cluster.
  (Model, Cmd?)? _handleInterruptKeys(KeyMsg msg) {
    switch (msg.key) {
      case 'ctrl+c':
        callbacks.onInterrupt?.call();
        return (this, () => quit());
      case 'esc':
        // Escape aborts the streaming run (pi's keybinding); a no-op when
        // idle because the host only aborts while busy. Unlike Ctrl+C it
        // never quits the program.
        callbacks.onInterrupt?.call();
        return (this, null);
      default:
        return null;
    }
  }

  /// Normal-mode Enter: submit, queue while busy, or Shift+Enter newline.
  (Model, Cmd?) _handleEnterKey() {
    // Enter submits; Shift+Enter inserts a newline. Terminals that do not
    // distinguish Shift+Enter in the input stream are handled through the
    // host modifier check (Core Graphics on macOS, like pi's helper).
    if (callbacks.isShiftPressed?.call() ?? false) {
      return _insertNewlineAtCursor();
    }
    final line = inputText.trim();
    // Empty submits are NOT dropped: guided flows (custom provider
    // setup) use "empty = keep the default" answers, and the host's
    // line handler ignores stray empties outside a pending prompt.
    if (busy &&
        line.isNotEmpty &&
        !line.startsWith('/') &&
        !line.startsWith('!')) {
      // While a run streams, plain messages queue up (kimi-cli); slash
      // and bang commands execute immediately via the normal path.
      return _enqueue(line);
    }
    return _submit(line);
  }

  /// Normal-mode history scroll keys; null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handleScrollKey(KeyMsg msg) {
    return _handleArrowScrollKey(msg) ?? _handlePageScrollKey(msg);
  }

  /// Normal-mode arrow scroll keys (↑/↓); null when the key belongs to
  /// another cluster. With an empty input ↑ first pops the message queue,
  /// then browses the submitted-message history (shell-style); ↓ walks it
  /// back. Viewport scrolling lives on PgUp/PgDn (and the mouse wheel when
  /// capture is on).
  (Model, Cmd?)? _handleArrowScrollKey(KeyMsg msg) {
    switch (msg.key) {
      case 'up':
        // Browsing: step to the older entry (stop at the oldest).
        if (historyIndex != -1) {
          if (historyIndex > 0) {
            final index = historyIndex - 1;
            final entry = inputHistory[index];
            return (
              copyWith(
                historyIndex: index,
                inputText: entry,
                cursor: entry.length,
              ),
              null,
            );
          }
          return (this, null);
        }
        if (inputText.isEmpty) {
          // With a non-empty queue, ↑ pops the last queued message back into
          // the input for editing (kimi-cli).
          if (queue.isNotEmpty) {
            final popped = queue.last;
            return (
              copyWith(
                queue: queue.sublist(0, queue.length - 1),
                inputText: popped,
                cursor: popped.length,
              ),
              null,
            );
          }
          // Then the submitted-message history.
          if (inputHistory.isNotEmpty) {
            final index = inputHistory.length - 1;
            final entry = inputHistory[index];
            return (
              copyWith(
                historyIndex: index,
                historyDraft: '',
                inputText: entry,
                cursor: entry.length,
              ),
              null,
            );
          }
          return (_scrolledTo(scrollOffset - 1), null);
        }
        return (this, null);
      case 'down':
        // Browsing: step to the newer entry; past the newest restores the
        // (empty) draft.
        if (historyIndex != -1) {
          if (historyIndex < inputHistory.length - 1) {
            final index = historyIndex + 1;
            final entry = inputHistory[index];
            return (
              copyWith(
                historyIndex: index,
                inputText: entry,
                cursor: entry.length,
              ),
              null,
            );
          }
          final draft = historyDraft ?? '';
          return (
            copyWith(
              historyIndex: -1,
              historyDraft: null,
              inputText: draft,
              cursor: draft.length,
            ),
            null,
          );
        }
        if (inputText.isEmpty) {
          return (_scrolledTo(scrollOffset + 1), null);
        }
        return (this, null);
      default:
        return null;
    }
  }

  /// Normal-mode page scroll keys (pgup/pgdown); null when the key belongs
  /// to another cluster.
  (Model, Cmd?)? _handlePageScrollKey(KeyMsg msg) {
    switch (msg.key) {
      case 'pgup':
        return (_scrolledTo(scrollOffset - _viewportHeight), null);
      case 'pgdown':
        return (_scrolledTo(scrollOffset + _viewportHeight), null);
      default:
        return null;
    }
  }

  /// Normal-mode cursor motion keys; null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handleCursorNavKey(KeyMsg msg) {
    return _handleLeftRightKey(msg) ??
        _handleWordNavKey(msg) ??
        _handleHomeEndKey(msg);
  }

  /// Normal-mode left/right arrow keys; null when the key belongs to
  /// another cluster.
  (Model, Cmd?)? _handleLeftRightKey(KeyMsg msg) {
    switch (msg.key) {
      case 'left':
        return (copyWith(cursor: cursor > 0 ? cursor - 1 : 0), null);
      case 'right':
        return (
          copyWith(cursor: cursor < inputText.length ? cursor + 1 : cursor),
          null,
        );
      default:
        return null;
    }
  }

  /// Normal-mode word-motion keys; null when the key belongs to another
  /// cluster. Word motion like pi's editor: alt+left/right jump by words.
  (Model, Cmd?)? _handleWordNavKey(KeyMsg msg) {
    switch (msg.key) {
      case 'alt+left':
        return (copyWith(cursor: _wordStartBefore(inputText, cursor)), null);
      case 'alt+right':
        return (copyWith(cursor: _wordEndAfter(inputText, cursor)), null);
      default:
        return null;
    }
  }

  /// Normal-mode home/end keys; null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handleHomeEndKey(KeyMsg msg) {
    switch (msg.key) {
      case 'home':
      case 'ctrl+a': // readline — also what macOS Cmd+Left sends (^A)
        return (copyWith(cursor: 0), null);
      case 'end':
      case 'ctrl+e': // readline — macOS Cmd+Right (^E)
        return (copyWith(cursor: inputText.length), null);
      default:
        return null;
    }
  }

  /// Normal-mode text-editing keys (deletion and character insert); catches
  /// every key the other clusters did not claim.
  (Model, Cmd?) _handleEditKey(KeyMsg msg) {
    final result =
        _handleBackspaceKey(msg) ??
        _handleKillKey(msg) ??
        _handleDeleteKey(msg) ??
        _handleCharInsertKey(msg);
    // Any real edit exits history browsing (the recalled entry becomes the
    // new draft).
    if (historyIndex == -1) return result;
    final (model, cmd) = result;
    return (
      (model as FaTuiModel).copyWith(historyIndex: -1, historyDraft: null),
      cmd,
    );
  }

  /// Normal-mode backspace; null when the key belongs to another cluster.
  (Model, Cmd?)? _handleBackspaceKey(KeyMsg msg) {
    switch (msg.key) {
      case 'backspace':
        if (cursor == 0 || inputText.isEmpty) return (this, null);
        final nextText =
            inputText.substring(0, cursor - 1) + inputText.substring(cursor);
        final nextCursor = cursor - 1;
        return (
          _updateMenuForInput(
            copyWith(inputText: nextText, cursor: nextCursor),
          ),
          null,
        );
      default:
        return null;
    }
  }

  /// Normal-mode kill keys (ctrl+u kills back to the line start, ctrl+w the
  /// word before the cursor); null when the key belongs to another cluster.
  (Model, Cmd?)? _handleKillKey(KeyMsg msg) {
    switch (msg.key) {
      case 'ctrl+u':
        // Kill from the cursor back to the start of the line (readline's
        // unix-line-discard — also what most terminals send for Cmd+Backspace).
        if (cursor == 0) return (this, null);
        return (
          _updateMenuForInput(
            copyWith(inputText: inputText.substring(cursor), cursor: 0),
          ),
          null,
        );
      case 'ctrl+w':
        return _killWordBeforeCursor();
      default:
        return null;
    }
  }

  /// Normal-mode forward delete; null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handleDeleteKey(KeyMsg msg) {
    switch (msg.key) {
      case 'delete':
        if (cursor >= inputText.length) return (this, null);
        final nextText =
            inputText.substring(0, cursor) + inputText.substring(cursor + 1);
        return (_updateMenuForInput(copyWith(inputText: nextText)), null);
      default:
        return null;
    }
  }

  /// Whether [keystroke] carries a command modifier (ctrl/alt/meta/hyper/
  /// super). The dart_tui decoder puts the BASE LETTER into `text` for
  /// control bytes (0x01 → ctrl+a with text 'a'), so a catch-all insert
  /// that trusts `text` prints the letter of every unhandled combo —
  /// macOS Cmd+Left (sends ^A) typed "aaaa" in the composer. Shift is
  /// deliberately NOT blocked: shifted letters arrive as plain runes in
  /// legacy mode and as `shift+<key>` with text under the kitty protocol.
  static bool _isCommandKeystroke(String keystroke) {
    return keystroke.startsWith('ctrl+') ||
        keystroke.startsWith('alt+') ||
        keystroke.startsWith('meta+') ||
        keystroke.startsWith('hyper+') ||
        keystroke.startsWith('super+');
  }

  /// Normal-mode character insert: the editing cluster's catch-all for
  /// single-character keys.
  (Model, Cmd?) _handleCharInsertKey(KeyMsg msg) {
    if (_isCommandKeystroke(msg.key)) return (this, null);
    final text = msg.keyEvent.text;
    if (text.isNotEmpty && text.length == 1) {
      final nextText =
          inputText.substring(0, cursor) + text + inputText.substring(cursor);
      final nextCursor = cursor + 1;
      return (
        _updateMenuForInput(copyWith(inputText: nextText, cursor: nextCursor)),
        null,
      );
    }
    return (this, null);
  }

  /// Ctrl+W: kill the word before the cursor (readline's unix-word-rubout):
  /// trailing whitespace first, then the word itself.
  (Model, Cmd?) _killWordBeforeCursor() {
    if (cursor == 0) return (this, null);
    var end = cursor;
    while (end > 0 && inputText[end - 1] == ' ') {
      end--;
    }
    while (end > 0 && inputText[end - 1] != ' ') {
      end--;
    }
    return (
      _updateMenuForInput(
        copyWith(
          inputText: inputText.substring(0, end) + inputText.substring(cursor),
          cursor: end,
        ),
      ),
      null,
    );
  }

  /// Picker mode: arrows navigate, enter/tab select, esc closes. Every
  /// picker has a type-to-filter input — the models picker rebuilds through
  /// the host callback, generic pickers (sessions, settings, agents, ...)
  /// filter their static item list locally.
  (Model, Cmd?) _handlePickerKey(KeyMsg msg) {
    return _handlePickerNavKey(msg) ?? _handlePickerSelectKey(msg);
  }

  /// Picker navigation keys (esc/arrows/pgup/pgdown); null when the key
  /// belongs to the select/filter cluster.
  (Model, Cmd?)? _handlePickerNavKey(KeyMsg msg) {
    return _handlePickerEscKey(msg) ??
        _handlePickerArrowKey(msg) ??
        _handlePickerPageKey(msg);
  }

  /// Picker esc: closes the picker; generic pickers also report the
  /// cancellation to the host (wizard flows wait on the answer). Null when
  /// the key belongs to another cluster.
  (Model, Cmd?)? _handlePickerEscKey(KeyMsg msg) {
    final isModelsPicker = pickerId == 'models';
    switch (msg.key) {
      case 'esc':
        if (!isModelsPicker && pickerId.isNotEmpty) {
          callbacks.onPickerCancelled?.call(pickerId);
        }
        return (
          copyWith(menuOpen: false, modelFilter: '', menuAllItems: const []),
          null,
        );
      default:
        return null;
    }
  }

  /// Picker arrow keys (↑/↓); null when the key belongs to another cluster.
  (Model, Cmd?)? _handlePickerArrowKey(KeyMsg msg) {
    switch (msg.key) {
      case 'up':
        return (
          copyWith(menuSelected: menuSelected > 0 ? menuSelected - 1 : 0),
          null,
        );
      case 'down':
        return (
          copyWith(
            menuSelected: menuSelected < menuItems.length - 1
                ? menuSelected + 1
                : menuSelected,
          ),
          null,
        );
      default:
        return null;
    }
  }

  /// Picker page keys (pgup/pgdown jump to the first/last item); null when
  /// the key belongs to another cluster.
  (Model, Cmd?)? _handlePickerPageKey(KeyMsg msg) {
    switch (msg.key) {
      case 'pgup':
        return (copyWith(menuSelected: 0), null);
      case 'pgdown':
        return (
          copyWith(menuSelected: menuItems.isEmpty ? 0 : menuItems.length - 1),
          null,
        );
      default:
        return null;
    }
  }

  /// Picker select/filter keys (backspace/enter/tab/type-to-filter).
  (Model, Cmd?) _handlePickerSelectKey(KeyMsg msg) {
    return _handlePickerBackspaceKey(msg) ??
        _handlePickerAcceptKey(msg) ??
        _pickerTypeFilter(msg);
  }

  /// Picker backspace: trims the filter and rebuilds the item list (the
  /// models picker via [FaTuiCallbacks.buildModelMenu], generic pickers by
  /// locally filtering [menuAllItems]). Null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handlePickerBackspaceKey(KeyMsg msg) {
    switch (msg.key) {
      case 'backspace':
        if (modelFilter.isEmpty) return (this, null);
        final nextFilter = modelFilter.substring(0, modelFilter.length - 1);
        return (_filteredPicker(nextFilter), null);
      default:
        return null;
    }
  }

  /// The picker state with [filter] applied: the models picker rebuilds via
  /// the host callback, generic pickers filter [menuAllItems] locally
  /// (case-insensitive contains over label + description).
  FaTuiModel _filteredPicker(String filter) {
    final isModelsPicker = pickerId == 'models';
    final items = isModelsPicker
        ? callbacks.buildModelMenu(filter)
        : _filterItems(menuAllItems, filter);
    return copyWith(modelFilter: filter, menuItems: items, menuSelected: 0);
  }

  /// The local generic-picker filter: [items] whose label or description
  /// contains [filter] (case-insensitive); an empty filter keeps everything.
  static List<MenuItem> _filterItems(List<MenuItem> items, String filter) {
    final query = filter.trim().toLowerCase();
    if (query.isEmpty) return items;
    return [
      for (final item in items)
        if ('${item.label} ${item.description}'.toLowerCase().contains(query))
          item,
    ];
  }

  /// Picker accept (enter/tab): closes the picker and resolves the
  /// selection through the host (the model pick for the models picker,
  /// [FaTuiCallbacks.onPickerSelected] for generic pickers). Null when the
  /// key belongs to another cluster.
  (Model, Cmd?)? _handlePickerAcceptKey(KeyMsg msg) {
    final isModelsPicker = pickerId == 'models';
    switch (msg.key) {
      case 'enter':
      case 'tab':
        if (menuItems.isEmpty) return (this, null);
        final item = menuItems[menuSelected];
        if (item.key.isEmpty) return (this, null);
        return (
          copyWith(
            menuOpen: false,
            modelFilter: '',
            menuAllItems: const [],
            inputText: '',
            cursor: 0,
          ),
          () async {
            if (isModelsPicker) {
              await callbacks.onModelSelected(item.key);
            } else {
              await callbacks.onPickerSelected?.call(pickerId, item.key);
            }
            return null;
          },
        );
      default:
        return null;
    }
  }

  /// Picker type-to-filter: each printable character extends the filter and
  /// rebuilds the item list (host callback for the models picker, a local
  /// [menuAllItems] filter for generic pickers).
  (Model, Cmd?) _pickerTypeFilter(KeyMsg msg) {
    if (_isCommandKeystroke(msg.key)) return (this, null);
    final text = msg.keyEvent.text;
    if (text.isNotEmpty && text.length == 1) {
      if (text == ' ' && modelFilter.isEmpty) return (this, null);
      return (_filteredPicker(modelFilter + text), null);
    }
    return (this, null);
  }

  /// Prompt-mode key routing: forwards the key to [handleTuiPromptKey] and
  /// resolves the host completer when it produces an answer (closing the
  /// prompt zone and handing control back to normal input).
  (Model, Cmd?) _handlePromptKey(KeyMsg msg) {
    final key = _promptKeyFromMsg(msg);
    if (key == null) return (this, null);
    final (state: next, resolved: answer) = handleTuiPromptKey(prompt!, key);
    if (answer != null) {
      _promptCompleter?.complete(answer);
      _promptCompleter = null;
      return (copyWith(clearPrompt: true), null);
    }
    return (copyWith(prompt: next), null);
  }

  /// Re-shapes a dart_tui [KeyMsg] into a transport-neutral [PromptKey] for
  /// the pure-Dart prompt handler.
  PromptKey? _promptKeyFromMsg(KeyMsg msg) {
    return switch (msg.key) {
      // dart_tui maps CR to 'enter' and LF to 'ctrl+j' — both mean Enter.
      // ctrl+c is NOT mapped here: it stays the global interrupt/quit key.
      'enter' || 'ctrl+j' => const PromptEnter(),
      'ctrl+r' => const PromptCtrlR(),
      'ctrl+u' => const PromptCtrlU(),
      'esc' => const PromptEscape(),
      'tab' => const PromptTab(),
      'up' => const PromptArrowUp(),
      'down' => const PromptArrowDown(),
      'left' => const PromptArrowLeft(),
      'right' => const PromptArrowRight(),
      'backspace' => const PromptBackspace(),
      _ =>
        !_isCommandKeystroke(msg.key) && msg.keyEvent.text.length == 1
            ? PromptChar(msg.keyEvent.text)
            : null,
    };
  }

  static bool _isWordBreak(String ch) => ch == ' ' || ch == '\n' || ch == '\t';

  (FaTuiModel, Cmd?) _insertNewlineAtCursor() {
    final nextText =
        '${inputText.substring(0, cursor)}\n${inputText.substring(cursor)}';
    return (copyWith(inputText: nextText, cursor: cursor + 1), null);
  }

  /// The user-message echo: a dim full-width rule above backgrounded input
  /// lines (background stored UNPADDED — the view-time formatter pads it to
  /// the then-current width, and the bg escape marks the lines as pre-styled
  /// so the markdown formatter leaves them alone). Two blank lines follow:
  /// the first is consumed by the run's first output line (thinking or the
  /// `>_Fa` prefix), leaving one visible empty line after the user message.
  List<String> _echoAppend(List<String> lines, String text) {
    final rule = _dim('─' * termWidth);
    const bg = '\x1b[48;2;30;34;42m';
    const reset = '\x1b[0m';
    final styledInput = text
        .split('\n')
        .map((line) => '$bg$line$reset')
        .join('\n');
    final appended = _appendOutput(lines, '$rule\n$styledInput', true);
    return _appendOutput(appended, '', true);
  }

  /// Submits [text]: echoes the input into the history immediately (no rule
  /// below — the run's thinking/answer flows directly under the user
  /// message), clears the input, snaps the viewport to the bottom, and runs
  /// the host callback.
  (FaTuiModel, Cmd?) _submit(String text) {
    final rule = _dim('─' * termWidth);
    const bg = '\x1b[48;2;30;34;42m';
    const reset = '\x1b[0m';
    // Empty submits (guided-flow "keep the default" answers) skip the
    // message echo — an empty backgrounded block would read as a glitch.
    if (inputText.isEmpty) {
      return (
        copyWith(inputText: '', cursor: 0),
        () async {
          await callbacks.onSubmit(text);
          return null;
        },
      );
    }
    final echoed = _echoAppend(outputLines, inputText);
    // Shell-style input history: plain messages only (no slash/bang
    // commands), consecutive duplicates collapsed, capped at 100.
    final history = _recordInputHistory(inputHistory, text);
    // The pinned echo for long answers (Copilot-style): rule + the first
    // input line, truncated to the width with a dim ellipsis marking any
    // remainder — a multi-line message or one simply longer than a row
    // (a bare long line previously got visually cut without any marker).
    final firstLine = inputText.split('\n').first;
    final fits = firstLine.length <= termWidth - 3 || termWidth <= 3;
    final shown = fits ? firstLine : firstLine.substring(0, termWidth - 3);
    final more = inputText.contains('\n') || !fits ? _dim(' …') : '';
    final cleared = copyWith(
      inputText: '',
      cursor: 0,
      inputHistory: history,
      historyIndex: -1,
      historyDraft: null,
      outputLines: echoed,
      stickyLines: [rule, '$bg$shown$reset$more'],
      stickyIndex: outputLines.length,
      stickyEchoLineCount: 2 + inputText.split('\n').length,
    );
    return (
      // A fresh submit always jumps to the bottom AND re-attaches follow:
      // without it, a latch detached by an earlier scroll-up froze the
      // stream off-screen (and the sticky echo never activated).
      cleared.copyWith(
        scrollOffset: cleared._scrollBottom(cleared._wrappedLines()),
        followTail: true,
      ),
      () async {
        await callbacks.onSubmit(text);
        return null;
      },
    );
  }

  /// The input history after recording [text]: plain messages only (no
  /// slash/bang commands), consecutive duplicates collapsed, capped at 100.
  /// Extracted from [_submit] to keep its CRAP in budget.
  static List<String> _recordInputHistory(List<String> history, String text) {
    final recordable =
        text.isNotEmpty && !text.startsWith('/') && !text.startsWith('!');
    if (!recordable || (history.isNotEmpty && history.last == text)) {
      return history;
    }
    final next = [...history, text];
    return next.length > 100 ? next.sublist(next.length - 100) : next;
  }

  /// Busy-mode Enter: queues the message (kimi-cli semantics — it is run as
  /// a separate turn after the current one settles). Slash/bang commands go
  /// through the normal submit path since they execute instantly.
  (FaTuiModel, Cmd?) _enqueue(String text) {
    return (copyWith(inputText: '', cursor: 0, queue: [...queue, text]), null);
  }

  /// Busy-mode Ctrl+S: steers the pending input plus every queued message
  /// into the running agent (each becomes a separate user message), echoing
  /// them into the history first.
  (FaTuiModel, Cmd?) _steerAll() {
    final messages = [
      if (inputText.trim().isNotEmpty) inputText.trim(),
      ...queue,
    ];
    if (messages.isEmpty) return (this, null);
    var lines = outputLines;
    for (final message in messages) {
      lines = _echoAppend(lines, message);
    }
    // A visible receipt: an echoed-but-unanswered message otherwise reads
    // as "sent into the void" while the turn runs (or wedges on a dead
    // endpoint).
    lines = _appendOutput(
      lines,
      _dim('⤷ steered into the running turn — esc aborts'),
      true,
    );
    // Steered messages are sent for real — they join the input history.
    var history = inputHistory;
    for (final message in messages) {
      if (message.startsWith('/') || message.startsWith('!')) continue;
      if (history.isEmpty || history.last != message) {
        history = [...history, message];
      }
    }
    if (history.length > 100) {
      history = history.sublist(history.length - 100);
    }
    final cleared = copyWith(
      inputText: '',
      cursor: 0,
      queue: const [],
      inputHistory: history,
      historyIndex: -1,
      historyDraft: null,
      outputLines: lines,
    );
    return (
      cleared.copyWith(
        scrollOffset: cleared._scrollBottom(cleared._wrappedLines()),
        followTail: true,
      ),
      () async {
        await callbacks.onSteer?.call(messages);
        return null;
      },
    );
  }

  int _wordStartBefore(String text, int pos) {
    var i = pos;
    while (i > 0 && _isWordBreak(text[i - 1])) {
      i--;
    }
    while (i > 0 && !_isWordBreak(text[i - 1])) {
      i--;
    }
    return i;
  }

  int _wordEndAfter(String text, int pos) {
    var i = pos;
    while (i < text.length && _isWordBreak(text[i])) {
      i++;
    }
    while (i < text.length && !_isWordBreak(text[i])) {
      i++;
    }
    return i;
  }

  FaTuiModel _updateMenuForInput(FaTuiModel model) {
    final text = model.inputText;

    // `/models <filter>` opens the picker with a pre-filled filter.
    final filterMatch = RegExp(r'^/models\s+(.*)$').firstMatch(text);
    if (filterMatch != null) {
      final filter = filterMatch.group(1)!;
      return model.copyWith(
        menuOpen: true,
        menuModelMode: true,
        modelFilter: filter,
        menuItems: callbacks.buildModelMenu(filter),
        menuSelected: 0,
        pickerId: 'models',
        pickerTitle: '',
      );
    }

    if (text == '/models') {
      return model.copyWith(
        menuOpen: true,
        menuModelMode: true,
        modelFilter: '',
        menuItems: callbacks.buildModelMenu(''),
        menuSelected: 0,
        pickerId: 'models',
        pickerTitle: '',
      );
    }
    if (text.startsWith('/')) {
      final items = callbacks.buildSlashMenu(text);
      if (items.isEmpty) {
        return model.copyWith(menuOpen: false);
      }
      return model.copyWith(
        menuOpen: true,
        menuModelMode: false,
        menuItems: items,
        menuSelected: 0,
      );
    }
    return model.copyWith(menuOpen: false);
  }

  @override
  View view() {
    final b = StringBuffer();
    final height = _viewportHeight;

    _writeStickyEcho(b);

    // Output history, padded to a fixed height. Markdown is formatted and
    // ANSI-safely wrapped to physical rows (SGR-only output, escapes never
    // cut at wrap points) so streamed text gains styling as closing markers
    // arrive; the pass is memoized in the shared wrap cache, so a frame
    // triggered by scrolling reuses the rows computed on the last change.
    final wrapped = _wrappedLines();
    final offset = _clampScroll(scrollOffset, wrapped);
    _writeHistoryRows(b, height, wrapped, offset);
    _writeScrollIndicator(b, wrapped, offset);

    // Menu above input.
    _writeMenu(b);

    _writeBusyAndQueue(b);

    // Prompt mode: the prompt zone replaces the entire input zone below it,
    // including the status line. The physical cursor stays HIDDEN the whole
    // time: text inputs render their own inline reverse-video caret
    // (_cursorInputRow), pickers and approvals need no caret at all — the
    // old "home to the bottom of the frame" behavior left a stray bar
    // sitting on the status line while the dialog had focus.
    if (prompt != null) {
      for (final line in renderTuiPrompt(prompt!, termWidth)) {
        b.writeln(line);
      }
      b.writeln(); // spacer
      b.write(_statusRow());
      const cursorLine = '\x1b[?25l';
      return View(
        content: b.toString() + cursorLine,
        cursor: null,
        mouseMode: mouseCapture ? MouseMode.cellMotion : MouseMode.none,
      );
    }

    final (cursorInputLine, cursorScreenCol) = _writeInputLines(b);
    b.writeln(_dim('─' * termWidth));
    // The status line stays plain; the busy indicator lives above the input.
    b.write(_statusRow());

    // One snapshot serves both consumers: newline counting for the cursor
    // row math (O(n) scan, ZERO allocations — the old split('\n') built a
    // List<String> of every physical row on every frame just to take its
    // length) and the frame body itself.
    final body = b.toString();
    final inputStartRow = _lineCount(body) - 2 - _inputLineCount;
    final cursorRow = inputStartRow + cursorInputLine;
    final cursorX = cursorScreenCol;
    // Pickers (models, sessions, mode, approval, provider, settings, wizard
    // steps) never show the physical cursor: generic pickers ignore typing
    // entirely, and the models picker's type-to-filter echoes into the
    // picker title ([Select model: …]), not the input line — a caret in the
    // empty input zone would blink nowhere near the text it "edits". The
    // slash menu DOES edit the input line, so it keeps the cursor.
    final pickerOpen = menuOpen && menuModelMode;
    // The caret stays visible in the input zone while a run streams:
    // typing mid-stream is first-class. The renderer re-homes the physical
    // cursor after every painting frame (forceHome on any written row/cell),
    // so the old "cursor jumps inside streamed text between spinner ticks"
    // artifact no longer applies. Selection-only pickers still hide it —
    // typing goes nowhere there.
    final hideCursor = pickerOpen;
    final cursorLine = hideCursor
        ? '\x1b[?25l'
        : '\x1b[?25h\x1b[${cursorRow + 1};${cursorX + 1}H';
    return View(
      content: body + cursorLine,
      cursor: hideCursor
          ? null
          : Cursor(x: cursorX, y: cursorRow, shape: CursorShape.bar),
      mouseMode: mouseCapture ? MouseMode.cellMotion : MouseMode.none,
    );
  }

  /// The sticky user echo pinned to the top while a run streams and the
  /// echo itself has scrolled out of view (Copilot-style). Rows come from
  /// the content-keyed cache — formatting per frame made typing during a
  /// stream O(echo lines) per keystroke.
  void _writeStickyEcho(StringBuffer b) {
    if (_stickyActive) {
      for (final line in _formattedStickyRows(termWidth)) {
        b.writeln(line);
      }
    }
  }

  /// The [height]-row window of the wrapped output history at [offset].
  void _writeHistoryRows(
    StringBuffer b,
    int height,
    List<String> wrapped,
    int offset,
  ) {
    for (var i = 0; i < height; i++) {
      final row = offset + i;
      b.writeln(row < wrapped.length ? wrapped[row] : '');
    }
  }

  /// Scroll progress indicator — only while the user scrolled away from
  /// the live edge (a "you are here" hint); while following, the row stays
  /// blank so the layout never shifts. (A transient viewport shrink, e.g.
  /// the busy row, must not light it up spuriously.)
  void _writeScrollIndicator(StringBuffer b, List<String> wrapped, int offset) {
    final bottom = _scrollBottom(wrapped);
    if (!followTail && offset < bottom) {
      final scrollPercent = bottom == 0
          ? 100
          : ((offset / bottom) * 100).round().clamp(0, 100);
      final progressText = ' $scrollPercent% ';
      final progressWidth = progressText.length;
      final leftWidth = (termWidth - progressWidth) ~/ 2;
      final rightWidth = termWidth - progressWidth - leftWidth;
      b.writeln(
        _dim('─' * (leftWidth < 0 ? 0 : leftWidth)) +
            _accent2Plain(progressText) +
            _dim('─' * (rightWidth < 0 ? 0 : rightWidth)),
      );
    } else {
      b.writeln();
    }
  }

  /// The menu header row: pickers echo their type-to-filter query
  /// (`[title: query]`), the slash menu is plain '[Commands]'.
  String _menuTitle() {
    if (!menuModelMode) return '[Commands]';
    final title = pickerId == 'models' ? 'Select model' : pickerTitle;
    return modelFilter.isNotEmpty ? '[$title: $modelFilter]' : '[$title]';
  }

  /// The slash/model/picker menu block above the input zone. A picker whose
  /// filter matched nothing keeps its title row plus a dim '(no matches)'
  /// hint — vanishing entirely would hide the query being edited.
  void _writeMenu(StringBuffer b) {
    if (!menuOpen) return;
    if (menuItems.isEmpty) {
      if (menuModelMode) {
        b.writeln(_accent2(_menuTitle()));
        b.writeln(_dim('  (no matches)'));
      }
      return;
    }
    b.writeln(_accent2(_menuTitle()));
    _writeMenuItems(b);
  }

  /// The visible window of menu items, with the scroll-more hint rows when
  /// the list overflows above or below.
  void _writeMenuItems(StringBuffer b) {
    final (start, end) = _menuWindow();
    if (start > 0) b.writeln(_dim('  ↑ more'));
    for (var i = start; i < end; i++) {
      b.writeln(_menuItemRow(menuItems[i], i == menuSelected));
    }
    if (end < menuItems.length) b.writeln(_dim('  ↓ more'));
  }

  /// One menu row (label + dim description, truncated to the width).
  String _menuItemRow(MenuItem item, bool selected) {
    final desc = item.description.isNotEmpty ? ' ${item.description}' : '';
    // Menu rows must never exceed the width: a soft-wrapped chrome line
    // desyncs the renderer's row math and smears frames on every key.
    final full = '${item.label}$desc';
    final prefix = selected ? '${_accent('▸')} ' : '  ';
    if (tuiTextWidth(full) <= termWidth - 2) {
      if (selected) {
        return '$prefix${_accent(item.label)}${_dim(desc)}';
      }
      return '$prefix${item.label}${_dim(desc)}';
    }
    final text = _fitWidth(full, termWidth - 2);
    return selected ? '$prefix${_accent(text)}' : '$prefix$text';
  }

  /// The busy indicator sits directly above the input zone (like pi's
  /// "Working…" row), so it is visible next to the cursor while a run
  /// streams. Queued messages (kimi-cli) render under it, one dim line per
  /// message plus the edit/steer hint, all above the framed input zone.
  void _writeBusyAndQueue(StringBuffer b) {
    if (busy) {
      final frame = _spinnerFrames[spinnerFrame % _spinnerFrames.length];
      final elapsedSeconds = busyStartedAtMs < 0
          ? 0
          : ((DateTime.now().millisecondsSinceEpoch - busyStartedAtMs) / 1000)
                .floor();
      final label = busyPhase.isEmpty ? 'Working…' : busyPhase;
      final quietSeconds = busyLastEventMs < 0
          ? 0
          : ((DateTime.now().millisecondsSinceEpoch - busyLastEventMs) / 1000)
                .floor();
      // Honesty suffixes: WHO armed the row (provenance) and whether the
      // stretch went quiet (no deltas/keys for minutes — reads as a hang,
      // now says so instead of pretending steady progress).
      final provenance = busySource.isEmpty ? '' : ' · $busySource';
      final quiet = quietSeconds >= 180
          ? ' · quiet ${quietSeconds ~/ 60}m'
          : '';
      b.writeln(
        '${_accent2Plain(frame)} '
        '${_dim('$label ${elapsedSeconds}s$quiet$provenance')}',
      );
    }
    if (queue.isNotEmpty) {
      for (final queued in queue) {
        final flat = queued.replaceAll('\n', ' ');
        final line = flat.length > termWidth - 2
            ? '${flat.substring(0, termWidth - 3)}…'
            : flat;
        b.writeln(_dim('❯ $line'));
      }
      b.writeln(_dim('↑ to edit · ctrl-s to send immediately'));
    }
    b.writeln(_dim('─' * termWidth));
  }

  /// The status row, fitted AND padded to the terminal width: a shorter new
  /// status (e.g. switching from a long model id to a short one) must
  /// overwrite the previous row's tail — the renderer only rewrites the
  /// cells the new content covers. Both operations are cell-width aware
  /// (grapheme clusters): UTF-16 padding underpads any status carrying wide
  /// characters and stale cells survive on the right.
  String _statusRow() => _dim(
    tuiPadRight(tuiFitWidth(callbacks.statusLine(), termWidth), termWidth),
  );

  /// The framed input lines with horizontal cursor-window scrolling; returns
  /// the cursor's input line index and screen column for the cursor home.
  (int, int) _writeInputLines(StringBuffer b) {
    final (rows, cursorRow, cursorCol) = _wrappedInput();
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) b.writeln();
      b.write(rows[i]);
    }
    b.writeln();
    return (cursorRow, cursorCol);
  }

  /// The input text soft-wrapped to the terminal width (the whole prompt
  /// stays visible as a paragraph — no horizontal clipping), plus the
  /// cursor's row/column inside the wrapped block. A cursor sitting exactly
  /// past a full-width chunk gets the empty trailing row it points at, so
  /// the row count is cursor-dependent — [_inputLineCount] uses this same
  /// computation and the two never disagree.
  (List<String>, int, int) _wrappedInput() {
    final width = termWidth < 1 ? 1 : termWidth;
    final logical = inputText.split('\n');
    final beforeCursor = inputText.substring(0, cursor);
    final cursorLogicalLine = '\n'.allMatches(beforeCursor).length;
    final lastNl = beforeCursor.lastIndexOf('\n');
    final cursorColInLine = lastNl < 0
        ? beforeCursor.length
        : beforeCursor.length - lastNl - 1;

    final rows = <String>[];
    var cursorRow = 0;
    var cursorCol = 0;
    for (var i = 0; i < logical.length; i++) {
      final lineRows = _wrapInputLine(logical[i], width);
      if (i == cursorLogicalLine) {
        cursorRow = rows.length + cursorColInLine ~/ width;
        cursorCol = cursorColInLine % width;
        if (cursorColInLine == logical[i].length &&
            cursorColInLine > 0 &&
            cursorColInLine % width == 0) {
          // The cursor rests one row past the last full-width chunk.
          lineRows.add('');
        }
      }
      rows.addAll(lineRows);
    }
    return (rows, cursorRow, cursorCol);
  }

  /// One logical input line soft-wrapped to [width]-column rows (always at
  /// least one row, empty when the line is). Extracted from
  /// [_wrappedInput] to keep its CRAP in budget.
  static List<String> _wrapInputLine(String line, int width) {
    final rows = <String>[
      for (var start = 0; start < line.length; start += width)
        line.substring(
          start,
          start + width > line.length ? line.length : start + width,
        ),
    ];
    if (rows.isEmpty) rows.add('');
    return rows;
  }

  static List<String> _appendOutput(
    List<String> lines,
    String text,
    bool newline,
  ) {
    if (text.isEmpty && !newline) return lines;
    final result = List.of(lines);
    final parts = text.split('\n');
    if (result.isEmpty) result.add('');
    result[result.length - 1] += parts.first;
    for (var i = 1; i < parts.length; i++) {
      result.add(parts[i]);
    }
    if (newline) result.add('');
    // Keep the history bounded — but AMORTIZED. Trimming back to exactly
    // maxLines on EVERY append drops the oldest line each flush, and a
    // changed first line breaks TranscriptMarkdown's boundary identity, so
    // once an answer crossed the cap every 50 ms streaming flush paid a
    // full O(history) formatAll+wrap pass (~27 ms at 2000 lines — over half
    // the flush budget): constant scroll/typing jank for long answers. A
    // slack window lets ordinary appends stay on the incremental path; one
    // batch rebuild per [trimSlack] dropped lines is imperceptible.
    const maxLines = 2000;
    const trimSlack = 400;
    if (result.length > maxLines + trimSlack) {
      return result.sublist(result.length - maxLines);
    }
    return result;
  }
}

/// Thin wrapper around [Program] that lets [AgentCli] push output and refresh
/// the model picker without knowing dart_tui internals.
/// Reference-counted busy accounting for the TUI spinner: nested
/// acquire/release pairs (a submit bracket around the run's own bracket,
/// slash commands mid-stream) collapse into ONE 0→1 / 1→0 edge for the
/// model, so the elapsed timer and sticky echo survive re-entry, and an
/// unpaired release clamps at zero instead of poisoning the count.
final class BusyDepth {
  var _depth = 0;

  /// The current nesting depth (0 = idle).
  int get depth => _depth;

  /// Records an acquire ([busy] true) or release; returns whether the model
  /// needs a `BusyMsg` (only the 0→1 / 1→0 edge reaches it).
  bool record(bool busy) {
    final next = math.max(0, _depth + (busy ? 1 : -1));
    final edge = (next > 0) != (_depth > 0);
    _depth = next;
    return edge;
  }
}

final class FaTuiController {
  FaTuiController({
    required this.callbacks,
    required this.isExited,
    this.programHooks,
    this.mouseCapture = true,
  });

  final FaTuiCallbacks callbacks;
  final bool Function() isExited;

  /// Whether the TUI captures the mouse (wheel scrolling); when false the
  /// terminal keeps its native text selection. See
  /// [FaTuiModel.mouseCapture].
  final bool mouseCapture;

  /// Headless test hooks (scripted key bytes, captured frames) — null in
  /// production, where the program reads stdin and renders to stdout.
  final TuiProgramHooks? programHooks;

  late final FaTuiModel _model = FaTuiModel(
    callbacks: callbacks,
    isExited: isExited,
    mouseCapture: mouseCapture,
  );
  late final Program _program = Program(
    options: [
      withAltScreen(),
      withHideCursor(false),
      if (mouseCapture) withMouseCellMotion(),
      ..._programHookOptions(programHooks),
    ],
  );

  /// Messages sent before [run] starts (e.g. the banner printed while the
  /// controller is already wired into the IO but the program is not yet
  /// listening). dart_tui drops sends that arrive before the event loop, so
  /// they are replayed into the initial model at [run] time instead.
  final List<Msg> _pending = [];
  var _running = false;

  /// Streaming text coalesces here and flushes on a short timer (or right
  /// before any non-output message, to preserve ordering). A fast token
  /// stream used to cost one model update — and one full markdown pass over
  /// the whole output history — PER DELTA, saturating the event loop so
  /// keystrokes queued up behind them (typing lag while a run streamed).
  final _outputBuffer = StringBuffer();
  Timer? _outputFlushTimer;
  // 16ms (~60 fps): frames are micro-cheap (traced p50 build 37µs on a
  // huge session), so flushing thrice as often just makes streamed text
  // — thinking included — appear smooth instead of in 50ms chunks.
  static const _outputFlushInterval = Duration(milliseconds: 16);

  FaTuiModel get model => _model;

  void _send(Msg msg) {
    if (msg is! OutputMsg) _flushOutput();
    if (_running) {
      _program.send(msg);
    } else {
      _pending.add(msg);
    }
  }

  void sendOutput(String text, {bool newline = false}) {
    // Merge semantics match sending the pieces separately: text just
    // concatenates and the newline flag is a trailing '\n' (the model's
    // _appendOutput splits on '\n' and its trailing empty part plays the
    // role of the flag's extra empty line).
    _outputBuffer.write(text);
    if (newline) _outputBuffer.write('\n');
    if (_running) {
      _outputFlushTimer ??= Timer(_outputFlushInterval, _flushOutput);
    } else {
      _flushOutput();
    }
  }

  void _flushOutput() {
    _outputFlushTimer?.cancel();
    _outputFlushTimer = null;
    if (_outputBuffer.isEmpty) return;
    final text = _outputBuffer.toString();
    _outputBuffer.clear();
    _send(OutputMsg(text));
  }

  void sendModelsRefresh() {
    _send(_ModelsRefreshMsg());
  }

  void openModelMenu() {
    _send(_OpenModelMenuMsg());
  }

  /// Opens a generic host picker (sessions, mode, approval, ...) with a
  /// static item list; selection resolves via [FaTuiCallbacks.onPickerSelected].
  void openPicker(
    String pickerId,
    String title,
    List<MenuItem> items, {
    String? initialKey,
  }) {
    var selected = 0;
    if (initialKey != null) {
      final index = items.indexWhere((item) => item.key == initialKey);
      if (index >= 0) selected = index;
    }
    _send(OpenPickerMsg(pickerId, title, items, initialIndex: selected));
  }

  void sendQuit() {
    _send(_QuitRequestedMsg());
  }

  /// Replaces the composer text (the `/skills` menu prefills `/skill:<name> `
  /// so the user can type arguments before pressing Enter).
  void sendInputText(String text) {
    _send(_SetInputTextMsg(text));
  }

  /// Opens the interactive prompt zone (ask/secret/approval) and resolves
  /// when the user answers (or cancels). The caller awaits the returned
  /// future, which completes from the model once the prompt key handler
  /// produces an answer.
  Future<TuiPromptAnswer?> openPrompt(TuiPromptSpec spec) {
    final completer = Completer<TuiPromptAnswer?>();
    _send(OpenPromptMsg(spec, completer));
    return completer.future;
  }

  var _busyDepth = 0;

  /// Toggles the animated thinking indicator while a run streams.
  ///
  /// Reference-counted: a second submit during a running turn (slash
  /// commands work mid-stream) must NOT reset the elapsed timer + sticky
  /// echo on re-enter, and its finally-branch must NOT switch the spinner
  /// off while the first run is still streaming.
  void sendBusy(bool busy, {String source = 'run'}) {
    // Clamp at zero so an unpaired release cannot poison the count.
    final depth = math.max(0, _busyDepth + (busy ? 1 : -1));
    final wasBusy = _busyDepth > 0;
    _busyDepth = depth;
    // Only the 0→1 / 1→0 edges reach the model; a re-entrant submit
    // (slash command mid-stream) keeps the spinner and elapsed timer.
    if ((depth > 0) != wasBusy) _send(BusyMsg(busy, source: source));
  }

  /// Relabels the busy row while a run streams (silent post-answer phases:
  /// auto-compaction, durable-memory extraction) WITHOUT restarting the
  /// spinner loop or resetting the elapsed window — the user sees WHAT is
  /// happening instead of a growing "Working… Ns" that reads like a hang.
  void setBusyPhase(String phase) {
    // Suppress post-run stragglers: at depth zero there is no live busy
    // stretch to relabel, and a raw BusyMsg(true) reaching an idle model
    // would resurrect the row (the model guards too — belt and braces for
    // a bug class that already burned a night at 100% CPU).
    if (_busyDepth <= 0) return;
    _send(BusyMsg(true, phase: phase));
  }

  /// Drains the queued messages (the model echoes them into the history) —
  /// the host runs them as separate turns after the current one settles.
  Future<List<String>> drainQueue() {
    final completer = Completer<List<String>>();
    _send(DrainQueueMsg(completer));
    return completer.future;
  }

  Future<void> run() async {
    _running = true;
    var model = _model;
    for (final msg in _pending) {
      model = model.update(msg).$1 as FaTuiModel;
    }
    _pending.clear();
    final savedTermios = await _disableTerminalFlowControl();
    try {
      await _program.run(model);
    } finally {
      if (savedTermios != null) await _restoreTermios(savedTermios);
    }
  }

  /// dart_tui's raw mode flips only Dart's echo/line flags; termios IXON
  /// (software flow control) stays on, so on terminals without the Kitty
  /// keyboard protocol Ctrl+S is the tty driver's VSTOP byte: the tty
  /// swallows the keypress and suspends output (XOFF) — the UI freezes while
  /// the app stays alive, and the steer never fires. Disable flow control
  /// for the TUI's lifetime; returns the saved termios string for
  /// [_restoreTermios], or null when there is no tty to fix.
  static Future<String?> _disableTerminalFlowControl() async {
    if (Platform.isWindows) return null;
    if (!stdin.hasTerminal) return null;
    return sttyDisableFlowControl(
      sttyDeviceFlag(),
      runner: (args) => Process.run('stty', args),
    );
  }

  /// The BSD/GNU device flag for `stty` (`-f` on macOS, `-F` elsewhere).
  static String sttyDeviceFlag() => Platform.isMacOS ? '-f' : '-F';

  /// Disables terminal flow control via `stty` and returns the saved termios
  /// string. [runner] is injected so tests can avoid real subprocesses.
  ///
  /// Public (package-visible) only for testing; do not call directly.
  static Future<String?> sttyDisableFlowControl(
    String deviceFlag, {
    required Future<ProcessResult> Function(List<String> args) runner,
  }) async {
    try {
      final saved = await runner([deviceFlag, '/dev/tty', '-g']);
      if (saved.exitCode != 0) return null;
      final cleared = await runner([deviceFlag, '/dev/tty', '-ixon', '-ixoff']);
      if (cleared.exitCode != 0) return null;
      return (saved.stdout as String).trim();
    } on ProcessException {
      return null; // no stty on PATH — leave the tty untouched
    }
  }

  static Future<void> _restoreTermios(String saved) async {
    final deviceFlag = Platform.isMacOS ? '-f' : '-F';
    try {
      await Process.run('stty', [deviceFlag, '/dev/tty', saved]);
    } on ProcessException {
      // Nothing sensible left to do — the next shell's own reset covers it.
    }
  }
}
