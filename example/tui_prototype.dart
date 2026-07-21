// Interactive TUI prototype for Fa, built on dart_tui components.
// Run: dart run example/tui_prototype.dart
//
// Layout (fixed):
//   header (app name + hints) — 3 lines
//   viewport (chat history) — variable height
//   separator — 1 line
//   fuzzy command menu (when / is typed) — 8 lines
//   input (fa> + multi-line editor) — 4 lines
//   info line (mode · model · cwd) — 1 line
//   tokens line (tokens · cost · turn) — 1 line

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:dart_tui/dart_tui.dart';

final _log = FileLog('/tmp/fa_tui_debug.log');

/// Whether the terminal responded positively to the Kitty keyboard protocol
/// query. When true, `\n` is treated as Shift+Enter (newline) and `\r` as
/// Enter (submit), matching pi's mode-aware handling.
var _kittyProtocolActive = false;

// macOS Core Graphics modifier check, mirroring pi's native-modifiers helper.
final _coreGraphics = DynamicLibrary.open(
  '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
);

typedef _CGEventSourceFlagsStateC = Uint64 Function(Uint32);
typedef _CGEventSourceFlagsStateDart = int Function(int);

final _cgEventSourceFlagsState = _coreGraphics
    .lookupFunction<_CGEventSourceFlagsStateC, _CGEventSourceFlagsStateDart>(
      'CGEventSourceFlagsState',
    );

bool _isShiftPressed() {
  const kCGEventSourceStateHIDSystemState = 1;
  const kCGEventFlagMaskShift = 0x00020000;
  try {
    final flags = _cgEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    return (flags & kCGEventFlagMaskShift) != 0;
  } on Object {
    return false;
  }
}

/// Converts modifyOtherKeys Shift+Enter (`CSI 27;2;13~`) into Ctrl+O so the
/// model can treat it as "insert newline" without touching dart_tui's decoder.
Stream<List<int>> _preprocessInput(Stream<List<int>> input) {
  return input.map((chunk) {
    _log(
      'raw input: ${chunk.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}',
    );
    final result = <int>[];
    for (var i = 0; i < chunk.length; i++) {
      // Kitty keyboard protocol response: CSI ? 1 ; 2 c (flags) or CSI ? 0 c
      // (no support). Pi treats any non-zero flags as "kitty active".
      if (i + 6 < chunk.length &&
          chunk[i] == 0x1b &&
          chunk[i + 1] == 0x5b &&
          chunk[i + 2] == 0x3f &&
          chunk[i + 3] == 0x31 &&
          chunk[i + 4] == 0x3b &&
          chunk[i + 5] == 0x32 &&
          chunk[i + 6] == 0x63) {
        _kittyProtocolActive = true;
        _log('kitty protocol active');
        i += 6;
        continue;
      }
      if (i + 5 < chunk.length &&
          chunk[i] == 0x1b &&
          chunk[i + 1] == 0x5b &&
          chunk[i + 2] == 0x3f &&
          chunk[i + 3] == 0x30 &&
          chunk[i + 4] == 0x63) {
        _kittyProtocolActive = false;
        _log('kitty protocol NOT supported');
        i += 5;
        continue;
      }
      // modifyOtherKeys Shift+Enter: CSI 27;2;13~
      if (i + 9 < chunk.length &&
          chunk[i] == 0x1b &&
          chunk[i + 1] == 0x5b &&
          chunk[i + 2] == 0x32 &&
          chunk[i + 3] == 0x37 &&
          chunk[i + 4] == 0x3b &&
          chunk[i + 5] == 0x32 &&
          chunk[i + 6] == 0x3b &&
          chunk[i + 7] == 0x31 &&
          chunk[i + 8] == 0x33 &&
          chunk[i + 9] == 0x7e) {
        _log('detected shift+enter (modifyOtherKeys)');
        result.add(0x0f); // Ctrl+O
        i += 9;
        continue;
      }
      // Kitty CSI-u Shift+Enter: CSI 13;2u
      if (i + 6 < chunk.length &&
          chunk[i] == 0x1b &&
          chunk[i + 1] == 0x5b &&
          chunk[i + 2] == 0x31 &&
          chunk[i + 3] == 0x33 &&
          chunk[i + 4] == 0x3b &&
          chunk[i + 5] == 0x32 &&
          chunk[i + 6] == 0x75) {
        _log('detected shift+enter (Kitty CSI-u)');
        result.add(0x0f); // Ctrl+O
        i += 6;
        continue;
      }
      // Kitty mapping: ESC CR is Shift+Enter when kitty protocol is active.
      if (_kittyProtocolActive &&
          i + 1 < chunk.length &&
          chunk[i] == 0x1b &&
          chunk[i + 1] == 0x0d) {
        _log('detected shift+enter (Kitty ESC CR)');
        result.add(0x0f); // Ctrl+O
        i += 1;
        continue;
      }

      result.add(chunk[i]);
    }
    return result;
  });
}

Future<void> main() async {
  try {
    await Program(
      options: const ProgramOptions(
        altScreen: true,
        tickInterval: Duration(milliseconds: 100),
        hideCursor: false,
      ),
      programOptions: [
        withInput(_preprocessInput(stdin)),
        withMouseAllMotion(),
      ],
    ).run(FaPrototypeModel());
  } finally {
    // Disable mouse reporting and keyboard protocols so the shell does not
    // echo SGR mouse motion events as text after exit.
    stdout.write(
      '\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l'
      '\x1b[>4;0m\x1b[<u',
    );
    await _log.close();
  }
}

final class FaPrototypeModel extends TeaModel {
  FaPrototypeModel({
    ViewportModel? viewport,
    TextAreaModel? input,
    ListModel? menu,
    this.mode = 'code',
    this.model = 'amazon/nova-micro-v1',
    this.cwd = '/Users/Uladzimir_Klyshevich/git/flutter_agent',
    this.totalTokens = 0,
    this.totalCost = 0.0,
    this.turn = 0,
    this.menuOpen = false,
    this.termWidth = 80,
    this.termHeight = 24,
    this.pendingFaReplies = 0,
  }) : viewport =
           viewport ?? ViewportModel(content: _welcome, width: 80, height: 20),
       input =
           input ??
           TextAreaModel(
             placeholder: 'Type a message… (Enter newline, Ctrl+S sends)',
             maxHeight: 4,
           ),
       menu =
           menu ?? ListModel(items: _slashItems, height: 6, title: 'Commands');

  static const _welcome =
      'fa v0.1.41\n'
      'escape interrupt · ctrl+c clear/exit · / commands · ! bash\n'
      'Press /help to show full commands and resources.\n';

  static const _slashItems = [
    ListItem(title: '/help', description: 'show full commands and resources'),
    ListItem(title: '/model', description: 'select model (opens selector)'),
    ListItem(title: '/models', description: 'list known models'),
    ListItem(title: '/mode', description: 'show or switch the active mode'),
    ListItem(title: '/session', description: 'manage named sessions'),
    ListItem(title: '/stats', description: 'show token and cost totals'),
    ListItem(title: '/reset', description: 'start a new session'),
    ListItem(
      title: '/compact',
      description: 'summarize history to free context',
    ),
    ListItem(title: '/exit', description: 'quit'),
  ];

  static const _faReplies = [
    'fa: I read the file and found the issue.',
    'fa: Running tests now…',
    'fa: The build failed with 2 errors.',
    'fa: Let me check the LSP diagnostics.',
    'fa: That command is not allowed in yolo mode.',
    'fa: Compacting context to free up tokens.',
    'fa: I created a checkpoint before the refactor.',
    'fa: The model list is stale, refreshing…',
  ];

  final ViewportModel viewport;
  final TextAreaModel input;
  final ListModel menu;
  final String mode;
  final String model;
  final String cwd;
  final int totalTokens;
  final double totalCost;
  final int turn;
  final bool menuOpen;
  final int termWidth;
  final int termHeight;
  final int pendingFaReplies;

  FaPrototypeModel copyWith({
    ViewportModel? viewport,
    TextAreaModel? input,
    ListModel? menu,
    String? mode,
    String? model,
    String? cwd,
    int? totalTokens,
    double? totalCost,
    int? turn,
    bool? menuOpen,
    int? termWidth,
    int? termHeight,
    int? pendingFaReplies,
  }) => FaPrototypeModel(
    viewport: viewport ?? this.viewport,
    input: input ?? this.input,
    menu: menu ?? this.menu,
    mode: mode ?? this.mode,
    model: model ?? this.model,
    cwd: cwd ?? this.cwd,
    totalTokens: totalTokens ?? this.totalTokens,
    totalCost: totalCost ?? this.totalCost,
    turn: turn ?? this.turn,
    menuOpen: menuOpen ?? this.menuOpen,
    termWidth: termWidth ?? this.termWidth,
    termHeight: termHeight ?? this.termHeight,
    pendingFaReplies: pendingFaReplies ?? this.pendingFaReplies,
  );

  @override
  Cmd? init() {
    // Enable modifyOtherKeys, query Kitty keyboard protocol, and enable mouse
    // tracking (button events + SGR coordinates) so two-finger trackpad
    // scrolling reports as wheel buttons 64/65 instead of motion events.
    stdout.write(
      '\x1b[>4;1m\x1b[>7u\x1b[?u\x1b[c'
      '\x1b[?1000h\x1b[?1002h\x1b[?1006h',
    );
    return null;
  }

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is KeyMsg) {
      _log(
        'key=${msg.key} text=${msg.keyEvent.text} mods=${msg.keyEvent.modifiers} menuOpen=$menuOpen',
      );
    }
    if (msg is MouseMsg) {
      _log(
        'mouse=${msg.mouse.button}@${msg.mouse.x},${msg.mouse.y} mods=${msg.mouse.modifiers}',
      );
    }
    if (msg is WindowSizeMsg) {
      final nextHeight = msg.height;
      final nextWidth = msg.width;
      // Clamp the viewport scroll offset to the new visible area so resizing
      // does not leave yOffset out of bounds (which showed >100% progress).
      final clampedOffset = _clampYOffset(
        viewport.yOffset,
        viewport.content,
        _viewportHeightFor(nextWidth, nextHeight),
      );
      return (
        copyWith(
          termWidth: nextWidth,
          termHeight: nextHeight,
          viewport: ViewportModel(
            content: viewport.content,
            width: nextWidth,
            height: _viewportHeightFor(nextWidth, nextHeight),
            yOffset: clampedOffset,
          ),
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
        return (copyWith(viewport: viewport.scrollBy(delta)), null);
      }
      return (this, null);
    }
    if (msg is _FaReplyMsg) {
      final reply = _faReplies[Random().nextInt(_faReplies.length)];
      final nextViewport = _appendToViewport(viewport, reply);
      return (
        copyWith(
          viewport: nextViewport,
          pendingFaReplies: pendingFaReplies > 0 ? pendingFaReplies - 1 : 0,
        ),
        pendingFaReplies > 1 ? _scheduleFaReply() : null,
      );
    }
    if (msg is PasteMsg) {
      final nextInput = _insertPaste(input, msg.content);
      return (copyWith(input: nextInput), null);
    }
    if (msg is! KeyMsg) return (this, null);

    // dart_tui's input decoder groups up to 4 ASCII bytes into a single rune,
    // and TextAreaModel advances the cursor by 1 instead of the inserted text
    // length. Split multi-character runes into individual key events so
    // 'hello' does not become 'hoell'.
    if (msg is KeyPressMsg &&
        msg.keyEvent.code == KeyCode.rune &&
        msg.keyEvent.text.length > 1) {
      var current = this;
      Cmd? lastCmd;
      for (final ch in msg.keyEvent.text.split('')) {
        final result = current._handleKey(
          KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
        );
        current = result.$1 as FaPrototypeModel;
        if (result.$2 != null) lastCmd = result.$2;
      }
      return (current, lastCmd);
    }

    return _handleKey(msg);
  }

  (Model, Cmd?) _handleKey(KeyMsg msg) {
    // Menu open: typing filters the list (without entering ListModel's
    // filterMode, so up/down still works), Esc closes, Enter selects.
    if (menuOpen) {
      if (msg.key == 'esc') {
        return (copyWith(menuOpen: false), null);
      }
      if (msg.key == 'backspace') {
        if (menu.filter.isNotEmpty) {
          final nextMenu = _withMenuFilter(
            menu,
            menu.filter.substring(0, menu.filter.length - 1),
          );
          return (copyWith(menu: nextMenu), null);
        }
        return (this, null);
      }
      if (msg.key == 'enter') {
        final selected = menu.selected;
        if (selected != null) {
          final nextInput = input.copyWith(
            value: selected.title,
            cursorCol: selected.title.length,
          );
          return (copyWith(input: nextInput, menuOpen: false), null);
        }
        return (copyWith(menuOpen: false), null);
      }
      // Printable characters filter the menu.
      if (msg.key.length == 1 && !msg.key.startsWith('\x1b')) {
        final nextMenu = _withMenuFilter(menu, menu.filter + msg.key);
        return (copyWith(menu: nextMenu), null);
      }
      final (nextMenu, cmd) = menu.update(msg);
      return (copyWith(menu: nextMenu as ListModel), cmd);
    }

    // Input mode: intercept / to open the menu, Enter to submit, Ctrl+Enter
    // to insert a newline via the TextAreaModel. Opening the menu does NOT
    // enter filterMode, so arrow keys work immediately; pressing / again
    // inside the menu starts fuzzy filtering.
    if (msg.key == '/' && input.value.isEmpty) {
      return (copyWith(menuOpen: true), null);
    }
    // Ctrl+S always submits, regardless of terminal Shift+Enter support.
    if (msg.key == 'ctrl+s') {
      final text = input.value.trim();
      if (text.isEmpty) return (this, null);
      final nextViewport = _appendToViewport(viewport, 'user: $text');
      final nextInput = input.copyWith(
        value: '',
        cursorRow: 0,
        cursorCol: 0,
        scrollOffset: 0,
      );
      return (
        copyWith(
          viewport: nextViewport,
          input: nextInput,
          turn: turn + 1,
          totalTokens: totalTokens + text.length,
          totalCost: totalCost + text.length * 0.000001,
          pendingFaReplies: pendingFaReplies + 1,
        ),
        _scheduleFaReply(),
      );
    }
    // Enter submits; Shift+Enter inserts a newline. On Apple Terminal (and
    // other terminals that do not distinguish Shift+Enter in the input
    // stream), we check the macOS modifier state via Core Graphics, exactly
    // like pi's native-modifiers helper.
    if (msg.key == 'enter') {
      if (_isShiftPressed()) {
        final (nextInput, cmd) = input.update(
          KeyPressMsg(const TeaKey(code: KeyCode.enter)),
        );
        return (copyWith(input: nextInput as TextAreaModel), cmd);
      }
      final text = input.value.trim();
      if (text.isEmpty) return (this, null);
      final nextViewport = _appendToViewport(viewport, 'user: $text');
      final nextInput = input.copyWith(
        value: '',
        cursorRow: 0,
        cursorCol: 0,
        scrollOffset: 0,
      );
      return (
        copyWith(
          viewport: nextViewport,
          input: nextInput,
          turn: turn + 1,
          totalTokens: totalTokens + text.length,
          totalCost: totalCost + text.length * 0.000001,
          pendingFaReplies: pendingFaReplies + 1,
        ),
        _scheduleFaReply(),
      );
    }
    // PageUp/PageDown (Fn+Up/Down on Mac) or Up/Down when the input is empty
    // scroll the chat history when the menu is closed. When the input has
    // text, Up/Down moves the cursor inside the TextAreaModel instead.
    if (!menuOpen &&
        (msg.key == 'pgup' || (msg.key == 'up' && input.value.isEmpty))) {
      return (copyWith(viewport: viewport.scrollBy(-viewport.height)), null);
    }
    if (!menuOpen &&
        (msg.key == 'pgdown' || (msg.key == 'down' && input.value.isEmpty))) {
      return (copyWith(viewport: viewport.scrollBy(viewport.height)), null);
    }
    // Ctrl+C quits so the program disables mouse reporting on exit.
    if (msg.key == 'ctrl+c') {
      return (this, () => quit());
    }
    // Word motion like pi's editor: alt+left/right jump by words.
    if (msg.key == 'alt+left') {
      final lines = input.lines;
      final row = input.cursorRow.clamp(0, lines.length - 1);
      final newCol = _wordStartBefore(lines[row], input.cursorCol);
      return (copyWith(input: input.copyWith(cursorCol: newCol)), null);
    }
    if (msg.key == 'alt+right') {
      final lines = input.lines;
      final row = input.cursorRow.clamp(0, lines.length - 1);
      final newCol = _wordEndAfter(lines[row], input.cursorCol);
      return (copyWith(input: input.copyWith(cursorCol: newCol)), null);
    }
    if (msg.key == 'ctrl+o' || msg.key == 'ctrl+j') {
      final (nextInput, cmd) = input.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
      return (copyWith(input: nextInput as TextAreaModel), cmd);
    }

    // Delegate to the input editor.
    final (nextInput, cmd) = input.update(msg);
    return (copyWith(input: nextInput as TextAreaModel), cmd);
  }

  Cmd _scheduleFaReply() {
    return () async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return _FaReplyMsg();
    };
  }

  int _wordStartBefore(String line, int pos) {
    var i = pos;
    while (i > 0 && line[i - 1] == ' ') {
      i--;
    }
    while (i > 0 && line[i - 1] != ' ') {
      i--;
    }
    return i;
  }

  int _wordEndAfter(String line, int pos) {
    var i = pos;
    while (i < line.length && line[i] == ' ') {
      i++;
    }
    while (i < line.length && line[i] != ' ') {
      i++;
    }
    return i;
  }

  ListModel _withMenuFilter(ListModel menu, String filter) {
    return ListModel(
      items: menu.items,
      cursor: 0,
      title: menu.title,
      height: menu.height,
      filter: filter,
      filterMode: false, // keep false so up/down still works
      styles: menu.styles,
      showStatusBar: menu.showStatusBar,
      showDescription: menu.showDescription,
      viewOffsetY: menu.viewOffsetY,
    );
  }

  TextAreaModel _insertPaste(TextAreaModel ta, String content) {
    final lines = ta.lines;
    final row = ta.cursorRow.clamp(0, lines.length - 1);
    final line = lines[row];
    final col = ta.cursorCol.clamp(0, line.length);
    final pasteLines = content.split('\n');

    if (pasteLines.length == 1) {
      // Single-line paste: insert at cursor.
      lines[row] = line.substring(0, col) + content + line.substring(col);
      return ta.copyWith(
        value: lines.join('\n'),
        cursorCol: col + content.length,
      );
    }

    // Multi-line paste: split the current line at cursor, insert paste lines.
    final before = line.substring(0, col);
    final after = line.substring(col);
    final newLines = <String>[
      ...lines.sublist(0, row),
      before + pasteLines.first,
      ...pasteLines.sublist(1, pasteLines.length - 1),
      pasteLines.last + after,
      ...lines.sublist(row + 1),
    ];
    return ta.copyWith(
      value: newLines.join('\n'),
      cursorRow: row + pasteLines.length - 1,
      cursorCol: pasteLines.last.length,
    );
  }

  ViewportModel _appendToViewport(ViewportModel vp, String line) {
    final newContent = vp.content.isEmpty ? line : '${vp.content}\n$line';
    final height = _viewportHeight;
    return ViewportModel(
      content: newContent,
      width: vp.width,
      height: height,
      yOffset: _bottomOffset(newContent, height),
    );
  }

  int _viewportHeightFor(int width, int height) {
    const headerH = 3;
    const separatorH = 1;
    const inputH = 4;
    const inputBorderH = 1;
    const infoH = 1;
    const tokensH = 1;
    const cursorMoveH = 1;
    final menuH = menuOpen ? 9 : 0;
    final used =
        headerH +
        separatorH +
        inputH +
        inputBorderH +
        infoH +
        tokensH +
        menuH +
        cursorMoveH;
    return (height - used).clamp(3, 9999);
  }

  int get _viewportHeight => _viewportHeightFor(termWidth, termHeight);

  int _clampYOffset(int yOffset, String content, int height) {
    final totalLines = content.split('\n').length;
    final maxOffset = (totalLines - height).clamp(0, totalLines);
    return yOffset.clamp(0, maxOffset);
  }

  int _bottomOffset(String content, int height) {
    final lines = content.split('\n');
    return lines.length > height ? lines.length - height : 0;
  }

  /// Truncates [line] to fit [width], keeping the cursor visible.
  String _visibleLine(String line, int cursorCol, int width) {
    if (line.length <= width) return line;
    final start = (cursorCol - width ~/ 2).clamp(0, line.length - width);
    return line.substring(start, start + width);
  }

  int _visibleCursorCol(String line, int cursorCol, int width) {
    if (line.length <= width) return cursorCol;
    final start = (cursorCol - width ~/ 2).clamp(0, line.length - width);
    return cursorCol - start;
  }

  static var _renderCount = 0;

  @override
  View view() {
    _renderCount++;
    final b = StringBuffer();

    // Header.
    b.writeln('fa — Flutter Agent Harness');
    b.writeln('interactive TUI prototype · dart_tui components');
    b.writeln('─' * termWidth);

    // Viewport (chat history), padded to a fixed height. The yOffset comes
    // from the model so scrolling (Up/Down, PageUp/PageDown) actually moves
    // the visible window instead of being reset to the bottom every frame.
    final vp = ViewportModel(
      content: viewport.content,
      width: termWidth,
      height: _viewportHeight,
      yOffset: viewport.yOffset,
    );
    final vpLines = vp.view().content.split('\n');
    for (var i = 0; i < _viewportHeight; i++) {
      if (i < vpLines.length) {
        b.writeln(vpLines[i]);
      } else {
        b.writeln();
      }
    }

    // Scroll progress indicator like the pager demo, capped to 0-100%.
    final scrollPercent = (vp.scrollPercent * 100).round().clamp(0, 100);
    final progressText = ' $scrollPercent% ';
    final progressWidth = progressText.length;
    final leftWidth = (termWidth - progressWidth) ~/ 2;
    final rightWidth = termWidth - progressWidth - leftWidth;
    b.writeln('─' * leftWidth + progressText + '─' * rightWidth);

    // Menu above input, fixed height.
    if (menuOpen) {
      final menuLines = menu.view().content.split('\n');
      for (var i = 0; i < 9; i++) {
        if (i < menuLines.length) {
          b.writeln(menuLines[i]);
        } else {
          b.writeln();
        }
      }
    }

    // Input, padded to 4 lines. Long lines are truncated around the cursor so
    // the cursor stays visible. The TextAreaModel scrollOffset tells us which
    // input lines are visible; without it the cursor flies to the top when
    // the input exceeds the visible height.
    const inputH = 4;
    final inputLines = input.lines;
    final inputStartRow = 3 + _viewportHeight + 1 + (menuOpen ? 8 : 0);
    var cursorScreenRow = 0;
    var cursorScreenCol = 0;
    for (var i = 0; i < inputH; i++) {
      if (i == 0) b.write('> ');
      final lineIndex = input.scrollOffset + i;
      if (lineIndex < inputLines.length) {
        final line = inputLines[lineIndex];
        final isCursorLine = lineIndex == input.cursorRow;
        final visibleLine = isCursorLine
            ? _visibleLine(line, input.cursorCol, termWidth - 2)
            : line;
        if (isCursorLine) {
          cursorScreenRow = inputStartRow + i;
          // The `> ` prompt occupies 2 columns only on the first visible line;
          // continuation lines start at column 0.
          cursorScreenCol =
              (i == 0 ? 2 : 0) +
              _visibleCursorCol(line, input.cursorCol, termWidth - 2);
        }
        b.writeln(visibleLine);
      } else {
        b.writeln();
      }
    }

    // Clear boundary below the input zone.
    b.writeln('─' * termWidth);

    // Info line.
    b.writeln('mode: $mode · model: $model · cwd: $cwd');

    // Tokens line.
    b.writeln(
      '${totalTokens}tok · \$${totalCost.toStringAsFixed(4)} · turn $turn',
    );

    // dart_tui's renderer shows/hides the cursor from View.cursor but does
    // not position it, so we emit the absolute cursor move as its own line.
    // A run of no-op SGR resets makes the line change every frame, forcing
    // the line-level diff to rewrite it instead of skipping it.
    final frame = b.toString();
    final lines = frame.split('\n');
    final cursorRow = cursorScreenRow.clamp(0, lines.length - 1);
    final cursorCol = cursorScreenCol.clamp(0, termWidth - 1);
    final cursorLine =
        '\x1b[${cursorRow + 1};${cursorCol + 1}H'
            '\x1b[0m' *
        (_renderCount % 10 + 1);
    return View(
      content: '$frame$cursorLine\n',
      cursor: Cursor(x: cursorCol, y: cursorRow, shape: CursorShape.bar),
    );
  }
}

final class _FaReplyMsg extends Msg {}
