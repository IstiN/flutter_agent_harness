// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Persistence backend for the web sandbox filesystem.
///
/// The web sandbox keeps its whole filesystem in memory (see
/// [MemoryExecutionEnv]); `PersistentWebExecutionEnv` serializes the tree
/// and hands records to an [FsRecordStore] for durable storage. The store
/// is a flat string key→value surface (issue #237, mirroring the extension
/// fix in #228/#236): one record holds the versioned JSON envelope of the
/// non-session tree, and every session file is its OWN record, so an
/// oversized session fails alone instead of taking unrelated data down
/// with it (quota isolation), and old-key cleanup can never drop live
/// session data. The browser implementation lives in
/// `fs_persistence_web.dart` (IndexedDB — binary-safe and quota-based,
/// unlike the ~5 MB string-only localStorage); everywhere else the store
/// is in-memory only (see `fs_persistence_stub.dart`).
abstract interface class FsRecordStore {
  /// Every stored record, keyed by storage key.
  ///
  /// Implementations may throw when storage is unavailable (e.g. blocked
  /// cookies); the caller treats that as "no snapshot" and starts clean.
  Future<Map<String, String>> loadAll();

  /// Persists [value] under [key], replacing any previous record.
  ///
  /// May throw (e.g. quota exceeded); the caller keeps the failed record
  /// dirty and retries on the next mutation.
  Future<void> save(String key, String value);

  /// Removes [keys]; missing keys are ignored.
  Future<void> remove(List<String> keys);
}

/// In-memory [FsRecordStore]: the non-web fallback and the host-test fake.
final class InMemoryFsRecordStore implements FsRecordStore {
  /// Creates an in-memory store. [quotaBytes] (test hook) caps the total
  /// stored payload: a [save] that would exceed it throws, like IndexedDB
  /// does under the per-origin quota.
  InMemoryFsRecordStore({int? quotaBytes}) : _quotaBytes = quotaBytes;

  final int? _quotaBytes;

  final Map<String, String> _records = {};

  /// How many times [save] completed (test observability).
  int saveCount = 0;

  /// How many times [remove] completed (test observability).
  int removeCount = 0;

  @override
  Future<Map<String, String>> loadAll() async => Map.of(_records);

  @override
  Future<void> save(String key, String value) async {
    final quota = _quotaBytes;
    if (quota != null) {
      final projected = _storedBytes() -
          (_records[key]?.length ?? 0) -
          key.length +
          key.length +
          value.length;
      if (projected > quota) {
        throw StateError('quota exceeded ($projected > $quota bytes)');
      }
    }
    _records[key] = value;
    saveCount++;
  }

  @override
  Future<void> remove(List<String> keys) async {
    for (final key in keys) {
      _records.remove(key);
    }
    removeCount++;
  }

  int _storedBytes() {
    var total = 0;
    for (final entry in _records.entries) {
      total += entry.key.length + entry.value.length;
    }
    return total;
  }

  /// Test hook: plants [raw] under [key] (e.g. a corrupt envelope).
  void seed(String key, String raw) => _records[key] = raw;
}
