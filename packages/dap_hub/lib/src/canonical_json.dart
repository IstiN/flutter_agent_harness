// Canonical JSON for DAP/1 signature payloads.
//
// Port of the Go hub's `canonicalJSON` (auth.go): UTF-8 JSON, object keys
// sorted recursively, no whitespace, no trailing newline, no HTML escaping
// (`SetEscapeHTML(false)`), with Go's unconditional escaping of U+2028 and
// U+2029. Every canonicalizer in the ecosystem (Go, JS, Dart) must produce
// byte-identical output or signature verification breaks.

/// Marshals [value] to canonical JSON: sorted keys, no whitespace.
String canonicalJson(Object? value) {
  final buf = StringBuffer();
  _writeCanonical(buf, value);
  return buf.toString();
}

void _writeCanonical(StringBuffer buf, Object? value) {
  switch (value) {
    case List<Object?> list:
      _writeCanonicalList(buf, list);
    case Map<Object?, Object?> map:
      _writeCanonicalMap(buf, map);
    default:
      _writeScalar(buf, value);
  }
}

void _writeScalar(StringBuffer buf, Object? value) {
  switch (value) {
    case null:
      buf.write('null');
    case bool b:
      buf.write(b ? 'true' : 'false');
    case num n:
      buf.write(_canonicalNum(n));
    case String s:
      _writeCanonicalString(buf, s);
    default:
      throw ArgumentError('not JSON-marshalable: ${value.runtimeType}');
  }
}

void _writeCanonicalList(StringBuffer buf, List<Object?> list) {
  buf.write('[');
  for (var i = 0; i < list.length; i++) {
    if (i > 0) buf.write(',');
    _writeCanonical(buf, list[i]);
  }
  buf.write(']');
}

void _writeCanonicalMap(StringBuffer buf, Map<Object?, Object?> map) {
  buf.write('{');
  final keys = map.keys.map((k) => '$k').toList()..sort();
  for (var i = 0; i < keys.length; i++) {
    if (i > 0) buf.write(',');
    _writeCanonicalString(buf, keys[i]);
    buf.write(':');
    _writeCanonical(buf, map[keys[i]]);
  }
  buf.write('}');
}

/// Numbers marshal like Go's encoding/json: integers plainly; doubles in
/// shortest round-trip form, integral doubles without a fraction.
String _canonicalNum(num n) {
  if (n is int) return n.toString();
  final d = n.toDouble();
  if (d == d.roundToDouble() && d.abs() < 1e15) {
    return d.round().toString();
  }
  return d.toString();
}

/// The one-letter escapes of the JSON spec.
const _shortEscapes = {
  0x22: r'\"',
  0x5C: r'\\',
  0x08: r'\b',
  0x09: r'\t',
  0x0A: r'\n',
  0x0C: r'\f',
  0x0D: r'\r',
};

/// String escaping matching Go's encoding/json with SetEscapeHTML(false):
/// quotes, backslash, the short control escapes, \u00XX for the remaining
/// control range, and Go's unconditional U+2028/U+2029 escapes.
void _writeCanonicalString(StringBuffer buf, String s) {
  buf.write('"');
  for (final unit in s.codeUnits) {
    final short = _shortEscapes[unit];
    if (short != null) {
      buf.write(short);
    } else if (unit < 0x20 || unit == 0x2028 || unit == 0x2029) {
      buf.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      buf.writeCharCode(unit);
    }
  }
  buf.write('"');
}
