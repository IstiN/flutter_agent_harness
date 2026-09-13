import 'dart:io';

/// Relative POSIX paths under the current working directory, breadth-first
/// so shallow files complete first; skips VCS/build dirs; stops at
/// [maxEntries]. ponytail: size-capped walk; swap for a real watcher if
/// staleness ever bites.
List<String> workspaceFileCandidates({int maxEntries = 5000}) {
  const skip = {'.git', '.dart_tool', '.worktrees', 'node_modules', 'build'};
  final rootPath = Directory.current.path;
  final out = <String>[];
  final queue = <Directory>[Directory.current];
  while (queue.isNotEmpty && out.length < maxEntries) {
    for (final entity in safeListSync(queue.removeAt(0))) {
      if (out.length >= maxEntries) break;
      final name = entityName(entity);
      if (skip.contains(name)) continue;
      if (entity is Directory) {
        queue.add(entity);
      } else if (entity is File) {
        out.add(relativeToRoot(entity.path, rootPath));
      }
    }
  }
  return out;
}

/// Lists [dir]; an unreadable directory yields nothing instead of
/// aborting the whole walk.
List<FileSystemEntity> safeListSync(Directory dir) {
  try {
    return dir.listSync(followLinks: false);
  } on FileSystemException {
    return const [];
  }
}

/// The last path segment of [entity] ('' segments dropped).
String entityName(FileSystemEntity entity) =>
    entity.uri.pathSegments.where((s) => s.isNotEmpty).last;

/// [path] relative to [rootPath]; passthrough when not underneath it.
String relativeToRoot(String path, String rootPath) =>
    path.startsWith('$rootPath/') ? path.substring(rootPath.length + 1) : path;

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

/// Test hook: drops the TTL cache so a test can force a re-walk.
void resetPathCandidatesCache() {
  _cache = null;
  _cacheAtMs = -1;
}
