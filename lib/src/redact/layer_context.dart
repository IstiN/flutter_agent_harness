/// L7: context-anchored secrets (`password=`, `api_key:`, `export SECRET=`,
/// JSON `"password": "..."`, cert-dump `subject=`/`issuer=`/`CN=` lines).
///
/// Only the value span is masked, never the key. Values are Unicode-aware
/// and run until a delimiter (or, for quoted values, the closing quote).
/// Variable placeholders (`$VAR`, `${VAR}`, `<...>`) are left alone.
library;

import 'redaction_types.dart';

/// Marker label used for generic context values.
const String sensitiveValueLabel = 'Sensitive Value';

/// Marker label used for certificate DN component values.
const String certificateDnLabel = 'Certificate DN';

final RegExp _contextAnchor = RegExp(
  r'(?:^|[{\[,;|\s(])'
  r'''["']?'''
  r'\b(?:password|passwd|pwd|secret|api[_-]?key|api[_-]?token'
  r'|access[_-]?token|refresh[_-]?token|client[_-]?token|client[_-]?secret'
  r'|session[_-]?token|auth[_-]?token|token|private[_-]?key)'
  r'''["']?'''
  r'\s*[:=]\s*',
  caseSensitive: false,
);

/// A line that reads as certificate-dump output.
final RegExp _certLine = RegExp(
  r'^.*(?:subject\s*[=:]|issuer\s*[=:]|CERTIFICATE).*$',
  caseSensitive: false,
  multiLine: true,
);

/// DN component assignment inside a certificate-dump line.
final RegExp _dnValue = RegExp(
  r'\b(?:subject|issuer|CN)\s*=\s*',
  caseSensitive: false,
);

const Set<String> _valueStops = {
  ' ',
  '\t',
  '\n',
  '\r',
  ',',
  ';',
  ')',
  ']',
  '}',
  '&',
  '"',
  "'",
};

/// Stop characters for DN component values; a value also ends at the next
/// DN anchor on the same line (`CN =` RDNs may span spaces).
const Set<String> _dnStops = {',', '\n', '\r'};

/// Finds context-anchored value spans in [text].
///
/// Pure function; see the library docs for what counts as an anchor.
List<RedactionMatch> layerContext(String text, RedactionConfig cfg) {
  if (text.isEmpty) return const [];
  if (!text.contains('=') && !text.contains(':')) return const [];
  final matches = <RedactionMatch>[];
  void add(int start, int end, String label) {
    final match = RedactionMatch(
      start: start,
      end: end,
      layer: RedactionLayer.context,
      kindLabel: label,
    );
    if (!matches.any(match.overlaps)) matches.add(match);
  }

  _scanContextValues(text, add);
  _scanCertValues(text, add);
  return matches;
}

/// Masks the values of every key/value anchor in [text].
void _scanContextValues(String text, void Function(int, int, String) add) {
  for (final anchor in _contextAnchor.allMatches(text)) {
    final span = _valueSpan(text, anchor.end);
    if (span == null) continue;
    add(span.$1, span.$2, sensitiveValueLabel);
  }
}

/// Resolves the value span that follows a key/value anchor at [i].
(int, int)? _valueSpan(String text, int i) {
  if (i >= text.length) return null;
  final quote = text[i];
  if (quote == '"' || quote == "'") return _quotedSpan(text, i);
  return _plainSpan(text, i);
}

/// Quoted value: everything between the quotes (escapes skip one char).
(int, int)? _quotedSpan(String text, int start) {
  final quote = text[start];
  var j = start + 1;
  while (j < text.length) {
    final c = text[j];
    if (c == r'\') {
      j += 2;
      continue;
    }
    if (c == quote) break;
    j++;
  }
  if (j >= text.length || j == start + 1) return null; // unterminated / empty
  return (start + 1, j);
}

/// Unquoted value: until a delimiter; placeholders are rejected.
(int, int)? _plainSpan(String text, int start) {
  var j = start;
  while (j < text.length && !_valueStops.contains(text[j])) {
    j++;
  }
  if (j - start < 2) return null; // too short to be a value
  final value = text.substring(start, j);
  if (value.startsWith(r'$') ||
      value.startsWith('<') ||
      value.startsWith('*')) {
    return null; // variable / template placeholder
  }
  return (start, j);
}

/// Masks the DN component values of every certificate-dump line in [text].
void _scanCertValues(String text, void Function(int, int, String) add) {
  for (final line in _certLine.allMatches(text)) {
    final chunk = line.group(0)!;
    final base = line.start;
    final anchors = _dnValue.allMatches(chunk).toList();
    for (var k = 0; k < anchors.length; k++) {
      final span = _dnSpan(chunk, anchors, k);
      if (span == null) continue;
      add(base + span.$1, base + span.$2, certificateDnLabel);
    }
  }
}

/// Value span of the k-th DN anchor on a certificate-dump line.
(int, int)? _dnSpan(String chunk, List<RegExpMatch> anchors, int k) {
  final anchor = anchors[k];
  final limit = k + 1 < anchors.length ? anchors[k + 1].start : chunk.length;
  var j = anchor.end;
  while (j < limit && !_dnStops.contains(chunk[j])) {
    j++;
  }
  var end = j;
  while (end > anchor.end &&
      (chunk[end - 1] == ' ' || chunk[end - 1] == '\r')) {
    end--;
  }
  if (end > anchor.end) return (anchor.end, end);
  return null;
}
