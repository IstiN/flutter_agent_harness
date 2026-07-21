import 'dart:async';

import 'package:dart_tui/dart_tui.dart';

import 'ansi_markdown.dart';
import 'tui_repl.dart' show MenuItem;

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

/// Message asking the model picker to refresh its items.
final class _ModelsRefreshMsg extends Msg {}

/// Message asking the model picker to open.
final class _OpenModelMenuMsg extends Msg {}

/// Message opening a generic host picker (sessions, mode, approval, ...).
final class OpenPickerMsg extends Msg {
  OpenPickerMsg(this.pickerId, this.title, this.items);
  final String pickerId;
  final String title;
  final List<MenuItem> items;
}

/// Message asking the program to quit because the host marked exit.
final class _QuitRequestedMsg extends Msg {}

/// Message toggling the busy ("thinking") indicator while a run streams.
final class BusyMsg extends Msg {
  BusyMsg(this.busy);
  final bool busy;
}

/// Internal spinner-frame tick; re-scheduled while the model stays busy.
final class SpinnerTickMsg extends Msg {}

/// Message draining the queued messages (kimi-cli semantics: after a run
/// settles the host takes them one-by-one as separate turns). The model
/// echoes them into the history before clearing.
final class DrainQueueMsg extends Msg {
  DrainQueueMsg(this.completer);
  final Completer<List<String>> completer;
}

/// The braille spinner frames cycled while [FaTuiModel.busy] is set.
const _spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// The dart_tui model backing the Fa interactive REPL.
final class FaTuiModel extends TeaModel {
  FaTuiModel({
    required this.callbacks,
    required this.isExited,
    this.outputLines = const [],
    this.inputText = '',
    this.cursor = 0,
    this.scrollOffset = 0,
    this.menuOpen = false,
    this.menuModelMode = false,
    this.menuSelected = 0,
    this.modelFilter = '',
    this.menuItems = const [],
    this.pickerId = '',
    this.pickerTitle = '',
    this.termWidth = 80,
    this.termHeight = 24,
    this.busy = false,
    this.spinnerFrame = 0,
    this.stickyLines = const [],
    this.stickyIndex = -1,
    this.queue = const [],
  });

  final FaTuiCallbacks callbacks;
  final bool Function() isExited;

  final List<String> outputLines;
  final String inputText;
  final int cursor;

  /// Persistent viewport scroll offset (0 = top). Snapped to the bottom on
  /// new output when the user has not scrolled up; kept while scrolling.
  final int scrollOffset;
  final bool menuOpen;
  final bool menuModelMode;
  final int menuSelected;
  final String modelFilter;
  final List<MenuItem> menuItems;

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
  final int spinnerFrame;

  /// The last submitted user echo (rule + first input line), pinned to the
  /// top of the viewport while a run streams and the echo itself has
  /// scrolled out of view — Copilot's sticky user message for long answers.
  final List<String> stickyLines;

  /// Index into [outputLines] where the sticky echo starts; -1 when unset.
  final int stickyIndex;

  /// Messages typed while a run streams (kimi-cli's queue): Enter enqueues,
  /// ↑ pops the last one back into the input, Ctrl+S steers them into the
  /// running agent, and the host drains them as separate turns afterwards.
  final List<String> queue;

  int get _inputLineCount => inputText.split('\n').length;

  /// Truncates [text] to [maxWidth] (default: the terminal width) with an
  /// ellipsis. Every chrome row (status, menu items) must fit on one
  /// terminal row: a soft-wrapped chrome line desyncs the renderer's row
  /// math and smears the frame on every repaint.
  String _fitWidth(String text, [int? maxWidth]) {
    final limit = maxWidth ?? termWidth;
    if (text.length <= limit) return text;
    if (limit <= 1) return text.substring(0, limit);
    return '${text.substring(0, limit - 1)}…';
  }

  /// Whether the sticky user echo is pinned right now: a run is streaming
  /// and the echo has scrolled above the visible window.
  bool get _stickyActive =>
      busy && stickyLines.isNotEmpty && scrollOffset > stickyIndex;

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

  int _viewportHeightFor(int width, int height) {
    const progressH = 1;
    // The input zone is framed by a rule above and a rule below it.
    const inputFrameH = 2;
    const statusH = 1;
    final busyH = busy ? 1 : 0;
    final stickyH = _stickyActive ? stickyLines.length : 0;
    final queueH = queue.isEmpty ? 0 : queue.length + 1; // + hint line
    final used =
        progressH +
        _menuReservedLines +
        busyH +
        stickyH +
        queueH +
        inputFrameH +
        statusH +
        _inputLineCount;
    return (height - used).clamp(3, 9999);
  }

  int get _viewportHeight => _viewportHeightFor(termWidth, termHeight);

  /// The output history formatted and wrapped to physical rows at [width]
  /// (default: the current terminal width). All scroll math happens in
  /// these rows — raw line counts lie once long lines wrap.
  List<String> _wrappedLines([int? width]) {
    final w = width ?? termWidth;
    final formatted = AnsiMarkdown(width: w).formatAll(outputLines);
    return [for (final line in formatted) ...wrapAnsiLine(line, w)];
  }

  /// The scroll offset that puts the last wrapped row at the bottom.
  int _scrollBottom(List<String> wrapped) =>
      (wrapped.length - _viewportHeight).clamp(0, wrapped.length);

  int _clampScroll(int offset, List<String> wrapped) =>
      offset.clamp(0, _scrollBottom(wrapped));

  FaTuiModel copyWith({
    List<String>? outputLines,
    String? inputText,
    int? cursor,
    int? scrollOffset,
    bool? menuOpen,
    bool? menuModelMode,
    int? menuSelected,
    String? modelFilter,
    List<MenuItem>? menuItems,
    String? pickerId,
    String? pickerTitle,
    int? termWidth,
    int? termHeight,
    bool? busy,
    int? spinnerFrame,
    List<String>? stickyLines,
    int? stickyIndex,
    List<String>? queue,
  }) {
    return FaTuiModel(
      callbacks: callbacks,
      isExited: isExited,
      outputLines: outputLines ?? this.outputLines,
      inputText: inputText ?? this.inputText,
      cursor: cursor ?? this.cursor,
      scrollOffset: scrollOffset ?? this.scrollOffset,
      menuOpen: menuOpen ?? this.menuOpen,
      menuModelMode: menuModelMode ?? this.menuModelMode,
      menuSelected: menuSelected ?? this.menuSelected,
      modelFilter: modelFilter ?? this.modelFilter,
      menuItems: menuItems ?? this.menuItems,
      pickerId: pickerId ?? this.pickerId,
      pickerTitle: pickerTitle ?? this.pickerTitle,
      termWidth: termWidth ?? this.termWidth,
      termHeight: termHeight ?? this.termHeight,
      busy: busy ?? this.busy,
      spinnerFrame: spinnerFrame ?? this.spinnerFrame,
      stickyLines: stickyLines ?? this.stickyLines,
      stickyIndex: stickyIndex ?? this.stickyIndex,
      queue: queue ?? this.queue,
    );
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
    // Output is handled before the exit check so trailing writes (e.g. the
    // 'bye' line from /exit) still render before the program quits; the host
    // sends _QuitRequestedMsg once it has marked exit.
    if (msg is OutputMsg) {
      final wasAtBottom = scrollOffset >= _scrollBottom(_wrappedLines());
      final newLines = _appendOutput(outputLines, msg.text, msg.newline);
      final next = copyWith(outputLines: newLines);
      final nextWrapped = next._wrappedLines();
      // Auto-follow the stream while at the bottom; preserve the scroll
      // position (clamped) when the user scrolled up.
      final nextOffset = wasAtBottom
          ? _scrollBottom(nextWrapped)
          : _clampScroll(scrollOffset, nextWrapped);
      return (next.copyWith(scrollOffset: nextOffset), null);
    }
    // Busy/spinner messages are handled before the exit check for the same
    // reason as output: /exit arrives wrapped in sendBusy(true/false) calls,
    // and quitting here would land in the same drained batch as the farewell
    // output and skip its render. The host's delayed _QuitRequestedMsg is
    // the only quit path that matters.
    if (msg is BusyMsg) {
      // Kick the spinner loop when going busy; the loop stops itself on the
      // first tick that finds the model idle again. Going idle also unpins
      // the sticky user echo.
      return (
        copyWith(
          busy: msg.busy,
          spinnerFrame: 0,
          stickyLines: msg.busy ? null : const [],
          stickyIndex: msg.busy ? null : -1,
        ),
        msg.busy ? _scheduleSpinnerTick() : null,
      );
    }
    if (msg is SpinnerTickMsg) {
      if (!busy) return (this, null);
      return (copyWith(spinnerFrame: spinnerFrame + 1), _scheduleSpinnerTick());
    }
    if (msg is DrainQueueMsg) {
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
      );
      return (next, null);
    }
    if (isExited()) return (this, () => quit());
    if (msg is _ModelsRefreshMsg) {
      // Only refresh while the model picker is actually open — the message
      // also arrives when the slash menu (or no menu) is up and must not
      // clobber its items.
      if (!menuOpen || !menuModelMode) return (this, null);
      final items = callbacks.buildModelMenu(modelFilter);
      final selected = items.isEmpty
          ? 0
          : menuSelected.clamp(0, items.length - 1);
      return (copyWith(menuItems: items, menuSelected: selected), null);
    }
    if (msg is _OpenModelMenuMsg) {
      final items = callbacks.buildModelMenu('');
      return (
        copyWith(
          menuOpen: true,
          menuModelMode: true,
          modelFilter: '',
          menuItems: items,
          menuSelected: 0,
          pickerId: 'models',
          pickerTitle: '',
        ),
        null,
      );
    }
    if (msg is OpenPickerMsg) {
      return (
        copyWith(
          menuOpen: true,
          menuModelMode: true,
          modelFilter: '',
          menuItems: msg.items,
          menuSelected: 0,
          pickerId: msg.pickerId,
          pickerTitle: msg.title,
        ),
        null,
      );
    }
    if (msg is _QuitRequestedMsg) {
      return (this, () => quit());
    }
    if (msg is WindowSizeMsg) {
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
    if (msg is MouseWheelMsg) {
      // Mouse wheel scrolls the chat history, like Copilot's transcript pane.
      final delta = switch (msg.mouse.button) {
        MouseButton.wheelUp => -3,
        MouseButton.wheelDown => 3,
        _ => 0,
      };
      if (delta != 0) {
        return (
          copyWith(
            scrollOffset: _clampScroll(scrollOffset + delta, _wrappedLines()),
          ),
          null,
        );
      }
      return (this, null);
    }
    if (msg is PasteMsg) {
      final before = inputText.substring(0, cursor);
      final after = inputText.substring(cursor);
      return (
        copyWith(
          inputText: before + msg.content + after,
          cursor: cursor + msg.content.length,
        ),
        null,
      );
    }

    // dart_tui's input decoder groups up to 4 ASCII bytes into a single rune,
    // and the cursor would advance by 1 instead of the inserted text length.
    // Split multi-character runes into individual key events so pasting plain
    // text (or fast typing) does not scramble the input.
    if (msg is KeyPressMsg &&
        msg.keyEvent.code == KeyCode.rune &&
        msg.keyEvent.text.length > 1) {
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

    if (msg is KeyMsg) {
      return _handleKey(msg);
    }
    return (this, null);
  }

  (Model, Cmd?) _handleKey(KeyMsg msg) {
    // Picker mode: arrows navigate, enter/tab select, esc closes. Only the
    // models picker has a type-to-filter input; generic pickers (sessions,
    // mode, approval, ...) navigate a static item list.
    if (menuOpen && menuModelMode) {
      final isModelsPicker = pickerId == 'models';
      switch (msg.key) {
        case 'esc':
          return (copyWith(menuOpen: false, modelFilter: ''), null);
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
        case 'pgup':
          return (copyWith(menuSelected: 0), null);
        case 'pgdown':
          return (
            copyWith(
              menuSelected: menuItems.isEmpty ? 0 : menuItems.length - 1,
            ),
            null,
          );
        case 'backspace':
          if (isModelsPicker && modelFilter.isNotEmpty) {
            final nextFilter = modelFilter.substring(0, modelFilter.length - 1);
            return (
              copyWith(
                modelFilter: nextFilter,
                menuItems: callbacks.buildModelMenu(nextFilter),
                menuSelected: 0,
              ),
              null,
            );
          }
          return (this, null);
        case 'enter':
        case 'tab':
          if (menuItems.isEmpty) return (this, null);
          final item = menuItems[menuSelected];
          if (item.key.isEmpty) return (this, null);
          return (
            copyWith(
              menuOpen: false,
              modelFilter: '',
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
          if (!isModelsPicker) return (this, null);
          final text = msg.keyEvent.text;
          if (text.isNotEmpty && text.length == 1) {
            if (text == ' ' && modelFilter.isEmpty) return (this, null);
            final nextFilter = modelFilter + text;
            return (
              copyWith(
                modelFilter: nextFilter,
                menuItems: callbacks.buildModelMenu(nextFilter),
                menuSelected: 0,
              ),
              null,
            );
          }
          return (this, null);
      }
    }

    // Slash/menu mode: arrows navigate, enter/tab accept, esc closes, and
    // typing keeps editing the input so `/models` can be typed in full.
    if (menuOpen) {
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
        case 'enter':
        case 'tab':
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
            copyWith(
              inputText: item.key,
              cursor: item.key.length,
              menuOpen: false,
            ),
            null,
          );
        case 'backspace':
          if (cursor > 0 && inputText.isNotEmpty) {
            final nextText =
                inputText.substring(0, cursor - 1) +
                inputText.substring(cursor);
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

    // Normal input editing.
    switch (msg.key) {
      case 'enter':
        // Enter submits; Shift+Enter inserts a newline. Terminals that do not
        // distinguish Shift+Enter in the input stream are handled through the
        // host modifier check (Core Graphics on macOS, like pi's helper).
        if (callbacks.isShiftPressed?.call() ?? false) {
          return _insertNewlineAtCursor();
        }
        final line = inputText.trim();
        if (line.isEmpty) return (this, null);
        if (busy && !line.startsWith('/') && !line.startsWith('!')) {
          // While a run streams, plain messages queue up (kimi-cli); slash
          // and bang commands execute immediately via the normal path.
          return _enqueue(line);
        }
        return _submit(line);
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
      case 'ctrl+c':
        callbacks.onInterrupt?.call();
        return (this, () => quit());
      case 'esc':
        // Escape aborts the streaming run (pi's keybinding); a no-op when
        // idle because the host only aborts while busy. Unlike Ctrl+C it
        // never quits the program.
        callbacks.onInterrupt?.call();
        return (this, null);
      case 'up':
        if (inputText.isEmpty) {
          // With a non-empty queue, ↑ pops the last queued message back into
          // the input for editing (kimi-cli); otherwise it scrolls.
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
          return (
            copyWith(
              scrollOffset: _clampScroll(scrollOffset - 1, _wrappedLines()),
            ),
            null,
          );
        }
        return (this, null);
      case 'down':
        if (inputText.isEmpty) {
          return (
            copyWith(
              scrollOffset: _clampScroll(scrollOffset + 1, _wrappedLines()),
            ),
            null,
          );
        }
        return (this, null);
      case 'pgup':
        return (
          copyWith(
            scrollOffset: _clampScroll(
              scrollOffset - _viewportHeight,
              _wrappedLines(),
            ),
          ),
          null,
        );
      case 'pgdown':
        return (
          copyWith(
            scrollOffset: _clampScroll(
              scrollOffset + _viewportHeight,
              _wrappedLines(),
            ),
          ),
          null,
        );
      case 'left':
        return (copyWith(cursor: cursor > 0 ? cursor - 1 : 0), null);
      case 'right':
        return (
          copyWith(cursor: cursor < inputText.length ? cursor + 1 : cursor),
          null,
        );
      case 'alt+left':
        // Word motion like pi's editor: alt+left/right jump by words.
        return (copyWith(cursor: _wordStartBefore(inputText, cursor)), null);
      case 'alt+right':
        return (copyWith(cursor: _wordEndAfter(inputText, cursor)), null);
      case 'home':
        return (copyWith(cursor: 0), null);
      case 'end':
        return (copyWith(cursor: inputText.length), null);
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
      case 'delete':
        if (cursor >= inputText.length) return (this, null);
        final nextText =
            inputText.substring(0, cursor) + inputText.substring(cursor + 1);
        return (_updateMenuForInput(copyWith(inputText: nextText)), null);
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
    final echoed = _echoAppend(outputLines, inputText);
    // The pinned echo for long answers (Copilot-style): rule + first input
    // line, with a dim ellipsis marking a multi-line message.
    final firstLine = inputText.split('\n').first;
    final more = inputText.contains('\n') ? _dim(' …') : '';
    final cleared = copyWith(
      inputText: '',
      cursor: 0,
      outputLines: echoed,
      stickyLines: [rule, '$bg$firstLine$reset$more'],
      stickyIndex: outputLines.length,
    );
    return (
      cleared.copyWith(
        scrollOffset: cleared._scrollBottom(cleared._wrappedLines()),
      ),
      () async {
        await callbacks.onSubmit(text);
        return null;
      },
    );
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
    final cleared = copyWith(
      inputText: '',
      cursor: 0,
      queue: const [],
      outputLines: lines,
    );
    return (
      cleared.copyWith(
        scrollOffset: cleared._scrollBottom(cleared._wrappedLines()),
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
    final md = AnsiMarkdown(width: termWidth);

    // The sticky user echo pinned to the top while a run streams and the
    // echo itself has scrolled out of view (Copilot-style).
    if (_stickyActive) {
      for (final line in stickyLines) {
        b.writeln(md.formatLine(line));
      }
    }

    // Output history, padded to a fixed height. Markdown is formatted and
    // ANSI-safely wrapped to physical rows at view time (SGR-only output,
    // escapes never cut at wrap points) so streamed text gains styling as
    // closing markers arrive, exactly like pi's per-delta re-render.
    final wrapped = md
        .formatAll(outputLines)
        .expand((line) => wrapAnsiLine(line, termWidth))
        .toList();
    final offset = _clampScroll(scrollOffset, wrapped);
    for (var i = 0; i < height; i++) {
      final row = offset + i;
      b.writeln(row < wrapped.length ? wrapped[row] : '');
    }

    // Scroll progress indicator — only while scrolled away from the bottom
    // (a "you are here" hint); at the live edge the row stays blank so the
    // layout never shifts.
    final bottom = _scrollBottom(wrapped);
    if (offset < bottom) {
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

    // Menu above input.
    if (menuOpen && menuItems.isNotEmpty) {
      final title = menuModelMode
          ? pickerId == 'models'
                ? '[Select model'
                      '${modelFilter.isNotEmpty ? ': $modelFilter' : ''}]'
                : '[$pickerTitle]'
          : '[Commands]';
      b.writeln(_accent2(title));
      final (start, end) = _menuWindow();
      if (start > 0) b.writeln(_dim('  ↑ more'));
      for (var i = start; i < end; i++) {
        final item = menuItems[i];
        final selected = i == menuSelected;
        final desc = item.description.isNotEmpty ? ' ${item.description}' : '';
        // Menu rows must never exceed the width: a soft-wrapped chrome line
        // desyncs the renderer's row math and smears frames on every key.
        final full = '${item.label}$desc';
        final prefix = selected ? '${_accent('▸')} ' : '  ';
        if (full.length <= termWidth - 2) {
          if (selected) {
            b.writeln('$prefix${_accent(item.label)}${_dim(desc)}');
          } else {
            b.writeln('$prefix${item.label}${_dim(desc)}');
          }
        } else {
          final text = _fitWidth(full, termWidth - 2);
          b.writeln(selected ? '$prefix${_accent(text)}' : '$prefix$text');
        }
      }
      if (end < menuItems.length) b.writeln(_dim('  ↓ more'));
    }

    // The busy indicator sits directly above the input zone (like pi's
    // "Working…" row), so it is visible next to the cursor while a run
    // streams. Queued messages (kimi-cli) render under it, one dim line per
    // message plus the edit/steer hint, all above the framed input zone.
    if (busy) {
      final frame = _spinnerFrames[spinnerFrame % _spinnerFrames.length];
      b.writeln('${_accent2Plain(frame)} ${_dim('Working…')}');
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

    final beforeCursor = inputText.substring(0, cursor);
    final cursorInputLine = '\n'.allMatches(beforeCursor).length;
    final lastNl = beforeCursor.lastIndexOf('\n');
    final cursorColInInput = lastNl < 0
        ? beforeCursor.length
        : beforeCursor.length - lastNl - 1;

    final inputLines = inputText.split('\n');
    var cursorScreenCol = cursorColInInput;
    for (var i = 0; i < inputLines.length; i++) {
      final avail = termWidth;
      var line = inputLines[i];
      if (line.length > avail && avail > 0) {
        if (i == cursorInputLine) {
          final start = (cursorColInInput - avail ~/ 2).clamp(
            0,
            line.length - avail,
          );
          line = line.substring(start, start + avail);
          cursorScreenCol = cursorColInInput - start;
        } else {
          line = line.substring(0, avail);
        }
      }
      if (i > 0) b.writeln();
      b.write(line);
    }
    b.writeln();
    b.writeln(_dim('─' * termWidth));
    // The status line stays plain; the busy indicator lives above the input.
    // Truncated to the width like every other chrome row — a wrapped status
    // line shifts the whole frame by one row on every repaint.
    b.write(_dim(_fitWidth(callbacks.statusLine())));

    final lines = b.toString().split('\n');
    final inputStartRow = lines.length - 2 - inputLines.length;
    final cursorRow = inputStartRow + cursorInputLine;
    final cursorX = cursorScreenCol;
    // The renderer diffs per line and emits the trailing cursor escape only
    // when the last line changes. While the spinner ticks (no other change)
    // the physical cursor would stay parked on the Working… row, so the last
    // line gets an invisible, frame-varying SGR suffix to force its rewrite.
    final idleSuffix = busy ? '\x1b[0m' * (spinnerFrame % 4) : '';
    final cursorLine = '$idleSuffix\x1b[${cursorRow + 1};${cursorX + 1}H';
    return View(
      content: b.toString() + cursorLine,
      cursor: Cursor(x: cursorX, y: cursorRow, shape: CursorShape.bar),
    );
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
    // Keep the history bounded.
    const maxLines = 200;
    if (result.length > maxLines) {
      return result.sublist(result.length - maxLines);
    }
    return result;
  }
}

/// Thin wrapper around [Program] that lets [AgentCli] push output and refresh
/// the model picker without knowing dart_tui internals.
final class FaTuiController {
  FaTuiController({required this.callbacks, required this.isExited});

  final FaTuiCallbacks callbacks;
  final bool Function() isExited;

  late final FaTuiModel _model = FaTuiModel(
    callbacks: callbacks,
    isExited: isExited,
  );
  late final Program _program = Program(
    options: const ProgramOptions(altScreen: true, hideCursor: false),
  );

  /// Messages sent before [run] starts (e.g. the banner printed while the
  /// controller is already wired into the IO but the program is not yet
  /// listening). dart_tui drops sends that arrive before the event loop, so
  /// they are replayed into the initial model at [run] time instead.
  final List<Msg> _pending = [];
  var _running = false;

  FaTuiModel get model => _model;

  void _send(Msg msg) {
    if (_running) {
      _program.send(msg);
    } else {
      _pending.add(msg);
    }
  }

  void sendOutput(String text, {bool newline = false}) {
    _send(OutputMsg(text, newline: newline));
  }

  void sendModelsRefresh() {
    _send(_ModelsRefreshMsg());
  }

  void openModelMenu() {
    _send(_OpenModelMenuMsg());
  }

  /// Opens a generic host picker (sessions, mode, approval, ...) with a
  /// static item list; selection resolves via [FaTuiCallbacks.onPickerSelected].
  void openPicker(String pickerId, String title, List<MenuItem> items) {
    _send(OpenPickerMsg(pickerId, title, items));
  }

  void sendQuit() {
    _send(_QuitRequestedMsg());
  }

  /// Toggles the animated thinking indicator while a run streams.
  void sendBusy(bool busy) {
    _send(BusyMsg(busy));
  }

  /// Drains the queued messages (the model echoes them into the history) —
  /// the host runs them as separate turns after the current one settles.
  Future<List<String>> drainQueue() {
    final completer = Completer<List<String>>();
    _send(DrainQueueMsg(completer));
    return completer.future;
  }

  Future<void> run() {
    _running = true;
    var model = _model;
    for (final msg in _pending) {
      model = model.update(msg).$1 as FaTuiModel;
    }
    _pending.clear();
    return _program.run(model);
  }
}
