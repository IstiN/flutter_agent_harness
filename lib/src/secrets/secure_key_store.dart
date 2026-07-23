/// Platform secure storage for API keys (OS keychains) with a synchronous
/// session cache.
///
/// [SecureKeyStore] abstracts the host's secure enclave — macOS Keychain,
/// freedesktop Secret Service (gnome-keyring/KWallet via `secret-tool`), or
/// the Windows Credential Locker. The platform implementations live in
/// `secure_key_store_io.dart` (`dart:io`, exported only from `lib/io.dart`);
/// this file stays pure Dart so the CLI core compiles for web.
///
/// Keychain reads spawn helper processes and are therefore async, while the
/// CLI's key lookups (`AgentCliConfig.envVarValue`/`envVarIsSet`, the roles
/// secrets snapshot) are synchronous — [SecureKeyCache] bridges that gap:
/// the host preloads the names it cares about once at startup and all later
/// reads hit the in-memory snapshot. Writes go through to the store and
/// update the snapshot atomically.
library;

/// A platform secure enclave for secrets, addressed by name.
abstract interface class SecureKeyStore {
  /// A short human label for messages (e.g. `macOS Keychain`).
  String get label;

  /// Whether the backend is usable on this host (helper binary present, a
  /// Secret Service provider on the session bus, ...). False means the host
  /// falls back to environment-only keys — never an error.
  Future<bool> isAvailable();

  /// Returns the stored value for [name], or null when absent.
  Future<String?> read(String name);

  /// Stores [value] under [name], replacing any existing entry.
  Future<void> write(String name, String value);

  /// Removes [name] (no-op when absent).
  Future<void> delete(String name);
}

/// A synchronous, session-scoped snapshot over a [SecureKeyStore].
///
/// `null` stores (web hosts, tests) are supported: [available] is then false
/// and every read misses, so callers need no null checks beyond [available].
final class SecureKeyCache {
  /// Creates a cache over [store] (may be null → always unavailable).
  SecureKeyCache(this._store);

  final SecureKeyStore? _store;
  final Map<String, String> _snapshot = {};
  var _available = false;

  /// The backing store's label (for messages), or null when there is none.
  String? get label => _store?.label;

  /// Whether the platform store answered the availability probe (run by
  /// [preload] or [probe]).
  bool get available => _available;

  /// Probes availability without loading anything. Idempotent.
  Future<bool> probe() async {
    final store = _store;
    if (store == null) return false;
    try {
      _available = await store.isAvailable();
    } on Object {
      _available = false;
    }
    return _available;
  }

  /// Probes the store and, when available, loads [names] into the snapshot
  /// (parallel reads; individual misses/errors simply stay absent — a
  /// keychain must never break startup).
  Future<void> preload(Iterable<String> names) async {
    if (!await probe()) return;
    final store = _store!;
    await Future.wait(
      names.toSet().map((name) async {
        try {
          final value = await store.read(name);
          if (value != null && value.isNotEmpty) _snapshot[name] = value;
        } on Object {
          // A single unreadable entry must not fail the whole preload.
        }
      }),
    );
  }

  /// Synchronous read from the snapshot (null when absent).
  String? read(String name) => _snapshot[name];

  /// The names currently held in the snapshot.
  Iterable<String> get names => _snapshot.keys;

  /// Writes [value] through to the store and updates the snapshot. Returns
  /// false when the store is unavailable OR the write fails (locked or
  /// MDM-managed keychain, missing Secret Service provider) — a failing
  /// backend must degrade to session-only, never crash the CLI.
  Future<bool> save(String name, String value) async {
    if (!available) return false;
    try {
      await _store!.write(name, value);
    } on Object {
      return false;
    }
    _snapshot[name] = value;
    return true;
  }

  /// Deletes [name] from the store and the snapshot. Returns false when the
  /// store is unavailable or the delete fails; deleting an absent name is a
  /// no-op.
  Future<bool> delete(String name) async {
    if (!available) return false;
    try {
      await _store!.delete(name);
    } on Object {
      return false;
    }
    _snapshot.remove(name);
    return true;
  }
}
