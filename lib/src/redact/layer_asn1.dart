/// L5: standalone DER (ASN.1) base64 blobs.
///
/// Matches base64 runs that start with `MII` (the DER SEQUENCE header) and
/// are at least 200 characters long, skipping spans already claimed by a
/// higher-priority layer (a PEM body, for instance).
library;

import 'redaction_types.dart';

/// Marker label used for standalone DER blobs.
const String asn1BlobLabel = 'ASN.1 DER Blob';

/// Finds standalone DER base64 runs in [text].
///
/// [prior] holds matches from higher-priority layers; runs inside those
/// spans are skipped. MII runs shorter than 200 chars are ignored.
List<RedactionMatch> layerAsn1(
  String text,
  RedactionConfig cfg, {
  List<RedactionMatch> prior = const [],
}) {
  if (text.length < 200 || !text.contains('MII')) return const [];
  const pattern = r'\bMII[A-Za-z0-9+/=]{197,}';
  final matches = <RedactionMatch>[];
  for (final m in RegExp(pattern).allMatches(text)) {
    final match = RedactionMatch(
      start: m.start,
      end: m.end,
      layer: RedactionLayer.asn1,
      kindLabel: asn1BlobLabel,
    );
    final claimed = prior.any(
      (p) => p.start <= match.start && match.end <= p.end,
    );
    if (claimed || matches.any(match.overlaps)) continue;
    matches.add(match);
  }
  return matches;
}
