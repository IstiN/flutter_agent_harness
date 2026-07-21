/// A single key press from an interactive terminal in raw mode.
///
/// Either [char] is set for a printable character, or [type] identifies a
/// special key. Modifiers are reported when the terminal sends them.
final class KeyEvent {
  const KeyEvent({
    this.char,
    required this.type,
    this.shift = false,
    this.ctrl = false,
    this.alt = false,
  });

  /// Printable character, if any. Null for special keys.
  final String? char;

  /// The key type.
  final KeyType type;

  /// Whether Shift was held.
  final bool shift;

  /// Whether Ctrl was held.
  final bool ctrl;

  /// Whether Alt/Meta was held.
  final bool alt;

  @override
  String toString() =>
      'KeyEvent(char: $char, type: $type, shift: $shift, ctrl: $ctrl, alt: $alt)';
}

/// Kinds of keys recognized by the TUI input loop.
enum KeyType {
  char,
  up,
  down,
  left,
  right,
  tab,
  shiftTab,
  enter,
  escape,
  backspace,
  delete,
  home,
  end,
  pageUp,
  pageDown,
  unknown,
}
