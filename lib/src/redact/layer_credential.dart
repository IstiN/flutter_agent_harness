/// L3: DOM credential firewall (issue #30).
///
/// Masks the VALUES of password/credential-shaped form fields in
/// serialized captures a tool returns: `<input>` tags in HTML/DOM dumps
/// and quoted key/value pairs in JSON-ish captures (`"password": "..."`).
/// Only the value span is masked, never the attribute or key. Empty
/// values, `placeholder=` hints and ordinary inputs stay verbatim, and a
/// value that is only an existing `[REDACTED:...]` marker never re-matches.
library;

import 'redaction_types.dart';

/// Marker label used for credential field values.
const String credentialLabel = 'credential';

/// Credential-ish field names, ids and JSON keys (`password`, `pwd`,
/// `secret`, `token`, `api_key`, `apiKey`, ...).
final RegExp _credKey = RegExp(
  r'pass(word)?|pwd|secret|token|api[-_]?key|apikey',
  caseSensitive: false,
);

/// Serialized `<input ...>` tags.
final RegExp _inputTag = RegExp(r'<input\b[^>]*>', caseSensitive: false);

/// One `name="value"` attribute inside an input tag; the leading `\s`
/// keeps names like `data-value` from reading as `value`.
final RegExp _attr = RegExp(
  r'''\s([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
);

/// Quoted key/value pairs in JSON-ish captures whose key is
/// credential-ish. The quotes anchor the key, so `passwordGenerator`
/// never reads as `password`.
final RegExp _jsonCred = RegExp(
  r'"(?:pass(?:word)?|pwd|secret|token|api[-_]?key|apikey)"\s*:\s*"([^"]*)"',
  caseSensitive: false,
);

/// Values that are only an existing `[REDACTED:...]` marker never re-match.
final RegExp _markerOnly = RegExp(r'^\[REDACTED:[^\]\n]*\]$');

/// Finds DOM credential value spans in [text].
///
/// Pure function; see the library docs for what counts as a credential
/// field.
List<RedactionMatch> layerCredential(String text, RedactionConfig config) {
  if (text.isEmpty) return const [];
  final matches = <RedactionMatch>[];
  void add(int start, int end) {
    final match = RedactionMatch(
      start: start,
      end: end,
      layer: RedactionLayer.credential,
      kindLabel: credentialLabel,
    );
    if (!matches.any(match.overlaps)) matches.add(match);
  }

  for (final tag in _inputTag.allMatches(text)) {
    final span = _credentialValueSpan(tag.group(0)!);
    if (span == null) continue;
    add(tag.start + span.$1, tag.start + span.$2);
  }
  for (final m in _jsonCred.allMatches(text)) {
    final value = m.group(1)!;
    if (value.isEmpty || _markerOnly.hasMatch(value)) continue;
    // The match ends with the closing quote; only the value is masked.
    add(m.end - 1 - value.length, m.end - 1);
  }
  return matches;
}

/// The in-tag span of the `value` attribute when [tag] is a credential
/// field, else `null`. A duplicate `value` attribute: first wins (like
/// browsers).
(int, int)? _credentialValueSpan(String tag) {
  final attrs = <String, String>{};
  (int, String)? value;
  for (final m in _attr.allMatches(tag)) {
    final name = m.group(1)!.toLowerCase();
    final v = m.group(2) ?? m.group(3)!;
    attrs[name] = v;
    if (name == 'value' && value == null) value = (m.end, v);
  }
  if (value == null) return null;
  final (endInTag, v) = value;
  if (v.isEmpty || _markerOnly.hasMatch(v) || !_isCredentialField(attrs)) {
    return null;
  }
  // The attribute match ends with the closing quote.
  return (endInTag - 1 - v.length, endInTag - 1);
}

/// Whether the input's attributes mark it credential-shaped: a password
/// type, a credential-ish name/id, or an autocomplete hint
/// (`current-password`, `new-password`, `cc-*`). `aria-*`/`data-*`
/// attributes and `placeholder` are never read.
bool _isCredentialField(Map<String, String> attrs) {
  if (attrs['type']?.toLowerCase() == 'password') return true;
  if (_credKey.hasMatch(attrs['name'] ?? '')) return true;
  if (_credKey.hasMatch(attrs['id'] ?? '')) return true;
  final auto = attrs['autocomplete']?.toLowerCase();
  return auto == 'current-password' ||
      auto == 'new-password' ||
      (auto?.startsWith('cc-') ?? false);
}
