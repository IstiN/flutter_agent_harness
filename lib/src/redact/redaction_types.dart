/// Core types for the layered redaction pipeline (issue #24, stage 1).
///
/// Everything under `lib/src/redact/` is pure synchronous Dart: no
/// `dart:io`, no Flutter imports, so the pipeline runs identically in the
/// CLI, the TUI, tests, and any other embedder.
library;

/// Redaction layers, listed in strict priority order.
///
/// When two layers report overlapping spans, the layer that comes first in
/// this order wins and the overlapping lower-priority span is discarded.
enum RedactionLayer {
  /// Exact registered secret values (injected into the pipeline).
  registered,

  /// Credential file paths and whole credential-file dumps (`.env`,
  /// `id_rsa`, `.aws/credentials`, ...).
  path,

  /// Known vendor token shapes (GitHub, AWS, OpenAI, JWT, ...).
  vendor,

  /// Fast `indexOf` pre-screen feeding [RedactionLayer.vendor]. Never emits
  /// spans of its own inside the pipeline; see `layerPrefix`.
  prefix,

  /// PEM / X.509 / OpenSSH / PGP armored blocks.
  pem,

  /// Standalone DER (ASN.1) base64 blobs starting with `MII`.
  asn1,

  /// Passwords embedded in connection URLs (`scheme://user:pass@host`).
  connection,

  /// Key/value context anchors (`password=`, `api_key:`, `export SECRET=`).
  context,

  /// Opt-in PII: email, phone, Luhn-valid card numbers, SSN, IBAN.
  pii,

  /// High-entropy token heuristic, evaluated last.
  entropy,
}

/// A single sensitive span reported by one redaction layer.
///
/// [start] is inclusive and [end] exclusive, so `text.substring(start, end)`
/// is the matched span.
final class RedactionMatch {
  /// Creates a match for the span `[start, end)` found by [layer].
  const RedactionMatch({
    required this.start,
    required this.end,
    required this.layer,
    required this.kindLabel,
  });

  /// Inclusive start offset of the sensitive span.
  final int start;

  /// Exclusive end offset of the sensitive span.
  final int end;

  /// The layer that produced this match.
  final RedactionLayer layer;

  /// Human-readable classification used in the `[REDACTED:<kindLabel>]`
  /// marker (e.g. `'GitHub Token'`, `'PEM PRIVATE KEY'`).
  final String kindLabel;

  /// Length of the matched span.
  int get length => end - start;

  /// Whether this span shares at least one character with [other].
  bool overlaps(RedactionMatch other) => start < other.end && other.start < end;

  /// Debug-friendly rendering: span, layer and label.
  @override
  String toString() =>
      'RedactionMatch($start..$end, ${layer.name}, $kindLabel)';
}

/// Immutable configuration for the redaction pipeline.
///
/// Layer toggles are sparse: a layer missing from [layerToggles] falls back
/// to its default state (enabled, except [RedactionLayer.pii] which is
/// opt-in).
final class RedactionConfig {
  /// Creates a configuration; see each field for its default.
  const RedactionConfig({
    this.enabled = true,
    this.blockMode = false,
    this.layerToggles = const {},
    this.allowlistRegexes = const [],
    this.minEntropy = 4.5,
    this.minLength = 32,
  });

  /// Master switch: when `false` the pipeline is a pass-through.
  final bool enabled;

  /// Reserved for the stage-2 hook wiring: when `true` the hook layer must
  /// fail closed (block the tool call) if redaction itself errors. Stage 1
  /// only carries the flag.
  final bool blockMode;

  /// Sparse per-layer overrides over the default toggle states.
  final Map<RedactionLayer, bool> layerToggles;

  /// Matches fully covering a redaction span suppress that span (all
  /// layers). Git SHAs and UUIDs survive via this list.
  final List<RegExp> allowlistRegexes;

  /// Minimum Shannon entropy (bits/char) for the entropy layer.
  final double minEntropy;

  /// Minimum token length for the entropy layer.
  final int minLength;

  /// Whether [layer] is active under this configuration.
  bool isLayerEnabled(RedactionLayer layer) =>
      layerToggles[layer] ?? (layer != RedactionLayer.pii);

  /// Restores a configuration written by [toJson]; tolerates `null` values
  /// and unknown/invalid keys by ignoring them and falling back to defaults.
  factory RedactionConfig.fromJson(Map<dynamic, dynamic>? json) {
    if (json == null) return const RedactionConfig();
    final toggles = <RedactionLayer, bool>{};
    final rawLayers = json['layers'];
    if (rawLayers is Map) {
      rawLayers.forEach((key, value) {
        if (key is! String || value is! bool) return;
        for (final layer in RedactionLayer.values) {
          if (layer.name == key) toggles[layer] = value;
        }
      });
    }
    final allowlist = <RegExp>[];
    final rawAllowlist = json['allowlist'];
    if (rawAllowlist is List) {
      for (final entry in rawAllowlist) {
        if (entry is String) allowlist.add(RegExp(entry));
      }
    }
    return RedactionConfig(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      blockMode: json['blockMode'] is bool ? json['blockMode'] as bool : false,
      layerToggles: toggles,
      allowlistRegexes: allowlist,
      minEntropy: json['minEntropy'] is num
          ? (json['minEntropy'] as num).toDouble()
          : 4.5,
      minLength: json['minLength'] is num
          ? (json['minLength'] as num).toInt()
          : 32,
    );
  }

  /// Serializes this configuration to a JSON-encodable map.
  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'blockMode': blockMode,
    'layers': <String, bool>{
      for (final entry in layerToggles.entries) entry.key.name: entry.value,
    },
    'allowlist': <String>[for (final r in allowlistRegexes) r.pattern],
    'minEntropy': minEntropy,
    'minLength': minLength,
  };

  @override
  bool operator ==(Object other) =>
      other is RedactionConfig &&
      !_scalarsDiffer(this, other) &&
      !_allowlistDiffers(this, other) &&
      !_togglesDiffer(this, other);

  @override
  int get hashCode => Object.hash(
    enabled,
    blockMode,
    minEntropy,
    minLength,
    Object.hashAll(allowlistRegexes.map((r) => r.pattern)),
    Object.hashAll([
      for (final entry in layerToggles.entries) ...[entry.key, entry.value],
    ]),
  );
}

/// Field comparison helpers keeping [RedactionConfig.==] simple.
bool _scalarsDiffer(RedactionConfig a, RedactionConfig b) =>
    a.enabled != b.enabled ||
    a.blockMode != b.blockMode ||
    a.minEntropy != b.minEntropy ||
    a.minLength != b.minLength;

bool _allowlistDiffers(RedactionConfig a, RedactionConfig b) {
  if (a.allowlistRegexes.length != b.allowlistRegexes.length) return true;
  for (var i = 0; i < a.allowlistRegexes.length; i++) {
    if (a.allowlistRegexes[i].pattern != b.allowlistRegexes[i].pattern) {
      return true;
    }
  }
  return false;
}

bool _togglesDiffer(RedactionConfig a, RedactionConfig b) {
  if (a.layerToggles.length != b.layerToggles.length) return true;
  for (final entry in a.layerToggles.entries) {
    if (b.layerToggles[entry.key] != entry.value) return true;
  }
  return false;
}
