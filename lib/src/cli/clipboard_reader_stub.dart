/// Web-safe stub for `clipboard_reader.dart` (the platform pasteboard
/// image reads). The real reads shell out to `osascript`/`xclip`/
/// `wl-paste`/PowerShell — all `dart:io` — so web builds of the root
/// library import this file conditionally:
///
/// ```dart
/// import 'clipboard_reader_stub.dart' if (dart.library.io)
///   'clipboard_reader.dart';
/// ```
///
/// On web the pasteboard is simply unavailable (edge E1): Ctrl+V prints
/// the clean "no image in the clipboard" note and the file-path fallback
/// hint, exactly like a terminal with no reachable pasteboard.
library;

import 'paste_image.dart';

/// Always unavailable on web — the browser owns the clipboard and the CLI
/// TUI never runs there.
Future<PasteboardRead> readPasteboardImage() async =>
    const PasteboardUnavailable('pasteboard reads need a desktop terminal');

/// Always unavailable on web — mirrors `clipboard_reader.dart`'s text read
/// (gh-1575): Ctrl+V's text fallback simply never fires on web.
Future<PasteboardRead> readPasteboardText() async =>
    const PasteboardUnavailable('pasteboard reads need a desktop terminal');
