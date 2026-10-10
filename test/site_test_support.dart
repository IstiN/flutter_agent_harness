// Shared harness for the test/site/* guards (gh-1476, PR #1479 owner
// directive): resolves the site root the guards serve against.
//
// Generated artifacts (blog/docs pages, sitemap.xml, llms-full.txt) are
// deploy-time products — gitignored, never committed. Resolution order:
//   1. `FA_SITE_ROOT` env var (CI builds to a temp dir with
//      `dart scripts/build_site.dart --out <dir>` and validates that
//      output — gh-1476 AC5);
//   2. `site/` when it already carries a built layer (local in-tree
//      preview);
//   3. otherwise a temp-dir build on the fly, so the guards are
//      self-contained on a fresh checkout.
import 'dart:io';

import 'package:test/test.dart';

import '../scripts/build_site.dart' as builder;

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/site').existsSync() &&
        Directory('${dir.path}/scripts').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('run from inside the flutter_agent repo');
    }
    dir = parent;
  }
}

/// The servable site root for the guards (see the file header).
Future<Directory> resolveSiteRoot() async {
  final env = Platform.environment['FA_SITE_ROOT'];
  if (env != null && env.isNotEmpty) {
    final dir = Directory(env);
    if (!File('${dir.path}/sitemap.xml').existsSync()) {
      fail(
        'FA_SITE_ROOT=$env has no built GEO layer (sitemap.xml missing) — '
        'run `dart scripts/build_site.dart --out $env` first',
      );
    }
    return dir;
  }
  final root = Directory('${_repoRoot()}/site');
  if (File('${root.path}/sitemap.xml').existsSync()) return root;
  final tmp = Directory.systemTemp.createTempSync('fa_site_test');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final outputs = builder.buildSite(root: _repoRoot());
  builder.emitSite(root: _repoRoot(), outDir: tmp.path, outputs: outputs);
  return Directory('${tmp.path}/site');
}
