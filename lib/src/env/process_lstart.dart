/// Pure parsing of `ps -o lstart=` values (issue #2201 / #478).
///
/// Split out of `process_probe_io.dart` (gh-2413) so the pure-Dart boot
/// reconcile can compare a live pid's start time against a manifest
/// entry's birth without importing `dart:io`: the io probe keeps
/// re-exporting this, so existing imports are unchanged.
library;

/// Parses one `ps -o lstart=` value ("Mon Nov 16 10:00:00 2026", LOCAL
/// time); null when the shape does not match. Second resolution only —
/// ps never reports sub-second starts.
DateTime? tryParseLstart(String value) {
  final m = _lstartPattern.firstMatch(value.trim());
  if (m == null) return null;
  final month = _lstartMonths[m.group(2)];
  if (month == null) return null;
  return DateTime(
    int.parse(m.group(7)!),
    month,
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}

final _lstartPattern = RegExp(
  r'^(\w{3}) (\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
);

const _lstartMonths = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};
