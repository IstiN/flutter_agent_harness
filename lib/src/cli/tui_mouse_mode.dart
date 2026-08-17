/// Mouse-scroll behaviour for the Fa TUI.
enum TuiMouseMode {
  /// The terminal keeps native text selection; the TUI does not capture
  /// mouse wheel events. Use PgUp/PgDn to scroll the TUI viewport.
  off,

  /// The TUI captures the mouse wheel to scroll its internal viewport.
  /// Most terminals still allow Shift+drag to select text.
  on,

  /// Start with mouse capture enabled and disable it if the terminal does
  /// not send a mouse wheel event within a short probe window.
  auto,
}

/// Parses a user-supplied string into a [TuiMouseMode].
TuiMouseMode parseTuiMouseMode(String? value) {
  final v = value?.trim().toLowerCase();
  return switch (v) {
    '1' || 'true' || 'yes' || 'on' => TuiMouseMode.on,
    '0' || 'false' || 'no' => TuiMouseMode.off,
    _ => TuiMouseMode.auto,
  };
}
