/// The pure-Dart entry point of the vendored dart_tui: styles, colors and
/// themes WITHOUT the program/terminal layer — no `dart:ffi` anywhere in
/// the import graph (web builds compile this; issue #279). For the full
/// TUI runtime use `package:dart_tui/dart_tui.dart`.
library;

export 'src/bubbles/style.dart';
export 'src/bubbles/themes.dart';
export 'src/msg.dart' show ColorProfile;
