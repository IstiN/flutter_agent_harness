/// L0: exact matching of pipeline-registered secret values.
///
/// The pipeline injects the secret strings (see `RedactionPipeline`
/// `registerSecret`); this layer finds every occurrence with the longest
/// values winning overlaps so a value that contains another still masks as
/// one span.
library;

import 'redaction_types.dart';

/// Marker label used for registered exact-value matches.
const String registeredSecretLabel = 'Registered Secret';

/// Finds every occurrence of every value in [secrets] inside [text].
///
/// Pure function: returns matches ordered left-to-right, non-overlapping
/// (longer values claim their spans first).
List<RedactionMatch> layerRegistered(String text, List<String> secrets) {
  if (text.isEmpty || secrets.isEmpty) return const [];
  // Longest-first so overlapping secrets collapse into the longest span.
  final sorted = [...secrets]..sort((a, b) => b.length.compareTo(a.length));
  final claimed = <RedactionMatch>[];
  for (final secret in sorted) {
    if (secret.isEmpty) continue;
    var from = 0;
    while (true) {
      final index = text.indexOf(secret, from);
      if (index < 0) break;
      final match = RedactionMatch(
        start: index,
        end: index + secret.length,
        layer: RedactionLayer.registered,
        kindLabel: registeredSecretLabel,
      );
      if (!claimed.any(match.overlaps)) claimed.add(match);
      from = index + 1;
    }
  }
  claimed.sort((a, b) => a.start.compareTo(b.start));
  return claimed;
}
