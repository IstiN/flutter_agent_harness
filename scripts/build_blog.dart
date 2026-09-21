// Builds the fa1.dev blog from the canonical Markdown sources in blog/.
//
//   dart run scripts/build_blog.dart
//
// 1. Reads blog/posts/*.md + YAML frontmatter (title/date/description/…).
// 2. Copies posts and assets to site/blog/posts/.
// 3. Regenerates site/blog/posts.json (index manifest, newest first).
//
// Pure Dart + dart:io, no package deps — frontmatter is parsed by hand.

import 'dart:convert';
import 'dart:io';

void main() {
  final root = _repoRoot();
  final postsDir = Directory('$root/blog/posts');
  final outDir = Directory('$root/site/blog/posts')
    ..createSync(recursive: true);

  if (!postsDir.existsSync()) {
    stderr.writeln('blog/posts/ not found — nothing to build.');
    exit(1);
  }

  final index = <Map<String, dynamic>>[];
  final files =
      postsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // date prefix desc

  for (final file in files) {
    final slug = file.uri.pathSegments.last.replaceAll('.md', '');
    final text = file.readAsStringSync();
    final fm = _frontmatter(text);

    // Copy the post (and assets once, below).
    File('${outDir.path}/$slug.md').writeAsStringSync(text);

    index.add({
      'slug': slug,
      'title': fm['title'] ?? slug,
      'date': fm['date'] ?? '',
      'description': fm['description'] ?? '',
      'author': fm['author'] ?? '',
      if (fm['cover'] != null) 'cover': fm['cover'],
      if (fm['video'] != null && !fm['video']!.contains('HERE'))
        'video': fm['video'],
      if (fm['linkedin'] != null) 'linkedin': fm['linkedin'],
      'tags': fm['tags'] ?? '',
    });
  }

  // Copy assets (cover images, …).
  final assets = Directory('${postsDir.path}/assets');
  if (assets.existsSync()) {
    final outAssets = Directory('${outDir.path}/assets')..createSync();
    for (final f in assets.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.substring(assets.path.length + 1);
      File('${outAssets.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsBytesSync(f.readAsBytesSync());
    }
  }

  File(
    '$root/site/blog/posts.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(index)}\n');

  stdout.writeln('blog built: ${index.length} post(s) -> site/blog/');
}

Map<String, String> _frontmatter(String text) {
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

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/blog').existsSync() &&
        Directory('${dir.path}/site').existsSync()) {
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
