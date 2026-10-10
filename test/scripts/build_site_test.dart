// Unit tests for the fa1.dev GEO build (gh-1476): the minimal Markdown
// renderer (scripts/site_markdown.dart) and the site builder
// (scripts/build_site.dart) — renderer constructs, page templates,
// sitemap/llms-full assembly, and the emit modes (in-tree local preview
// and `--out <dir>` for deploy/CI — generated artifacts are deploy-time
// products, never committed: gh-1476 owner directive, PR #1479).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/build_site.dart' as site;
import '../../scripts/site_markdown.dart' as md;

void main() {
  group('frontmatter', () {
    test('parses key: value pairs', () {
      final fm = md.parseFrontmatter(
        '---\ntitle: Hello\ndate: 2026-01-02\n---\nbody',
      );
      expect(fm['title'], 'Hello');
      expect(fm['date'], '2026-01-02');
    });

    test('missing frontmatter yields empty map and unchanged body', () {
      expect(md.parseFrontmatter('no frontmatter'), isEmpty);
      expect(md.stripFrontmatter('no frontmatter'), 'no frontmatter');
    });

    test('stripFrontmatter removes only the front-matter block', () {
      expect(md.stripFrontmatter('---\ntitle: X\n---\n\n# Hello'), '# Hello');
    });
  });

  group('renderMarkdown', () {
    test('renders ATX headings', () {
      expect(
        md.renderMarkdown('# One\n\n## Two'),
        '<h1>One</h1>\n<h2>Two</h2>\n',
      );
    });

    test('escapes raw HTML in paragraphs', () {
      expect(
        md.renderMarkdown('a <script>alert(1)</script> b'),
        '<p>a &lt;script&gt;alert(1)&lt;/script&gt; b</p>\n',
      );
    });

    test('renders inline bold, em, code, and strike', () {
      expect(
        md.renderMarkdown('**b** *e* `c` ~~s~~'),
        '<p><strong>b</strong> <em>e</em> <code>c</code> <del>s</del></p>\n',
      );
    });

    test('renders links with rel and images with alt', () {
      expect(
        md.renderMarkdown('[t](https://x.example) ![a](img.png)'),
        '<p><a href="https://x.example" target="_blank" rel="noopener">t</a> '
        '<img src="img.png" alt="a" loading="lazy"></p>\n',
      );
    });

    test('renders autolinks', () {
      expect(
        md.renderMarkdown('<https://fa1.dev>'),
        '<p><a href="https://fa1.dev" target="_blank" rel="noopener">https://fa1.dev</a></p>\n',
      );
    });

    test('renders fenced code with language and escaping', () {
      expect(
        md.renderMarkdown('```dart\nvar a = "<x>";\n```'),
        '<pre><code class="language-dart">var a = &quot;&lt;x&gt;&quot;;</code></pre>\n',
      );
    });

    test('renders GFM pipe tables with alignment', () {
      final html = md.renderMarkdown(
        '| A | B | C |\n|:---|---:|:---:|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n',
      );
      expect(html, contains('<table>'));
      expect(html, contains('<th style="text-align: left">A</th>'));
      expect(html, contains('<th style="text-align: right">B</th>'));
      expect(html, contains('<th style="text-align: center">C</th>'));
      expect(html, contains('<td style="text-align: left">1</td>'));
      expect(html, contains('<td style="text-align: center">6</td>'));
    });

    test('renders unordered lists with 2+ items', () {
      expect(md.renderMarkdown('- a\n- b'), '<ul><li>a</li><li>b</li></ul>\n');
    });

    test('renders ordered lists and nested lists by indent', () {
      expect(
        md.renderMarkdown('1. a\n2. b'),
        '<ol><li>a</li><li>b</li></ol>\n',
      );
      expect(
        md.renderMarkdown('- a\n  - a1\n  - a2\n- b'),
        '<ul><li>a<ul><li>a1</li><li>a2</li></ul></li><li>b</li></ul>\n',
      );
    });

    test('lazy continuation lines merge into the list item', () {
      expect(
        md.renderMarkdown(
          '- item text that\n  wraps onto a second line\n- next',
        ),
        '<ul><li>item text that wraps onto a second line</li><li>next</li></ul>\n',
      );
    });

    test('renders blockquotes and horizontal rules', () {
      expect(
        md.renderMarkdown('> quoted\n\ntext\n\n---'),
        '<blockquote><p>quoted</p>\n</blockquote>\n<p>text</p>\n<hr>\n',
      );
    });
  });

  group('plainText', () {
    test('strips markdown formatting', () {
      expect(
        md.plainText(
          '**Tool availability** (issue #19) decides [`x`](https://a)',
        ),
        'Tool availability (issue #19) decides x (https://a)',
      );
    });
  });

  group('blog post page', () {
    site.BlogPost post({
      String slug = '2026-01-02-hello',
      String body = 'Hello world.',
      Map<String, String>? meta,
    }) => site.BlogPost(
      slug: slug,
      meta: {
        'title': 'Hello & <welcome>',
        'date': '2026-01-02',
        'description': 'A "quoted" description.',
        'author': 'Uladimir Klyshevich',
        'cover': 'assets/cover.png',
        ...?meta,
      },
      body: body,
    );

    test('carries the raw content without JS and exactly one h1', () {
      final html = site.renderBlogPostPage(
        post(
          body:
              '![Hello & <welcome>](assets/cover.png)\n\n# Hello & <welcome>\n\nDistinctive core text.',
        ),
      );
      expect(html, contains('Distinctive core text'));
      expect(html, isNot(contains('fetch(')));
      expect(html, isNot(contains('Loading')));
      expect(RegExp('<h1>').allMatches(html), hasLength(1));
      // The leading cover image is lifted to .post-cover (post.html parity).
      expect(html, contains('class="post-cover"'));
      expect(html, isNot(contains('<p><img')));
    });

    test('emits BlogPosting JSON-LD with real dates', () {
      final html = site.renderBlogPostPage(post());
      final json = _extractJsonLd(html);
      expect(json['@type'], 'BlogPosting');
      expect(json['headline'], 'Hello & <welcome>');
      expect(json['datePublished'], '2026-01-02');
      expect(json['dateModified'], '2026-01-02');
      expect(json['url'], '${site.siteOrigin}/blog/2026-01-02-hello/');
      expect(json['author'], containsPair('@type', 'Organization'));
      expect(
        html,
        contains(
          '<link rel="canonical" href="${site.siteOrigin}/blog/2026-01-02-hello/">',
        ),
      );
      expect(
        html,
        contains(
          'og:image" content="${site.siteOrigin}/blog/posts/assets/cover.png',
        ),
      );
    });

    test('escapes title and description in head meta', () {
      final html = site.renderBlogPostPage(post());
      expect(html, contains('Hello &amp; &lt;welcome&gt; — &gt;_Fa blog'));
      expect(html, contains('content="A &quot;quoted&quot; description."'));
    });

    test('lastmod prefers updated over date over filename prefix', () {
      expect(post().lastmod, '2026-01-02');
      expect(post(meta: {'updated': '2026-03-04'}).lastmod, '2026-03-04');
      expect(
        post(slug: '2025-12-31-x', meta: {'date': '', 'updated': ''}).lastmod,
        '2025-12-31',
      );
    });

    test('dateless post fails the build instead of fabricating a lastmod', () {
      final dateless = site.BlogPost(
        slug: 'untitled-post',
        meta: {'title': 'No date'},
        body: 'b',
      );
      expect(() => dateless.lastmod, throwsA(isA<StateError>()));
    });

    test('escapes the cover path in every HTML attribute', () {
      final p = post(meta: {'cover': 'assets/evil"-cover.png'});
      final html = site.renderBlogPostPage(p);
      expect(html, contains('posts/assets/evil&quot;-cover.png'));
      expect(html, isNot(contains('posts/assets/evil"-cover.png')));
      final block = site.blogIndexBlock([p]);
      expect(block, contains('src="posts/assets/evil&quot;-cover.png"'));
    });
  });

  group('docs page', () {
    test('renders TechArticle JSON-LD and canonical URL', () {
      final d = site.DocsPage(
        source: site.docsRegistry.first,
        title: 'Tool availability',
        body:
            'Body text with [a relative link](redaction.md) and [an outside one](backend-agent-mode.md).',
        description: 'desc',
        raw: '# Tool availability\n\nraw',
      );
      final html = site.renderDocsPage(d);
      final json = _extractJsonLd(html);
      expect(json['@type'], 'TechArticle');
      expect(json['headline'], 'Tool availability');
      expect(json['dateModified'], site.docsRegistry.first.updated);
      expect(
        html,
        contains(
          '<link rel="canonical" href="${site.siteOrigin}/docs/tool-availability/">',
        ),
      );
      // Curated .md target → /docs/ page; uncurated → GitHub source.
      expect(html, contains('href="/docs/redaction/"'));
      expect(
        html,
        contains('${site.repoUrl}/blob/main/docs/backend-agent-mode.md'),
      );
    });

    test('renders exactly one visible h1 with the doc title', () {
      final d = site.DocsPage(
        source: site.docsRegistry.first,
        title: 'Tool availability',
        body: 'Body text.',
        description: 'desc',
        raw: '# Tool availability\n\nraw',
      );
      final html = site.renderDocsPage(d);
      expect(RegExp('<h1>').allMatches(html), hasLength(1));
      expect(html, contains('<h1>Tool availability</h1>'));
      // The headline opens the article, ahead of the post-meta line.
      expect(
        html,
        contains(
          '<h1>Tool availability</h1>\n    <div class="post-meta">Updated',
        ),
      );
    });

    test('rewrites parent-relative .md links without leaking .. segments', () {
      final rewrite = site.docsLinkRewriter();
      expect(rewrite('../foo.md'), '${site.repoUrl}/blob/main/foo.md');
      expect(rewrite('../../x.md'), '${site.repoUrl}/blob/main/x.md');
      expect(
        rewrite('./sub/bar.md'),
        '${site.repoUrl}/blob/main/docs/sub/bar.md',
      );
      expect(rewrite('redaction.md'), '/docs/redaction/');
      expect(rewrite('https://example.com/x.md'), 'https://example.com/x.md');
      expect(rewrite('#anchor'), '#anchor');
    });
  });

  group('sitemap', () {
    test('lists statics, posts, and docs with sane priorities', () {
      final posts = [
        site.BlogPost(
          slug: '2027-01-02-b',
          meta: {'title': 'B', 'date': '2027-01-02'},
          body: 'b',
        ),
        site.BlogPost(
          slug: '2025-12-31-a',
          meta: {'title': 'A', 'date': '2025-12-31'},
          body: 'a',
        ),
      ];
      final docs = [
        site.DocsPage(
          source: site.docsRegistry.first,
          title: 'T',
          body: 'x',
          description: 'd',
          raw: 'r',
        ),
      ];
      final xml = site.buildSitemapXml(site.collectPages(posts, docs));
      expect(xml, contains('<loc>${site.siteOrigin}/</loc>'));
      expect(xml, contains('<priority>1.0</priority>'));
      // Newest post lifts /blog/ lastmod above its floor.
      expect(
        xml,
        contains(
          '<loc>${site.siteOrigin}/blog/</loc>\n    <lastmod>2027-01-02</lastmod>',
        ),
      );
      expect(
        xml,
        contains(
          '<loc>${site.siteOrigin}/blog/2027-01-02-b/</loc>\n    <lastmod>2027-01-02</lastmod>\n    <changefreq>monthly</changefreq>\n    <priority>0.8</priority>',
        ),
      );
      expect(
        xml,
        contains('<loc>${site.siteOrigin}/docs/tool-availability/</loc>'),
      );
      expect(xml, contains('<loc>${site.siteOrigin}/widgets/</loc>'));
    });
  });

  group('llms-full', () {
    test('sections are headed by canonical URLs and the budget holds', () {
      final posts = [
        site.BlogPost(
          slug: '2026-01-02-b',
          meta: {'title': 'B', 'date': '2026-01-02'},
          body: 'Full **post** body.',
        ),
      ];
      final docs = [
        site.DocsPage(
          source: site.docsRegistry.first,
          title: 'T',
          body: 'x',
          description: 'd',
          raw: '# T\n\nFull doc body.',
        ),
      ];
      final text = site.buildLlmsFull(
        llmsTxt: '# Fa\n\nFact sheet.',
        posts: posts,
        docs: docs,
      );
      expect(text, contains('# ${site.siteOrigin}/llms.txt'));
      expect(text, contains('Fact sheet.'));
      expect(text, contains('# ${site.siteOrigin}/blog/2026-01-02-b/'));
      expect(text, contains('Full **post** body.'));
      expect(text, contains('# ${site.siteOrigin}/docs/tool-availability/'));
      expect(text, contains('Full doc body.'));
      expect(text.length, lessThan(site.llmsFullBudgetBytes));
    });

    test('budget guard measures UTF-8 bytes, not UTF-16 code units', () {
      final posts = [
        site.BlogPost(
          slug: '2026-01-02-b',
          meta: {'title': 'B', 'date': '2026-01-02'},
          body: 'x',
        ),
      ];
      final docs = [
        site.DocsPage(
          source: site.docsRegistry.first,
          title: 'T',
          body: 'x',
          description: 'd',
          raw: 'r',
        ),
      ];
      // 80k em-dashes: 80,000 UTF-16 code units (under budget) but
      // 160,000 UTF-8 bytes (over the 153,600-byte budget) — the guard
      // must reject on real bytes.
      expect(
        () => site.buildLlmsFull(
          llmsTxt: '${'—' * 80000}\n',
          posts: posts,
          docs: docs,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('blog index block', () {
    test('renders a card per post with 2+ posts, escaping titles', () {
      site.BlogPost p(String slug, String title) => site.BlogPost(
        slug: slug,
        meta: {'title': title, 'date': '2026-01-02', 'description': 'd<\$>'},
        body: 'x',
      );
      final block = site.blogIndexBlock([p('a', 'A & B'), p('b', 'Second')]);
      expect(RegExp('class="post-card"').allMatches(block), hasLength(2));
      expect(block, contains('<h2>A &amp; B</h2>'));
      expect(block, contains('href="./a/"'));
      expect(block, contains('<p>d&lt;\$&gt;</p>'));
    });
  });

  group('buildSite (temp root)', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('build_site_test');
      final posts = Directory('${root.path}/site/blog/posts')
        ..createSync(recursive: true);
      File('${posts.path}/2026-01-02-one.md').writeAsStringSync(
        '---\ntitle: One\ndate: 2026-01-02\ndescription: d1\n---\n\n# One\n\nBody one.',
      );
      File('${posts.path}/2025-12-31-two.md').writeAsStringSync(
        '---\ntitle: Two\ndate: 2025-12-31\ndescription: d2\n---\n\n# Two\n\nBody two.',
      );
      File('${root.path}/site/blog/index.html').writeAsStringSync(
        '<html>\n<!-- #blog-post-list:start -->\nold\n<!-- #blog-post-list:end -->\n</html>\n',
      );
      File('${root.path}/site/llms.txt').writeAsStringSync('# Fa\n');
      for (final d in site.docsRegistry) {
        final f = File('${root.path}/${d.source}')..createSync(recursive: true);
        f.writeAsStringSync('# ${d.slug}\n\nDoc body for ${d.slug}.\n');
      }
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('generates post pages, docs pages, sitemap, and llms-full', () {
      final outputs = site.buildSite(root: root.path);
      final byPath = {for (final o in outputs) o.path: o.content};
      expect(byPath.keys, contains('site/blog/2026-01-02-one/index.html'));
      expect(byPath.keys, contains('site/blog/2025-12-31-two/index.html'));
      expect(
        byPath.keys.where((k) => k.startsWith('site/docs/')),
        hasLength(site.docsRegistry.length),
      );
      expect(
        byPath['site/blog/2026-01-02-one/index.html'],
        contains('Body one.'),
      );
      expect(byPath['site/blog/index.html'], isNot(contains('old')));
      expect(
        byPath['site/blog/index.html'],
        contains('href="./2026-01-02-one/"'),
      );
      expect(byPath['site/sitemap.xml'], contains('2026-01-02-one'));
      expect(
        byPath['site/llms-full.txt'],
        contains('# ${site.siteOrigin}/docs/dap/'),
      );
    });

    test('regeneration is deterministic (idempotent)', () {
      final first = site.buildSite(root: root.path);
      final second = site.buildSite(root: root.path);
      expect(
        [for (final o in second) '${o.path}${o.content}'],
        [for (final o in first) '${o.path}${o.content}'],
      );
    });
  });

  group('emitSite (--out)', () {
    // gh-1476 owner directive (PR #1479): generated artifacts are
    // deploy-time products, never committed. `--out <dir>` must produce a
    // complete servable tree (statics copied + artifacts written) without
    // touching the source tree, and prune stale generated pages.
    late Directory root;
    late Directory out;

    setUp(() {
      root = Directory.systemTemp.createTempSync('build_site_emit_test');
      final posts = Directory('${root.path}/site/blog/posts')
        ..createSync(recursive: true);
      File('${posts.path}/2026-01-02-one.md').writeAsStringSync(
        '---\ntitle: One\ndate: 2026-01-02\ndescription: d1\n---\n\n# One\n\nBody one.',
      );
      File('${root.path}/site/blog/index.html').writeAsStringSync(
        '<html>\n<!-- #blog-post-list:start -->\nold\n<!-- #blog-post-list:end -->\n</html>\n',
      );
      File('${root.path}/site/styles.css').writeAsStringSync('body{}\n');
      File('${root.path}/site/robots.txt').writeAsStringSync(
        'User-agent: *\n',
      );
      File('${root.path}/site/llms.txt').writeAsStringSync('# Fa\n');
      for (final d in site.docsRegistry) {
        final f = File('${root.path}/${d.source}')..createSync(recursive: true);
        f.writeAsStringSync('# ${d.slug}\n\nDoc body for ${d.slug}.\n');
      }
      // A stale generated page from a since-removed post, sitting in the
      // source tree (e.g. a local in-tree build) — it must not be copied
      // into the out dir.
      final stale = Directory('${root.path}/site/blog/2024-01-01-old')
        ..createSync(recursive: true);
      File('${stale.path}/index.html').writeAsStringSync('stale');
      out = Directory('${root.path}-out');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    test('writes a complete servable tree without touching the sources', () {
      final outputs = site.buildSite(root: root.path);
      site.emitSite(root: root.path, outDir: out.path, outputs: outputs);

      // Statics copied.
      expect(
        File('${out.path}/site/styles.css').readAsStringSync(),
        'body{}\n',
      );
      expect(File('${out.path}/site/robots.txt').existsSync(), isTrue);
      expect(File('${out.path}/site/llms.txt').existsSync(), isTrue);
      // Generated artifacts written.
      expect(
        File('${out.path}/site/blog/2026-01-02-one/index.html').existsSync(),
        isTrue,
      );
      expect(File('${out.path}/site/docs/dap/index.html').existsSync(), isTrue);
      expect(File('${out.path}/site/sitemap.xml').existsSync(), isTrue);
      expect(File('${out.path}/site/llms-full.txt').existsSync(), isTrue);
      // The rendered blog index replaces the template's marker block.
      final index = File('${out.path}/site/blog/index.html').readAsStringSync();
      expect(index, isNot(contains('old')));
      expect(index, contains('href="./2026-01-02-one/"'));
      // The stale source-tree page did not ride along.
      expect(
        Directory('${out.path}/site/blog/2024-01-01-old').existsSync(),
        isFalse,
      );
      // The source tree got no generated artifacts.
      expect(File('${root.path}/site/sitemap.xml').existsSync(), isFalse);
      expect(File('${root.path}/site/llms-full.txt').existsSync(), isFalse);
    });

    test('prunes stale generated pages already in the out dir', () {
      final staleOut = Directory('${out.path}/site/blog/2024-01-01-old')
        ..createSync(recursive: true);
      File('${staleOut.path}/index.html').writeAsStringSync('stale');
      final outputs = site.buildSite(root: root.path);
      site.emitSite(root: root.path, outDir: out.path, outputs: outputs);
      expect(staleOut.existsSync(), isFalse);
    });

    test('in-tree emit writes artifacts next to the sources (local preview)', () {
      final outputs = site.buildSite(root: root.path);
      site.emitSite(root: root.path, outputs: outputs);
      expect(File('${root.path}/site/sitemap.xml').existsSync(), isTrue);
      expect(
        File('${root.path}/site/blog/2026-01-02-one/index.html').existsSync(),
        isTrue,
      );
      // Stale generated pages are pruned in-tree too.
      expect(
        Directory('${root.path}/site/blog/2024-01-01-old').existsSync(),
        isFalse,
      );
    });
  });
}

Map<String, dynamic> _extractJsonLd(String html) {
  final m = RegExp(
    r'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>',
    dotAll: true,
  ).firstMatch(html);
  expect(m, isNotNull, reason: 'page must carry a JSON-LD block');
  return (json.decode(m!.group(1)!) as Map).cast<String, dynamic>();
}
