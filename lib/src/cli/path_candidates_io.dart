import 'dart:io';

/// Relative POSIX paths under the current working directory, breadth-first
/// so shallow files complete first; skips VCS/build dirs; stops at
/// [maxEntries]. ponytail: size-capped walk; swap for a real watcher if
/// staleness ever bites.
List<String> workspaceFileCandidates({int maxEntries = 5000}) {
  const skip = {'.git', '.dart_tool', '.worktrees', 'node_modules', 'build'};
  final root = Directory.current;
  final rootPath = root.path;
  final out = <String>[];
  final queue = <Directory>[root];
  while (queue.isNotEmpty && out.length < maxEntries) {
    final dir = queue.removeAt(0);
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final entity in entries) {
      final segments = entity.uri.pathSegments.where((s) => s.isNotEmpty);
      if (segments.isEmpty) continue;
      final name = segments.last;
      if (skip.contains(name)) continue;
      if (entity is Directory) {
        queue.add(entity);
      } else if (entity is File) {
        out.add(
          entity.path.startsWith('$rootPath/')
              ? entity.path.substring(rootPath.length + 1)
              : entity.path,
        );
        if (out.length >= maxEntries) break;
      }
    }
  }
  return out;
}

/// Fragment-aware candidate source with a 30s TTL cache: the composer calls
/// this per keystroke, and re-walking a big tree every frame is the frame
/// hitch issue #275 calls out. Lives here so the cache also stays behind
/// the conditional import (web builds get the no-op stub).
const pathCandidatesTtlMs = 30000;
List<String>? _cache;
int _cacheAtMs = -1;
List<String> pathCandidatesFor(String fragment) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _cacheAtMs > pathCandidatesTtlMs || _cache == null) {
    _cache = workspaceFileCandidates();
    _cacheAtMs = now;
  }
  return _cache!;
}
