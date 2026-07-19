/// Round-robin rotation over stacked API keys with per-credential backoff
/// and session affinity.
///
/// Ported (reduced) from oh-my-pi's credential switching in
/// `agent-session.ts` (`markUsageLimitReached`, sibling-credential wait) and
/// the account rotation sketched in `docs/providers.md`. omp rotates OAuth
/// accounts through its auth storage; here the stack is simpler: multiple
/// keys per provider live in a [SecretsStore]-shaped map under a base name
/// (`OPENAI_API_KEY`, `OPENAI_API_KEY_2`, `OPENAI_API_KEY_3`, ...).
///
/// Semantics:
///
/// - **Round-robin**: each new ring starts one slot past the previous ring
///   for the same base name, so consecutive sessions spread over the stack
///   instead of hammering the first key.
/// - **Session affinity**: a ring keeps handing out its current key
///   ([currentKey]) until that key is reported rate-limited; requests within
///   a run therefore share one credential.
/// - **Per-key backoff**: [reportRateLimited] benches the failing key until
///   its backoff expires; [currentKey]/[rotate] skip keys still in backoff.
library;

/// One credential in an [ApiKeyRing]: its secrets-store [name] and secret
/// [value]. The value must never be logged or sent to the model.
final class ApiKeyCredential {
  /// Creates a credential pair.
  const ApiKeyCredential(this.name, this.value);

  /// The secrets-store name (e.g. `OPENAI_API_KEY_2`).
  final String name;

  /// The secret value.
  final String value;
}

/// Collects a key stack for [baseName] from [secrets]: the bare name first,
/// then `_2`, `_3`, ... in numeric order. Returns an empty list when the
/// base name is absent.
List<ApiKeyCredential> collectKeyStack(
  Map<String, String> secrets,
  String baseName,
) {
  final suffixPattern = RegExp('^${RegExp.escape(baseName)}_(\\d+)\$');
  final numbered = <int, String>{};
  for (final entry in secrets.entries) {
    final match = suffixPattern.firstMatch(entry.key);
    if (match != null && entry.value.isNotEmpty) {
      numbered[int.parse(match[1]!)] = entry.value;
    }
  }
  final stack = <ApiKeyCredential>[];
  final base = secrets[baseName];
  if (base != null && base.isNotEmpty) {
    stack.add(ApiKeyCredential(baseName, base));
  }
  for (final index in numbered.keys.toList()..sort()) {
    stack.add(ApiKeyCredential('${baseName}_$index', numbered[index]!));
  }
  return stack;
}

/// A rotating view over one provider's API-key stack.
///
/// Not synchronized: the harness drives agents single-threaded per run, and
/// backoff timestamps make cross-run sharing benign.
final class ApiKeyRing {
  /// Creates a ring over [credentials] (must be non-empty), starting at a
  /// round-robin offset for [baseName] unless [startIndex] pins one (tests).
  ApiKeyRing({
    required this.baseName,
    required List<ApiKeyCredential> credentials,
    int? startIndex,
    DateTime Function()? now,
  }) : _credentials = List.unmodifiable(credentials),
       _now = now ?? DateTime.now {
    if (credentials.isEmpty) {
      throw ArgumentError.value(
        credentials,
        'credentials',
        'an API key ring needs at least one credential',
      );
    }
    _index = (startIndex ?? _nextStartOffset(baseName)) % _credentials.length;
  }

  /// Builds a ring from [secrets] for [baseName]; returns `null` when the
  /// stack is empty (no key configured).
  static ApiKeyRing? fromSecrets(
    Map<String, String> secrets,
    String baseName, {
    int? startIndex,
    DateTime Function()? now,
  }) {
    final stack = collectKeyStack(secrets, baseName);
    if (stack.isEmpty) return null;
    return ApiKeyRing(
      baseName: baseName,
      credentials: stack,
      startIndex: startIndex,
      now: now,
    );
  }

  static final _startOffsets = <String, int>{};

  /// Per-base-name round-robin sequence: each new ring starts one slot later.
  static int _nextStartOffset(String baseName) {
    final offset = _startOffsets[baseName] ?? 0;
    _startOffsets[baseName] = offset + 1;
    return offset;
  }

  /// The secrets-store base name this ring rotates (e.g. `OPENAI_API_KEY`).
  final String baseName;

  final List<ApiKeyCredential> _credentials;
  final DateTime Function() _now;
  final _backoffUntil = <String, DateTime>{};

  var _index = 0;

  /// The number of credentials in the stack.
  int get length => _credentials.length;

  /// The credential at the current position, ignoring backoff.
  ApiKeyCredential get currentCredential => _credentials[_index];

  /// The affinity credential: the current position unless it is in backoff,
  /// in which case the next non-benched credential (round-robin order).
  /// `null` when every credential is benched.
  ApiKeyCredential? get availableCredential {
    for (var step = 0; step < _credentials.length; step++) {
      final candidate = _credentials[(_index + step) % _credentials.length];
      if (!isInBackoff(candidate.name)) {
        _index = (_index + step) % _credentials.length;
        return candidate;
      }
    }
    return null;
  }

  /// Whether [name] is benched right now.
  bool isInBackoff(String name) {
    final until = _backoffUntil[name];
    if (until == null) return false;
    if (_now().isBefore(until)) return true;
    _backoffUntil.remove(name);
    return false;
  }

  /// The earliest moment any benched credential frees up, or `null` when no
  /// credential is in backoff. Used to wait out a fully benched stack (omp's
  /// sibling-credential wait).
  DateTime? get earliestBackoffEnd {
    DateTime? earliest;
    for (final name in _backoffUntil.keys.toList()) {
      if (!isInBackoff(name)) continue;
      final until = _backoffUntil[name]!;
      if (earliest == null || until.isBefore(earliest)) earliest = until;
    }
    return earliest;
  }

  /// Benches the credential [name] for [backoff] from now.
  void reportRateLimited(String name, Duration backoff) {
    _backoffUntil[name] = _now().add(backoff);
  }

  /// Advances the affinity position past [from] to the next non-benched
  /// credential (round-robin), returning it; `null` when all are benched.
  ApiKeyCredential? rotate(String from) {
    final fromIndex = _credentials.indexWhere((c) => c.name == from);
    final start = fromIndex == -1 ? _index : fromIndex;
    for (var step = 1; step <= _credentials.length; step++) {
      final next = (start + step) % _credentials.length;
      final candidate = _credentials[next];
      if (!isInBackoff(candidate.name)) {
        _index = next;
        return candidate;
      }
    }
    return null;
  }

  /// Advances the affinity position to [credential] (session affinity: a
  /// switched key stays current until it fails).
  void stickTo(ApiKeyCredential credential) {
    final index = _credentials.indexWhere((c) => c.name == credential.name);
    if (index != -1) _index = index;
  }
}
