/// L8: opt-in PII detection (disabled by default).
///
/// Covers email, phone (+1, +7 and trunk-8 shapes), credit-card numbers
/// (13–19 digits, Luhn-valid only), US SSN and IBAN. Opt in through
/// `RedactionConfig(layerToggles: {RedactionLayer.pii: true})`.
library;

import 'redaction_types.dart';

final RegExp _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

final RegExp _phoneUs = RegExp(r'\+1[ .-]?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}\b');
final RegExp _phoneRu = RegExp(
  r'\+7[ (.\-]?\d{3}[ ).\-]?\d{3}[ .-]?\d{2}[ .-]?\d{2}\b',
);
final RegExp _phoneTrunk = RegExp(
  r'(?<!\d)8[ (.\-]?\d{3}[ ).\-]?\d{3}[ .-]?\d{2}[ .-]?\d{2}\b',
);

final RegExp _cardRun = RegExp(r'\b(?:\d[ -]?){12,18}\d\b');
final RegExp _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
final RegExp _iban = RegExp(r'\b[A-Z]{2}\d{2}[A-Z0-9]{13,30}\b');

/// Whether the digit string passes the Luhn checksum.
bool luhnValid(String digits) {
  var sum = 0;
  var doubled = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = digits.codeUnitAt(i) - 48;
    if (doubled) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    doubled = !doubled;
  }
  return sum % 10 == 0;
}

/// Finds PII spans in [text]; non-overlapping, left-to-right.
List<RedactionMatch> layerPii(String text, RedactionConfig cfg) {
  if (text.isEmpty) return const [];
  final matches = <RedactionMatch>[];
  void add(int start, int end, String label) {
    final match = RedactionMatch(
      start: start,
      end: end,
      layer: RedactionLayer.pii,
      kindLabel: label,
    );
    if (!matches.any(match.overlaps)) matches.add(match);
  }

  for (final m in _email.allMatches(text)) {
    add(m.start, m.end, 'Email');
  }
  for (final pattern in [_phoneUs, _phoneRu, _phoneTrunk]) {
    for (final m in pattern.allMatches(text)) {
      add(m.start, m.end, 'Phone');
    }
  }
  _addCardMatches(text, add);
  for (final m in _ssn.allMatches(text)) {
    add(m.start, m.end, 'SSN');
  }
  for (final m in _iban.allMatches(text)) {
    add(m.start, m.end, 'IBAN');
  }
  return matches;
}

/// Adds Luhn-valid card runs (13–19 digits, optional space/dash grouping).
void _addCardMatches(String text, void Function(int, int, String) add) {
  for (final m in _cardRun.allMatches(text)) {
    final digits = m.group(0)!.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length >= 13 && digits.length <= 19 && luhnValid(digits)) {
      add(m.start, m.end, 'Card Number');
    }
  }
}
