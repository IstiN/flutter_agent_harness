// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Persistence backend for the web sandbox filesystem.
///
/// The web sandbox keeps its whole filesystem in memory (see
/// [MemoryExecutionEnv]); `PersistentWebExecutionEnv` serializes the tree to
/// a single versioned JSON snapshot and hands it to an [FsSnapshotStore] for
/// durable storage. The browser implementation lives in
/// `fs_persistence_web.dart` (IndexedDB — binary-safe and quota-based,
/// unlike the ~5 MB string-only localStorage); everywhere else the store is
/// in-memory only (see `fs_persistence_stub.dart`).
abstract interface class FsSnapshotStore {
  /// The stored snapshot, or `null` when none was saved yet.
  ///
  /// Implementations may throw when storage is unavailable (e.g. blocked
  /// cookies); the caller treats that as "no snapshot" and starts clean.
  Future<String?> load();

  /// Persists [snapshot], replacing any previously stored one.
  Future<void> save(String snapshot);
}

/// In-memory [FsSnapshotStore]: the non-web fallback and the host-test fake.
final class InMemoryFsSnapshotStore implements FsSnapshotStore {
  String? _snapshot;

  /// How many times [save] completed (test observability).
  int saveCount = 0;

  @override
  Future<String?> load() async => _snapshot;

  @override
  Future<void> save(String snapshot) async {
    _snapshot = snapshot;
    saveCount++;
  }

  /// Test hook: plants [raw] as the stored snapshot (e.g. corrupt data).
  void seed(String raw) => _snapshot = raw;
}
