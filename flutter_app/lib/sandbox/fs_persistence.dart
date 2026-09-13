// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Persistence backend for the web sandbox filesystem.
///
/// The web sandbox keeps its whole filesystem in memory (see
/// [MemoryExecutionEnv]); `PersistentWebExecutionEnv` serializes the tree to
/// a versioned JSON envelope and hands it to an [FsSnapshotStore] for
/// durable storage. The browser implementation lives in
/// `fs_persistence_web.dart` (IndexedDB — binary-safe and quota-based,
/// unlike the ~5 MB string-only localStorage); everywhere else the store is
/// in-memory only (see `fs_persistence_stub.dart`).
///
/// The store is a flat record map, not one opaque blob (issue #237): the
/// envelope rides its own key and every session file gets its own record,
/// so an oversized or torn write damages one record instead of the whole
/// history.
abstract interface class FsSnapshotStore {
  /// All stored records, or an empty map when none were saved yet.
  ///
  /// Implementations may throw when storage is unavailable (e.g. blocked
  /// cookies); the caller treats that as "no snapshot" and starts clean.
  Future<Map<String, String>> load();

  /// Upserts [records], replacing any previously stored values for the
  /// same keys. One atomic storage write per call.
  Future<void> save(Map<String, String> records);

  /// Removes [keys] — stale session records whose files left the tree.
  Future<void> remove(Iterable<String> keys);
}

/// In-memory [FsSnapshotStore]: the non-web fallback and the host-test fake.
final class InMemoryFsSnapshotStore implements FsSnapshotStore {
  final Map<String, String> _records = {};

  /// How many times [save] completed (test observability).
  int saveCount = 0;

  /// Test observability: the records as last written.
  Map<String, String> get records => Map.unmodifiable(_records);

  @override
  Future<Map<String, String>> load() async => Map.of(_records);

  @override
  Future<void> save(Map<String, String> records) async {
    _records.addAll(records);
    saveCount++;
  }

  @override
  Future<void> remove(Iterable<String> keys) async {
    for (final key in keys) {
      _records.remove(key);
    }
  }

  /// Test hook: plants [records] as the stored data (e.g. a corrupt or
  /// older-version envelope to recover from).
  void seed(Map<String, String> records) => _records.addAll(records);
}
