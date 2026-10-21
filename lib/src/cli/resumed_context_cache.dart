/// The warm-switch resumed-context cache (gh-1734 root cause 3): a
/// session whose file is unchanged since its last open reuses the built
/// [SessionContext] instead of re-paying the projection walk on every
/// open/switch. Entries are keyed by (path, sizeBytes, mtimeMs); any
/// change to the file (append, rotation, truncate) produces a different
/// fingerprint and a clean miss.
library;

import '../session/session_tree.dart';

/// One memoized context build with the stat fingerprint it was built at.
final class _Entry {
  _Entry({
    required this.sizeBytes,
    required this.mtimeMs,
    required this.context,
  });

  final int sizeBytes;
  final int mtimeMs;
  final SessionContext context;
}

/// LRU-bounded per-process cache of built session contexts.
///
/// The CLI holds one instance for the process lifetime (contexts are
/// rebuilt from the session file, so a process-wide cache is consistent
/// with every writer: a foreign append changes the file's stat and the
/// entry misses). [match] hands out a fresh message list per hit — a
/// consumer mutating its copy never corrupts the cache, and the cached
/// message objects themselves must be treated as immutable (the session
/// layer never mutates projected messages in place).
final class ResumedContextCache {
  /// Creates a cache holding at most [capacity] sessions (≥ 1).
  ResumedContextCache({int capacity = 4})
    : capacity = capacity < 1 ? 1 : capacity;

  /// Maximum number of sessions kept resident.
  final int capacity;

  final Map<String, _Entry> _entries = {};

  /// Number of cached sessions.
  int get length => _entries.length;

  /// The context built for [path] when the file still has exactly
  /// ([sizeBytes], [mtimeMs]) — the state it was built from. The returned
  /// context carries a fresh message list; the entry is refreshed as the
  /// most recently used. A stale probe does not evict the entry (the
  /// caller rebuilds and re-remembers over it).
  SessionContext? match(
    String path, {
    required int sizeBytes,
    required int mtimeMs,
  }) {
    final entry = _entries[path];
    if (entry == null) return null;
    if (entry.sizeBytes != sizeBytes || entry.mtimeMs != mtimeMs) {
      return null;
    }
    _entries.remove(path);
    _entries[path] = entry;
    return SessionContext(
      messages: List.of(entry.context.messages),
      thinkingLevel: entry.context.thinkingLevel,
      model: entry.context.model,
      activeToolNames: entry.context.activeToolNames == null
          ? null
          : List.of(entry.context.activeToolNames!),
    );
  }

  /// Remembers [context] as the build for [path] at the given fingerprint.
  void remember(
    String path, {
    required int sizeBytes,
    required int mtimeMs,
    required SessionContext context,
  }) {
    _entries.remove(path);
    _entries[path] = _Entry(
      sizeBytes: sizeBytes,
      mtimeMs: mtimeMs,
      context: context,
    );
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Drops every entry.
  void clear() => _entries.clear();
}
