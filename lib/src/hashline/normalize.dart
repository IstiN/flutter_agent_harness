/// Minimal text-shape normalization: line-ending detection / round-trip and
/// BOM stripping, ported from oh-my-pi `packages/hashline/src/normalize.ts`.
/// The patcher uses these to canonicalize text to LF before applying edits
/// and to restore the original shape on write-back.
library;

/// Line-ending style of a text body.
enum LineEnding {
  /// Windows-style CRLF.
  crlf,

  /// Unix-style LF.
  lf,
}

/// Detects the first line ending style in [content]. Defaults to
/// [LineEnding.lf] when neither is present.
LineEnding detectLineEnding(String content) {
  final crlfIndex = content.indexOf('\r\n');
  final lfIndex = content.indexOf('\n');
  if (lfIndex == -1) return LineEnding.lf;
  if (crlfIndex == -1) return LineEnding.lf;
  return crlfIndex < lfIndex ? LineEnding.crlf : LineEnding.lf;
}

/// Normalizes every line ending to LF.
String normalizeToLF(String text) {
  return text.replaceAll(RegExp(r'\r\n?'), '\n');
}

/// Re-encodes LF text with the requested line ending.
String restoreLineEndings(String text, LineEnding ending) {
  return ending == LineEnding.crlf ? text.replaceAll('\n', '\r\n') : text;
}

/// Result of stripping a leading UTF-8 BOM from a text body.
typedef BomStripResult = ({String bom, String text});

/// Strips a UTF-8 BOM if present and returns both the BOM and the trailing
/// text.
BomStripResult stripBom(String content) {
  return content.startsWith('\uFEFF')
      ? (bom: '\uFEFF', text: content.substring(1))
      : (bom: '', text: content);
}
