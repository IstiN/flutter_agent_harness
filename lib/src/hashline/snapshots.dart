/// Per-session snapshot store used by the hashline patcher to bind section
/// tags to the exact file content that minted them, ported from oh-my-pi
/// `packages/hashline/src/snapshots.ts` (`InMemorySnapshotStore`).
///
/// A section tag is a content-derived hash of the *whole file* (see
/// [computeFileHash]). Any read of byte-identical content mints the same
/// tag, so reads of one file state fuse onto one anchor and a follow-up edit
/// anchored at any line validates whenever the live file still hashes to it.
///
/// Producers (the `read` tool in hashline mode, the `edit` tool after a
/// successful apply) call [HashlineSnapshotStore.record] with the full
/// normalized text they observed. The store hashes it, dedups against the
/// per-path history, and returns the tag. Consumers (the patcher) resolve a
/// stale tag back to the recorded full text.
library;

// Public named parameters assigning to private fields: initializing formals
// would force private parameter names onto the public API.
// ignore_for_file: prefer_initializing_formals

import 'format.dart';

/// One full-file version observed at a point in time. The tag the model sees
/// is [hash]; diagnostics replay against [text].
final class HashlineSnapshot {
  /// Creates a snapshot; prefer [HashlineSnapshotStore.record].
  HashlineSnapshot({
    required this.path,
    required this.text,
    required this.hash,
    required this.recordedAt,
  });

  /// Canonical path this version belongs to.
  final String path;

  /// Full normalized (LF, no BOM) file text as observed.
  final String text;

  /// Content-derived tag for [text] (see [computeFileHash]).
  final String hash;

  /// Timestamp (ms since epoch) the version was recorded or last re-seen.
  int recordedAt;

  /// 1-indexed file lines a producer actually *displayed* under this tag. A
  /// partial read (offset/limit, or a truncated prefix) leaves this sparse;
  /// a whole-file read fills every line. Multiple reads of the same content
  /// union into one set. `null` means "no provenance recorded" — the patcher
  /// then skips the seen-line check and applies as before. Mutated in place
  /// as more of the same content is read.
  Set<int>? seenLines;
}

const _defaultMaxPaths = 30;
const _defaultMaxVersionsPerPath = 4;

/// Global ceiling on retained snapshot text across all paths (UTF-16 code
/// units).
const _defaultMaxTotalBytes = 64 * 1024 * 1024;

/// Unions [lines] into `snapshot.seenLines`, lazily creating the set.
void _mergeSeenLines(HashlineSnapshot snapshot, Iterable<int>? lines) {
  if (lines == null) return;
  final seen = snapshot.seenLines ??= <int>{};
  seen.addAll(lines);
}

/// In-memory snapshot store: a bounded set of paths, each with a short
/// history of full-file versions so in-session edit chains can still recover
/// against the version a stale tag names.
///
/// Recording byte-identical content again refreshes recency and reuses the
/// existing tag (read fusion); recording new content unshifts a fresh
/// version onto the front of the path history. Two distinct texts that
/// collide on the short 4-hex tag are retained as separate versions so
/// callers can still tell them apart via [HashlineSnapshot.text] — the tag
/// is only a fast index, never the identity (omp issue #4075).
final class HashlineSnapshotStore {
  /// Creates a store with the given bounds.
  HashlineSnapshotStore({
    int maxPaths = _defaultMaxPaths,
    int maxVersionsPerPath = _defaultMaxVersionsPerPath,
    int maxTotalBytes = _defaultMaxTotalBytes,
  }) : _maxPaths = maxPaths,
       _maxVersionsPerPath = maxVersionsPerPath,
       _maxTotalBytes = maxTotalBytes;

  /// Path histories ordered least-recently-used first. A path "use" (read or
  /// write) re-inserts it at the end.
  final _LruPathMap _versions = _LruPathMap();
  final int _maxPaths;
  final int _maxVersionsPerPath;
  final int _maxTotalBytes;

  /// Most-recently recorded version for [path], or `null` if none.
  HashlineSnapshot? head(String path) {
    final history = _versions.get(path);
    return history == null || history.isEmpty ? null : history.first;
  }

  /// Recorded version for [path] whose tag equals [hash], or `null`. When
  /// two distinct texts collide on the 16-bit tag, returns the
  /// most-recently recorded one (histories are newest-first).
  HashlineSnapshot? byHash(String path, String hash) {
    final history = _versions.get(path);
    if (history == null) return null;
    for (final version in history) {
      if (version.hash == hash) return version;
    }
    return null;
  }

  /// Recorded version for [path] whose text equals [fullText], or `null`.
  /// The patcher uses it on the no-drift path to attach seen-line provenance
  /// to the exact text the model read.
  HashlineSnapshot? byContent(String path, String fullText) {
    final history = _versions.get(path);
    if (history == null) return null;
    for (final version in history) {
      if (version.text == fullText) return version;
    }
    return null;
  }

  /// Every retained version whose tag equals [hash], across all tracked
  /// paths. The patcher uses this to recover the intended file when a
  /// section names a path that does not exist on disk but carries a tag the
  /// store minted.
  List<HashlineSnapshot> findByHash(String hash) {
    final matches = <HashlineSnapshot>[];
    _versions.forEachValue((history) {
      for (final version in history) {
        if (version.hash == hash) matches.add(version);
      }
    });
    return matches;
  }

  /// Records the full normalized text of [path] and returns its content tag.
  /// [seenLines] (optional) are the 1-indexed lines the producer displayed;
  /// they merge into [HashlineSnapshot.seenLines] across reads of identical
  /// text.
  String record(String path, String fullText, [Iterable<int>? seenLines]) {
    final hash = computeFileHash(fullText);
    final history = _versions.get(path) ?? <HashlineSnapshot>[];
    // Dedup requires full-text equality, not just tag equality: two distinct
    // texts that happen to share the 4-hex tag are DIFFERENT snapshots —
    // fusing them under one entry would corrupt seenLines (attaching lines
    // from text B onto the stored text A) and let the patcher misresolve
    // which snapshot the section tag names (omp issue #4075).
    HashlineSnapshot? existing;
    for (final version in history) {
      if (version.hash == hash && version.text == fullText) {
        existing = version;
        break;
      }
    }
    if (existing != null) {
      // Same content state observed again: refresh recency and promote to
      // head (it is the current file content), then reuse the tag. Union
      // any newly-displayed lines so re-reading more of the file widens
      // coverage.
      existing.recordedAt = DateTime.now().millisecondsSinceEpoch;
      _mergeSeenLines(existing, seenLines);
      if (history.first != existing) {
        history
          ..remove(existing)
          ..insert(0, existing);
      }
      _versions.set(path, history);
      _evictIfNeeded();
      return hash;
    }

    final snapshot = HashlineSnapshot(
      path: path,
      text: fullText,
      hash: hash,
      recordedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _mergeSeenLines(snapshot, seenLines);
    history.insert(0, snapshot);
    if (history.length > _maxVersionsPerPath) {
      history.removeRange(_maxVersionsPerPath, history.length);
    }
    _versions.set(path, history);
    _evictIfNeeded();
    return hash;
  }

  /// Merges [lines] into the seen-lines of the version of [path] whose tag
  /// equals [hash]. No-op when no such version is retained.
  void recordSeenLines(String path, String hash, Iterable<int> lines) {
    final version = byHash(path, hash);
    if (version != null) _mergeSeenLines(version, lines);
  }

  /// Drops the version history for a single path.
  void invalidate(String path) {
    _versions.remove(path);
  }

  /// Moves retained version history (and read provenance) from [from] to
  /// [to]. No-op when [from] has no history.
  void relocate(String from, String to) {
    final sourceHistory = _versions.get(from);
    if (sourceHistory == null || sourceHistory.isEmpty) return;
    final relocated = [
      for (final version in sourceHistory)
        HashlineSnapshot(
            path: to,
            text: version.text,
            hash: version.hash,
            recordedAt: version.recordedAt,
          )
          ..seenLines = version.seenLines == null
              ? null
              : Set.of(version.seenLines!),
    ];
    final destHistory = _versions.get(to);
    if (destHistory == null) {
      _versions.set(to, relocated);
    } else {
      final seen = <String>{};
      final merged = <HashlineSnapshot>[];
      for (final version in [...relocated, ...destHistory]) {
        if (!seen.add(version.hash)) continue;
        merged.add(version);
      }
      if (merged.length > _maxVersionsPerPath) {
        merged.removeRange(_maxVersionsPerPath, merged.length);
      }
      _versions.set(to, merged);
    }
    _versions.remove(from);
    _evictIfNeeded();
  }

  /// Drops every version history.
  void clear() {
    _versions.clear();
  }

  int _historySize(List<HashlineSnapshot> history) {
    var total = 1;
    for (final version in history) {
      total += version.text.length;
    }
    return total;
  }

  void _evictIfNeeded() {
    while (_versions.length > _maxPaths) {
      _versions.removeFirst();
    }
    while (true) {
      var total = 0;
      _versions.forEachValue((history) {
        total += _historySize(history);
      });
      if (total <= _maxTotalBytes || _versions.isEmpty) return;
      _versions.removeFirst();
    }
  }
}

/// A tiny insertion-ordered map with LRU touch semantics on [get]/[set] —
/// the slice of `LinkedHashMap` + lru-cache behavior the store needs.
/// Iteration order is least-recently-used first.
final class _LruPathMap {
  final Map<String, List<HashlineSnapshot>> _map = {};

  /// Number of tracked paths.
  int get length => _map.length;

  /// Whether no paths are tracked.
  bool get isEmpty => _map.isEmpty;

  /// Looks up [key] and marks it most-recently used.
  List<HashlineSnapshot>? get(String key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value;
    return value;
  }

  /// Sets [key] to [value] and marks it most-recently used.
  void set(String key, List<HashlineSnapshot> value) {
    _map.remove(key);
    _map[key] = value;
  }

  /// Removes the least-recently used entry.
  void removeFirst() {
    if (_map.isEmpty) return;
    _map.remove(_map.keys.first);
  }

  /// Removes [key] without affecting the order of the rest.
  void remove(String key) {
    _map.remove(key);
  }

  /// Removes every entry.
  void clear() {
    _map.clear();
  }

  /// Iterates values from least- to most-recently used. The callback must
  /// not mutate the map.
  void forEachValue(void Function(List<HashlineSnapshot> history) action) {
    for (final value in List.of(_map.values)) {
      action(value);
    }
  }
}
