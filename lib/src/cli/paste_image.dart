/// Clipboard image paste (issue #276): pure sniffing / capping / naming.
///
/// The dart_tui REPL binds Ctrl+V to a pasteboard read (platform glue in
/// `clipboard_reader.dart`). The bytes land here: magic-byte sniffing decides
/// image vs not, the size cap turns an oversized clipboard into a NAMED error
/// (never a silent truncation), and the attachment carries the chip label the
/// composer renders. Pure Dart — no `dart:io` — so the web stub and the tests
/// share the exact rules the real reader enforces.
library;

/// The byte cap for a pasted image (10 MiB). A bigger clipboard is rejected
/// with the size IN the error plus a downscale suggestion — edge case E4.
const maxPasteImageBytes = 10 * 1024 * 1024;

/// Magic-byte signatures, checked in order (same set the `inspect_image`
/// tool sniffs).
const _imageMagicSignatures = [
  ('image/png', <int>[0x89, 0x50]),
  ('image/jpeg', <int>[0xFF, 0xD8]),
  ('image/gif', <int>[0x47, 0x49, 0x46]),
  ('image/webp', <int>[0x52, 0x49]), // RIFF
];

/// Sniffs the image MIME type from magic bytes; `null` when [bytes] do not
/// start with a known image signature (a text clipboard, a PDF, …).
String? sniffImageMime(List<int> bytes) {
  if (bytes.length < 8) return null;
  for (final (mimeType, magic) in _imageMagicSignatures) {
    var matches = true;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return mimeType;
  }
  return null;
}

/// The canonical file extension for a sniffed image MIME type.
String imageMimeExtension(String mimeType) => switch (mimeType) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  _ => 'bin',
};

/// Human-readable byte size for chips and errors: raw B under 1 KiB, KiB
/// under 1 MiB, MiB above (one decimal).
String formatPasteBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    final kib = bytes / 1024;
    return kib == kib.roundToDouble()
        ? '${kib.toStringAsFixed(0)}KB'
        : '${kib.toStringAsFixed(1)}KB';
  }
  final mib = bytes / (1024 * 1024);
  return '${mib.toStringAsFixed(1)}MB';
}

/// An image pasted from the clipboard, waiting in the composer as a chip.
final class TuiImageAttachment {
  const TuiImageAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  /// File name in the session images store (`clipboard-3.png`).
  final String name;

  /// Sniffed MIME type (`image/png`).
  final String mimeType;

  /// Raw image bytes (base64-encoded only at send time).
  final List<int> bytes;

  /// The composer chip label: `[image: clipboard-3.png 248KB]`.
  String get chip => '[image: $name ${formatPasteBytes(bytes.length)}]';
}

/// Validates clipboard [bytes] as a paster-able image.
///
/// Returns the error text when the paste must be rejected (oversized or not
/// an image — both NAMED), `null` when the bytes are good.
String? pasteImageError(List<int> bytes) {
  if (bytes.length > maxPasteImageBytes) {
    return 'clipboard image too large: ${formatPasteBytes(bytes.length)} '
        '(cap ${formatPasteBytes(maxPasteImageBytes)}) — downscale the image '
        'and paste again';
  }
  if (sniffImageMime(bytes) == null) {
    return 'clipboard does not hold a recognized image '
        '(png/jpeg/gif/webp magic bytes expected)';
  }
  return null;
}

/// The outcome of a pasteboard read: image bytes, or a named failure
/// reason. Pure data — the IO glue in `clipboard_reader.dart` produces it,
/// the REPL consumes it (both behind the same web-safe import).
sealed class PasteboardRead {
  const PasteboardRead();
}

final class PasteboardImage extends PasteboardRead {
  const PasteboardImage(this.bytes);

  /// Raw image bytes (sniffed/capped downstream).
  final List<int> bytes;
}

/// No image reachable — carries the failure reason for the transcript.
final class PasteboardUnavailable extends PasteboardRead {
  const PasteboardUnavailable(this.reason);
  final String reason;
}

/// The clean note for a terminal with no reachable pasteboard (edge E1):
/// names what happened and the file-path fallback.
const clipboardUnavailableHint =
    'clipboard has no image (terminal or pasteboard unavailable) — '
    'save the screenshot to a file and paste its path instead';
