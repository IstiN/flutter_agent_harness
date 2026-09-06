/// Trust records for JS extensions: provenance, content hash, capability
/// snapshot, grant time, and the prompt request rendered for the user.
library;

/// Where a trusted extension came from.
enum ExtTrustSource {
  /// The extension catalog (`sourceRef` = `<catalogId>`).
  catalog,

  /// A GitHub repo (`sourceRef` = `owner/repo@<gitSha|branch>`).
  github,

  /// A local directory (`sourceRef` = absolute path).
  local,

  /// Shipped with the harness (`sourceRef` = `bundled`).
  bundled,
}

/// A user-granted trust decision for one extension content hash.
final class TrustRecord {
  /// Where the extension came from.
  final ExtTrustSource source;

  /// Source-specific provenance string (see [ExtTrustSource]).
  final String sourceRef;

  /// sha256 hex (see `extContentHash`) of the content trust was granted to.
  final String contentSha256;

  /// `manifest.capabilities.toJson()` snapshot at grant time; a capability
  /// diff on update triggers a re-prompt (hash-only change does not).
  final Map<String, dynamic> capabilities;

  /// When trust was granted (UTC).
  final DateTime grantedAt;

  /// Creates a trust record.
  TrustRecord({
    required this.source,
    required this.sourceRef,
    required this.contentSha256,
    required this.capabilities,
    required this.grantedAt,
  });

  /// Strict parse; throws [FormatException] describing the first bad field.
  factory TrustRecord.fromJson(Map<String, dynamic> json) {
    final sourceValue = json['source'];
    if (sourceValue is! String) {
      throw const FormatException('trust source must be a string');
    }
    final source = ExtTrustSource.values.asNameMap()[sourceValue];
    if (source == null) {
      throw FormatException('unknown trust source: $sourceValue');
    }
    final sourceRef = json['sourceRef'];
    if (sourceRef is! String) {
      throw const FormatException('trust sourceRef must be a string');
    }
    final contentSha256 = json['contentSha256'];
    if (contentSha256 is! String) {
      throw const FormatException('trust contentSha256 must be a string');
    }
    final capabilities = json['capabilities'];
    if (capabilities is! Map<String, dynamic>) {
      throw const FormatException('trust capabilities must be an object');
    }
    final grantedAtValue = json['grantedAt'];
    if (grantedAtValue is! String) {
      throw const FormatException('trust grantedAt must be an ISO-8601 string');
    }
    final grantedAt = DateTime.tryParse(grantedAtValue);
    if (grantedAt == null) {
      throw FormatException('invalid trust grantedAt: $grantedAtValue');
    }
    return TrustRecord(
      source: source,
      sourceRef: sourceRef,
      contentSha256: contentSha256,
      capabilities: capabilities,
      grantedAt: grantedAt.toUtc(),
    );
  }

  /// Serializes with a UTC ISO-8601 `grantedAt` timestamp.
  Map<String, dynamic> toJson() => {
    'source': source.name,
    'sourceRef': sourceRef,
    'contentSha256': contentSha256,
    'capabilities': capabilities,
    'grantedAt': grantedAt.toUtc().toIso8601String(),
  };

  /// Equality on (source, sourceRef, contentSha256, capabilities) —
  /// `grantedAt` is deliberately excluded (re-grants compare content, not
  /// time).
  @override
  bool operator ==(Object other) =>
      other is TrustRecord &&
      other.source == source &&
      other.sourceRef == sourceRef &&
      other.contentSha256 == contentSha256 &&
      extCapabilitiesEqual(other.capabilities, capabilities);

  @override
  int get hashCode => Object.hash(source, sourceRef, contentSha256);
}

/// Deep equality of two capability-snapshot maps, ignoring key ORDER (and
/// recursive through nested maps; list ELEMENT order is significant).
bool extCapabilitiesEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key)) return false;
    if (!_deepValueEqual(a[key], b[key])) return false;
  }
  return true;
}

bool _deepValueEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) return _deepMapEqual(a, b);
  if (a is List && b is List) return _deepListEqual(a, b);
  return a == b;
}

bool _deepMapEqual(Map a, Map b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || !_deepValueEqual(a[key], b[key])) return false;
  }
  return true;
}

bool _deepListEqual(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_deepValueEqual(a[i], b[i])) return false;
  }
  return true;
}

/// What a trust prompt renders: the extension identity, its content hash, the
/// requested capability snapshot, and (on updates) the previously granted one
/// when the diff is what triggered the re-prompt.
final class ExtTrustRequest {
  /// Extension name.
  final String name;

  /// Where the extension came from.
  final ExtTrustSource source;

  /// Source-specific provenance string.
  final String sourceRef;

  /// Content hash about to be trusted.
  final String contentSha256;

  /// Requested capability snapshot.
  final Map<String, dynamic> capabilities;

  /// Previously granted snapshot; non-null on UPDATE when the capability diff
  /// is the reason for the re-prompt.
  final Map<String, dynamic>? previousCapabilities;

  /// Creates a trust request.
  ExtTrustRequest({
    required this.name,
    required this.source,
    required this.sourceRef,
    required this.contentSha256,
    required this.capabilities,
    this.previousCapabilities,
  });

  /// One plain-language line per declared capability, in grant-relevant order
  /// (exec, fs, hooks, network, keys, tools, menus).
  List<String> humanSummary() {
    final lines = <String>[];
    final allowed = capabilities['allowedCommands'];
    if (allowed is List &&
        allowed.isNotEmpty &&
        allowed.every((entry) => entry is String)) {
      lines.add('exec: run only: ${allowed.join(', ')}');
    }
    if (capabilities['fs'] == true) {
      lines.add('fs: read project files');
    }
    final hooks = capabilities['hooks'];
    if (hooks is List && hooks.isNotEmpty) {
      lines.add('hooks: ${hooks.join(', ')}');
    }
    if (capabilities['network'] == true) {
      lines.add('network: make network requests');
    }
    if (capabilities['keys'] == true) {
      lines.add('keys: request access to stored keys by name');
    }
    if (capabilities['tools'] == true) {
      lines.add('tools: register agent tools');
    }
    if (capabilities['menus'] == true) {
      lines.add('menus: register provider flows');
    }
    return lines;
  }
}

/// User decision callback for a [ExtTrustRequest]; returning false (or a null
/// prompt) denies — the extension stays in tombstone state.
typedef ExtTrustPrompt = Future<bool> Function(ExtTrustRequest request);
