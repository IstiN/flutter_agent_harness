// Hub persistence: channels registry and issued-secret hashes.
//
// The core serializes JSON; the bytes go through a [HubStore] so the pure
// Dart core never touches a filesystem. The io entry point provides an
// atomic (tmp + rename) file implementation; tests use [MemoryHubStore].

/// A single-document store (one instance per persisted file).
abstract interface class HubStore {
  /// The stored document, or null when absent/unreadable (first boot).
  Future<String?> read();

  /// Replaces the stored document. Implementations must be atomic
  /// (tmp + rename) where the medium allows.
  Future<void> write(String contents);
}

/// Volatile in-memory store — the default when no persistence is wired.
final class MemoryHubStore implements HubStore {
  String? _contents;

  /// The current snapshot (test introspection).
  String? get contents => _contents;

  @override
  Future<String?> read() async => _contents;

  @override
  Future<void> write(String contents) async => _contents = contents;
}
