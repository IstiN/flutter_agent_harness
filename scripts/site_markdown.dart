// Minimal Markdown → HTML renderer for the fa1.dev static pre-render
// (gh-1476). Pure Dart, no package deps — same convention as
// scripts/build_blog.dart. Supports the constructs used by the blog posts
// and curated docs: ATX headings, paragraphs, **bold**/­*em*/`code`/
// ~~strike~~ inline, [links](…)/![images](…), <autolinks>, fenced code
// blocks with language, GFM pipe tables, ordered/unordered lists with
// indentation-based nesting, blockquotes, and horizontal rules.
//
// This is deliberately NOT a CommonMark implementation — it renders the
// repo's own content deterministically; anything unsupported degrades to
// a paragraph, never to broken HTML.

/// Parses a `---\n…\n---` YAML front-matter block. Values are raw strings
/// (one level deep: `key: value`); a missing block yields an empty map.
Map<String, String> parseFrontmatter(String text) {
  final out = <String, String>{};
  if (!text.startsWith('---\n')) return out;
  final end = text.indexOf('\n---', 4);
  if (end < 0) return out;
  for (final line in text.substring(4, end).split('\n')) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  return out;
}

/// Returns the body of [text] with the front-matter block removed.
String stripFrontmatter(String text) {
  if (!text.startsWith('---\n')) return text;
  final end = text.indexOf('\n---', 4);
  if (end < 0) return text;
  final body = text.substring(end + 4);
  return body.replaceFirst(RegExp(r'^\n'), '');
}

String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

final _inlinePattern = RegExp(
  r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)' // 1 alt, 2 src, 3 title
  r'|\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)' // 4 text, 5 href, 6 title
  r'|<((?:https?|mailto):[^>\s]+)>' // 7 autolink
  r'|`([^`]+)`' // 8 code
  r'|\*\*([^*]+)\*\*' // 9 bold
  r'|\*([^*\n]+)\*' // 10 em
  r'|~~([^~]+)~~', // 11 strike
);

/// Renders inline Markdown to HTML with escaping. [rewriteLink] and
/// [rewriteImg] may rewrite link targets / image sources (e.g. blog
/// assets, docs cross-links).
String renderInline(
  String text, {
  String Function(String href)? rewriteLink,
  String Function(String src)? rewriteImg,
}) {
  final out = StringBuffer();
  var pos = 0;
  for (final m in _inlinePattern.allMatches(text)) {
    out.write(escapeHtml(text.substring(pos, m.start)));
    String img(String alt, String src, String? title) {
      final resolved = rewriteImg?.call(src) ?? src;
      return '<img src="${escapeHtml(resolved)}" alt="${escapeHtml(alt)}"'
          '${title != null ? ' title="${escapeHtml(title)}"' : ''} loading="lazy">';
    }

    String a(String label, String href, String? title) {
      final resolved = rewriteLink?.call(href) ?? href;
      final ext = RegExp(r'^(?:https?:)?//').hasMatch(resolved)
          ? ' target="_blank" rel="noopener"'
          : '';
      return '<a href="${escapeHtml(resolved)}"$ext'
          '${title != null ? ' title="${escapeHtml(title)}"' : ''}>$label</a>';
    }

    if (m.group(1) != null) {
      out.write(img(m.group(1)!, m.group(2)!, m.group(3)));
    } else if (m.group(4) != null) {
      out.write(a(renderInline(m.group(4)!), m.group(5)!, m.group(6)));
    } else if (m.group(7) != null) {
      final url = m.group(7)!;
      out.write('<a href="${escapeHtml(url)}" target="_blank" rel="noopener">'
          '${escapeHtml(url)}</a>');
    } else if (m.group(8) != null) {
      out.write('<code>${escapeHtml(m.group(8)!)}</code>');
    } else if (m.group(9) != null) {
      out.write('<strong>${renderInline(m.group(9)!)}</strong>');
    } else if (m.group(10) != null) {
      out.write('<em>${renderInline(m.group(10)!)}</em>');
    } else if (m.group(11) != null) {
      out.write('<del>${renderInline(m.group(11)!)}</del>');
    }
    pos = m.end;
  }
  out.write(escapeHtml(text.substring(pos)));
  return out.toString();
}

class _ListItem {
  _ListItem(this.indent, this.ordered, this.text);
  final int indent;
  final bool ordered;
  final String text;
}

final _ulItem = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _olItem = RegExp(r'^(\s*)\d+[.)]\s+(.*)$');
final _fence = RegExp(r'^```(\S*)\s*$');
final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _hr = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
final _tableDelimiter = RegExp(r'^\|?[\s:]*-[-\s:|]*\|?\s*$');

/// Renders Markdown [md] to a static HTML fragment. See the library
/// doc-comment for the supported construct set.
String renderMarkdown(
  String md, {
  String Function(String href)? rewriteLink,
  String Function(String src)? rewriteImg,
}) {
  final lines = md.replaceAll('\r\n', '\n').split('\n');
  final out = StringBuffer();
  final para = StringBuffer();

  void flushPara() {
    if (para.isNotEmpty) {
      out.writeln(
        '<p>${renderInline(para.toString().trim(), rewriteLink: rewriteLink, rewriteImg: rewriteImg)}</p>',
      );
      para.clear();
    }
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final t = line.trim();
    if (t.isEmpty) {
      flushPara();
      i++;
      continue;
    }
    final fence = _fence.firstMatch(t);
    if (fence != null) {
      flushPara();
      final lang = fence.group(1)!;
      final buf = StringBuffer();
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        buf.writeln(lines[i]);
        i++;
      }
      i++; // closing fence
      out.writeln(
        '<pre><code${lang.isNotEmpty ? ' class="language-${escapeHtml(lang)}"' : ''}>'
        '${escapeHtml(buf.toString().trimRight())}</code></pre>',
      );
      continue;
    }
    final h = _heading.firstMatch(t);
    if (h != null) {
      flushPara();
      final level = h.group(1)!.length;
      out.writeln(
        '<h$level>${renderInline(h.group(2)!, rewriteLink: rewriteLink, rewriteImg: rewriteImg)}</h$level>',
      );
      i++;
      continue;
    }
    if (_hr.hasMatch(t)) {
      flushPara();
      out.writeln('<hr>');
      i++;
      continue;
    }
    if (_isTableStart(lines, i)) {
      flushPara();
      i = _renderTable(lines, i, out, rewriteLink, rewriteImg);
      continue;
    }
    if (_ulItem.hasMatch(line) || _olItem.hasMatch(line)) {
      flushPara();
      final items = <_ListItem>[];
      var j = i;
      while (j < lines.length) {
        final l = lines[j];
        final ul = _ulItem.firstMatch(l);
        final ol = _olItem.firstMatch(l);
        if (ul != null) {
          items.add(_ListItem(ul.group(1)!.length, false, ul.group(2)!));
          j++;
          continue;
        }
        if (ol != null) {
          items.add(_ListItem(ol.group(1)!.length, true, ol.group(2)!));
          j++;
          continue;
        }
        // Lazy continuation: a wrapped list-item line (indented or not)
        // extends the previous item instead of ending the list.
        if (items.isNotEmpty &&
            l.trim().isNotEmpty &&
            !_heading.hasMatch(l.trim()) &&
            !_fence.hasMatch(l.trim()) &&
            !_hr.hasMatch(l.trim()) &&
            !l.trim().startsWith('>') &&
            !_isTableStart(lines, j)) {
          final last = items.last;
          items[items.length - 1] = _ListItem(
            last.indent,
            last.ordered,
            '${last.text} ${l.trim()}',
          );
          j++;
          continue;
        }
        break;
      }
      _emitList(items, out, rewriteLink, rewriteImg);
      i = j;
      continue;
    }
    if (t.startsWith('>')) {
      flushPara();
      final buf = StringBuffer();
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        var q = lines[i].trim();
        q = q.startsWith('> ') ? q.substring(2) : q.substring(1);
        buf.writeln(q);
        i++;
      }
      out.writeln(
        '<blockquote>${renderMarkdown(buf.toString().trim(), rewriteLink: rewriteLink, rewriteImg: rewriteImg)}</blockquote>',
      );
      continue;
    }
    para
      ..write(' ')
      ..write(t);
    i++;
  }
  flushPara();
  return out.toString();
}

bool _isTableStart(List<String> lines, int i) {
  if (i + 1 >= lines.length) return false;
  if (!lines[i].contains('|')) return false;
  final d = lines[i + 1].trim();
  return _tableDelimiter.hasMatch(d) && d.contains('-');
}

List<String> _splitRow(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return t.split('|').map((c) => c.trim()).toList();
}

String? _cellAlign(String delimiterCell) {
  final left = delimiterCell.trimLeft().startsWith(':');
  final right = delimiterCell.trimRight().endsWith(':');
  if (left && right) return 'center';
  if (right) return 'right';
  if (left) return 'left';
  return null;
}

int _renderTable(
  List<String> lines,
  int i,
  StringBuffer out,
  String Function(String href)? rewriteLink,
  String Function(String src)? rewriteImg,
) {
  String cell(String tag, String content, String? align) => '<$tag'
      '${align != null ? ' style="text-align: $align"' : ''}>'
      '${renderInline(content, rewriteLink: rewriteLink, rewriteImg: rewriteImg)}</$tag>';

  final header = _splitRow(lines[i]);
  final delimiters = _splitRow(lines[i + 1]);
  final aligns = delimiters.map(_cellAlign).toList();
  String? alignFor(int col) => col < aligns.length ? aligns[col] : null;

  out.writeln('<table>');
  out.write('<thead><tr>');
  for (var c = 0; c < header.length; c++) {
    out.write(cell('th', header[c], alignFor(c)));
  }
  out.writeln('</tr></thead>');
  out.writeln('<tbody>');
  var j = i + 2;
  while (j < lines.length && lines[j].contains('|') && lines[j].trim().isNotEmpty) {
    final row = _splitRow(lines[j]);
    out.write('<tr>');
    for (var c = 0; c < row.length; c++) {
      out.write(cell('td', row[c], alignFor(c)));
    }
    out.writeln('</tr>');
    j++;
  }
  out.writeln('</tbody>');
  out.writeln('</table>');
  return j;
}

void _emitList(
  List<_ListItem> items,
  StringBuffer out,
  String Function(String href)? rewriteLink,
  String Function(String src)? rewriteImg,
) {
  var k = 0;
  while (k < items.length) {
    final ordered = items[k].ordered;
    final level = items[k].indent;
    out.write(ordered ? '<ol>' : '<ul>');
    while (k < items.length &&
        items[k].indent == level &&
        items[k].ordered == ordered) {
      out.write('<li>');
      out.write(renderInline(items[k].text,
          rewriteLink: rewriteLink, rewriteImg: rewriteImg));
      k++;
      final sub = <_ListItem>[];
      while (k < items.length && items[k].indent > level) {
        sub.add(items[k]);
        k++;
      }
      if (sub.isNotEmpty) _emitList(sub, out, rewriteLink, rewriteImg);
      out.write('</li>');
    }
    out.write(ordered ? '</ol>' : '</ul>');
  }
}

/// Strips Markdown formatting for use in meta descriptions / plain
/// fallbacks: links keep their text, images are dropped, markers removed.
String plainText(String md) {
  var s = md;
  s = s.replaceAllMapped(
    RegExp(r'!\[[^\]]*\]\([^)]+\)'),
    (_) => '',
  );
  s = s.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)'),
    (m) => '${m.group(1)!} (${m.group(2)!})',
  );
  s = s.replaceAll(RegExp(r'[`*_~#>]'), '');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
