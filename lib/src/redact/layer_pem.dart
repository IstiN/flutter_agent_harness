/// L4: PEM / X.509 / OpenSSH / PGP armored blocks.
///
/// Matches a `-----BEGIN <label>-----` header through the matching
/// `-----END <label>-----` including the base64 body. A block whose end
/// marker is missing (truncated output) is masked to the end of the text.
library;

import 'redaction_types.dart';

/// Matches complete armored blocks; group 1 is the label.
final RegExp _pemBlock = RegExp(
  r'-----BEGIN ((?:[A-Z0-9]+ )*?(?:PRIVATE KEY|CERTIFICATE)|PGP (?:PRIVATE|PUBLIC) KEY BLOCK)-----'
  r'[\s\S]*?'
  r'-----END \1-----',
);

/// Matches begin markers only (used to detect truncated blocks).
final RegExp _pemBegin = RegExp(
  r'-----BEGIN ((?:[A-Z0-9]+ )*?(?:PRIVATE KEY|CERTIFICATE)|PGP (?:PRIVATE|PUBLIC) KEY BLOCK)-----',
);

/// Finds PEM/X.509/PGP blocks in [text].
///
/// Complete blocks report their header label (`'PEM CERTIFICATE'`, ...); a
/// begin marker without an end marker reports one span reaching the end of
/// the text.
List<RedactionMatch> layerPem(String text, RedactionConfig cfg) {
  if (text.isEmpty || !text.contains('-----BEGIN')) return const [];
  final matches = <RedactionMatch>[];
  void add(int start, int end, String label) {
    final match = RedactionMatch(
      start: start,
      end: end,
      layer: RedactionLayer.pem,
      kindLabel: 'PEM $label',
    );
    if (!matches.any(match.overlaps)) matches.add(match);
  }

  for (final m in _pemBlock.allMatches(text)) {
    add(m.start, m.end, m.group(1)!);
  }
  // Truncated blocks: a begin marker not covered by any complete block
  // masks everything up to the end of the text.
  for (final b in _pemBegin.allMatches(text)) {
    final covered = matches.any((m) => m.start <= b.start && b.start < m.end);
    if (!covered) add(b.start, text.length, b.group(1)!);
  }
  return matches;
}
