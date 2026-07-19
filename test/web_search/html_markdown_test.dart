/// Tests for the HTML → Markdown converter: structure preservation
/// (headings, link anchors, lists, code blocks), junk stripping, entity
/// decoding, and resilience to malformed markup.
library;

import 'package:flutter_agent_harness/src/web_search/html_markdown.dart';
import 'package:flutter_agent_harness/src/web_search/html_text.dart';
import 'package:test/test.dart';

void main() {
  group('htmlToMarkdown', () {
    test('converts headings and paragraphs', () {
      final md = htmlToMarkdown(
        '<h1>Title</h1><p>First.</p><h2>Section</h2><p>Second.</p>',
      );
      expect(md, '# Title\n\nFirst.\n\n## Section\n\nSecond.');
    });

    test('preserves link anchors and resolves relative hrefs', () {
      final md = htmlToMarkdown(
        '<p>See <a href="/docs">the docs</a> and '
        '<a href="https://other.dev/x">external</a>.</p>',
        baseUrl: Uri.parse('https://example.com/guide/page'),
      );
      expect(
        md,
        'See [the docs](https://example.com/docs) and '
        '[external](https://other.dev/x).',
      );
    });

    test('drops anchor/javascript/mailto links, keeping the text', () {
      final md = htmlToMarkdown(
        '<p><a href="#frag">jump</a> <a href="javascript:void(0)">js</a> '
        '<a href="mailto:a@b.dev">mail</a></p>',
      );
      expect(md, 'jump js mail');
    });

    test('emits the bare URL when link text equals the href', () {
      final md = htmlToMarkdown(
        '<p><a href="https://example.com">https://example.com</a></p>',
      );
      expect(md, 'https://example.com');
    });

    test('converts unordered and ordered lists, nested included', () {
      final md = htmlToMarkdown(
        '<ul><li>a</li><li>b<ul><li>b1</li><li>b2</li></ul></li></ul>'
        '<ol><li>one</li><li>two</li></ol>',
      );
      expect(md, '- a\n- b\n  - b1\n  - b2\n\n1. one\n2. two');
    });

    test('converts pre blocks with the language hint', () {
      final md = htmlToMarkdown(
        '<pre><code class="language-dart">void main() {\n  print(1);\n}</code></pre>',
      );
      expect(md, '```dart\nvoid main() {\n  print(1);\n}\n```');
    });

    test('keeps code generics inside pre (unknown tags are text)', () {
      final md = htmlToMarkdown(
        '<pre><code>List&lt;String&gt; a = &lt;String&gt;[];\n'
        'List<String> b = &lt;String&gt;[];</code></pre>',
      );
      expect(md, contains('List<String> a = <String>[];'));
      expect(md, contains('List<String> b = <String>[];'));
    });

    test('converts inline code, bold, and italic', () {
      final md = htmlToMarkdown(
        '<p>Call <code>fetch()</code> with <strong>care</strong>, '
        '<em>really</em>.</p>',
      );
      expect(md, 'Call `fetch()` with **care**, *really*.');
    });

    test('uses double backticks when inline code contains a backtick', () {
      final md = htmlToMarkdown('<p>Use <code>a`b</code> here.</p>');
      expect(md, 'Use ``a`b`` here.');
    });

    test('strips empty emphasis spans', () {
      final md = htmlToMarkdown('<p>a<b> </b>b</p>');
      expect(md, 'a b');
    });

    test('converts blockquotes', () {
      final md = htmlToMarkdown(
        '<blockquote><p>Quoted line one.</p><p>Line two.</p></blockquote>',
      );
      expect(md, '> Quoted line one.\n>\n> Line two.');
    });

    test('strips script, style, nav, footer, head, and comments', () {
      final md = htmlToMarkdown(
        '<html><head><title>T</title><style>body{}</style></head>'
        '<body><nav>menu links</nav><p>Real content.</p>'
        '<script>alert(1)</script><!-- a comment -->'
        '<footer>legal</footer></body></html>',
      );
      expect(md, 'Real content.');
    });

    test('decodes entities in text', () {
      final md = htmlToMarkdown(
        '<p>Fish &amp; Chips &lt;tag&gt; &quot;quoted&quot; &#8212; dash</p>',
      );
      expect(md, 'Fish & Chips <tag> "quoted" — dash');
    });

    test('converts images with alt text', () {
      final md = htmlToMarkdown(
        '<p><img src="/img/logo.png" alt="Logo"></p>',
        baseUrl: Uri.parse('https://example.com/a/b'),
      );
      expect(md, '![Logo](https://example.com/img/logo.png)');
    });

    test('converts tables with a header separator', () {
      final md = htmlToMarkdown(
        '<table><tr><th>Name</th><th>Value</th></tr>'
        '<tr><td>a</td><td>1</td></tr></table>',
      );
      expect(md, '| Name | Value |\n| --- | --- |\n| a | 1 |');
    });

    test('converts hr and collapses blank-line runs', () {
      final md = htmlToMarkdown('<p>a</p><hr><p>b</p><br><p>c</p>');
      expect(md, 'a\n\n---\n\nb\n\nc');
    });

    test('handles malformed markup without throwing', () {
      final md = htmlToMarkdown('<p>unclosed <b>bold <div>block</p> after');
      expect(md, contains('unclosed'));
      expect(md, contains('block'));
    });

    test('treats a bare less-than in text as text', () {
      final md = htmlToMarkdown('<p>1 < 2 and a < b</p>');
      expect(md, contains('1 < 2'));
    });

    test('returns empty for an empty document', () {
      expect(htmlToMarkdown(''), '');
      expect(htmlToMarkdown('<script>only()</script>'), '');
    });
  });

  group('extractHtmlTitle', () {
    test('extracts and decodes the title', () {
      expect(
        extractHtmlTitle('<html><head><title>A &amp; B</title></head></html>'),
        'A & B',
      );
    });

    test('returns null without a title', () {
      expect(extractHtmlTitle('<p>none</p>'), isNull);
    });
  });
}
