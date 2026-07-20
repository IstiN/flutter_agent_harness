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
/// This class is intentionally host-agnostic: it knows nothing about the agent
/// or provider catalog. The embedding [AgentCli] supplies menu builders and the
/// submit callback.
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
  });

  final void Function(String) write;
  final void Function(String) writeln;
  final String prompt;
  final String Function() statusLine;
  final TuiStyle style;
  final List<MenuItem> Function(String prefix) buildSlashMenu;
  final List<MenuItem> Function() buildModelMenu;
  final Future<void> Function(String line) onSubmit;
  final Future<void> Function(String modelId) onModelSelected;
  final void Function()? onInterrupt;
  final bool Function()? isExited;

  final StringBuffer _buffer = StringBuffer();
  var _cursor = 0;
  var _menuOpen = false;
  var _menuModelMode = false;
  var _menuSelected = 0;
  List<MenuItem> _menuItems = const [];
  var _menuHeight = 0;

  String get _text => _buffer.toString();

  /// Runs the repl until the input key stream closes or the host marks exit.
  Future<void> run(Stream<dynamic> keysOrLines) async {
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
  }

  bool get _hostExited => isExited?.call() ?? false;

  void _handleKey(KeyEvent key) {
    switch (key.type) {
      case KeyType.enter:
        if (_menuOpen) {
          _acceptMenuItem();
        } else {
          _submitCurrent();
        }
      case KeyType.escape:
        _closeMenu();
      case KeyType.tab:
        if (_menuOpen) _acceptMenuItem();
      case KeyType.up:
        if (_menuOpen && _menuSelected > 0) _menuSelected--;
      case KeyType.down:
        if (_menuOpen && _menuSelected < _menuItems.length - 1) {
          _menuSelected++;
        }
      case KeyType.left:
        if (_cursor > 0) _cursor--;
      case KeyType.right:
        if (_cursor < _text.length) _cursor++;
      case KeyType.home:
        _cursor = 0;
      case KeyType.end:
        _cursor = _text.length;
      case KeyType.backspace:
        _deleteLeft();
        _updateMenu();
      case KeyType.delete:
        _deleteRight();
        _updateMenu();
      case KeyType.char:
        final ch = key.char;
        if (ch != null && ch.length == 1) {
          _insert(ch);
          _updateMenu();
        }
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
    if (text == '/m') {
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

  void _openModelMenu() {
    _menuModelMode = true;
    _menuItems = buildModelMenu();
    _menuSelected = 0;
    _menuOpen = true;
  }

  void _closeMenu() {
    _menuOpen = false;
    _menuModelMode = false;
    _menuItems = const [];
    _menuSelected = 0;
    _menuHeight = 0;
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

  void _render() {
    // Move cursor to the start and clear everything drawn in the previous
    // frame: status bar (1 line), prompt + input (1 line), menu lines.
    final totalLines = 1 + 1 + _menuHeight;
    final clear = StringBuffer();
    for (var i = 0; i < totalLines; i++) {
      if (i > 0) clear.write('\n');
      clear.write('\r\x1B[K');
    }
    // Move back up to the top of the cleared block.
    if (totalLines > 1) clear.write('\x1b[${totalLines - 1}A');
    write(clear.toString());

    // Status bar
    writeln(style.dim('─' * 60));
    writeln(style.dim(statusLine()));

    // Prompt + input
    write(style.bold(style.cyan(prompt)));
    write(_text);

    // Menu
    if (_menuOpen && _menuItems.isNotEmpty) {
      final title = _menuModelMode
          ? style.bold('[Select model]')
          : style.bold('[Commands]');
      writeln('');
      writeln(title);
      _menuHeight = 1 + _menuItems.length;
      for (var i = 0; i < _menuItems.length; i++) {
        final item = _menuItems[i];
        final selected = i == _menuSelected;
        final prefix = selected ? style.green('▸ ') : '  ';
        final label = selected ? style.bold(item.label) : item.label;
        final desc = item.description.isNotEmpty
            ? ' ${style.dim(item.description)}'
            : '';
        writeln('$prefix$label$desc');
      }
    } else {
      _menuHeight = 0;
      writeln('');
    }

    // Position cursor inside the input line. Count visible chars roughly by
    // stripping ANSI escapes. The prompt length is also stripped below.
    final promptVisible = _stripAnsi(prompt).length;
    final targetCol = promptVisible + _cursor;
    // Move up from after the menu to the input line, then to the target column.
    if (_menuHeight > 0) {
      write('\x1b[${_menuHeight + 1}A');
    }
    write('\r\x1b[${targetCol}C');
  }

  String _stripAnsi(String text) {
    // Remove ANSI SGR and cursor sequences for column counting.
    return text.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');
  }
}
