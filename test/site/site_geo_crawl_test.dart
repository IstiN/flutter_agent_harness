// GEO invariant tests for fa1.dev (gh-1476) — the no-JS crawl contract:
// every meaningful page serves its core text as raw HTML, robots.txt
// welcomes the named AI crawlers, llms.txt/llms-full.txt are served as
// text/plain with canonical-URL section headers, every JSON-LD block
// parses, and every sitemap <loc> resolves. Served over a real loopback
// HttpServer from the committed site/ tree — zero JavaScript involved.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// URL path → file under site/, mirroring GitHub Pages' static serving.
String? resolveSiteFile(String path) {
  if (path.contains('..')) return null;
  final rel = path.endsWith('/')
      ? '${path.substring(0, path.length - 1)}/index.html'
      : path;
  if (rel.isEmpty || rel == 'index.html') return 'site/index.html';
  final file = 'site$rel';
  return File(file).existsSync() ? file : null;
}

void main() {
  late HttpServer server;
  late String origin;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = Uri.decodeComponent(req.uri.path);
      final file = resolveSiteFile(path);
      if (file == null) {
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
      } else {
        final ext = file.split('.').last;
        req.response.headers.contentType = switch (ext) {
          'html' => ContentType.html,
          'txt' => ContentType.text,
          'xml' => ContentType.parse('application/xml'),
          'png' => ContentType.parse('image/png'),
          'svg' => ContentType.parse('image/svg+xml'),
          'json' => ContentType.json,
          _ => ContentType.binary,
        };
        await req.response.addStream(File(file).openRead());
      }
      await req.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  Future<(int, String, String?)> get(String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$origin$path'));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      return (res.statusCode, body, res.headers.contentType?.mimeType);
    } finally {
      client.close(force: true);
    }
  }

  final sitemap = File('site/sitemap.xml').readAsStringSync();
  final locs = RegExp(r'<loc>(https://fa1\.dev[^<]+)</loc>')
      .allMatches(sitemap)
      .map((m) => m.group(1)!)
      .toList();

  group('no-JS crawl (gh-1476 test matrix)', () {
    test('every sitemap <loc> returns 200', () async {
      expect(locs, isNotEmpty);
      for (final loc in locs) {
        final path = loc.substring('https://fa1.dev'.length);
        // /app/ is the Flutter web demo built at deploy time — absent
        // from the static tree by design.
        if (path == '/app/') continue;
        final (status, _, _) = await get(path.isEmpty ? '/' : path);
        expect(status, 200, reason: '$loc must serve without JS');
      }
    });

    test('landing page carries its core text raw', () async {
      final (status, body, type) = await get('/');
      expect(status, 200);
      expect(type, 'text/html');
      expect(body, contains('One agent harness'));
      expect(body, contains('id="faq"'));
    });

    test('blog index lists posts without JS', () async {
      final (status, body, _) = await get('/blog/');
      expect(status, 200);
      expect(body, isNot(contains('Loading')));
      expect(
        body,
        contains('We burned 40 billion tokens'),
        reason: 'the post list is server-rendered (gh-1476 G1)',
      );
    });

    test('every blog post page serves its full text without JS', () async {
      for (final entity in Directory('site/blog')
          .listSync()
          .whereType<Directory>()) {
        final slug = entity.uri.pathSegments.last;
        final mdFile = File('site/blog/posts/$slug.md');
        if (!mdFile.existsSync()) continue;
        final (status, body, _) = await get('/blog/$slug/');
        expect(status, 200, reason: '/blog/$slug/');
        // Distinctive strings straight from the markdown source.
        final src = mdFile.readAsStringSync();
        for (final needle in ['## The bill', 'Kimi K3']) {
          expect(src, contains(needle), reason: 'fixture sanity: $needle');
          expect(body, contains(needle),
              reason: 'post page must contain `$needle` without JS');
        }
        expect(body, isNot(contains('fetch(')));
      }
    });

    test('every docs page serves its core text without JS', () async {
      final docsDir = Directory('site/docs');
      expect(docsDir.existsSync(), isTrue);
      for (final entity in docsDir.listSync().whereType<Directory>()) {
        final slug = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final (status, body, _) = await get('/docs/$slug/');
        expect(status, 200, reason: '/docs/$slug/');
        expect(body, contains('<article'), reason: '/docs/$slug/');
      }
      final (_, redaction, _) = await get('/docs/redaction/');
      expect(redaction, contains('RedactionPipeline'));
    });
  });

  group('robots.txt contract (gh-1476 D2)', () {
    test('names every AI crawler with Allow and points at the llms files',
        () async {
      final (status, body, type) = await get('/robots.txt');
      expect(status, 200);
      expect(type, 'text/plain');
      for (final bot in [
        'GPTBot',
        'OAI-SearchBot',
        'ChatGPT-User',
        'Google-Extended',
        'ClaudeBot',
        'anthropic-ai',
        'PerplexityBot',
        'Perplexity-User',
        'CCBot',
        'Applebot-Extended',
        'Meta-ExternalAgent',
      ]) {
        expect(body, contains('User-agent: $bot\nAllow: /\n'),
            reason: '$bot must be welcomed by name');
      }
      expect(body, contains('User-agent: *\nAllow: /'));
      expect(body, contains('https://fa1.dev/llms.txt'));
      expect(body, contains('https://fa1.dev/llms-full.txt'));
      expect(body, contains('Sitemap: https://fa1.dev/sitemap.xml'));
    });
  });

  group('llms files (gh-1476 G3)', () {
    test('llms.txt and llms-full.txt serve 200 text/plain', () async {
      for (final path in ['/llms.txt', '/llms-full.txt']) {
        final (status, body, type) = await get(path);
        expect(status, 200, reason: path);
        expect(type, 'text/plain', reason: path);
        expect(body, isNotEmpty);
      }
    });

    test('llms-full.txt heads every curated source with its canonical URL',
        () async {
      final (_, body, _) = await get('/llms-full.txt');
      final postAndDocLocs = locs
          .where((l) => l.contains('/blog/20') || l.contains('/docs/'))
          .toList();
      expect(postAndDocLocs.length, greaterThanOrEqualTo(6));
      for (final loc in postAndDocLocs) {
        expect(body, contains('# $loc'),
            reason: 'llms-full.txt must carry the full text of $loc');
      }
      expect(
        File('site/llms-full.txt').lengthSync(),
        lessThan(150 * 1024),
        reason: 'context-window budget (gh-1476 threat model)',
      );
    });
  });

  group('structured data (gh-1476 D3/D4)', () {
    List<Map<String, dynamic>> jsonLdBlocks(String html) => [
          for (final m in RegExp(
            r'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>',
            dotAll: true,
          ).allMatches(html))
            (json.decode(m.group(1)!) as Map).cast<String, dynamic>(),
        ];

    test('landing page carries one validated @graph with the new entities',
        () async {
      final (_, body, _) = await get('/');
      final blocks = jsonLdBlocks(body);
      expect(blocks, hasLength(1));
      final graph = (blocks.first['@graph'] as List).cast<Map<String, dynamic>>();
      final types = {for (final n in graph) n['@type']};
      expect(
        types,
        containsAll([
          'Organization',
          'WebSite',
          'SoftwareApplication',
          'SoftwareSourceCode',
          'FAQPage',
          'HowTo',
        ]),
      );
      final app = graph.firstWhere((n) => n['@type'] == 'SoftwareApplication');
      expect(app['sameAs'], contains(site_repo));
      expect(app['sameAs'], contains(site_pub));
      final source =
          graph.firstWhere((n) => n['@type'] == 'SoftwareSourceCode');
      expect(source['codeRepository'], site_repo);
      expect(source['runtimePlatform'], 'Dart');
      // REG: the pre-existing FAQ/HowTo content survived the @graph merge.
      final faq = graph.firstWhere((n) => n['@type'] == 'FAQPage');
      final questions = json.encode(faq);
      expect(questions, contains('What is Fa?'));
      expect(questions, contains('How do I install the Chrome extension?'));
      final howTo = graph.firstWhere((n) => n['@type'] == 'HowTo');
      expect(json.encode(howTo), contains('Run the installer'));
    });

    test('every page in site/ has only parseable JSON-LD', () {
      final files = Directory('site')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.html'));
      var checked = 0;
      for (final f in files) {
        for (final block in jsonLdBlocks(f.readAsStringSync())) {
          expect(block['@type'] ?? block['@graph'], isNotNull,
              reason: '${f.path}: JSON-LD node needs a type');
          checked++;
        }
      }
      expect(checked, greaterThanOrEqualTo(7)); // landing graph + posts + docs
    });

    test('blog posts carry BlogPosting, docs pages carry TechArticle',
        () async {
      for (final entity in Directory('site/blog')
          .listSync()
          .whereType<Directory>()) {
        final slug = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!File('site/blog/posts/$slug.md').existsSync()) continue;
        final (_, body, _) = await get('/blog/$slug/');
        final blocks = jsonLdBlocks(body);
        expect(
          blocks.any((b) => b['@type'] == 'BlogPosting'),
          isTrue,
          reason: '/blog/$slug/ needs BlogPosting schema',
        );
      }
      for (final entity in Directory('site/docs')
          .listSync()
          .whereType<Directory>()) {
        final slug = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final (_, body, _) = await get('/docs/$slug/');
        final blocks = jsonLdBlocks(body);
        expect(
          blocks.any((b) => b['@type'] == 'TechArticle'),
          isTrue,
          reason: '/docs/$slug/ needs TechArticle schema',
        );
      }
    });

    test('sitemap lastmod values are real dates', () {
      final lastmods = RegExp(r'<lastmod>(\d{4}-\d{2}-\d{2})</lastmod>')
          .allMatches(sitemap)
          .map((m) => m.group(1)!)
          .toList();
      expect(lastmods.length, locs.length);
    });
  });
}

const site_repo = 'https://github.com/IstiN/flutter_agent_harness';
const site_pub = 'https://pub.dev/packages/flutter_agent_harness';
