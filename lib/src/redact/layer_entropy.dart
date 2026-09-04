/// L9 (last): high-entropy token heuristic.
///
/// ASCII token runs (`[A-Za-z0-9+/=_-]`) of at least `minLength` chars whose
/// Shannon entropy reaches `minEntropy` are masked — but only when no
/// higher-priority layer already claimed the span.
library;

import 'dart:math' as math;

import 'redaction_types.dart';

/// Marker label used for high-entropy spans.
const String highEntropyLabel = 'High Entropy String';

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
  final pattern = RegExp('[A-Za-z0-9+/=_-]{$minLength,}');
  final matches = <RedactionMatch>[];
  for (final m in pattern.allMatches(text)) {
    final token = m.group(0)!;
    // Alphabet-length guard: a real secret never uses a tiny alphabet.
    if (token.codeUnits.toSet().length < 8) continue;
    if (shannonEntropy(token) < cfg.minEntropy) continue;
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
