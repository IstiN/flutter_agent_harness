import 'package:dart_tui/src/key_buffer_parser.dart';
import 'package:dart_tui/src/msg.dart';
import 'package:test/test.dart';

/// CP1251 repair map for the Latin-1 range, the way windows_terminal.dart
/// builds it from GetACP/MultiByteToWideChar. Only the entries the tests
/// touch are listed; unmapped chars fall back to themselves.
String _repair(String text) {
  const map = <int, int>{
    0xEF: 0x043F, // 'ï' → 'п'
    0xF0: 0x0440, // 'ð' → 'р'
    0xE8: 0x0438, // 'è' → 'и'
    0xE2: 0x0432, // 'â' → 'в'
    0xE5: 0x0435, // 'å' → 'е'
    0xF2: 0x0442, // 'ò' → 'т'
  };
  return text.replaceAllMapped(RegExp('[\u00A0-\u00FF]'),
      (m) => String.fromCharCode(map[m[0]!.runes.first] ?? m[0]!.runes.first));
}

void main() {
  group('consoleTextRepair (Windows legacy-code-page mojibake)', () {
    tearDown(() {
      consoleTextRepair = null;
    });

    test('hook unset: mojibake pairs decode to Latin-1 text (old behavior)',
        () {
      final buffer = <int>[0xC3, 0xAF]; // UTF-8 for U+00EF 'ï'
      final key = parseKeyFromBuffer(buffer);
      expect(key!.code, KeyCode.rune);
      expect(key.text, String.fromCharCode(0xEF));
    });

    test('hook set: a CP-6501 translation pair repairs to the real char', () {
      consoleTextRepair = _repair;
      final buffer = <int>[0xC3, 0xAF]; // 'п' mis-delivered as 'ï'
      final key = parseKeyFromBuffer(buffer);
      expect(key!.code, KeyCode.rune);
      expect(key.text, 'п');
      expect(buffer, isEmpty);
    });

    test('hook set: a mojibake word in one burst repairs fully', () {
      consoleTextRepair = _repair;
      final buffer = <int>[
        0xC3, 0xAF, 0xC3, 0xB0, 0xC3, 0xA8, // 'при' mis-delivered
      ];
      final keys = <String>[];
      while (true) {
        final key = parseKeyFromBuffer(buffer);
        if (key == null) break;
        if (key.code == KeyCode.rune) keys.add(key.text);
      }
      expect(keys.join(), 'при');
    });

    test('hook set: the lone-legacy-byte fallback rune repairs too', () {
      consoleTextRepair = _repair;
      // A console the CP flip never reaches hands over the bare CP1251 byte.
      // 0xF0 is the next keystroke ('р'): it proves 0xEF can never complete
      // as UTF-8, so the parser surfaces the head (issue #1973 path).
      final buffer = <int>[0xEF, 0xF0];
      final key = parseKeyFromBuffer(buffer);
      expect(key!.code, KeyCode.rune);
      expect(key.text, 'п');
      expect(buffer, <int>[0xF0], reason: 'only the head byte is consumed');
    });

    test('hook set: true UTF-8 Cyrillic passes through untouched', () {
      consoleTextRepair = _repair;
      final buffer = <int>[0xD0, 0xBF, 0xD1, 0x80]; // 'пр' real UTF-8
      final keys = <String>[];
      while (true) {
        final key = parseKeyFromBuffer(buffer);
        if (key == null) break;
        if (key.code == KeyCode.rune) keys.add(key.text);
      }
      expect(keys.join(), 'пр');
    });

    test('hook set: ASCII and control keys never repair', () {
      consoleTextRepair = _repair;
      final buffer = <int>[0x61, 0x0d]; // 'a' + Enter
      final a = parseKeyFromBuffer(buffer)!;
      expect(a.code, KeyCode.rune);
      expect(a.text, 'a');
      final enter = parseKeyFromBuffer(buffer)!;
      expect(enter.code, KeyCode.enter);
    });

    test('hook set: chars outside the Latin-1 range never repair', () {
      consoleTextRepair = _repair;
      final buffer = <int>[0xD1, 0x91]; // 'ё' (U+0451) as real UTF-8
      final key = parseKeyFromBuffer(buffer);
      expect(key!.text, 'ё');
    });
  });
}
