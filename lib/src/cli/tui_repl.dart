import 'dart:async';

import 'key_event.dart';

/// A selectable item in the TUI inline menu.
final class MenuItem {
  const MenuItem({
    required this.key,
    required this.label,
    this.description = '',
  });

  /// The text inserted when the item is accepted (e.g. `/model`).
  final String key;

  /// The visible label.
  final String label;

  /// Optional one-line description shown to the right.
  final String description;
}

/// Minimal ANSI styling contract used by [TuiRepl].
abstract interface class TuiStyle {
  String bold(String text);
  String dim(String text);
  String cyan(String text);
  String green(String text);
  String yellow(String text);
  String magenta(String text);
}

/// A raw-mode terminal REPL with an inline slash-command menu and model picker.
///
/// Uses the terminal's alternate screen buffer so the frame never pollutes
/// shell scrollback, and redraws changed rows at absolute positions wrapped
/// in synchronized-output markers. Output history is kept above the fixed
/// input line, so streaming text and tool notices append without moving the
/// prompt. The hardware cursor is hidden for the whole session and restored
/// on exit.
final class TuiRepl {
  TuiRepl({
    required this.write,
    required this.writeln,
    required this.prompt,
    required this.statusLine,
    required this.style,
    required this.buildSlashMenu,
    required this.buildModelMenu,
    required this.onSubmit,
    required this.onModelSelected,
    this.onInterrupt,
    this.isExited,
    this.columns = 80,
    this.rows = 24,
  });

  final void Function(String) write;
  final void Function(String) writeln;
  final String prompt;
  final String Function() statusLine;
  final TuiStyle style;
  final List<MenuItem> Function(String prefix) buildSlashMenu;
  final List<MenuItem> Function(String filter) buildModelMenu;
  final Future<void> Function(String line) onSubmit;
  final Future<void> Function(String modelId) onModelSelected;
  final void Function()? onInterrupt;
  final bool Function()? isExited;

  /// Terminal width in columns.
  final int columns;

  /// Terminal height in rows.
  final int rows;

  /// Maximum number of menu items rendered at once; the rest scrolls.
  static const _maxMenuItems = 10;

  /// Maximum output history kept above the input line.
  static const _maxOutputLines = 200;

  final StringBuffer _buffer = StringBuffer();
  var _cursor = 0;
  var _menuOpen = false;
  var _menuModelMode = false;
  var _menuSelected = 0;
  String _modelFilter = '';
  List<MenuItem> _menuItems = const [];

  /// Bounded output history shown above the input line.
  final List<String> _outputLines = <String>[];

  /// Previous rendered frame, padded to [rows] lines, used for diffing.
  List<String> _previousLines = const [];

  var _renderScheduled = false;

  String get _text => _buffer.toString();

  /// Appends host output (assistant text, tool notices, errors) above the
  /// input line. Chunked streaming text is merged into the current last line;
  /// embedded newlines split into new entries.
  void appendOutput(String text, {bool newline = false}) {
    if (text.isEmpty && !newline) return;
    final parts = text.split('\n');
    if (_outputLines.isEmpty) _outputLines.add('');
    _outputLines[_outputLines.length - 1] += parts.first;
    for (var i = 1; i < parts.length; i++) {
      _outputLines.add(parts[i]);
    }
    if (newline) _outputLines.add('');
    if (_outputLines.length > _maxOutputLines) {
      _outputLines.removeRange(0, _outputLines.length - _maxOutputLines);
    }
    _scheduleRender();
  }

  void _scheduleRender() {
    if (_renderScheduled) return;
    _renderScheduled = true;
    scheduleMicrotask(() {
      _renderScheduled = false;
      _render();
    });
  }

  /// Runs the repl until the input key stream closes or the host marks exit.
  Future<void> run(Stream<dynamic> keysOrLines) async {
    // Enter the alternate screen buffer and hide the hardware cursor so the
    // TUI frame never pollutes shell scrollback and redraws don't flicker.
    write('\x1b[?1049h\x1b[?25l');
    try {
      _render();
      await for (final event in keysOrLines) {
        if (_hostExited) break;
        if (event is String) {
          await _submitLine(event);
          if (_hostExited) break;
          _render();
        } else if (event is KeyEvent) {
          _handleKey(event);
          if (_hostExited) break;
          _render();
        }
      }
    } finally {
      write('\x1b[?25h\x1b[?1049l');
    }
  }

  bool get _hostExited => isExited?.call() ?? false;

  void _handleKey(KeyEvent key) {
    // When the model picker is open, typing filters the list instead of
    // editing the input buffer.
    if (_menuOpen && _menuModelMode) {
      switch (key.type) {
        case KeyType.char:
          final ch = key.char;
          if (ch != null && ch.length == 1) {
            // Ignore the first space after the picker opens: `/models open`
            // should start filtering at `open`, not at the separating space.
            if (ch == ' ' && _modelFilter.isEmpty) return;
            _modelFilter += ch;
            _refreshModelMenu();
          }
          return;
        case KeyType.backspace:
          if (_modelFilter.isNotEmpty) {
            _modelFilter = _modelFilter.substring(0, _modelFilter.length - 1);
            _refreshModelMenu();
          }
          return;
        case KeyType.enter:
        case KeyType.tab:
          _acceptMenuItem();
          return;
        case KeyType.escape:
          _closeMenu();
          return;
        case KeyType.up:
          if (_menuSelected > 0) _menuSelected--;
          return;
        case KeyType.down:
          if (_menuSelected < _menuItems.length - 1) _menuSelected++;
          return;
        case KeyType.pageUp:
          _menuSelected = 0;
          return;
        case KeyType.pageDown:
          _menuSelected = _menuItems.isEmpty ? 0 : _menuItems.length - 1;
          return;
        case KeyType.shiftTab:
          if (_menuSelected > 0) _menuSelected--;
          return;
        case KeyType.home:
        case KeyType.end:
        case KeyType.left:
        case KeyType.right:
        case KeyType.delete:
        case KeyType.unknown:
          return;
      }
    }

    switch (key.type) {
      case KeyType.enter:
        if (_menuOpen) {
          _acceptMenuItem();
        } else {
          _submitCurrent();
        }
        break;
      case KeyType.escape:
        _closeMenu();
        break;
      case KeyType.tab:
        if (_menuOpen) _acceptMenuItem();
        break;
      case KeyType.shiftTab:
        if (_menuOpen && _menuSelected > 0) _menuSelected--;
        break;
      case KeyType.up:
        if (_menuOpen && _menuSelected > 0) _menuSelected--;
        break;
      case KeyType.down:
        if (_menuOpen && _menuSelected < _menuItems.length - 1) {
          _menuSelected++;
        }
        break;
      case KeyType.left:
        if (_cursor > 0) _cursor--;
        break;
      case KeyType.right:
        if (_cursor < _text.length) _cursor++;
        break;
      case KeyType.home:
        _cursor = 0;
        break;
      case KeyType.end:
        _cursor = _text.length;
        break;
      case KeyType.backspace:
        _deleteLeft();
        _updateMenu();
        break;
      case KeyType.delete:
        _deleteRight();
        _updateMenu();
        break;
      case KeyType.char:
        final ch = key.char;
        if (ch != null && ch.length == 1) {
          _insert(ch);
          _updateMenu();
        }
        break;
      case KeyType.pageUp:
        if (_menuOpen) _menuSelected = 0;
        break;
      case KeyType.pageDown:
        if (_menuOpen) _menuSelected = _menuItems.length - 1;
        break;
      case KeyType.unknown:
        break;
    }
  }

  void _insert(String ch) {
    final text = _text;
    if (_cursor == text.length) {
      _buffer.write(ch);
    } else {
      _buffer
        ..clear()
        ..write(text.substring(0, _cursor))
        ..write(ch)
        ..write(text.substring(_cursor));
    }
    _cursor++;
  }

  void _deleteLeft() {
    final text = _text;
    if (_cursor == 0 || text.isEmpty) return;
    _buffer
      ..clear()
      ..write(text.substring(0, _cursor - 1))
      ..write(text.substring(_cursor));
    _cursor--;
  }

  void _deleteRight() {
    final text = _text;
    if (_cursor >= text.length) return;
    _buffer
      ..clear()
      ..write(text.substring(0, _cursor))
      ..write(text.substring(_cursor + 1));
  }

  void _updateMenu() {
    final text = _text;

    // `/models <filter>` opens the picker with a pre-filled filter.
    final filterMatch = RegExp(r'^/models\s+(.*)$').firstMatch(text);
    if (filterMatch != null) {
      _openModelMenu(filter: filterMatch.group(1)!);
      return;
    }

    if (text == '/models') {
      _openModelMenu();
      return;
    }
    if (text == '/' || text.startsWith('/')) {
      final items = buildSlashMenu(text);
      if (items.isEmpty) {
        _closeMenu();
      } else {
        _menuModelMode = false;
        _menuItems = items;
        _menuSelected = 0;
        _menuOpen = true;
      }
      return;
    }
    _closeMenu();
  }

  /// Refreshes the currently open menu and re-renders the frame. Call this
  /// when the host asynchronously updates the model list while the picker is
  /// visible.
  void refresh() {
    if (_menuOpen && _menuModelMode) {
      _menuItems = buildModelMenu(_modelFilter);
      if (_menuSelected >= _menuItems.length) {
        _menuSelected = _menuItems.isEmpty ? 0 : _menuItems.length - 1;
      }
    }
    _render();
  }

  /// Opens the model picker. Called by the host when the user submits a bare
  /// `/model` command in TUI mode.
  void openModelMenu() {
    _openModelMenu();
    _render();
  }

  void _openModelMenu({String filter = ''}) {
    _menuModelMode = true;
    _modelFilter = filter;
    _menuItems = buildModelMenu(filter);
    _menuSelected = 0;
    _menuOpen = true;
  }

  void _refreshModelMenu() {
    _menuItems = buildModelMenu(_modelFilter);
    _menuSelected = 0;
    _render();
  }

  void _closeMenu() {
    _menuOpen = false;
    _menuModelMode = false;
    _menuItems = const [];
    _menuSelected = 0;
    _modelFilter = '';
  }

  void _acceptMenuItem() {
    if (!_menuOpen || _menuItems.isEmpty) return;
    final item = _menuItems[_menuSelected];
    if (_menuModelMode) {
      _closeMenu();
      _clearBuffer();
      onModelSelected(item.key);
      return;
    }
    // Selecting /model or /models from the slash menu opens the model picker
    // instead of inserting the command text.
    if (item.key == '/model' || item.key == '/models') {
      _openModelMenu();
      return;
    }
    _buffer
      ..clear()
      ..write(item.key);
    _cursor = item.key.length;
    _closeMenu();
  }

  void _clearBuffer() {
    _buffer.clear();
    _cursor = 0;
  }

  Future<void> _submitCurrent() {
    final line = _text.trim();
    _clearBuffer();
    _closeMenu();
    return _submitLine(line);
  }

  Future<void> _submitLine(String line) async {
    if (line.isEmpty) return;
    await onSubmit(line);
  }

  /// Builds the visible frame as plain lines. Layout is:
  ///   output history (bounded, oldest at top)
  ///   separator
  ///   status line
  ///   prompt + input
  ///   optional menu
  List<String> _buildFrame() {
    final lines = <String>[];

    lines.addAll(_outputLines);
    lines.add(style.dim('─' * columns));
    lines.add(style.dim(statusLine()));
    lines.add('${style.bold(style.cyan(prompt))}$_text');

    if (_menuOpen && _menuItems.isNotEmpty) {
      final title = _menuModelMode
          ? style.bold(
              '[Select model${_modelFilter.isNotEmpty ? ': $_modelFilter' : ''}]',
            )
          : style.bold('[Commands]');
      lines.add(title);
      var start = 0;
      if (_menuItems.length > _maxMenuItems) {
        start = (_menuSelected - (_maxMenuItems ~/ 2)).clamp(
          0,
          _menuItems.length - _maxMenuItems,
        );
      }
      final end = _menuItems.length < start + _maxMenuItems
          ? _menuItems.length
          : start + _maxMenuItems;
      if (start > 0) lines.add(style.dim('  ↑ more'));
      for (var i = start; i < end; i++) {
        final item = _menuItems[i];
        final selected = i == _menuSelected;
        final prefix = selected ? style.green('▸ ') : '  ';
        final label = selected ? style.bold(item.label) : item.label;
        final desc = item.description.isNotEmpty
            ? ' ${style.dim(item.description)}'
            : '';
        lines.add('$prefix$label$desc');
      }
      if (end < _menuItems.length) lines.add(style.dim('  ↓ more'));
    }

    return lines;
  }

  /// Pads/truncates the frame to exactly [rows] lines. The input line is
  /// always the last line of the visible frame; when content is taller than
  /// the screen the oldest output is scrolled off the top.
  List<String> _visibleFrame(List<String> frame) {
    if (frame.length > rows) {
      return frame.sublist(frame.length - rows);
    }
    final padding = rows - frame.length;
    if (padding <= 0) return frame;
    return List<String>.filled(padding, '') + frame;
  }

  void _render() {
    final frame = _buildFrame();
    final visible = _visibleFrame(frame);

    // The input line is the last non-menu structural line before menu items.
    final inputRow = _inputRow(visible);
    final promptVisible = _stripAnsi(prompt).length;
    final targetCol = promptVisible + _cursor;

    final out = StringBuffer();
    out.write('\x1b[?2026h');

    for (var i = 0; i < visible.length; i++) {
      final newLine = visible[i];
      final oldLine = i < _previousLines.length ? _previousLines[i] : '';
      if (newLine != oldLine) {
        out.write('\x1b[${i + 1};1H');
        out.write(_truncate(newLine, columns));
        // Only erase to end of line when the new line is narrower than the
        // old one; unconditionally clearing the whole line first flickers.
        if (_stripAnsi(newLine).length < _stripAnsi(oldLine).length) {
          out.write('\x1b[K');
        }
      }
    }

    out.write('\x1b[?2026l');

    // Position the cursor on the input line.
    out.write('\x1b[${inputRow + 1};${targetCol + 1}H');

    write(out.toString());
    _previousLines = List.of(visible);
  }

  int _inputRow(List<String> visible) {
    // Find the line containing the prompt, searching from the bottom.
    for (var i = visible.length - 1; i >= 0; i--) {
      if (_stripAnsi(visible[i]).startsWith(prompt)) return i;
    }
    return visible.length - 1;
  }

  /// Truncates [line] to [width] visible columns, preserving ANSI sequences.
  String _truncate(String line, int width) {
    if (_stripAnsi(line).length <= width) return line;
    final out = StringBuffer();
    var visible = 0;
    var i = 0;
    while (i < line.length && visible < width) {
      if (line[i] == '\x1b') {
        final match = RegExp(
          r'^\x1b\[[0-9;]*[A-Za-z]',
        ).firstMatch(line.substring(i));
        if (match != null) {
          out.write(match.group(0));
          i += match.group(0)!.length;
          continue;
        }
      }
      out.write(line[i]);
      visible++;
      i++;
    }
    return out.toString();
  }

  String _stripAnsi(String text) {
    // Remove ANSI SGR and cursor sequences for column counting.
    return text.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');
  }
}
