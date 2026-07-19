/// Pragmatic HTML → Markdown converter for the `web_fetch` tool (the generic
/// fallback behind the site-handler interface, omp's Turndown role).
///
/// Hand-rolled on the forgiving [scanHtml] tokenizer — no parser dependency,
/// no ML. Headings, link anchors (`[text](url)`, relative URLs resolved
/// against the page), lists, code blocks, bold/italic, blockquotes, and
/// tables are preserved; navigation/boilerplate subtrees (`nav`, `footer`,
/// `script`, `style`, …) are dropped wholesale. Malformed markup degrades to
/// text rather than failing.
library;

import 'html_text.dart';

/// Converts an HTML document to structured Markdown. [baseUrl] resolves
/// relative link/image targets; when null they are emitted verbatim.
String htmlToMarkdown(String html, {Uri? baseUrl}) {
  final tokens = scanHtml(html).toList(growable: false);
  final converter = _Converter(baseUrl);
  return converter.convert(tokens);
}

/// Elements whose entire subtree is boilerplate/junk for content extraction.
const _droppedElements = {
  'head',
  'title',
  'script',
  'style',
  'noscript',
  'template',
  'svg',
  'iframe',
  'nav',
  'footer',
  'select',
  'object',
};

/// Accumulates Markdown output with blank-line management.
final class _MdWriter {
  final StringBuffer _buffer = StringBuffer();
  int _trailingNewlines = 0;

  void write(String s) {
    if (s.isEmpty) return;
    _buffer.write(s);
    var n = 0;
    for (var i = s.length - 1; i >= 0 && s[i] == '\n'; i--) {
      n++;
    }
    _trailingNewlines = n == s.length ? _trailingNewlines + n : n;
  }

  /// Ensures at least [n] trailing newlines (never produces leading blank
  /// lines at the start of the output).
  void ensureNewlines(int n) {
    if (_buffer.isEmpty) return;
    for (var i = _trailingNewlines; i < n; i++) {
      write('\n');
    }
  }

  String get text => _buffer.toString();
}

/// An open inline/block construct collecting content into a nested writer.
final class _Frame {
  _Frame(this.kind, [this.data]);

  /// `link`, `bold`, `italic`, `code`, `blockquote`, or `cell`.
  final String kind;

  /// Frame payload (link href).
  final String? data;

  final writer = _MdWriter();
}

final class _ListContext {
  _ListContext(this.ordered);
  final bool ordered;
  var nextIndex = 1;
}

final class _Converter {
  _Converter(this.baseUrl);

  final Uri? baseUrl;
  final _root = _MdWriter();
  final _frames = <_Frame>[];
  final _lists = <_ListContext>[];

  bool _preActive = false;
  final _preBuffer = StringBuffer();
  String? _preLanguage;

  bool _inTable = false;
  bool _rowHasHeader = false;
  var _rowCellCount = 0;

  _MdWriter get _current => _frames.isEmpty ? _root : _frames.last.writer;

  String convert(List<Object> tokens) {
    var i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token is HtmlText) {
        _writeText(token.text);
      } else if (token is HtmlTag) {
        if (!token.closing && _droppedElements.contains(token.name)) {
          i = _skipSubtree(tokens, i);
          continue;
        }
        _handleTag(token);
      }
      i++;
    }
    // Malformed documents can leave frames unclosed; flush their collected
    // text (markers lost) rather than dropping the content.
    while (_frames.isNotEmpty) {
      _root.write(_frames.removeAt(0).writer.text);
    }
    return _finalize(_root.text);
  }

  /// Advances past the subtree rooted at the dropped element at [openIndex].
  int _skipSubtree(List<Object> tokens, int openIndex) =>
      skipHtmlSubtree(tokens, openIndex);

  void _writeText(String raw) {
    if (_preActive) {
      _preBuffer.write(decodeHtmlEntities(raw));
      return;
    }
    final text = decodeHtmlEntities(raw).replaceAll(RegExp(r'\s+'), ' ');
    if (text == ' ') {
      // Whitespace-only node: an inline separator, useless at a block edge.
      _current.write(' ');
      return;
    }
    _current.write(text);
  }

  void _handleTag(HtmlTag tag) {
    if (_preActive && tag.name != 'pre' && tag.name != 'code') {
      return; // markup inside <pre> is decorative (syntax highlighting)
    }
    switch (tag.name) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.parse(tag.name.substring(1));
        if (tag.closing) {
          _current.ensureNewlines(2);
        } else {
          _current.ensureNewlines(2);
          _current.write('${'#' * level} ');
        }
      case 'p' ||
          'div' ||
          'section' ||
          'article' ||
          'main' ||
          'aside' ||
          'figure' ||
          'figcaption' ||
          'details' ||
          'summary' ||
          'dl' ||
          'dt' ||
          'dd' ||
          'header' ||
          'form':
        _current.ensureNewlines(2);
      case 'br':
        if (!tag.closing) _current.write('\n');
      case 'hr':
        if (!tag.closing) {
          _current.ensureNewlines(2);
          _current.write('---');
          _current.ensureNewlines(2);
        }
      case 'a':
        if (tag.closing) {
          _closeLink();
        } else {
          _frames.add(_Frame('link', tag.attributes['href']));
        }
      case 'img':
        if (!tag.closing) _writeImage(tag);
      case 'b' || 'strong':
        if (tag.closing) {
          _closeInline('bold', '**');
        } else {
          _frames.add(_Frame('bold'));
        }
      case 'i' || 'em':
        if (tag.closing) {
          _closeInline('italic', '*');
        } else {
          _frames.add(_Frame('italic'));
        }
      case 'code':
        if (_preActive) {
          if (!tag.closing) _captureCodeLanguage(tag);
        } else if (tag.closing) {
          _closeCode();
        } else {
          _frames.add(_Frame('code'));
        }
      case 'pre':
        if (tag.closing) {
          _closePre();
        } else if (!tag.selfClosing) {
          _preActive = true;
          _preLanguage = null;
        }
      case 'blockquote':
        if (tag.closing) {
          _closeBlockquote();
        } else {
          _frames.add(_Frame('blockquote'));
        }
      case 'ul' || 'ol':
        if (tag.closing) {
          if (_lists.isNotEmpty) _lists.removeLast();
          _current.ensureNewlines(2);
        } else {
          _current.ensureNewlines(_lists.isEmpty ? 2 : 1);
          _lists.add(_ListContext(tag.name == 'ol'));
        }
      case 'li':
        if (!tag.closing && _lists.isNotEmpty) {
          final list = _lists.last;
          _current.ensureNewlines(1);
          final indent = '  ' * (_lists.length - 1);
          final marker = list.ordered ? '${list.nextIndex++}.' : '-';
          _current.write('$indent$marker ');
        }
      case 'table':
        _inTable = !tag.closing;
        _current.ensureNewlines(2);
      case 'tr':
        if (!_inTable) break;
        if (tag.closing) {
          _current.write('\n');
          if (_rowHasHeader && _rowCellCount > 0) {
            _current.write('|${' --- |' * _rowCellCount}\n');
          }
          _rowHasHeader = false;
          _rowCellCount = 0;
        } else {
          _current.ensureNewlines(1);
          _current.write('|');
        }
      case 'td' || 'th':
        if (!_inTable) break;
        if (tag.closing) {
          _closeCell(tag.name == 'th');
        } else {
          _frames.add(_Frame('cell'));
        }
      default:
        break; // transparent: tag dropped, content kept
    }
  }

  void _closeLink() {
    final frame = _popFrame('link');
    if (frame == null) return;
    final text = _collapseInline(frame.writer.text);
    final href = frame.data?.trim() ?? '';
    if (text.isEmpty) return;
    final resolved = _resolveLink(href);
    if (resolved == null || resolved == text) {
      _current.write(text);
    } else {
      _current.write('[$text]($resolved)');
    }
  }

  /// Resolves [href] against the page URL. Returns null for links that carry
  /// no useful target for the model (anchors, javascript:, mailto:, …).
  String? _resolveLink(String href) {
    if (href.isEmpty || href.startsWith('#')) return null;
    final lower = href.toLowerCase();
    if (lower.startsWith('javascript:') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('tel:') ||
        lower.startsWith('data:')) {
      return null;
    }
    final base = baseUrl;
    if (base == null) return href;
    try {
      return base.resolve(href).toString();
    } on Object {
      return href;
    }
  }

  void _writeImage(HtmlTag tag) {
    final src = tag.attributes['src']?.trim() ?? '';
    if (src.isEmpty || src.startsWith('data:')) return;
    final alt = _collapseInline(
      decodeHtmlEntities(tag.attributes['alt'] ?? ''),
    );
    final resolved = _resolveLink(src) ?? src;
    _current.write('![$alt]($resolved)');
  }

  void _closeInline(String kind, String marker) {
    final frame = _popFrame(kind);
    if (frame == null) return;
    final text = _collapseInline(frame.writer.text);
    // An empty span still carried a whitespace separator (`a<b> </b>b`).
    if (text.isEmpty) {
      _current.write(' ');
      return;
    }
    _current.write('$marker$text$marker');
  }

  void _closeCode() {
    final frame = _popFrame('code');
    if (frame == null) return;
    final text = _collapseInline(frame.writer.text);
    if (text.isEmpty) {
      _current.write(' ');
      return;
    }
    final fence = text.contains('`') ? '``' : '`';
    _current.write('$fence$text$fence');
  }

  void _captureCodeLanguage(HtmlTag tag) {
    for (final token in tag.classTokens) {
      if (token.startsWith('language-') && token.length > 9) {
        _preLanguage = token.substring(9);
        return;
      }
    }
  }

  void _closePre() {
    _preActive = false;
    var code = _preBuffer.toString();
    _preBuffer.clear();
    // Trim one structural newline around the code, keep the rest verbatim.
    if (code.startsWith('\n')) code = code.substring(1);
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    _current.ensureNewlines(2);
    _current.write('```${_preLanguage ?? ''}\n');
    _current.write('$code\n');
    _current.write('```');
    _current.ensureNewlines(2);
  }

  void _closeBlockquote() {
    final frame = _popFrame('blockquote');
    if (frame == null) return;
    final text = frame.writer.text.trim();
    if (text.isEmpty) return;
    final quoted = text
        .split('\n')
        .map((line) => line.trim().isEmpty ? '>' : '> $line')
        .join('\n');
    _current.ensureNewlines(2);
    _current.write(quoted);
    _current.ensureNewlines(2);
  }

  void _closeCell(bool isHeader) {
    final frame = _popFrame('cell');
    if (frame == null) return;
    final text = _collapseInline(frame.writer.text).replaceAll('|', r'\|');
    _current.write(' $text |');
    _rowCellCount++;
    if (isHeader) _rowHasHeader = true;
  }

  /// Pops the innermost frame of [kind]. Unclosed frames left inside it are
  /// folded into its content first (malformed nesting degrades to text).
  _Frame? _popFrame(String kind) {
    final index = _frames.lastIndexWhere((f) => f.kind == kind);
    if (index == -1) return null;
    while (_frames.length - 1 > index) {
      final orphan = _frames.removeLast();
      _frames.last.writer.write(orphan.writer.text);
    }
    return _frames.removeLast();
  }

  String _collapseInline(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _finalize(String text) {
    return text
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
