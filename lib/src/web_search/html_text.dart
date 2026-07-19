/// Low-level HTML text helpers shared by the web search provider parsers and
/// the markdown converter: entity decoding, a forgiving tag scanner, and a
/// tag-stripping text normalizer.
///
/// These are deliberately lenient — real-world markup is malformed more often
/// than not, and search-result markup rots silently, so scanning never throws.
library;

/// Decodes the small set of HTML entities seen in search results and page
/// content (named, decimal, and hexadecimal forms).
String decodeHtmlEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(
    RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);'),
    (match) {
      final body = match.group(1)!;
      if (body.startsWith('#x') || body.startsWith('#X')) {
        final code = int.tryParse(body.substring(2), radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      if (body.startsWith('#')) {
        final code = int.tryParse(body.substring(1));
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      return _namedEntities[body.toLowerCase()] ?? match.group(0)!;
    },
  );
}

const _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'laquo': '«',
  'raquo': '»',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'deg': '°',
  'plusmn': '±',
  'times': '×',
  'divide': '÷',
  'middot': '·',
  'bull': '•',
  'dagger': '†',
  'permil': '‰',
  'prime': '′',
  'euro': '€',
  'pound': '£',
  'yen': '¥',
  'cent': '¢',
  'sect': '§',
  'para': '¶',
  'micro': 'µ',
  'szlig': 'ß',
};

/// Strips all tags, decodes entities, and collapses whitespace — the text
/// content of an HTML fragment (omp's `decodeHtmlText`).
String stripHtmlTags(String html) {
  final withoutTags = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
  return decodeHtmlEntities(withoutTags).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// One scanned HTML tag (open, close, or self-closing).
final class HtmlTag {
  const HtmlTag._(
    this.name,
    this.attributes,
    this.closing,
    this.selfClosing,
    this.openEnd,
  );

  /// Lowercased tag name (e.g. `div`).
  final String name;

  /// Attribute map with lowercased names (values keep their case).
  final Map<String, String> attributes;

  /// Whether this is a close tag (`</name>`).
  final bool closing;

  /// Whether this tag self-closes (`<br/>` or a void element like `<img>`).
  final bool selfClosing;

  /// Offset in the source just past this tag's `>`.
  final int openEnd;

  /// The class attribute split into tokens (empty when absent).
  List<String> get classTokens =>
      attributes['class']
          ?.split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList() ??
      const [];

  /// Whether the class attribute contains exactly [token].
  bool hasClass(String token) => classTokens.contains(token);
}

/// A plain-text chunk between tags.
final class HtmlText {
  const HtmlText(this.text, this.offset);

  /// Raw (still entity-encoded) text.
  final String text;

  /// Offset in the source where the chunk starts.
  final int offset;
}

/// Tags that have no content model and never need a close tag.
const voidHtmlTags = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// HTML tag names the scanner recognizes. Unknown names without a dash are
/// treated as literal text so code generics (`List<String>`) inside `<pre>`
/// survive conversion; custom elements (which always carry a dash) still
/// parse as tags. SVG names are included so subtree skipping matches
/// open/close tags correctly.
const knownHtmlTags = {
  'a', 'abbr', 'address', 'area', 'article', 'aside', 'audio', //
  'b', 'base', 'bdi', 'bdo', 'blockquote', 'body', 'br', 'button', //
  'canvas', 'caption', 'cite', 'code', 'col', 'colgroup', //
  'data',
  'datalist',
  'dd',
  'del',
  'details',
  'dfn',
  'dialog',
  'div',
  'dl',
  'dt', //
  'em', 'embed', //
  'fieldset', 'figcaption', 'figure', 'footer', 'form', //
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'head',
  'header',
  'hgroup',
  'hr',
  'html', //
  'i', 'iframe', 'img', 'input', 'ins', //
  'kbd', 'label', 'legend', 'li', 'link', //
  'main', 'map', 'mark', 'menu', 'meta', 'meter', //
  'nav', 'noscript', 'object', 'ol', 'optgroup', 'option', 'output', //
  'p', 'picture', 'pre', 'progress', //
  'q', 'rp', 'rt', 'ruby', //
  's', 'samp', 'script', 'search', 'section', 'select', 'slot', 'small',
  'source', 'span', 'strong', 'style', 'sub', 'summary', 'sup', //
  'table', 'tbody', 'td', 'template', 'textarea', 'tfoot', 'th', 'thead',
  'time', 'title', 'tr', 'track', //
  'u', 'ul', 'var', 'video', 'wbr', //
  'svg', 'g', 'path', 'circle', 'rect', 'line', 'polyline', 'polygon',
  'ellipse', 'defs', 'use', 'symbol', 'text', 'tspan', 'clippath', 'mask',
  'pattern', 'lineargradient', 'radialgradient', 'stop', 'image',
  'foreignobject', 'desc', 'animate',
};

/// Whether [tagName] parses as a markup tag (vs. literal text).
bool isKnownHtmlTag(String tagName) =>
    knownHtmlTags.contains(tagName) || tagName.contains('-');

/// Scans [html] sequentially, yielding [HtmlTag] and [HtmlText] tokens in
/// document order. Comments, doctypes, and processing instructions are
/// skipped. Malformed input degrades to text instead of throwing.
Iterable<Object> scanHtml(String html) sync* {
  var i = 0;
  final length = html.length;
  while (i < length) {
    final lt = html.indexOf('<', i);
    if (lt == -1) {
      yield HtmlText(html.substring(i), i);
      return;
    }
    if (lt > i) yield HtmlText(html.substring(i, lt), i);
    // Not a tag start (a literal '<' in text): emit it as text and move on.
    if (lt + 1 >= length || !_isTagStart(html.codeUnitAt(lt + 1))) {
      yield HtmlText('<', lt);
      i = lt + 1;
      continue;
    }
    if (html.startsWith('<!--', lt)) {
      final end = html.indexOf('-->', lt + 4);
      i = end == -1 ? length : end + 3;
      continue;
    }
    if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
      final end = html.indexOf('>', lt + 2);
      i = end == -1 ? length : end + 1;
      continue;
    }
    final gt = _findTagEnd(html, lt + 1);
    if (gt == -1) {
      // Unterminated tag at EOF: treat the rest as text.
      yield HtmlText(html.substring(lt), lt);
      return;
    }
    final tag = _parseTag(html.substring(lt + 1, gt), gt + 1);
    if (tag != null) {
      // Unknown names without a dash (`<String>` in code) are literal text.
      yield isKnownHtmlTag(tag.name)
          ? tag
          : HtmlText(html.substring(lt, gt + 1), lt);
    }
    i = gt + 1;
  }
}

bool _isTagStart(int codeUnit) {
  const letters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ/!';
  return letters.contains(String.fromCharCode(codeUnit));
}

/// Finds the index of the `>` closing the tag opened at [from], honoring
/// quoted attribute values that may themselves contain `>`.
int _findTagEnd(String html, int from) {
  String? quote;
  for (var i = from; i < html.length; i++) {
    final ch = html[i];
    if (quote != null) {
      if (ch == quote) quote = null;
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == '>') {
      return i;
    }
  }
  return -1;
}

final _tagNamePattern = RegExp(r'^/?\s*([a-zA-Z][a-zA-Z0-9]*)');
final _attributePattern = RegExp(
  r'''([a-zA-Z_:][a-zA-Z0-9_:.\-]*)\s*(?:=\s*("([^"]*)"|'([^']*)'|[^\s>]+))?''',
);

/// Parses the inside of `<...>` into an [HtmlTag]. Returns null when the
/// content does not start with a tag name (e.g. `</ >` garbage).
HtmlTag? _parseTag(String content, int openEnd) {
  final nameMatch = _tagNamePattern.firstMatch(content);
  if (nameMatch == null) return null;
  final closing = content.startsWith('/');
  final name = nameMatch.group(1)!.toLowerCase();
  final rest = content.substring(nameMatch.end);
  final selfClosing =
      rest.trimRight().endsWith('/') || voidHtmlTags.contains(name);
  final attributes = <String, String>{};
  for (final match in _attributePattern.allMatches(rest)) {
    final attrName = match.group(1)!.toLowerCase();
    if (attrName == '/') continue;
    final value = match.group(3) ?? match.group(4) ?? match.group(2) ?? '';
    attributes[attrName] = value;
  }
  return HtmlTag._(name, attributes, closing, selfClosing, openEnd);
}

/// Extracts and decodes the `<title>` of an HTML document, or null when
/// absent or empty.
String? extractHtmlTitle(String html) {
  final match = RegExp(
    r'<title\b[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  if (match == null) return null;
  final title = stripHtmlTags(match.group(1)!);
  return title.isEmpty ? null : title;
}

/// Returns the index of the token closing the subtree rooted at the open tag
/// [openIndex] within [tokens] (depth-counted on the same tag name). Returns
/// [openIndex] itself for self-closing tags, or the last token index when the
/// close tag is missing (malformed input).
int skipHtmlSubtree(List<Object> tokens, int openIndex) {
  final open = tokens[openIndex] as HtmlTag;
  if (open.selfClosing) return openIndex;
  var depth = 1;
  var i = openIndex + 1;
  while (i < tokens.length && depth > 0) {
    final token = tokens[i];
    if (token is HtmlTag && token.name == open.name) {
      if (token.closing) {
        depth--;
      } else if (!token.selfClosing) {
        depth++;
      }
    }
    i++;
  }
  return i - 1;
}
