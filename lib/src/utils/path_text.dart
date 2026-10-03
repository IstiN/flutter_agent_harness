// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Lexical (string-math) POSIX path helpers shared across modules.
///
/// Pure text: no filesystem access, no symlink resolution.
library;

/// Collapses `.`, `..`, empty (duplicate-slash) and trailing segments of
/// [path] against the root `/`, staying at the root when `..` climbs above
/// it — the sandbox shells' normalizer semantics (`/a/../..` → `/`).
String normalizeLexicalPath(String path) {
  final segments = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(part);
  }
  return '/${segments.join('/')}';
}

/// Strips redundant trailing slashes from [path]; a lone `/` root and a
/// bare name are returned unchanged. Matching stays lexical.
String stripTrailingSlashes(String path) {
  var stripped = path;
  while (stripped.length > 1 && stripped.endsWith('/')) {
    stripped = stripped.substring(0, stripped.length - 1);
  }
  return stripped;
}
