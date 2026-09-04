/// Bounded Markdown-to-text projection shared by trajectory consumers.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-preview.ts`. The upstream extractor parses streaming GFM and
/// strips exactly the markup a renderer would draw; this port keeps the same
/// pipeline (slice → strip → collapse → cap → ellipsis) with a conservative
/// char-scan stripper so the pure-Dart core needs no Markdown dependency.
library;

/// Source characters inspected before the projection is truncated.
const _previewSourceCharacters = 2048;

/// Maximum characters of the collapsed preview that survive.
const _previewOutputCharacters = 512;

/// Builds a bounded one-line preview without parsing the full document.
///
/// Returns the Markdown-stripped, whitespace-collapsed head of [text],
/// capped at 512 characters, with a trailing `…` whenever the source or the
/// collapsed text was cut short.
String trajectoryPreviewText(String text) {
  final source = text.length > _previewSourceCharacters
      ? text.substring(0, _previewSourceCharacters)
      : text;
  final compact = _collapseWhitespace(markdownToPlainText(source));
  var preview = compact.length > _previewOutputCharacters
      ? compact.substring(0, _previewOutputCharacters)
      : compact;
  while (preview.isNotEmpty && _trailingWhitespace.hasMatch(preview)) {
    preview = preview.substring(0, preview.length - 1);
  }
  final truncated =
      source.length < text.length || preview.length < compact.length;
  return truncated ? '$preview…' : preview;
}

final RegExp _trailingWhitespace = RegExp(r'\s$');

String _collapseWhitespace(String text) =>
    text.replaceAll(_whitespaceRuns, ' ').trim();

final RegExp _whitespaceRuns = RegExp(r'\s+');

/// Strips common GFM presentation markup, preserving content text.
///
/// Raw HTML stays literal; links keep their labels, images keep their alt
/// text, and fenced code keeps its source text.
String markdownToPlainText(String source) {
  final lines = source.split('\n');
  final out = <String>[];
  var fenced = false;
  for (final line in lines) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      fenced = !fenced;
      continue;
    }
    if (fenced) {
      out.add(line);
      continue;
    }
    out.add(_stripInline(_stripLinePrefix(line)));
  }
  return out.join('\n');
}

String _stripLinePrefix(String line) {
  var result = line.replaceFirst(_headingPrefix, '');
  result = result.replaceFirst(_quotePrefix, '');
  result = result.replaceFirst(_bulletPrefix, '');
  return result;
}

/// `#`–`######` heading markers.
final RegExp _headingPrefix = RegExp(r'^ {0,3}#{1,6}\s+');

/// Blockquote markers.
final RegExp _quotePrefix = RegExp(r'^ {0,3}>\s?');

/// Bullet and ordered list markers.
final RegExp _bulletPrefix = RegExp(r'^ {0,3}(?:[-*+]|\d{1,9}[.)])\s+');

String _stripInline(String text) {
  var result = text.replaceAllMapped(_imageSyntax, (m) => m.group(1) ?? '');
  result = result.replaceAllMapped(_linkSyntax, (m) => m.group(1) ?? '');
  result = result.replaceAllMapped(_strongSyntax, (m) => m.group(2) ?? '');
  result = result.replaceAllMapped(_emphasisSyntax, (m) => m.group(2) ?? '');
  result = result.replaceAllMapped(_codeSyntax, (m) => m.group(1) ?? '');
  result = result.replaceAllMapped(_escapeSyntax, (m) => m.group(1) ?? '');
  return result;
}

/// `![alt](url)` keeps the alt text.
final RegExp _imageSyntax = RegExp(r'!\[([^\]]*)\]\([^)]*\)');

/// `[label](url)` keeps the label.
final RegExp _linkSyntax = RegExp(r'\[([^\]]*)\]\([^)]*\)');

/// Paired `**bold**` / `__bold__` keeps the inner text.
final RegExp _strongSyntax = RegExp(r'(\*\*|__)(.*?)\1');

/// Paired `*em*` / `_em_` / `~~strike~~` keeps the inner text.
final RegExp _emphasisSyntax = RegExp(r'([*_~])([^*_~\n]*?)\1');

/// Paired backticks keep the code source text.
final RegExp _codeSyntax = RegExp(r'`([^`\n]*)`');

/// Backslash escapes keep the escaped punctuation.
final RegExp _escapeSyntax = RegExp(r'\\([\\`*_{}\[\]()#+\-.!~|>])');
