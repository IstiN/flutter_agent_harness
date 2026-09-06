/// Layered redaction pipeline (issue #24, stage 1).
///
/// Eleven pure layers ([RedactionLayer]) scan text for sensitive spans; the
/// pipeline merges their findings by layer priority, suppresses
/// allowlisted spans, and rewrites the text by slice/concat so the output
/// is idempotent and line-count preserving. Everything here is pure
/// synchronous Dart — no `dart:io`, no Flutter.
///
/// Marker format: `[REDACTED:<kindLabel>]`, e.g. `[REDACTED:GitHub Token]`.
library;

import 'layer_asn1.dart';
import 'layer_connection.dart';
import 'layer_credential.dart';
import 'layer_context.dart';
import 'layer_entropy.dart';
import 'layer_path.dart';
import 'layer_pem.dart';
import 'layer_pii.dart';
import 'layer_registered.dart';
import 'layer_vendor.dart';
import 'redaction_types.dart';

export 'layer_asn1.dart' show asn1BlobLabel, layerAsn1;
export 'layer_connection.dart' show connectionPasswordLabel, layerConnection;
export 'layer_credential.dart' show credentialLabel, layerCredential;
export 'layer_context.dart'
    show certificateDnLabel, layerContext, sensitiveValueLabel;
export 'layer_entropy.dart' show highEntropyLabel, layerEntropy, shannonEntropy;
export 'layer_path.dart' show credentialFileLabel, isCredentialPath, layerPath;
export 'layer_pem.dart' show layerPem;
export 'layer_pii.dart' show layerPii, luhnValid;
export 'layer_prefix.dart' show layerPrefix;
export 'layer_registered.dart' show layerRegistered, registeredSecretLabel;
export 'layer_vendor.dart'
    show githubTokenLabel, layerVendor, quickScreen, vendorPrefixes;
export 'redaction_types.dart';

/// Existing pipeline markers in a text; re-redacting never touches them.
final RegExp _existingMarker = RegExp(r'\[REDACTED:[^\]\n]*\]');

/// `data:<mime>;base64,<payload>` URLs pass through untouched.
final RegExp _dataUrl = RegExp(
  r'data:[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+',
);

/// Per-layer and per-tool counters for the pipeline.
///
/// [byLayer] and [total] count the matches each [RedactionPipeline.scan]
/// produces (after dedupe, allowlist and pass-through filtering);
/// [record] counts redaction events per tool name for hook wiring.
final class RedactionStats {
  final Map<String, int> _byLayer = {};
  final Map<String, int> _byTool = {};
  int _total = 0;

  /// Surviving matches per layer name (e.g. `'vendor'`), unmodifiable.
  Map<String, int> get byLayer => Map.unmodifiable(_byLayer);

  /// Recorded redaction events per tool name, unmodifiable.
  Map<String, int> get byTool => Map.unmodifiable(_byTool);

  /// Total surviving matches counted across all scans.
  int get total => _total;

  /// Records one redaction event issued by [toolName].
  void record(String toolName) {
    _byTool[toolName] = (_byTool[toolName] ?? 0) + 1;
  }

  void _countMatch(RedactionMatch match) {
    _byLayer[match.layer.name] = (_byLayer[match.layer.name] ?? 0) + 1;
    _total++;
  }
}

/// The layered redaction pipeline.
///
/// Wraps the eleven pure layer functions with priority-ordered merging,
/// allowlist suppression, data-URL pass-through, idempotent marker output
/// and statistics. See [scan] (detection) and [redact] (rewriting).
final class RedactionPipeline {
  /// Creates a pipeline pre-loaded with [registeredSecrets].
  ///
  /// [config] may be swapped at any time through the [config] setter for
  /// live re-toggling.
  RedactionPipeline({
    required List<String> registeredSecrets,
    this.config = const RedactionConfig(),
  }) {
    for (final secret in registeredSecrets) {
      registerSecret(secret);
    }
  }

  /// Values shorter than this are never registered — short strings appear
  /// in ordinary output too often (parity with `SecretRedactor`).
  static const minValueLength = 8;

  /// The active configuration; assigning replaces it live.
  RedactionConfig config;

  final List<String> _secrets = [];

  /// The registered secret values, in registration order.
  List<String> get registeredSecrets => List.unmodifiable(_secrets);

  /// Registers [value] for exact-value masking; values shorter than
  /// [minValueLength] are ignored.
  void registerSecret(String value) {
    if (value.length < minValueLength) return;
    if (!_secrets.contains(value)) _secrets.add(value);
  }

  /// Removes [value] from the registered secrets.
  void unregisterSecret(String value) {
    _secrets.remove(value);
  }

  final RedactionStats stats = RedactionStats();

  /// Scans [text] and returns the surviving matches: merged by layer
  /// priority (higher priority wins overlaps), sorted by [RedactionMatch.start],
  /// non-overlapping.
  ///
  /// [pathHint] is the tool's file path when known; a credential-file hint
  /// makes the path layer treat the whole text as one span. Matches fully
  /// covered by an allowlist regex, spans inside existing
  /// `[REDACTED:...]` markers or inside `data:` base64 URLs are not
  /// reported (registered exact values remain exempt from marker
  /// suppression so secrets containing the literal marker text still get
  /// masked).
  List<RedactionMatch> scan(String text, {String? pathHint}) {
    final cfg = config;
    if (!cfg.enabled || text.isEmpty) return const [];

    // Collect matches layer by layer in priority order; lower layers see
    // the spans already claimed by higher layers (kept in `prior`).
    final prior = <RedactionMatch>[];
    final candidates = <RedactionMatch>[];
    for (final layer in RedactionLayer.values) {
      if (!cfg.isLayerEnabled(layer)) continue;
      final found = _scanLayer(
        layer,
        text,
        cfg,
        pathHint: pathHint,
        secrets: _secrets,
        prior: prior,
      );
      candidates.addAll(found);
      prior.addAll(found);
    }

    final merged = _merge(candidates);
    final protected = [
      for (final m in _dataUrl.allMatches(text)) (m.start, m.end),
    ];
    final markers = [
      for (final m in _existingMarker.allMatches(text)) (m.start, m.end),
    ];
    final surviving =
        merged
            .where((match) => _kept(match, protected, markers, cfg, text))
            .toList()
          ..sort(_compareByStart);
    for (final match in surviving) {
      stats._countMatch(match);
    }
    return surviving;
  }

  /// Redacts [text] with `[REDACTED:<kindLabel>]` markers.
  ///
  /// Matches are applied by slice/concat (never a global replace). When a
  /// match spans N newlines, N newline characters are re-emitted after the
  /// single-line marker so the total line count never changes. Output is
  /// idempotent: `redact(redact(x)) == redact(x)`.
  String redact(String text, {String? pathHint}) {
    final cfg = config;
    if (!cfg.enabled || text.isEmpty) return text;
    final matches = scan(text, pathHint: pathHint);
    if (matches.isEmpty) return text;
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in matches) {
      buffer
        ..write(text.substring(cursor, match.start))
        ..write('[REDACTED:${match.kindLabel}]');
      for (var i = match.start; i < match.end; i++) {
        if (text.codeUnitAt(i) == 0x0A) buffer.write('\n');
      }
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    return buffer.toString();
  }

  /// Priority-ordered greedy merge: earlier layer wins an overlap; ties are
  /// broken by leftmost start, then by the longer span.
  List<RedactionMatch> _merge(List<RedactionMatch> candidates) {
    candidates.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final byLayer = a.layer.index.compareTo(b.layer.index);
      if (byLayer != 0) return byLayer;
      return b.length.compareTo(a.length);
    });
    final accepted = <RedactionMatch>[];
    for (final match in candidates) {
      if (!accepted.any(match.overlaps)) accepted.add(match);
    }
    return accepted;
  }
}

/// Runs one layer over the text (dispatch kept out of [RedactionPipeline.scan]
/// to stay simple). Layers run in priority order, so [prior] already holds
/// every span claimed by higher-priority layers.
List<RedactionMatch> _scanLayer(
  RedactionLayer layer,
  String text,
  RedactionConfig cfg, {
  required String? pathHint,
  required List<String> secrets,
  required List<RedactionMatch> prior,
}) {
  return layer.index <= RedactionLayer.pem.index
      ? _scanEarlyLayer(layer, text, cfg, pathHint: pathHint, secrets: secrets)
      : _scanLateLayer(layer, text, cfg, prior: prior);
}

/// The six highest-priority layers.
List<RedactionMatch> _scanEarlyLayer(
  RedactionLayer layer,
  String text,
  RedactionConfig cfg, {
  required String? pathHint,
  required List<String> secrets,
}) {
  switch (layer) {
    case RedactionLayer.registered:
      return layerRegistered(text, secrets);
    case RedactionLayer.path:
      return layerPath(text, cfg, pathHint: pathHint);
    case RedactionLayer.credential:
      return layerCredential(text, cfg);
    case RedactionLayer.vendor:
      return layerVendor(text, cfg);
    case RedactionLayer.prefix:
      // Pure pre-screen: the pipeline gates the vendor regex pass through
      // quickScreen instead (see layer_prefix.dart).
      return const [];
    case RedactionLayer.pem:
      return layerPem(text, cfg);
    default:
      throw StateError('not an early layer: $layer');
  }
}

/// The five lowest-priority layers.
List<RedactionMatch> _scanLateLayer(
  RedactionLayer layer,
  String text,
  RedactionConfig cfg, {
  required List<RedactionMatch> prior,
}) {
  switch (layer) {
    case RedactionLayer.asn1:
      return layerAsn1(text, cfg, prior: prior);
    case RedactionLayer.connection:
      return layerConnection(text, cfg);
    case RedactionLayer.context:
      return layerContext(text, cfg);
    case RedactionLayer.pii:
      return layerPii(text, cfg);
    case RedactionLayer.entropy:
      return layerEntropy(text, cfg, prior: prior);
    default:
      throw StateError('not a late layer: $layer');
  }
}

/// Whether [match] survives filtering: `data:` base64 URLs pass through,
/// allowlist-covered spans stay verbatim, and existing markers are never
/// re-processed (registered values exempt, so a secret containing the
/// literal marker text still gets masked).
bool _kept(
  RedactionMatch match,
  List<(int, int)> protected,
  List<(int, int)> markers,
  RedactionConfig cfg,
  String text,
) {
  if (protected.any((p) => match.start < p.$2 && p.$1 < match.end)) {
    return false;
  }
  if (_allowlisted(match, text, cfg)) return false;
  if (match.layer != RedactionLayer.registered &&
      markers.any((m) => match.start < m.$2 && m.$1 < match.end)) {
    return false;
  }
  return true;
}

/// Whether [match] is fully covered by an allowlist match in [text].
bool _allowlisted(RedactionMatch match, String text, RedactionConfig cfg) {
  for (final regex in cfg.allowlistRegexes) {
    for (final allow in regex.allMatches(text)) {
      if (allow.start <= match.start && match.end <= allow.end) return true;
    }
  }
  return false;
}

/// Leftmost-first ordering for the final match list.
int _compareByStart(RedactionMatch a, RedactionMatch b) =>
    a.start.compareTo(b.start);
