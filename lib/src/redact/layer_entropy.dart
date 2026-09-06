/// L9 (last): high-entropy token heuristic.
///
/// Secret-shaped ASCII token runs (`[A-Za-z0-9+=_-]`, at least
/// `minLength` chars) whose Shannon entropy reaches `minEntropy` are
/// masked - but only when no higher-priority layer already claimed the
/// span, and never for well-known STRUCTURED values:
///
/// - `/` is deliberately NOT a token character: it is a path separator,
///   so a filesystem path never glues into one giant "secret" (mixed-case
///   paths cross `minEntropy` easily and every ls/find/read listing would
///   shred). Base64 rarely needs `/`; when it has one, the surrounding
///   segments still match individually.
/// - a token immediately after `/` is a path component, not a value.
/// - UUIDs, pure-hex runs, ISO-timestamp-prefixed ids, and subresource
///   integrity hashes (`sha256-...`) are public structure, not secrets.
library;

import 'dart:math' as math;

import 'redaction_types.dart';

/// Marker label used for high-entropy spans.
const String highEntropyLabel = 'High Entropy String';

final RegExp _uuidShape = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
  r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\$',
);
final RegExp _hexRun = RegExp(r'^[0-9a-fA-F][0-9a-fA-F_-]+\$');
final RegExp _isoTimestamp = RegExp(r'^\d{4}-\d{2}-\d{2}T');
final RegExp _integrityHash = RegExp(r'^sha(256|384|512)-');

/// Whether [token] is a well-known safe structured value a secret never
/// takes the shape of (public hashes, ids, timestamps).
bool isStructuredIdentifier(String token) {
  if (_uuidShape.hasMatch(token)) return true;
  if (_hexRun.hasMatch(token)) return true;
  if (_isoTimestamp.hasMatch(token)) return true;
  if (_integrityHash.hasMatch(token)) return true;
  return false;
}

/// Shannon entropy of [token] in bits per character.
double shannonEntropy(String token) {
  final counts = <int, int>{};
  for (final c in token.codeUnits) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  var entropy = 0.0;
  final n = token.length;
  for (final count in counts.values) {
    final p = count / n;
    entropy -= p * (math.log(p) / math.ln2);
  }
  return entropy;
}

/// Finds high-entropy ASCII token spans in [text].
///
/// [prior] holds matches from higher-priority layers; tokens inside those
/// spans are skipped.
List<RedactionMatch> layerEntropy(
  String text,
  RedactionConfig cfg, {
  List<RedactionMatch> prior = const [],
}) {
  final minLength = cfg.minLength;
  if (text.length < minLength) return const [];
  final pattern = RegExp('[A-Za-z0-9+=_-]{$minLength,}');
  final matches = <RedactionMatch>[];
  for (final m in pattern.allMatches(text)) {
    final token = m.group(0)!;
    // Alphabet-length guard: a real secret never uses a tiny alphabet.
    if (token.codeUnits.toSet().length < 8) continue;
    if (shannonEntropy(token) < cfg.minEntropy) continue;
    if (isStructuredIdentifier(token)) continue;
    // A token glued after `/` is a path component, not a standalone
    // value - real secrets do not live in directory names.
    if (m.start > 0 && text[m.start - 1] == '/') continue;
    final match = RedactionMatch(
      start: m.start,
      end: m.end,
      layer: RedactionLayer.entropy,
      kindLabel: highEntropyLabel,
    );
    if (prior.any(match.overlaps) || matches.any(match.overlaps)) continue;
    matches.add(match);
  }
  return matches;
}
