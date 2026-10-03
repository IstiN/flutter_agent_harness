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

/// The classified outcome of one secure-store read (gh-1059 observability).
enum SecureKeyReadStatus { found, absent, error }

/// One preload read's classified result: [status] with the resolved
/// [value] (`found` only) or a one-line [error] diagnostic (`error` only).
///
/// The diagnostic carries the exit code / stderr tail / timeout note —
/// never the secret itself (reads print secrets to stdout, errors to
/// stderr).
final class SecureKeyReadOutcome {
  /// Creates an outcome; [value] and [error] are mutually exclusive.
  const SecureKeyReadOutcome(this.name, this.status, {this.value, this.error});

  /// The store name that was read.
  final String name;

  /// The classification.
  final SecureKeyReadStatus status;

  /// The resolved secret (`found` only; empty values read as `absent`).
  final String? value;

  /// A one-line backend diagnostic — exit code, stderr tail, timeout or
  /// validation note. Never contains the secret.
  final String? error;
}

/// Collapses a diagnostic to one log-safe line: trim → collapse internal
/// whitespace → keep the LAST 200 chars (failures announce themselves in
/// the tail). The ONE canonical collapse (gh-1059 review): both the
/// preload error paths and the platform runner's captured stderr go
/// through it, so boot diagnostics and helper diagnostics can never drift
/// apart (a diverged cap would truncate the two surfaces differently).
String secureKeyDiagnosticLine(String text) {
  final flat = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return flat.length > 200 ? flat.substring(flat.length - 200) : flat;
}

/// The summary of one [SecureKeyCache.preload] run. The executable turns
/// it into per-name debug lines and the zero-resolved boot warning — the
/// cache itself never prints (a keychain must never break startup, and
/// the pure core has no `dart:io`).
final class SecureKeyPreloadReport {
  /// Creates a report; [outcomes] is empty when the store was unavailable.
  const SecureKeyPreloadReport({
    required this.storeAvailable,
    required this.outcomes,
  });

  /// Whether the backend answered the availability probe. False means no
  /// read was attempted and [outcomes] is empty.
  final bool storeAvailable;

  /// One outcome per requested name (request order, deduped).
  final List<SecureKeyReadOutcome> outcomes;

  /// How many names resolved a value.
  int get foundCount =>
      outcomes.where((o) => o.status == SecureKeyReadStatus.found).length;

  /// How many names the store answered with a clean "not stored".
  int get absentCount =>
      outcomes.where((o) => o.status == SecureKeyReadStatus.absent).length;

  /// How many reads failed for a diagnosable reason (spawn failure, helper
  /// timeout, non-zero exit other than "item not found", invalid name).
  int get errorCount =>
      outcomes.where((o) => o.status == SecureKeyReadStatus.error).length;
}

/// Implemented by backends that can CLASSIFY a read miss (gh-1059): a
/// clean "not stored" vs a failure with a diagnostic. Optional capability —
/// [SecureKeyCache.preload] uses it when the store offers it and falls back
/// to plain [SecureKeyStore.read] otherwise.
abstract interface class SecureKeyDiagnostics {
  /// One classified read: `found` (with [SecureKeyReadOutcome.value]),
  /// `absent`, or `error` (with a one-line [SecureKeyReadOutcome.error]
  /// diagnostic — exit code / stderr tail / timeout — never the secret).
  /// Invalid names throw like [SecureKeyStore.read].
  Future<SecureKeyReadOutcome> readDetailed(String name);
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
  var _saveFailures = 0;
  String? _lastSaveError;

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
  ///
  /// Returns a [SecureKeyPreloadReport] classifying every requested name
  /// (`found` / `absent` / `error` + diagnostic) so the host can surface a
  /// boot where the config references store keys but none resolved, instead
  /// of the silent absence gh-1059 shipped with. Stores offering
  /// [SecureKeyDiagnostics] get the classification from the backend;
  /// plain stores (and thrown errors) degrade to absent / error outcomes.
  Future<SecureKeyPreloadReport> preload(Iterable<String> names) async {
    final requested = names.toSet().toList();
    if (!await probe()) {
      return SecureKeyPreloadReport(storeAvailable: false, outcomes: const []);
    }
    final store = _store!;
    final SecureKeyDiagnostics? diagnostics = store is SecureKeyDiagnostics
        ? store as SecureKeyDiagnostics
        : null;
    final outcomes = await Future.wait(
      requested.map((name) async {
        try {
          if (diagnostics != null) return await diagnostics.readDetailed(name);
          return await _plainOutcome(store, name);
        } on Object catch (error) {
          // A single unreadable entry must not fail the whole preload.
          return SecureKeyReadOutcome(
            name,
            SecureKeyReadStatus.error,
            error: secureKeyDiagnosticLine(error.toString()),
          );
        }
      }),
    );
    for (final outcome in outcomes) {
      final value = outcome.value;
      if (outcome.status == SecureKeyReadStatus.found &&
          value != null &&
          value.isNotEmpty) {
        _snapshot[outcome.name] = value;
      }
    }
    return SecureKeyPreloadReport(storeAvailable: true, outcomes: outcomes);
  }

  /// Synchronous read from the snapshot (null when absent).
  String? read(String name) => _snapshot[name];

  /// The names currently held in the snapshot.
  Iterable<String> get names => _snapshot.keys;

  /// How many save attempts degraded to session-only since process start
  /// (unavailable store or a failing write — gh-1059: the loud per-save
  /// print stays, and `/key` status names the degradations; saves happen
  /// after boot, so the boot summary deliberately does not cover them).
  int get saveFailures => _saveFailures;

  /// The last save degradation's diagnostic, when any.
  String? get lastSaveError => _lastSaveError;

  /// Writes [value] through to the store and updates the snapshot. Returns
  /// false when the store is unavailable OR the write fails (locked or
  /// MDM-managed keychain, missing Secret Service provider) — a failing
  /// backend must degrade to session-only, never crash the CLI.
  Future<bool> save(String name, String value) async {
    if (!available) {
      _recordSaveFailure('secure store unavailable');
      return false;
    }
    try {
      await _store!.write(name, value);
    } on Object catch (error) {
      _recordSaveFailure(secureKeyDiagnosticLine(error.toString()));
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

  /// Records a degraded save for the `/key` status summary (the per-save
  /// print at the call site stays).
  void _recordSaveFailure(String message) {
    _saveFailures++;
    _lastSaveError = message;
  }

  /// Classifies one read off a plain [SecureKeyStore] (no diagnostics
  /// capability): a non-empty value is `found`, everything else `absent`.
  Future<SecureKeyReadOutcome> _plainOutcome(
    SecureKeyStore store,
    String name,
  ) async {
    final value = await store.read(name);
    return value != null && value.isNotEmpty
        ? SecureKeyReadOutcome(name, SecureKeyReadStatus.found, value: value)
        : SecureKeyReadOutcome(name, SecureKeyReadStatus.absent);
  }
}
