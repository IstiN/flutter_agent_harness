/// Web-safe stub for `clipboard_writer.dart` (the platform pasteboard
/// text writes behind `/provider export`). The real writes shell out to
/// `pbcopy`/`xclip`/`wl-copy`/`clip` — all `dart:io` — so web builds of
/// the root library import this file conditionally.
///
/// On web the clipboard is simply unavailable: `/provider export` prints
/// the named failure instead of a copy confirmation.
library;

import 'paste_image.dart';

/// Always unavailable on web — the browser owns the clipboard.
Future<PasteboardWriteResult> writeClipboardText(String text) async =>
    const PasteboardWriteUnavailable(
      'pasteboard writes need a desktop terminal',
    );
