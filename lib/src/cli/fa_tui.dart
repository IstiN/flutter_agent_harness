import 'dart:async';
import 'dart:math' as math;
import 'dart:convert' show latin1, utf8;
import 'dart:io'
    show IOSink, Platform, Process, ProcessException, ProcessResult, stdin;

import 'package:dart_tui/dart_tui.dart';
import 'package:meta/meta.dart';

import 'composer_overlay.dart';
import 'ansi_markdown.dart';
import 'agent_hub_tui.dart';
import 'model_picker_table.dart' show modelPickerFooterHint;
import 'package:characters/characters.dart';
import 'tui_hit_regions.dart';
import 'tui_prompt.dart';
import 'tui_theme.dart';
import 'tui_repl.dart' show MenuItem, QueuedMessage, TuiProgramHooks;
import 'system_notice_render.dart';
import 'tui_text_width.dart'
    show tuiFitWidth, tuiGraphemeWidth, tuiPadRight, tuiTextWidth;
import '../messaging/scheduled_messages.dart' show ScheduledMessageQueue;
import 'paste_image.dart';

part 'fa_tui_messages.dart';
part 'fa_tui_hub.dart';
part 'fa_tui_mouse.dart';
part 'fa_tui_rows.dart';
part 'fa_tui_paste.dart';
part 'fa_tui_theme_swap.dart';
part 'fa_tui_controller_io.dart';
part 'fa_tui_picker.dart';
part 'fa_tui_composer.dart';

/// Translates the (web-safe) headless test hooks into dart_tui program
/// options: a scripted key byte stream replaces stdin, the rendered frames
/// go to the given byte consumer, and the OS signal handler stays off (the
/// test runner owns the signals). Empty without hooks.
List<ProgramOption> _programHookOptions(TuiProgramHooks? hooks) {
  if (hooks == null) return const [];
  return [
    if (hooks.input != null) withInput(hooks.input),
    if (hooks.output != null) withOutput(IOSink(hooks.output!)),
    if (hooks.width != null && hooks.height != null)
      withWindowSize(hooks.width!, hooks.height!),
    withoutSignalHandler(),
  ];
}

/// The session TUI theme (issue #279) supplies every palette escape;
/// width math in the view always uses the raw strings — escapes are
/// added only at write time. Byte-identical to the historical site
/// palette (teal #5eead4, indigo #818cf8) under the default theme.
String _accent(String s) => tuiAccent(s);
String _accent2(String s) => tuiAccent2(s);
String _accent2Plain(String s) => tuiAccent2Soft(s);
String _dim(String s) => tuiDim(s);

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
    this.pathCandidates,
    this.onHubAction,
    this.readClipboardImage,
  });

  /// Called when the user submits a non-empty input line. [images] carries
  /// the clipboard chips attached via Ctrl+V (empty for slash/bang
  /// commands — those never consume attachments).
  final Future<void> Function(String line, {List<TuiImageAttachment> images})
  onSubmit;

  /// Called when the user picks a model from the picker.
  final Future<void> Function(String modelId) onModelSelected;

  /// Builds slash-command menu items for the given prefix.
  final List<MenuItem> Function(String prefix) buildSlashMenu;

  /// Builds model-picker menu items (the resolved table) for the filter at
  /// the given terminal width — the width drives the column elision.
  final List<MenuItem> Function(String filter, int width) buildModelMenu;

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

  /// Workspace file paths for the composer's fuzzy path completion
  /// (`@token` and shell words on a `!` line, issue #275 AC1). Called per
  /// keystroke — the host must cache the listing (the issue's "candidates
  /// cached" clause). Null disables path completion.
  final List<String> Function(String fragment)? pathCandidates;

  /// Reads the platform pasteboard for an image (Ctrl+V). Null = no
  /// reader wired (prints the unavailable hint). Runs OFF the UI loop —
  /// the result comes back as a [PasteboardResultMsg].
  final Future<PasteboardRead> Function()? readClipboardImage;

  /// Agents-hub overlay actions (issue #277): [FaHubAction.enter] drills
  /// into the selected agent's transcript ([key] = row key), back returns
  /// from a transcript to the tree, close hides the overlay. The host
  /// pushes fresh [HubStateMsg] content in response.
  final Future<void> Function(String action, String? key)? onHubAction;
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
    LineEditor? editor,
    this.scrollOffset = 0,
    this.followTail = true,
    this.menuOpen = false,
    this.menuModelMode = false,
    this.menuSelected = 0,
    this.menuTokenStart = -1,
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
    this.runStalled = false,
    this.mouseCapture = true,
    this.spinnerFrame = 0,
    this.stickyLines = const [],
    this.stickyIndex = -1,
    this.stickyEchoLineCount = 0,
    this.queue = const [],
    this.attachments = const [],
    this.inputHistory = const [],
    this.historyIndex = -1,
    this.historyDraft,
    this.scheduledCount = 0,
    this.scheduledNextDueMs = -1,
    this.jobBoardLines = const [],
    this.waitingJobs = const [],
    this.waitingTimers = const [],
    this.waitingLostJobs = 0,
    this.scheduledTickPending = false,
    this.frameNonce = 0,
    this.hub,
    DateTime Function()? now,
  }) : nowFn = now ?? DateTime.now,
       editor = editor ?? const LineEditor.empty();

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

  /// The readline-grade line editor (issue #275 scope 3): single source of
  /// truth for the composer text + caret, carrying the per-session
  /// kill-ring and grouped undo (E4: the ring survives submissions —
  /// the model lives for the whole session).
  final LineEditor editor;

  String get inputText => editor.text;
  int get cursor => editor.cursor;

  /// The open agents-hub overlay state (issue #277); null when closed.
  final FaHubState? hub;

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

  /// Where the completed token starts inside [inputText] (issue #275):
  /// 0 for a slash command line, the offset after '@' or the shell-word
  /// start for path completion. -1 = no token (whole-input replace on
  /// accept, the legacy slash/picker behavior).
  final int menuTokenStart;
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

  /// Whether the run is currently wedged (issue #514): pushed by the
  /// host's wedge watchdog (heartbeat silent past `steeringStaleAfter`)
  /// — the busy row's `Stalled…` label reads this instead of guessing
  /// from TUI output activity.
  final bool runStalled;

  /// Pending scheduled follow-up messages (`schedule_message` records this
  /// instance can still deliver); 0 hides the indicator row (issue #115).
  final int scheduledCount;

  /// Earliest pending due time (epoch ms; -1 unknown) — rendered as the
  /// "next in 25m" suffix.
  final int scheduledNextDueMs;

  /// The background-job board's live region (issue #429): summary lines +
  /// live rows, dim, above the busy row. Empty hides the region.
  final List<String> jobBoardLines;

  /// The visible-waiting row state (issue #450): purposes of the running
  /// background jobs and the armed self-wake timers (due epoch ms +
  /// preview), pushed by the host on every waiter enter/leave. The row
  /// renders only while idle — the busy row owns the screen while working.
  final List<String> waitingJobs;
  final List<({int dueMs, String preview})> waitingTimers;

  /// Background jobs the previous run of this session left running — the
  /// honesty note under the waiting row after a restart.
  final int waitingLostJobs;

  /// Whether a [ScheduledTickMsg] timer is outstanding (issue #213) — the
  /// guard that keeps the countdown chain at one pending timer max.
  final bool scheduledTickPending;

  /// Clock seam (issue #213 tests): the scheduled-row ETA and the tick
  /// delay read this instead of [DateTime.now] directly.
  final DateTime Function() nowFn;

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

  /// Messages typed while a run streams (kimi-cli's queue): Enter enqueues
  /// a follow-up, ↑ pops the last one back into the input, ctrl+x deletes
  /// it, ctrl+s steers everything into the running agent, and the host
  /// drains them as separate turns afterwards. [QueuedMessage.steer] rows
  /// interrupt at the next step boundary (the soft-yield steering path)
  /// and render badged; plain rows wait for the run to settle.
  final List<QueuedMessage> queue;

  /// Clipboard images attached via Ctrl+V, waiting in the composer as
  /// chips; consumed by the next plain submit (slash/bang commands keep
  /// them), rendered above the input frame.
  final List<TuiImageAttachment> attachments;

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

  /// Hit-regions of the LAST RENDERED frame + press/drag router (issue
  /// #278): input plumbing, NOT model state; view() rebuilds the registry
  /// (E2), copyWith carries all three (press survives copies, hint once).
  TuiHitRegionRegistry _hitRegions = TuiHitRegionRegistry();
  TuiMouseRouter _mouseRouter = TuiMouseRouter();

  /// Whether the E4 degrade hint already printed this session.
  bool _mouseHintShown = false;

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
    // NOTE: deliberately the RAW scroll offset — the effective (tail-riding)
    // offset lives in view(); routing _scrollBottom through here would
    // recurse (the plan needs sticky, sticky would need the plan's viewport).
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

  /// Exact number of lines the open menu occupies in the view (including
  /// the models-table footer hint row when a models-family picker is open).
  int get _menuReservedLines {
    if (!menuOpen || menuItems.isEmpty) return 0;
    final (start, end) = _menuWindow();
    var lines = 1 + (end - start); // title + items
    lines += _groupHeadersIn(start, end); // section headers
    if (start > 0) lines++; // '↑ more'
    if (end < menuItems.length) lines++; // '↓ more'
    if (_modelPickerFamilyOpen) lines++; // footer hint
    return lines;
  }

  /// Group-header rows the visible window renders (one per group change,
  /// issue #275) — the height math and the renderer must agree.
  int _groupHeadersIn(int start, int end) {
    var count = 0;
    var last = '';
    for (var i = start; i < end; i++) {
      final group = menuItems[i].group;
      if (group.isNotEmpty && group != last) count++;
      last = group;
    }
    return count;
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
    LineEditor? editor,
    int? scrollOffset,
    bool? followTail,
    bool? menuOpen,
    bool? menuModelMode,
    int? menuSelected,
    int? menuTokenStart,
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
    List<QueuedMessage>? queue,
    List<TuiImageAttachment>? attachments,
    List<String>? inputHistory,
    int? historyIndex,
    int? scheduledCount,
    int? scheduledNextDueMs,
    List<String>? jobBoardLines,
    List<String>? waitingJobs,
    List<({int dueMs, String preview})>? waitingTimers,
    int? waitingLostJobs,
    bool? scheduledTickPending,
    bool? runStalled,
    Object? historyDraft = _unset,
    FaHubState? hub,
    bool clearHub = false,
  }) {
    final copy = FaTuiModel(
      callbacks: callbacks,
      isExited: isExited,
      prompt: clearPrompt ? null : (prompt ?? this.prompt),
      outputLines: outputLines ?? this.outputLines,
      editor:
          editor ??
          (inputText == null && cursor == null
              ? this.editor
              : this.editor.withBuffer(
                  LineBuffer(
                    inputText ?? this.inputText,
                    cursor ?? this.cursor,
                  ),
                )),
      scrollOffset: scrollOffset ?? this.scrollOffset,
      followTail: followTail ?? this.followTail,
      menuOpen: menuOpen ?? this.menuOpen,
      menuModelMode: menuModelMode ?? this.menuModelMode,
      menuSelected: menuSelected ?? this.menuSelected,
      menuTokenStart: menuTokenStart ?? this.menuTokenStart,
      modelFilter: modelFilter ?? this.modelFilter,
      menuItems: menuItems ?? this.menuItems,
      menuAllItems: menuAllItems ?? this.menuAllItems,
      pickerId: pickerId ?? this.pickerId,
      pickerTitle: pickerTitle ?? this.pickerTitle,
      runStalled: runStalled ?? this.runStalled,
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
      attachments: attachments ?? this.attachments,
      inputHistory: inputHistory ?? this.inputHistory,
      historyIndex: historyIndex ?? this.historyIndex,
      scheduledCount: scheduledCount ?? this.scheduledCount,
      scheduledNextDueMs: scheduledNextDueMs ?? this.scheduledNextDueMs,
      jobBoardLines: jobBoardLines ?? this.jobBoardLines,
      waitingJobs: waitingJobs ?? this.waitingJobs,
      waitingTimers: waitingTimers ?? this.waitingTimers,
      waitingLostJobs: waitingLostJobs ?? this.waitingLostJobs,
      scheduledTickPending: scheduledTickPending ?? this.scheduledTickPending,
      now: nowFn,
      historyDraft: historyDraft == _unset
          ? this.historyDraft
          : historyDraft as String?,
      hub: clearHub ? null : (hub ?? this.hub),
      // Every copy is a new model state: bump the frame nonce so the view's
      // cursor line always differs after a change (see [frameNonce]).
      frameNonce: frameNonce + 1,
    );
    copy._wrapCache = _wrapCache;
    copy._stickyFmtRows = _stickyFmtRows;
    copy._stickyFmtSource = _stickyFmtSource;
    copy._stickyFmtWidth = _stickyFmtWidth;
    copy._promptCompleter = _promptCompleter;
    copy._hitRegions = _hitRegions;
    copy._mouseRouter = _mouseRouter;
    copy._mouseHintShown = _mouseHintShown;
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

  /// Arms the one-shot minute-boundary repaint for the scheduled-follow-ups
  /// countdown (issue #213, fix option A): the ETA renders in whole minutes
  /// (`ScheduledMessageQueue.formatDelay`), so waking at the next wall-clock
  /// minute boundary is exact — no sub-minute waste, no timers while nothing
  /// is scheduled, and the "due now" flip appears within a minute.
  Cmd _scheduleScheduledTick() {
    final nowMs = nowFn().millisecondsSinceEpoch;
    final delayMs = 60000 - (nowMs % 60000);
    return () async {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      return const ScheduledTickMsg();
    };
  }

  @override
  (Model, Cmd?) update(Msg msg) {
    // Activity heartbeat for the busy row: any real message while busy
    // (stream deltas, tool rows, key input) proves the stretch is alive;
    // only spinner ticks and busy bookkeeping are excluded.
    final FaTuiModel self =
        (busy &&
            msg is! SpinnerTickMsg &&
            msg is! BusyMsg &&
            msg is! RunStalledMsg &&
            msg is! ScheduledTickMsg)
        ? copyWith(busyLastEventMs: DateTime.now().millisecondsSinceEpoch)
        : this;
    return self._updateWithHeartbeat(msg);
  }

  (Model, Cmd?) _updateWithHeartbeat(Msg msg) {
    final scheduled = _updateScheduled(msg);
    if (scheduled != null) return scheduled;
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
    if (msg is RunStalledMsg) return _handleRunStalled(msg);
    if (msg is SpinnerTickMsg) return _handleSpinnerTick();
    if (msg is DrainQueueMsg) return _handleDrainQueue(msg);
    if (msg is ClearQueueMsg) return _handleClearQueue();
    if (msg is OpenPromptMsg) {
      _promptCompleter = msg.completer;
      return (copyWith(prompt: TuiPromptState(msg.spec)), null);
    }
    if (isExited()) return (this, () => quit());
    return _updateAfterExitCheck(msg);
  }

  /// Scheduled/waiting dispatch group ([_updateWithHeartbeat] prefix):
  /// host-pushed count/ETA updates, the minute-boundary tick, the job
  /// board and the waiting row. Returns `null` when [msg] belongs to a
  /// later group.
  (Model, Cmd?)? _updateScheduled(Msg msg) {
    if (msg is ScheduledStatusMsg) return _handleScheduledStatus(msg);
    if (msg is ScheduledTickMsg) return _handleScheduledTick();
    if (msg is JobBoardMsg) return _handleJobBoard(msg);
    if (msg is WaitingStatusMsg) return _handleWaitingStatus(msg);
    return null;
  }

  /// The scheduled follow-ups indicator is a host push for the count/ETA;
  /// while a countdown is showing the model also arms a one-shot
  /// minute-boundary tick (issue #213) so the idle "next in Nm" keeps
  /// ticking — [scheduledTickPending] caps the chain at one timer.
  (Model, Cmd?) _handleScheduledStatus(ScheduledStatusMsg msg) {
    final next = copyWith(
      scheduledCount: msg.count,
      scheduledNextDueMs: msg.nextDueMs ?? -1,
    );
    if (next.scheduledCount > 0 &&
        next.scheduledNextDueMs >= 0 &&
        !scheduledTickPending) {
      return (
        next.copyWith(scheduledTickPending: true),
        _scheduleScheduledTick(),
      );
    }
    return (next, null);
  }

  /// The background-job board's live region (issue #429): the host pushes
  /// pre-rendered lines; an empty list hides the region.
  (Model, Cmd?) _handleJobBoard(JobBoardMsg msg) =>
      (copyWith(jobBoardLines: msg.lines), null);

  /// True while any countdown is on screen (issue #115 scheduled row, and
  /// the waiting row's timer countdown — issue #450): the shared
  /// minute-boundary tick chain repaints both.
  bool get _hasCountdown =>
      (scheduledCount > 0 && scheduledNextDueMs >= 0) ||
      waitingTimers.isNotEmpty;

  /// The minute-boundary countdown tick fired (issue #213): the row
  /// recomputes from [nowFn] at render time, so the repaint alone refreshes
  /// the ETA; re-arm while there is still a countdown to show ([_hasCountdown]).
  (Model, Cmd?) _handleScheduledTick() {
    final next = copyWith(scheduledTickPending: false);
    if (!next._hasCountdown) {
      return (next, null);
    }
    return (
      next.copyWith(scheduledTickPending: true),
      _scheduleScheduledTick(),
    );
  }

  (Model, Cmd?) _handleOutputMsg(OutputMsg msg) {
    // System-notice blocks and service lines (the compaction report
    // header) render as dim blockquotes, not raw text.
    final displayText = needsSystemNoticeRewrite(msg.text)
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

  /// The wedge watchdog's liveness push (issue #514): flips the busy row's
  /// label to `Stalled…` (and back) without touching the elapsed window —
  /// the stall is a STATE, not a phase relabel.
  (Model, Cmd?) _handleRunStalled(RunStalledMsg msg) =>
      (copyWith(runStalled: msg.stalled), null);

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
        // A new bracket always starts unstalled: the host pushes the
        // stall state per-episode, so a stale `Stalled…` must never
        // leak into the next run (issue #514).
        runStalled: msg.busy ? runStalled : false,
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
    // settles; echo them into the history as they are handed out. Flush
    // order is queue order (AC2).
    final queued = queue;
    msg.completer.complete([for (final m in queued) m.text]);
    if (queued.isEmpty) return (this, null);
    var lines = outputLines;
    for (final message in queued) {
      lines = _echoAppend(lines, message.text);
    }
    final cleared = copyWith(queue: const [], outputLines: lines);
    final next = cleared.copyWith(
      scrollOffset: cleared._scrollBottom(cleared._wrappedLines()),
      followTail: true,
    );
    return (next, null);
  }

  (Model, Cmd?) _handleClearQueue() {
    if (queue.isEmpty) return (this, null);
    return (copyWith(queue: const []), null);
  }

  /// Test seam: drives the composer prefill (`/skills` menu →
  /// `sendInputText`) into the model without a running program, so the
  /// message branch is exercisable headlessly.
  @visibleForTesting
  FaTuiModel setInputTextForTest(String text) =>
      update(_SetInputTextMsg(text)).$1 as FaTuiModel;

  (Model, Cmd?) _updateAfterExitCheck(Msg msg) {
    if (msg is _ModelsRefreshMsg) return _handleModelsRefresh();
    if (msg is _ThemeChangedMsg) return _handleThemeChanged();
    if (msg is _OpenModelMenuMsg) return _handleOpenModelMenu();
    if (msg is OpenPickerMsg) return _handleOpenPicker(msg);
    if (msg is HubStateMsg) return _handleHubStateMsg(msg);
    if (msg is _CloseHubMsg) return (copyWith(clearHub: true), null);

    if (msg is _SetInputTextMsg) {
      return (
        copyWith(
          inputText: msg.text,
          cursor: msg.text.length,
          menuOpen: false,
          menuTokenStart: -1,
        ),
        null,
      );
    }
    if (msg is SetInputHistoryMsg) {
      return (
        copyWith(
          inputHistory: msg.history,
          historyIndex: -1,
          historyDraft: null,
        ),
        null,
      );
    }
    if (msg is _QuitRequestedMsg) return (this, () => quit());
    if (msg is ThemeSwappedMsg) return _handleThemeSwapped();
    if (msg is PasteboardResultMsg) return _handlePasteboardResult(msg);
    return _handleTerminalMsg(msg);
  }

  /// Terminal events: resizes, mouse wheel scrolling, pastes, keys.
  (Model, Cmd?) _handleTerminalMsg(Msg msg) {
    if (msg is WindowSizeMsg) return _handleWindowSize(msg);
    if (msg is MouseClickMsg) return _handleMouseClick(msg);
    if (msg is MouseMotionMsg) return _handleMouseMotion(msg);
    if (msg is MouseReleaseMsg) return _handleMouseRelease(msg);
    if (msg is MouseWheelMsg) return _handleMouseWheel(msg);
    if (msg is PasteMsg) return _handlePaste(msg);
    return _handleKeyMsg(msg);
  }

  /// Key events: runes split, then every key through the mode-aware clusters.
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

  /// Theme switched (issue #279): drop rendered-color caches and repaint.
  /// The wrap cache holds text geometry only (colors apply at emit time),
  /// so invalidation is a cache reset plus a redraw on the next frame
  /// boundary — never a torn frame (E1).
  (Model, Cmd?) _handleThemeChanged() {
    final copy = copyWith(menuSelected: menuSelected);
    copy._wrapCache = _WrapCache();
    // The sticky echo caches formatted rows keyed on width+content —
    // both unchanged by a theme switch — so drop it explicitly or the
    // pinned lines keep the old palette until the next submit.
    copy._stickyFmtSource = null;
    return (copy, null);
  }

  /// Test seam: the private [_ThemeChangedMsg] (tests drive the model
  /// update loop directly and cannot name the class).
  static Msg themeChangedMsgForTest() => _ThemeChangedMsg();

  /// Whether the open menu is the model picker (not the slash menu).
  bool get _modelPickerOpen => menuOpen && menuModelMode;

  /// Rebuilds the open model picker's items, keeping the selection in
  /// bounds.
  (Model, Cmd?) _refreshedModelMenu() {
    final items = callbacks.buildModelMenu(modelFilter, termWidth);
    final selected = items.isEmpty
        ? 0
        : menuSelected.clamp(0, items.length - 1);
    return (copyWith(menuItems: items, menuSelected: selected), null);
  }

  (Model, Cmd?) _handleOpenModelMenu() {
    final items = callbacks.buildModelMenu('', termWidth);
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
    // Capture off: the hint says wheel is disabled — honor it even for
    // bytes a not-yet-disarmed terminal still sends (issue #278, AC4).
    if (!mouseCapture) return (this, null);
    // Hub overlay: the wheel moves the fleet-tree selection.
    if (hub != null) {
      final delta = switch (msg.mouse.button) {
        MouseButton.wheelUp => -1,
        MouseButton.wheelDown => 1,
        _ => 0,
      };
      if (delta != 0) {
        final (next, _) = hub!.handleKey(
          delta < 0 ? 'up' : 'down',
          viewport: _viewportHeight - 3,
        );
        return (copyWith(hub: next), null);
      }
      return (this, null);
    }
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
    // One insert call = one undo group: a paste undoes as a whole.
    return (copyWith(editor: editor.insert(content)), null);
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
    // Hub overlay: a full-screen modal owns every key while open (before
    // prompt/menu so the overlay is not shortcut through those zones).
    if (hub != null) return _handleHubKey(msg);

    // Prompt mode: route keys to the interactive prompt zone.
    if (prompt != null) return _handlePromptKey(msg);

    // Picker mode: arrows navigate, enter/tab select, esc closes.
    if (menuOpen && menuModelMode) return _handlePickerKey(msg);

    // Slash/menu mode: arrows navigate, enter/tab accept, esc closes, and
    // typing keeps editing so `/models` can be typed in full. Path
    // overlays (@token / !word) are passive — Tab accepts, Enter keeps
    // submitting (issue #275 review).
    if (menuOpen) {
      if (menuTokenStart > 0) {
        final pathKey = _handlePathMenuKey(msg);
        if (pathKey != null) return pathKey;
      } else {
        return _handleSlashMenuKey(msg);
      }
    }

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

  /// Path-completion overlay keys: Tab accepts, arrows navigate, esc
  /// closes; everything else falls through (Enter SUBMITS, editing edits).
  (Model, Cmd?)? _handlePathMenuKey(KeyMsg msg) {
    switch (msg.key) {
      case 'tab':
        return _acceptSlashMenuItem();
      case 'esc':
        return (copyWith(menuOpen: false, menuTokenStart: -1), null);
      case 'up':
      case 'down':
        return _handleSlashMenuNavKey(msg);
      default:
        return null;
    }
  }

  /// Slash-menu navigation keys (esc/up/down); null when the key belongs to
  /// the accept or edit clusters.
  (Model, Cmd?)? _handleSlashMenuNavKey(KeyMsg msg) {
    switch (msg.key) {
      case 'esc':
        return (copyWith(menuOpen: false, menuTokenStart: -1), null);
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
          return (
            _updateMenuForInput(copyWith(editor: editor.backspace())),
            null,
          );
        }
        return (this, null);
      default:
        final text = msg.keyEvent.text;
        if (text.isNotEmpty && text.length == 1) {
          return (
            _updateMenuForInput(copyWith(editor: editor.insert(text))),
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
          menuItems: callbacks.buildModelMenu('', termWidth),
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
        copyWith(menuOpen: false, inputText: '', cursor: 0, pickerId: ''),
        () async {
          await callbacks.onSubmit(item.key, images: const []);
          return null;
        },
      );
    }
    // Token splice (issue #275): replace just the completed token — an
    // `@`-fragment or a shell word after '!' — with the chosen path plus a
    // trailing space that ends the token. Slash commands (tokenStart == 0,
    // line-start) keep the legacy whole-input replace below.
    if (menuTokenStart > 0) {
      final head = inputText.substring(0, menuTokenStart);
      final tail = inputText.substring(
        cursor.clamp(menuTokenStart, inputText.length),
      );
      final inserted = '${item.key} ';
      return (
        copyWith(
          inputText: head + inserted + tail,
          cursor: menuTokenStart + inserted.length,
          menuOpen: false,
          menuTokenStart: -1,
        ),
        null,
      );
    }
    return (
      copyWith(
        inputText: item.key,
        cursor: item.key.length,
        menuOpen: false,
        menuTokenStart: -1,
      ),
      null,
    );
  }

  /// Normal-mode control keys (submit/steer/newline/interrupt/abort); null
  /// when the key belongs to another cluster.
  (Model, Cmd?)? _handleControlKey(KeyMsg msg) {
    return _handlePasteImageKey(msg) ??
        _handleSubmitKeys(msg) ??
        _handleQueueKeys(msg) ??
        _handleInterruptKeys(msg);
  }

  /// Normal-mode submit keys (enter/ctrl+s) and the newline-insertion
  /// fallbacks (ctrl+o/ctrl+j); null when the key belongs to another cluster.
  (Model, Cmd?)? _handleSubmitKeys(KeyMsg msg) {
    switch (msg.key) {
      case 'enter':
        return _handleEnterKey();
      case 'ctrl+s':
        if (busy) {
          // Marks the pending input as a steering row (AC2 badge has a
          // production producer), then steers the whole queue — the
          // steered payload is unchanged.
          final pending = inputText.trim();
          var model = this;
          if (pending.isNotEmpty) {
            model = model._enqueue(pending, steer: true).$1;
          }
          return model._steerAll(includePending: false);
        }
        // Ctrl+S always submits, regardless of terminal Shift+Enter support.
        final text = inputText.trim();
        if (text.isEmpty) return (this, null);
        return _submit(text);
      case 'ctrl+o':
      case 'ctrl+j':
      case 'shift+enter':
      case 'alt+enter':
        // Fallback newline insertion (modifyOtherKeys Shift+Enter is mapped
        // to Ctrl+O by the input preprocessor on supporting terminals;
        // kitty-protocol terminals deliver Shift+Enter as a literal
        // 'shift+enter' keystroke — it used to fall through and die as a
        // no-op; legacy terminals without kitty/modifyOtherKeys send the
        // ESC CR encoding, which decodes as 'alt+enter').
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

  /// Queue-row keys while a run streams: ctrl+x deletes the last queued
  /// row (issue #275 AC2). Idle ctrl+x is NOT handled here — it stays an
  /// unhandled combo that must never insert its letter.
  (Model, Cmd?)? _handleQueueKeys(KeyMsg msg) {
    if (msg.key != 'ctrl+x') return null;
    if (!busy || queue.isEmpty) return (this, null);
    return (copyWith(queue: queue.sublist(0, queue.length - 1)), null);
  }

  /// Normal-mode Enter: submit, queue while busy, or Shift+Enter newline.
  (Model, Cmd?) _handleEnterKey() {
    // Enter submits; Shift+Enter inserts a newline. Terminals that do not
    // distinguish Shift+Enter in the input stream use the host modifier
    // check (Core Graphics on macOS, session-gated — issue #355).
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
  /// then browses the submitted-message history; ↓ walks it back.
  /// Viewport scrolling lives on PgUp/PgDn (and the wheel when captured).
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
                inputText: popped.text,
                cursor: popped.text.length,
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
    final result =
        _handleLeftRightKey(msg) ??
        _handleWordNavKey(msg) ??
        _handleHomeEndKey(msg);
    if (result == null) return null;
    // The completion token is cursor-anchored: motion re-evaluates the
    // overlay (issue #275) — moving off a token closes it, moving onto
    // one opens it.
    return (_updateMenuForInput(result.$1 as FaTuiModel), result.$2);
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
        _handleReadlineKey(msg) ??
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
        return (
          _updateMenuForInput(copyWith(editor: editor.backspace())),
          null,
        );
      default:
        return null;
    }
  }

  /// Normal-mode kill keys on the editor's kill-ring (issue #275): ctrl+u
  /// kills back to the line start, ctrl+w the word before the cursor.
  /// Null when the key belongs to another cluster.
  (Model, Cmd?)? _handleKillKey(KeyMsg msg) {
    switch (msg.key) {
      case 'ctrl+u':
        // Kill from the cursor back to the start of the line (readline's
        // unix-line-discard — also what most terminals send for Cmd+Backspace).
        if (cursor == 0) return (this, null);
        return (
          _updateMenuForInput(copyWith(editor: editor.killToLineStart())),
          null,
        );
      case 'ctrl+w':
        if (cursor == 0) return (this, null);
        return (
          _updateMenuForInput(copyWith(editor: editor.killWordBefore())),
          null,
        );
      default:
        return null;
    }
  }

  /// Readline single-key editing beyond kills (issue #275): ctrl+k kill to
  /// line end, ctrl+y yank (consecutive ctrl+y walks the ring older),
  /// ctrl+t transpose, ctrl+z grouped undo. Null when unclaimed.
  (Model, Cmd?)? _handleReadlineKey(KeyMsg msg) {
    final LineEditor edited;
    switch (msg.key) {
      case 'ctrl+k':
        if (cursor >= inputText.length) return (this, null);
        edited = editor.killToLineEnd();
      case 'ctrl+y':
        if (!editor.canYank) return (this, null);
        edited = editor.lastActionWasYank ? editor.yankOlder() : editor.yank();
      case 'ctrl+t':
        edited = editor.transpose();
        if (identical(edited, editor)) return (this, null);
      case 'ctrl+z':
        if (!editor.canUndo) return (this, null);
        edited = editor.undo();
      default:
        return null;
    }
    return (_updateMenuForInput(copyWith(editor: edited)), null);
  }

  /// Normal-mode forward delete; null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handleDeleteKey(KeyMsg msg) {
    switch (msg.key) {
      case 'delete':
        if (cursor >= inputText.length) return (this, null);
        return (
          _updateMenuForInput(copyWith(editor: editor.deleteForward())),
          null,
        );
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
      return (_updateMenuForInput(copyWith(editor: editor.insert(text))), null);
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
      // A kitty-protocol Shift+Enter arrives as 'shift+enter' and still
      // means confirm inside a prompt. ctrl+c is NOT mapped here: it stays
      // the global interrupt/quit key.
      'enter' ||
      'ctrl+j' ||
      'shift+enter' ||
      'alt+enter' => const PromptEnter(),
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
    return (copyWith(editor: editor.insert('\n')), null);
  }

  /// The user-message echo: a dim full-width rule above backgrounded input
  /// lines (background stored UNPADDED — the view-time formatter pads it to
  /// the then-current width, and the bg escape marks the lines as pre-styled
  /// so the markdown formatter leaves them alone). Two blank lines follow:
  /// the first is consumed by the run's first output line (thinking or the
  /// `>_Fa` prefix), leaving one visible empty line after the user message.
  List<String> _echoAppend(List<String> lines, String text) {
    final rule = _dim('─' * termWidth);
    final styledInput = text.split('\n').map(tuiUserMessageLine).join('\n');
    final appended = _appendOutput(lines, '$rule\n$styledInput', true);
    return _appendOutput(appended, '', true);
  }

  /// Submits [text]: echoes the input into the history immediately (no rule
  /// below — the run's thinking/answer flows directly under the user
  /// message), clears the input, snaps the viewport to the bottom, and runs
  /// the host callback.
  (FaTuiModel, Cmd?) _submit(String text) {
    // The TUI-side /mouse toggle executes locally (never reaches the host,
    // never echoes into history) — including while a run streams, since
    // slash commands bypass the busy queue.
    final mouseCommand = _handleMouseCommand(text);
    if (mouseCommand != null) return mouseCommand;
    // Slash/bang commands execute instantly and never consume clipboard
    // chips — they persist for the next real message (E2).
    final keepAttachments = text.startsWith('/') || text.startsWith('!');
    final images = keepAttachments
        ? const <TuiImageAttachment>[]
        : List<TuiImageAttachment>.of(attachments);
    final rule = _dim('─' * termWidth);
    // Empty submits (guided-flow "keep the default" answers) skip the
    // message echo — an empty backgrounded block would read as a glitch.
    if (inputText.isEmpty) {
      return (
        copyWith(
          inputText: '',
          cursor: 0,
          menuOpen: false,
          menuTokenStart: -1,
          attachments: keepAttachments ? null : const [],
        ),
        () async {
          await callbacks.onSubmit(text, images: images);
          return null;
        },
      );
    }
    final echoed = _echoAppend(outputLines, inputText);
    // Shell-style input history: plain messages only (no slash/bang
    // commands), consecutive duplicates collapsed, capped at 100.
    final history = _recordInputHistory(inputHistory, text);
    // The pinned echo for long answers (Copilot-style): rule + the first
    // input line, truncated to the width with an ellipsis marking any
    // remainder — a multi-line message or one simply longer than a row
    // (a bare long line previously got visually cut without any marker).
    // The ellipsis is stored PLAIN: the sticky formatter paints it with
    // the current theme at emit time; a baked dim SGR would freeze the
    // old palette after a mid-session /theme switch (issue #279 E1).
    final firstLine = inputText.split('\n').first;
    final fits = firstLine.length <= termWidth - 3 || termWidth <= 3;
    final shown = fits ? firstLine : firstLine.substring(0, termWidth - 3);
    final more = inputText.contains('\n') || !fits ? ' …' : '';
    final cleared = copyWith(
      inputText: '',
      cursor: 0,
      inputHistory: history,
      historyIndex: -1,
      historyDraft: null,
      outputLines: echoed,
      menuOpen: false,
      menuTokenStart: -1,
      stickyLines: [rule, '${tuiUserMessageLine(shown)}$more'],
      stickyIndex: outputLines.length,
      stickyEchoLineCount: 2 + inputText.split('\n').length,
      attachments: keepAttachments ? null : const [],
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
        await callbacks.onSubmit(text, images: images);
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
  /// [steer] marks the row as a steering interrupt (ctrl+s later flushes
  /// the whole queue through the steering path); it renders badged.
  (FaTuiModel, Cmd?) _enqueue(String text, {bool steer = false}) {
    return (
      copyWith(
        inputText: '',
        cursor: 0,
        menuOpen: false,
        menuTokenStart: -1,
        queue: [
          ...queue,
          QueuedMessage(text, steer: steer),
        ],
      ),
      null,
    );
  }

  /// Busy-mode Ctrl+S: steers the queue into the running agent (each
  /// message becomes a separate user turn), echoing them into the history
  /// first. Steering rows go before follow-ups.
  (FaTuiModel, Cmd?) _steerAll({bool includePending = true}) {
    final messages = [
      if (includePending && inputText.trim().isNotEmpty) inputText.trim(),
      // Steering rows interrupt first; follow-ups keep queue order.
      ...[for (final m in queue.where((m) => m.steer)) m.text],
      ...[for (final m in queue.where((m) => !m.steer)) m.text],
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

  FaTuiModel _updateMenuForInput(FaTuiModel model) =>
      updateMenuForInput(model, callbacks);

  @override
  View view() {
    // Hub overlay: a full-screen modal frame replaces the whole view.
    if (hub != null) {
      return View(
        content: renderHubFrame(hub!, width: termWidth, height: _viewportHeight),
        cursor: null,
        mouseMode: _viewMouseMode,
      );
    }
    final b = StringBuffer();
    final plan = _framePlanFor(termWidth, termHeight);
    final height = plan.history;
    // Every frame rebuilds the hit-region registry from the current
    // layout — a resize re-derives every rect before the next click can
    // land (issue #278, E2).
    _hitRegions.clear();
    final stickyRows = _writeStickyEcho(b, plan.sticky);

    // Output history, padded to a fixed height. Markdown is formatted and
    // ANSI-safely wrapped to physical rows (SGR-only output, escapes never
    // cut at wrap points) so streamed text gains styling as closing markers
    // arrive; the pass is memoized in the shared wrap cache, so a frame
    // triggered by scrolling reuses the rows computed on the last change.
    final wrapped = _wrappedLines();
    // A following tail rides the CURRENT bottom (issue #496): when the
    // frame squeezes, the viewport shrinks without any history append —
    // only re-clamping here keeps the live edge (the sent echo) on screen
    // instead of stranding the window at a stale offset.
    final offset = followTail
        ? _scrollBottom(wrapped)
        : _clampScroll(scrollOffset, wrapped);
    final historyRows = _writeHistoryRows(b, height, wrapped, offset);
    _writeScrollIndicator(b, wrapped, offset);
    _hitRegions.add(
      TuiHitRegion(
        x: 0,
        y: stickyRows,
        w: termWidth,
        h: historyRows + 1,
        kind: TuiRegionKind.scrollback,
      ),
    );

    // Menu above input.
    var row = stickyRows + historyRows + 1;
    row += _writeMenu(b, row);

    row += _writeBusyAndQueue(b, row, plan);

    // Prompt mode: the prompt zone replaces the entire input zone below it,
    // including the status line. The physical cursor stays HIDDEN the whole
    // time: text inputs render their own inline reverse-video caret
    // (_cursorInputRow), pickers and approvals need no caret at all — the
    // old "home to the bottom of the frame" behavior left a stray bar
    // sitting on the status line while the dialog had focus.
    if (prompt != null) return _promptModeView(b);

    final (cursorInputLine, cursorScreenCol) = _writeInputLines(b, row, plan);
    b.writeln(_dim('─' * termWidth));
    // The status line stays plain; the busy indicator lives above the input.
    b.write(_statusRow());

    // One snapshot serves both consumers: newline counting for the cursor
    // row math (O(n) scan, ZERO allocations — the old split('\n') built a
    // List<String> of every physical row on every frame just to take its
    // length) and the frame body itself.
    final body = _cropToGlass(b.toString());
    final inputStartRow = _lineCount(body) - 2 - plan.input;
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
    // typing mid-stream is first-class. Visibility itself is ONE rule —
    // the View's cursor field: null hides the physical cursor via the
    // program's DECTCEM (?25l), non-null shows it and the renderer re-homes
    // it after every painting frame (forceHome on any written row/cell).
    // The old escape-smuggled-in-content scheme never reached the wire:
    // the cell renderer parses content into an SGR-only grid and dropped
    // the DECTCEM, leaving the caret stranded on the last painted cell of
    // every picker frame (#510).
    return View(
      content: body,
      cursor: pickerOpen
          ? null
          : Cursor(x: cursorX, y: cursorRow, shape: CursorShape.bar),
      mouseMode: _viewMouseMode,
    );
  }

  /// The mouse mode every rendered [View] carries (mouse capture on =
  /// cell-motion tracking for the wheel/click routing).
  MouseMode get _viewMouseMode =>
      mouseCapture ? MouseMode.cellMotion : MouseMode.none;

  /// Prompt-mode frame tail: the prompt zone replaces the input zone and
  /// the status row owns the bottom; no physical cursor anywhere.
  View _promptModeView(StringBuffer b) {
    for (final line in renderTuiPrompt(prompt!, termWidth)) {
      b.writeln(line);
    }
    b.writeln(); // spacer
    b.write(_statusRow());
    return View(
      content: b.toString(),
      cursor: null,
      mouseMode: _viewMouseMode,
    );
  }

  /// Hard glass guard (#503): whatever the sections miscounted, the frame
  /// must NEVER exceed the terminal — in a shorter terminal the rows past
  /// the bottom clamp onto the last row and overwrite the status with
  /// blanks (owner: status gone at 100x10). Drops the overflow from the
  /// TOP (oldest history/padding — the most dispensable rows) so the
  /// bottom chrome always lands on the glass. Frame rows are complete
  /// self-contained lines by construction, so dropping leading lines is
  /// ANSI-safe. Caveat: hit-regions shift by the dropped count on this
  /// rare path; the next frame re-derives them.
  String _cropToGlass(String body) {
    final paintedRows = _lineCount(body);
    if (paintedRows <= termHeight || termHeight <= 0) return body;
    var idx = 0;
    for (var d = paintedRows - termHeight; d > 0; d--) {
      final nl = body.indexOf('\n', idx);
      if (nl < 0) break;
      idx = nl + 1;
    }
    return body.substring(idx);
  }

  /// The menu title row: '[Commands]' for the slash menu, otherwise the
  /// picker title with the active filter.
  String _menuTitle() {
    if (!menuModelMode) return '[Commands]';
    final title = pickerId == 'models' ? 'Select model' : pickerTitle;
    return modelFilter.isNotEmpty ? '[$title: $modelFilter]' : '[$title]';
  }

  /// The slash/model/picker menu block above the input zone. A picker whose
  /// filter matched nothing keeps its title row plus a dim '(no matches)'
  /// hint — vanishing entirely would hide the query being edited.
  int _writeMenu(StringBuffer b, int baseRow) {
    if (!menuOpen) return 0;
    if (menuItems.isEmpty) {
      if (menuModelMode) {
        b.writeln(_accent2(_menuTitle()));
        b.writeln(_dim('  (no matches)'));
        return 2;
      }
      return 0;
    }
    b.writeln(_accent2(_menuTitle()));
    return 1 + _writeMenuItems(b, baseRow + 1);
  }

  /// Matches a code-fence opener/closer line exactly like the view-time
  /// markdown walk (ansi_markdown.dart `_fenceRe`): parity over the
  /// retained history must agree with what the renderer will compute.
  static final RegExp _fenceLineStart = RegExp(r'^\s*```');

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
    // A streamed paragraph with no trailing newline grows the last line
    // without bound: minutes-long thinking bursts produced HUNDRED-KB
    // lines, and TranscriptMarkdown's (throttled) tail passes re-format +
    // re-wrap the WHOLE line each pass — the event loop stalled in bursts
    // and typing froze. Cap the tail: hard-split an oversized last line
    // into bounded chunks. Soft wrap renders them identically (the text
    // continues at the same cell); only an inline span crossing the rare
    // split point loses its styling into the next chunk.
    const maxTailLineChars = 32 * 1024;
    const tailChunkChars = 16 * 1024;
    if (result.last.length > maxTailLineChars) {
      final tail = result.last;
      result
        ..removeLast()
        ..addAll([
          for (var i = 0; i < tail.length; i += tailChunkChars)
            tail.substring(i, (i + tailChunkChars).clamp(0, tail.length)),
        ]);
    }
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
      // A cut landing inside a fenced code block leaves the retained
      // history with an open fence: the block's closing ``` then toggles
      // the walk OPEN and every markdown line after it renders verbatim
      // (raw **/### walls after a long stream). Count fence lines in the
      // DROPPED head — the state the rebuilt walk starts in — and prepend
      // a synthetic closing fence when it is open. The same trick
      // tui_replay.dart uses for truncated replays.
      final cut = result.length - maxLines;
      var open = false;
      for (var i = 0; i < cut; i++) {
        if (_fenceLineStart.hasMatch(result[i])) open = !open;
      }
      final trimmed = result.sublist(cut);
      if (open) trimmed.insert(0, '```');
      return trimmed;
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
/// One soft-wrapped composer row with the buffer offset (UTF-16 code units
/// into the SOURCE line) where it starts — the cursor maps back through
/// these offsets, so a resize re-wraps while the cursor stays on the same
/// buffer position (issue #467 E3).
final class WrappedComposerRow {
  const WrappedComposerRow(this.text, this.startUnit);

  /// The visible row (break-point spaces at its end dropped).
  final String text;

  /// Code units into the source logical line where this row begins.
  final int startUnit;
}

/// Soft-wraps one logical composer line to [width]-terminal-cell rows
/// (issue #467): word-boundary preferred, a word wider than the viewport
/// hard-breaks (E1, no wrap-point loop), grapheme clusters never split
/// across rows (E2 — the renderer measures cells, not code units, and a
/// row overflowing its width makes the terminal hardware-wrap and desync
/// the frame). Break-point space runs are dropped only where a row breaks;
/// interior runs render verbatim. Always returns at least one row.
List<WrappedComposerRow> wrapComposerRows(String line, int width) =>
    _ComposerWrap(width < 1 ? 1 : width).run(line);

/// Plain-row view of [wrapComposerRows].
List<String> wrapComposerLine(String line, int width) => [
  for (final row in wrapComposerRows(line, width)) row.text,
];

/// The greedy-wrap state machine behind [wrapComposerRows]. One mutable
/// walker per line; kept as a class so every method stays inside the CRAP
/// gate and the wrap rules read one per method.
final class _ComposerWrap {
  _ComposerWrap(this.width);

  /// Row capacity in terminal cells.
  final int width;

  final rows = <WrappedComposerRow>[];
  final _row = StringBuffer();
  final _word = StringBuffer();
  final _pending = StringBuffer(); // space run since the last word
  int _rowCells = 0;
  int _rowStartUnit = 0;
  int _wordCells = 0;
  int _wordStartUnit = 0;
  int _unit = 0; // code units consumed from the line

  List<WrappedComposerRow> run(String line) {
    if (line.isEmpty) return [const WrappedComposerRow('', 0)];
    for (final cluster in line.characters) {
      if (cluster == ' ') {
        _flushWord();
        _pending.write(' ');
      } else {
        if (_word.isEmpty) _wordStartUnit = _unit;
        _word.write(cluster);
        _wordCells += tuiGraphemeWidth(cluster);
      }
      _unit += cluster.length;
    }
    _flushWord();
    if (_row.isNotEmpty || rows.isEmpty) _emitRow();
    return rows;
  }

  /// Rows that end the frame must be flushed verbatim; [_emitRow] is the
  /// single place a row leaves the walker.
  void _emitRow() {
    rows.add(WrappedComposerRow(_row.toString(), _rowStartUnit));
    _row.clear();
    _rowCells = 0;
  }

  /// Lands the pending word on the current row, breaking the row (dropping
  /// the pending space run) when the word does not fit, and hard-breaking
  /// a word wider than the viewport (E1).
  void _flushWord() {
    if (_word.isEmpty) return;
    if (_wordCells > width) {
      _hardBreakWord();
      return;
    }
    if (_rowCells == 0) {
      _row.write(_word);
      _rowCells = _wordCells;
      _rowStartUnit = _wordStartUnit;
    } else if (_rowCells + _pending.length + _wordCells <= width) {
      _row
        ..write(_pending)
        ..write(_word);
      _rowCells += _pending.length + _wordCells;
    } else {
      _emitRow();
      _row.write(_word);
      _rowCells = _wordCells;
      _rowStartUnit = _wordStartUnit;
    }
    _word.clear();
    _wordCells = 0;
    _pending.clear();
  }

  /// E1: a word wider than the viewport slices into width-cell rows —
  /// clusters are never cut, and every slice starts a fresh row so two
  /// wrap points can never fight over the same cluster (no loop).
  void _hardBreakWord() {
    if (_rowCells > 0) _emitRow();
    final clusters = _word.toString().characters.toList();
    final slice = StringBuffer();
    var sliceCells = 0;
    var sliceStartUnit = _wordStartUnit;
    var sliceUnits = 0;
    for (final cluster in clusters) {
      final cells = tuiGraphemeWidth(cluster);
      if (sliceCells > 0 && sliceCells + cells > width) {
        rows.add(WrappedComposerRow(slice.toString(), sliceStartUnit));
        slice.clear();
        sliceStartUnit += sliceUnits;
        sliceCells = 0;
        sliceUnits = 0;
      }
      slice.write(cluster);
      sliceCells += cells;
      sliceUnits += cluster.length;
    }
    // The trailing slice becomes the current row (later words may join it).
    _row.write(slice);
    _rowCells = sliceCells;
    _rowStartUnit = sliceStartUnit;
    _word.clear();
    _wordCells = 0;
    _pending.clear();
  }
}

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
    this.syncOutput,
  });

  final FaTuiCallbacks callbacks;
  final bool Function() isExited;

  /// Whether the TUI captures the mouse (wheel scrolling); when false the
  /// terminal keeps its native text selection. See
  /// [FaTuiModel.mouseCapture].
  final bool mouseCapture;

  /// DEC 2026 synchronized output tri-state: true forces BSU/ESU framing,
  /// false forces legacy writes, null = auto-detect via DECRQM
  /// (`FA_TUI_SYNC`, see [AgentCliConfig.tuiSyncOutput]).
  final bool? syncOutput;

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
      // Cursor visibility derives from View.cursor == null (one rule for
      // every picker/wizard/prompt surface, #510): the program emits the
      // DECTCEM hide/show OUT-OF-BAND — escapes inside frame content die
      // in the cell renderer's SGR-only grid and never reach the wire.
      withHideCursor(),
      // Mouse modes are VIEW-driven per frame (the view emits
      // cellMotion/none from mouseCapture) — never boot-static, so
      // /mouse off can actually disarm the terminal (issue #278, AC4).
      // Differential cell renderer (#274): cell-level diff + pure-scroll
      // ops + BSU/ESU framing — the line renderer repaints every shifted
      // row on scroll and has no atomic frames.
      withCellRenderer(),
      // FA_TUI_SYNC tri-state: force on, force off, or auto (DECRQM).
      if (syncOutput != null)
        syncOutput! ? withSyncUpdates() : withoutSyncUpdates(),
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

  /// The live terminal width (the hub driver's block/overlay rendering
  /// width; the picker table elision, #278). Mirrored by the web stub as
  /// a constant 80.
  int get termWidth => _model.termWidth;

  void _send(Msg msg) {
    if (msg is! OutputMsg) _flushOutput();
    if (_running) {
      _program.send(msg);
    } else {
      _pending.add(msg);
    }
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

  /// Pushes the pending scheduled follow-up count (`schedule_message`
  /// records) so the indicator row tracks the queue live (issue #115).
  void setScheduled(int count, int? nextDueMs) {
    _send(ScheduledStatusMsg(count, nextDueMs));
  }

  /// Replaces the visible-waiting row state (issue #450) so an idle
  /// terminal shows WHAT the agent waits for: running background jobs,
  /// armed self-wake timers, and jobs a previous run lost.
  void setWaiting({
    required List<String> jobs,
    required List<({int dueMs, String preview})> timers,
    int lostJobs = 0,
  }) {
    _send(WaitingStatusMsg(jobs: jobs, timers: timers, lostJobs: lostJobs));
  }

  /// Pushes the run-liveness state (issue #514): `true` flips the busy row
  /// to `Stalled…` while the wedge watchdog sees a stale heartbeat. No
  /// busy guard — the model renders the label only while the row is up.
  void setRunStalled(bool stalled) {
    _send(RunStalledMsg(stalled));
  }

  /// Pushes the background-job board's live region (issue #429): summary
  /// lines + live rows for the transient area above the busy row. An empty
  /// list hides the region (everything settled).
  void setJobBoard(List<String> lines) {
    _send(JobBoardMsg(List.unmodifiable(lines)));
  }

  /// Drains the queued messages (the model echoes them into the history) —
  /// the host runs them as separate turns after the current one settles.
  Future<List<String>> drainQueue() {
    // No attached program: the model never sees the drain request, so the
    // completer would park forever — nothing can be queued either.
    if (!_running) return Future<List<String>>.value(const []);
    final completer = Completer<List<String>>();
    _send(DrainQueueMsg(completer));
    return completer.future;
  }

  /// Clears the queued messages without running them (`/queue clear`,
  /// issue #275). The strip disappearing is the user's confirmation.
  void clearQueue() {
    _send(const ClearQueueMsg());
  }

  Future<void> run() async {
    var model = _model;
    for (final msg in _pending) {
      model = model.update(msg).$1 as FaTuiModel;
    }
    _pending.clear();
    final savedTermios = await _sanitizeTermiosInput();
    try {
      // Flip `_running` only here — after every await, immediately before
      // `_program.run` flips the Program's own gate (synchronously, at
      // `_runCore` entry). With `_running = true` earlier, an output flush
      // landing while the termios probe awaits (a real `stty` subprocess,
      // ~20ms on Linux) routed through `_program.send`, which DROPS
      // messages sent before the program started — boot-time plugin
      // output (e.g. the hub plugin's `[hub] connected as …`) vanished on
      // slow hosts (issue #538: dap integration legs red on Linux CI,
      // green on fast dev machines). Until this point `_send` parks
      // messages in `_pending`; drain them again now.
      _running = true;
      for (final msg in _pending) {
        model = model.update(msg).$1 as FaTuiModel;
      }
      _pending.clear();
      await _program.run(model);
    } finally {
      if (savedTermios != null) await _restoreTermios(savedTermios);
    }
  }

  /// dart_tui's raw mode flips only Dart's echo/line flags (termios
  /// ICANON/ECHO). Two input-processing flags stay on and corrupt raw
  /// keystrokes: IXON (software flow control — Ctrl+S is the tty driver's
  /// VSTOP byte: the keypress is swallowed and output suspends) and ICRNL
  /// (CR→LF input translation — a host delivering Shift+Enter as the legacy
  /// ESC CR wire, e.g. an IDE embedded terminal, gets it rewritten to
  /// ESC LF before fa reads it, killing the alt+enter decode). Clear both
  /// for the TUI's lifetime; returns the saved termios string for
  /// [_restoreTermios], or null when there is no tty to fix.
  static Future<String?> _sanitizeTermiosInput() async {
    if (Platform.isWindows) return null;
    if (!stdin.hasTerminal) return null;
    return sttySanitizeInput(
      sttyDeviceFlag(),
      runner: (args) => Process.run('stty', args),
    );
  }

  /// The BSD/GNU device flag for `stty` (`-f` on macOS, `-F` elsewhere).
  static String sttyDeviceFlag() => Platform.isMacOS ? '-f' : '-F';

  /// Clears the TUI-hostile termios input flags (IXON/IXOFF flow control,
  /// ICRNL CR→LF translation) via `stty` and returns the saved termios
  /// string. [runner] is injected so tests can avoid real subprocesses.
  ///
  /// Public (package-visible) only for testing; do not call directly.
  static Future<String?> sttySanitizeInput(
    String deviceFlag, {
    required Future<ProcessResult> Function(List<String> args) runner,
  }) async {
    try {
      final saved = await runner([deviceFlag, '/dev/tty', '-g']);
      if (saved.exitCode != 0) return null;
      final cleared = await runner([
        deviceFlag,
        '/dev/tty',
        '-ixon',
        '-ixoff',
        '-icrnl',
      ]);
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
