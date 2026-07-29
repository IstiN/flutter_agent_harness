/// Tests for the JSON parse/repair helpers: valid passthrough, control
/// character escaping inside strings, backslash/escape repair, and the
/// truncated-JSON fallbacks of the streaming parser.
library;

import 'package:flutter_agent_harness/src/json_parse.dart';
import 'package:test/test.dart';

void main() {
  group('repairJson', () {
    const cases = {
      'passes valid JSON through unchanged': ['{"a": 1}', '{"a": 1}'],
      'keeps plain strings unchanged': ['a "b" c "d"', 'a "b" c "d"'],
      'leaves control characters outside strings untouched': [
        '{\n"a": 1,\n"b": 2}',
        '{\n"a": 1,\n"b": 2}',
      ],
      'escapes a raw newline inside a string': ['"a\nb"', r'"a\nb"'],
      'escapes a raw tab inside a string': ['"a\tb"', r'"a\tb"'],
      'escapes a raw carriage return inside a string': ['"a\rb"', r'"a\rb"'],
      'escapes backspace and form feed inside a string': [
        '"a\bb\fc"',
        r'"a\bb\fc"',
      ],
      'escapes other control characters as unicode': [
        '"a\x01b\x1fc"',
        r'"a\u0001b\u001fc"',
      ],
      'escapes control characters only inside strings': [
        '{"k": "v\n"}',
        r'{"k": "v\n"}',
      ],
      'keeps valid escape sequences unchanged': [
        r'"\n\t\r\b\f\/\\"',
        r'"\n\t\r\b\f\/\\"',
      ],
      'keeps a valid unicode escape unchanged': [r'"Aé"', r'"Aé"'],
      'keeps a non-hex unicode escape via the valid-escape path': [
        r'"\uzz"',
        r'"\uzz"',
      ],
      'doubles the backslash before an invalid escape': [r'"\x"', r'"\\x"'],
      'doubles a trailing backslash inside a string': ['"a\\', r'"a\\'],
      'passes a truncated string through unchanged': ['{"a": "b', '{"a": "b'],
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(repairJson(entry.value[0]), entry.value[1]);
      });
    }
  });

  group('parseStreamingJson', () {
    test('returns an empty map for blank input', () {
      expect(parseStreamingJson(''), isEmpty);
      expect(parseStreamingJson('   '), isEmpty);
    });

    test('parses a valid JSON object', () {
      expect(parseStreamingJson('{"a": 1}'), {'a': 1});
    });

    test('returns an empty map for valid non-object JSON', () {
      expect(parseStreamingJson('[1, 2]'), isEmpty);
    });

    test('repairs raw control characters and parses', () {
      expect(parseStreamingJson('{"a": "x\ny"}'), {'a': 'x\ny'});
    });

    test('repairs an invalid escape and parses', () {
      expect(parseStreamingJson(r'{"a": "\x"}'), {'a': r'\x'});
    });

    test('returns an empty map for unrepairable JSON', () {
      expect(parseStreamingJson('{bad'), isEmpty);
    });
  });

  group('parseJsonWithRepair', () {
    test('parses valid JSON directly', () {
      expect(parseJsonWithRepair('{"a": 1}'), {'a': 1});
    });

    test('parses after a repair pass', () {
      expect(parseJsonWithRepair('{"a": "x\ny"}'), {'a': 'x\ny'});
    });

    test('rethrows when the repaired text still does not parse', () {
      expect(() => parseJsonWithRepair('{bad'), throwsFormatException);
    });
  });
}
