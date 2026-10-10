// Builds the agent-legible (GEO) layer of fa1.dev — gh-1476.
//
//   dart scripts/build_site.dart          # regenerate every artifact
//   dart scripts/build_site.dart --check  # exit 1 if any artifact drifted
//
// What it generates (all COMMITTED; the CI static gate reruns `--check`
// and fails on drift — hand-editing generated output is a red build):
//   site/blog/<slug>/index.html  — static post pages, raw-HTML content,
//                                  BlogPosting JSON-LD (no JS needed)
//   site/docs/<slug>/index.html  — curated docs/*.md as TechArticle pages
//   site/blog/index.html         — the post-list block between the
//                                  #blog-post-list markers
//   site/sitemap.xml             — every indexable page, real lastmod
//   site/llms-full.txt           — llms.txt + full curated post/doc text
//
// lastmod discipline (deterministic from committed inputs — no git, no
// mtimes, so CI checkouts rebuild byte-identically): blog posts take
// front-matter `updated:`/`date:` (filename date prefix as fallback),
// docs take the `updated` field of their [_docsRegistry] entry (bump it
// when the source doc changes), static pages take [_staticPages].
//
// Pure Dart + dart:io, no package deps (same convention as
// scripts/build_blog.dart).

import 'dart:convert';
import 'dart:io';

import 'site_markdown.dart';

const siteOrigin = 'https://fa1.dev';
const orgName = 'IstiN';
const orgUrl = 'https://github.com/IstiN';
const repoUrl = 'https://github.com/IstiN/flutter_agent_harness';
const pubDevUrl = 'https://pub.dev/packages/flutter_agent_harness';

/// Hard cap for llms-full.txt (gh-1476 threat model: a context-window
/// budget, not a repo dump).
const llmsFullBudgetBytes = 150 * 1024;

/// One sitemap entry.
class SitePage {
  const SitePage(this.loc, this.lastmod, this.changefreq, this.priority);
  final String loc;
  final String lastmod;
  final String changefreq;
  final String priority;
}

/// A curated docs/*.md page surfaced as static HTML (gh-1476 D5).
class DocsSource {
  const DocsSource(this.slug, this.source, this.updated, this.description);
  final String slug;
  final String source; // repo-relative markdown path
  final String updated; // YYYY-MM-DD — bump when the source doc changes
  final String description; // for OG/JSON-LD when the doc has no lede
}

/// Agent-quotable docs surfaced under /docs/ (bounded by design — a full
/// docs site is a separate card). `updated` mirrors the source's last
/// meaningful change.
const docsRegistry = [
  DocsSource(
    'tool-availability',
    'docs/tool-availability.md',
    '2026-10-10',
    'Per-tool availability in Fa: how the tools: config section stacks '
        'global, project, session, and runtime scopes over the host '
        'capability floor, and how load modes decide what is loaded.',
  ),
  DocsSource(
    'redaction',
    'docs/redaction.md',
    '2026-10-10',
    'Layered secret redaction in Fa: the exact-value SecretRedactor and '
        'the shape-detecting RedactionPipeline, their layers, attach '
        'points, and configuration.',
  ),
  DocsSource(
    'migrating-from-claude-copilot-codex',
    'docs/migrating-from-claude-copilot-codex.md',
    '2026-10-10',
    'Migrating to Fa from Claude Code, GitHub Copilot, or Codex: config, '
        'skills, agents, hooks, and command surfaces mapped onto their '
        'Fa equivalents.',
  ),
  DocsSource(
    'hep',
    'docs/hep.md',
    '2026-10-10',
    'HEP — the Harness Event Protocol: strict JSONL event frames on '
        'stdout for server-side supervisors of headless fa runs.',
  ),
  DocsSource(
    'dap',
    'docs/dap.md',
    '2026-10-10',
    'DAP — the device access protocol hub: local hub lifecycle, '
        'enrollment, and how Fa instances pair through it.',
  ),
];

/// Static indexable pages. `lastmod` is registry-maintained: bump it in
/// this table when the page changes (same discipline as the previous
/// hand-edited sitemap, now in exactly one place).
const staticPages = [
  SitePage('$siteOrigin/', '2026-09-10', 'weekly', '1.0'),
  SitePage('$siteOrigin/app/', '2026-07-25', 'weekly', '0.9'),
  SitePage('$siteOrigin/app-store/', '2026-09-19', 'weekly', '0.8'),
  SitePage('$siteOrigin/blog/', '2026-09-20', 'weekly', '0.8'),
  SitePage('$siteOrigin/widgets/', '2026-10-10', 'monthly', '0.6'),
  SitePage('$siteOrigin/privacy.html', '2026-07-29', 'monthly', '0.3'),
];

/// The blog/ floor for lastmod — the real lastmod is
/// max(this, newest post date) so a new post lifts /blog/ automatically.
const blogIndexFloor = '2026-09-20';

/// A loaded blog post (source: `site/blog/posts/<slug>.md`, kept in sync
/// with blog/posts/ by scripts/build_blog.dart).
class BlogPost {
  BlogPost({required this.slug, required this.meta, required this.body});
  final String slug;
  final Map<String, String> meta;
  final String body;

  String get title => meta['title'] ?? slug;
  String get description => meta['description'] ?? '';
  String get author => meta['author'] ?? orgName;
  String? get cover => meta['cover'];
  String? get linkedin => meta['linkedin'];
  String? get video => meta['video'];

  /// Real lastmod: `updated:` front-matter wins, then `date:`, then the
  /// `YYYY-MM-DD-` filename prefix. A post with none of these is a build
  /// error — a fabricated date would leak into the sitemap and JSON-LD,
  /// and a wrong date is worse for search than none (gh-1476 review).
  String get lastmod {
    final updated = meta['updated'];
    if (updated != null && updated.isNotEmpty) return updated;
    final date = meta['date'];
    if (date != null && date.isNotEmpty) return date;
    final prefix = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(slug);
    if (prefix != null) return prefix.group(1)!;
    throw StateError(
      'blog post "$slug" has no lastmod — add `updated:` or `date:` '
      'front-matter, or use a YYYY-MM-DD- filename prefix (gh-1476 '
      'lastmod discipline)',
    );
  }

  String get url => '$siteOrigin/blog/$slug/';
}

/// A loaded docs page.
class DocsPage {
  DocsPage({
    required this.source,
    required this.title,
    required this.body,
    required this.description,
    required this.raw,
  });
  final DocsSource source;
  final String title;
  final String body;
  final String description;

  /// The source markdown verbatim (for llms-full.txt).
  final String raw;

  String get url => '$siteOrigin/docs/${source.slug}/';
  String get updated => source.updated;
}

/// A file the build produces.
class OutputFile {
  OutputFile(this.path, this.content);
  final String path; // repo-relative
  final String content;
}

List<BlogPost> loadPosts(String root) {
  final dir = Directory('$root/site/blog/posts');
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // newest first
  return [
    for (final f in files)
      BlogPost(
        slug: f.uri.pathSegments.last.replaceAll('.md', ''),
        meta: parseFrontmatter(f.readAsStringSync()),
        body: stripFrontmatter(f.readAsStringSync()),
      ),
  ];
}

List<DocsPage> loadDocs(String root) {
  return [
    for (final source in docsRegistry)
      () {
        final raw = File('$root/${source.source}').readAsStringSync();
        final titleMatch = RegExp(
          r'^#\s+(.+)$',
          multiLine: true,
        ).firstMatch(raw);
        final title = titleMatch != null
            ? plainText(titleMatch.group(1)!)
            : source.slug;
        // Drop the leading H1 — the page template renders it as the headline.
        final body = titleMatch != null
            ? raw.replaceFirst(titleMatch.group(0)!, '').trimLeft()
            : raw;
        final firstPara = RegExp(
          r'^([^\n#|>-][^\n]*(?:\n(?!\n)[^\n#|>-][^\n]*)*)',
          multiLine: true,
        ).firstMatch(body);
        final lede = firstPara != null ? plainText(firstPara.group(1)!) : '';
        return DocsPage(
          source: source,
          title: title,
          body: body,
          description: lede.isNotEmpty ? lede : source.description,
          raw: raw,
        );
      }(),
  ];
}

/// The generated post-list block in site/blog/index.html.
const blogIndexStart = '<!-- #blog-post-list:start';
const blogIndexEnd = '<!-- #blog-post-list:end -->';

String blogIndexBlock(List<BlogPost> posts) {
  final out = StringBuffer()
    ..writeln(
      '$blogIndexStart — generated by scripts/build_site.dart; do not '
      'hand-edit (CI freshness gate, gh-1476) -->',
    )
    ..writeln('<div id="posts">');
  for (final p in posts) {
    final cover = p.cover;
    out
      ..writeln('<a class="post-card" href="./${p.slug}/">')
      ..writeln(
        cover != null
            ? '<img src="posts/${escapeHtml(cover)}" alt="" loading="lazy">'
            : '<h2>${escapeHtml(p.title)}</h2>',
      );
    if (cover != null) out.writeln('<h2>${escapeHtml(p.title)}</h2>');
    out
      ..writeln(
        '<div class="meta">${escapeHtml(p.meta['date'] ?? p.lastmod)}'
        '${p.author.isNotEmpty ? ' · ${escapeHtml(p.author)}' : ''}</div>',
      )
      ..writeln('<p>${escapeHtml(p.description)}</p>')
      ..writeln('</a>');
  }
  out
    ..writeln('</div>')
    ..write(blogIndexEnd);
  return out.toString();
}

Map<String, Object?> _publisherJson() => {
  '@type': 'Organization',
  'name': orgName,
  'url': siteOrigin,
  'sameAs': [orgUrl],
};

String _jsonLd(Map<String, Object?> obj) =>
    const JsonEncoder.withIndent('  ').convert(obj);

Map<String, Object?> blogPostingJson(BlogPost p) => {
  '@context': 'https://schema.org',
  '@type': 'BlogPosting',
  'headline': p.title,
  if (p.description.isNotEmpty) 'description': p.description,
  if (p.cover != null) 'image': ['$siteOrigin/blog/posts/${p.cover}'],
  'datePublished': p.meta['date'] ?? p.lastmod,
  'dateModified': p.lastmod,
  'author': {'@type': 'Organization', 'name': orgName, 'url': orgUrl},
  'publisher': _publisherJson(),
  'mainEntityOfPage': {'@type': 'WebPage', '@id': p.url},
  'url': p.url,
  if ((metaTags(p)).isNotEmpty) 'keywords': metaTags(p),
};

String metaTags(BlogPost p) =>
    (p.meta['tags'] ?? '').replaceAll(RegExp(r'[\[\]]'), '').trim();

Map<String, Object?> techArticleJson(DocsPage d) => {
  '@context': 'https://schema.org',
  '@type': 'TechArticle',
  'headline': d.title,
  'description': d.description,
  'datePublished': d.updated,
  'dateModified': d.updated,
  'author': {'@type': 'Organization', 'name': orgName, 'url': orgUrl},
  'publisher': _publisherJson(),
  'about': {'@type': 'SoftwareApplication', 'name': 'Fa', 'url': siteOrigin},
  'mainEntityOfPage': {'@type': 'WebPage', '@id': d.url},
  'url': d.url,
};

/// Shared nav header. [prefix] is the relative path back to the site root
/// ('' for root pages, '../' one level, '../../' two).
String _nav(String prefix, {String? current}) =>
    '''
<header class="nav">
  <div class="nav-inner">
    <a class="brand" href="$prefix">
      <span class="brand-mark" aria-hidden="true">&gt;_</span>
      <span class="brand-name">Fa</span>
      <span class="brand-sub">fa1.dev</span>
    </a>
    <nav class="nav-links" aria-label="Sections">
      <a href="$prefix#demo">Demo</a>
      <a href="$prefix#install">Install</a>
      <a href="$prefix#features">Features</a>
      <a href="${prefix}widgets/">Widgets</a>
      <a href="${prefix}blog/"${current == 'blog' ? ' aria-current="page"' : ''}>Blog</a>
    </nav>
    <nav class="nav-ext" aria-label="Project links">
      <a href="$repoUrl" rel="noopener">GitHub</a>
      <a href="$pubDevUrl" rel="noopener">pub.dev</a>
    </nav>
  </div>
</header>''';

String _videoEmbed(String url) {
  final esc = escapeHtml(url);
  final yt = RegExp(
    r'(?:youtube\.com/watch\?v=|youtu\.be/)([\w-]+)',
  ).firstMatch(url);
  if (yt != null) {
    return '<div class="post-video"><iframe src="https://www.youtube.com/embed/${yt.group(1)}" allowfullscreen></iframe></div>';
  }
  if (RegExp(r'\.(mp4|webm|mov)$').hasMatch(url)) {
    return '<div class="post-video"><video src="$esc" controls></video></div>';
  }
  return '<p><a href="$esc" target="_blank" rel="noopener">🎬 Watch the video ↗</a></p>';
}

/// Renders a full static blog post page — raw-HTML content, no JS needed
/// to read it (the GEO invariant, gh-1476 G1).
String renderBlogPostPage(BlogPost p) {
  final title = escapeHtml(p.title);
  final desc = escapeHtml(p.description);
  final cover = p.cover;
  // The raw path matches against the post body (cover lifting); the
  // escaped variant is what reaches HTML attributes, like every other
  // front-matter value in these templates.
  final coverEsc = cover != null ? escapeHtml(cover) : null;
  final video = p.video;
  final linkedin = p.linkedin;

  // The post markdown usually opens with its own `# <title>` H1 and a
  // leading cover image — both are lifted into the page template (the
  // cover becomes the .post-cover figure, mirroring blog/post.html).
  final bodyLines = p.body.split('\n');
  var start = 0;
  var strippedH1 = false;
  var coverFromBody = false;
  while (start < bodyLines.length) {
    final line = bodyLines[start].trim();
    if (line.isEmpty) {
      start++;
      continue;
    }
    if (!strippedH1) {
      final h1 = RegExp(r'^#\s+(.+)$').firstMatch(line);
      if (h1 != null && plainText(h1.group(1)!) == plainText(p.title)) {
        strippedH1 = true;
        start++;
        continue;
      }
    }
    if (cover != null && !coverFromBody) {
      final img = RegExp(
        r'^!\[[^\]]*\]\(' + RegExp.escape(cover) + r'\)\s*$',
      ).firstMatch(line);
      if (img != null) {
        coverFromBody = true;
        start++;
        continue;
      }
    }
    break;
  }
  final body = bodyLines.sublist(start).join('\n').trimLeft();

  final bodyHtml = renderMarkdown(
    body,
    rewriteImg: (src) => RegExp(r'^(?:https?:)?//|^/|^data:').hasMatch(src)
        ? src
        : '../posts/$src',
  );

  final meta = StringBuffer()
    ..writeln(
      '<div class="post-meta">${escapeHtml(p.meta['date'] ?? p.lastmod)}'
      '${p.author.isNotEmpty ? ' · ${escapeHtml(p.author)}' : ''}'
      '${linkedin != null ? ' · <a href="${escapeHtml(linkedin)}" target="_blank" rel="noopener">also on LinkedIn ↗</a>' : ''}'
      '</div>',
    );
  if (video != null && !video.contains('HERE')) {
    meta.writeln(_videoEmbed(video));
  }

  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title — &gt;_Fa blog</title>
<meta name="description" content="$desc">
<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1">
<meta name="theme-color" content="#070a10">
<link rel="canonical" href="${p.url}">
<link rel="icon" href="../../favicon.svg?v=2" type="image/svg+xml">

<!-- Open Graph -->
<meta property="og:type" content="article">
<meta property="og:site_name" content=">_Fa">
<meta property="og:title" content="$title">
<meta property="og:description" content="$desc">
<meta property="og:url" content="${p.url}">
<meta property="og:image" content="${coverEsc != null ? '$siteOrigin/blog/posts/$coverEsc' : '$siteOrigin/og-image.png?v=2'}">
${cover != null ? '<meta property="og:image:alt" content="$title">' : ''}

<!-- Twitter -->
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="$title">
<meta name="twitter:description" content="$desc">
<meta name="twitter:image" content="${coverEsc != null ? '$siteOrigin/blog/posts/$coverEsc' : '$siteOrigin/og-image.png?v=2'}">
${cover != null ? '<meta name="twitter:image:alt" content="$title">' : ''}

<link rel="stylesheet" href="../../styles.css?v=3">
<link rel="stylesheet" href="../../blog.css?v=1">
<script type="application/ld+json">
${_jsonLd(blogPostingJson(p))}
</script>
</head>
<body>
<div class="bg" aria-hidden="true"></div>

${_nav('../', current: 'blog')}

<main class="blog-wrap">
  <p><a class="back-link" href="../">← all posts</a></p>
  <article class="post-body" id="post">
    <h1>$title</h1>
    ${coverEsc != null && (coverFromBody || !body.contains(']($cover)')) ? '<img class="post-cover" src="../posts/$coverEsc" alt="$title">' : ''}
$meta$bodyHtml  </article>
</main>
</body>
</html>
''';
}

/// Docs cross-link rewrite: relative `*.md` links point at the surfaced
/// /docs/ page when curated, else at the GitHub source.
String Function(String) docsLinkRewriter() {
  final byFile = {
    for (final d in docsRegistry) d.source.split('/').last: d.slug,
  };
  return (href) {
    if (RegExp(r'^(?:https?:)?//|^#|^mailto:').hasMatch(href)) return href;
    if (href.endsWith('.md')) {
      final file = href.split('/').last;
      final slug = byFile[file];
      if (slug != null) return '/docs/$slug/';
      return _docsSourceUrl(href);
    }
    return href;
  };
}

/// Resolves `.`/`..` segments of a relative markdown href against the
/// `docs/` directory (GitHub source parity) so parent-relative links
/// like `../foo.md` never leak `..` into a published URL. `..` is
/// clamped at the repo root.
String _docsSourceUrl(String href) {
  final stack = ['docs'];
  for (final seg in href.replaceAll(RegExp(r'^\./'), '').split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    stack.add(seg);
  }
  return '$repoUrl/blob/main/${stack.join('/')}';
}

/// Renders a curated docs page as static HTML with TechArticle JSON-LD.
String renderDocsPage(DocsPage d) {
  final title = escapeHtml(d.title);
  final desc = escapeHtml(d.description);
  final bodyHtml = renderMarkdown(d.body, rewriteLink: docsLinkRewriter());

  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title — Fa docs</title>
<meta name="description" content="$desc">
<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1">
<meta name="theme-color" content="#070a10">
<link rel="canonical" href="${d.url}">
<link rel="icon" href="../../favicon.svg?v=2" type="image/svg+xml">

<!-- Open Graph -->
<meta property="og:type" content="article">
<meta property="og:site_name" content="Fa">
<meta property="og:title" content="$title">
<meta property="og:description" content="$desc">
<meta property="og:url" content="${d.url}">
<meta property="og:image" content="$siteOrigin/og-image.png?v=2">
<meta property="og:image:alt" content="Fa — one agent harness, every device.">

<!-- Twitter -->
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="$title">
<meta name="twitter:description" content="$desc">
<meta name="twitter:image" content="$siteOrigin/og-image.png?v=2">

<link rel="stylesheet" href="../../styles.css?v=3">
<script type="application/ld+json">
${_jsonLd(techArticleJson(d))}
</script>
</head>
<body>
<div class="bg" aria-hidden="true"></div>

${_nav('../../')}

<main class="blog-wrap">
  <p><a class="back-link" href="$repoUrl/blob/main/${d.source.source}" target="_blank" rel="noopener">← source on GitHub ↗</a></p>
  <article class="post-body" id="doc">
    <h1>$title</h1>
    <div class="post-meta">Updated ${d.updated} · ${escapeHtml(orgName)}</div>
$bodyHtml  </article>
</main>
</body>
</html>
''';
}

/// Every page that belongs in sitemap.xml, statics first, then posts
/// (newest first), then docs.
List<SitePage> collectPages(List<BlogPost> posts, List<DocsPage> docs) {
  final newestPost = posts.isEmpty ? '' : posts.first.lastmod;
  final blogLastmod = newestPost.compareTo(blogIndexFloor) > 0
      ? newestPost
      : blogIndexFloor;
  return [
    for (final p in staticPages)
      p.loc == '$siteOrigin/blog/'
          ? SitePage(p.loc, blogLastmod, p.changefreq, p.priority)
          : p,
    for (final p in posts) SitePage(p.url, p.lastmod, 'monthly', '0.8'),
    for (final d in docs) SitePage(d.url, d.updated, 'monthly', '0.7'),
  ];
}

String buildSitemapXml(List<SitePage> pages) {
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');
  for (final p in pages) {
    out
      ..writeln('  <url>')
      ..writeln('    <loc>${p.loc}</loc>')
      ..writeln('    <lastmod>${p.lastmod}</lastmod>')
      ..writeln('    <changefreq>${p.changefreq}</changefreq>')
      ..writeln('    <priority>${p.priority}</priority>')
      ..writeln('  </url>');
  }
  out.writeln('</urlset>');
  return out.toString();
}

/// Assembles llms-full.txt: the llms.txt fact sheet verbatim, then every
/// curated source in full, each section headed by its canonical URL
/// (https://llmstxt.org/ companion-file convention, gh-1476 G3).
String buildLlmsFull({
  required String llmsTxt,
  required List<BlogPost> posts,
  required List<DocsPage> docs,
}) {
  final out = StringBuffer()
    ..writeln('# Fa (Flutter Agent Harness) — llms-full.txt')
    ..writeln()
    ..writeln(
      '> Full curated documentation for LLM agents with large context '
      'windows: the llms.txt fact sheet, every blog post, and the '
      'agent-facing docs — each section headed by its canonical URL.',
    )
    ..writeln('> Generated by scripts/build_site.dart — do not edit (gh-1476).')
    ..writeln()
    ..writeln('# $siteOrigin/llms.txt')
    ..writeln()
    ..writeln(llmsTxt.trimRight())
    ..writeln()
    ..writeln('## Blog posts (full text)')
    ..writeln();
  for (final p in posts) {
    out
      ..writeln('# ${p.url}')
      ..writeln()
      ..writeln(p.body.trim())
      ..writeln();
  }
  out
    ..writeln('## Documentation (full text)')
    ..writeln();
  for (final d in docs) {
    out
      ..writeln('# ${d.url}')
      ..writeln()
      ..writeln(d.raw.trim())
      ..writeln();
  }
  final text = out.toString();
  // The budget is a byte budget (context-window threat model) — the file
  // is written as UTF-8, so measure encoded bytes, not UTF-16 code units.
  final byteLength = utf8.encode(text).length;
  if (byteLength > llmsFullBudgetBytes) {
    throw StateError(
      'llms-full.txt is $byteLength bytes — over the '
      '$llmsFullBudgetBytes-byte budget (gh-1476 threat model). Curate '
      'fewer/smaller sources or raise the cap deliberately.',
    );
  }
  return text;
}

/// Computes every generated artifact without touching disk.
List<OutputFile> buildSite({required String root}) {
  final posts = loadPosts(root);
  final docs = loadDocs(root);

  final blogIndex = File('$root/site/blog/index.html').readAsStringSync();
  final block = blogIndexBlock(posts);
  final startIdx = blogIndex.indexOf(blogIndexStart);
  final endIdx = blogIndex.indexOf(blogIndexEnd);
  if (startIdx < 0 || endIdx < 0 || endIdx < startIdx) {
    throw StateError(
      'site/blog/index.html is missing the #blog-post-list generated '
      'block markers — restore them from git.',
    );
  }
  final regeneratedIndex = blogIndex.replaceRange(
    startIdx,
    endIdx + blogIndexEnd.length,
    block,
  );

  return [
    for (final p in posts)
      OutputFile('site/blog/${p.slug}/index.html', renderBlogPostPage(p)),
    for (final d in docs)
      OutputFile('site/docs/${d.source.slug}/index.html', renderDocsPage(d)),
    OutputFile('site/blog/index.html', regeneratedIndex),
    OutputFile('site/sitemap.xml', buildSitemapXml(collectPages(posts, docs))),
    OutputFile(
      'site/llms-full.txt',
      buildLlmsFull(
        llmsTxt: File('$root/site/llms.txt').readAsStringSync(),
        posts: posts,
        docs: docs,
      ),
    ),
  ];
}

/// Generated directories that mirror a source list — used to prune stale
/// pages in write mode and to detect extras in check mode.
List<String> _generatedPageDirs(String root) {
  final dirs = <String>[];
  for (final base in ['site/blog', 'site/docs']) {
    final dir = Directory('$root/$base');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync().whereType<Directory>()) {
      if (File('${entity.path}/index.html').existsSync()) {
        dirs.add(entity.path.substring(root.length + 1));
      }
    }
  }
  return dirs;
}

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/site').existsSync() &&
        Directory('${dir.path}/scripts').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('run from inside the flutter_agent repo');
      exit(1);
    }
    dir = parent;
  }
}

void main(List<String> args) {
  final check = args.contains('--check');
  final root = _repoRoot();
  final outputs = buildSite(root: root);

  if (check) {
    var drift = 0;
    final expectedPaths = {for (final o in outputs) o.path};
    for (final o in outputs) {
      final f = File('$root/${o.path}');
      if (!f.existsSync() || f.readAsStringSync() != o.content) {
        drift++;
        stderr.writeln(
          'STALE: ${o.path} — rerun `dart scripts/build_site.dart`',
        );
      }
    }
    for (final dir in _generatedPageDirs(root)) {
      if (!expectedPaths.any((p) => p.startsWith('$dir/'))) {
        drift++;
        stderr.writeln('STALE: $dir/ — no matching source; remove it');
      }
    }
    if (drift > 0) {
      stderr.writeln(
        'site build drift: $drift artifact(s) — CI gate (gh-1476)',
      );
      exit(1);
    }
    stdout.writeln('site build fresh: ${outputs.length} artifact(s)');
    return;
  }

  for (final o in outputs) {
    final f = File('$root/${o.path}')..createSync(recursive: true);
    f.writeAsStringSync(o.content);
  }
  // Prune generated pages whose source disappeared.
  final expectedPaths = {for (final o in outputs) o.path};
  for (final dir in _generatedPageDirs(root)) {
    if (!expectedPaths.any((p) => p.startsWith('$dir/'))) {
      Directory('$root/$dir').deleteSync(recursive: true);
      stdout.writeln('pruned stale page: $dir/');
    }
  }
  stdout.writeln(
    'site built: ${outputs.length} artifact(s) — blog posts, docs pages, '
    'sitemap.xml, llms-full.txt',
  );
}
