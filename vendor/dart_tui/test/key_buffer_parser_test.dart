import 'package:dart_tui/src/key_buffer_parser.dart';
import 'package:dart_tui/src/msg.dart';
import 'package:test/test.dart';

void main() {
  group('UTF-8 keyboard input on Windows (Cyrillic)', () {
    test('multi-byte UTF-8 decodes even when every byte lands alone', () {
      // Valid UTF-8 is what the console sends once its input code page is
      // UTF-8 (windows_terminal.dart). Split reads must not lose bytes.
      final buffer = <int>[];
      final keys = <String>[];
      for (final b in <int>[0xD0, 0xBF, 0xD1, 0x80, 0xD0, 0xB8]) {
        buffer.add(b); // 'при', one byte per read
        final key = parseKeyFromBuffer(buffer);
        if (key != null) keys.add(key.text);
      }

      expect(keys.join(), 'при');
      expect(buffer, isEmpty);
    });

    test('a single-byte code page can never wedge the parser', () {
      // A legacy console page delivers 'п' as ONE byte (0xEF) — a 3-byte
      // UTF-8 lead that is never followed by continuations. The parser used
      // to return null forever and the buffer only grew: every later
      // keystroke was swallowed (the reported "cannot type Russian at all").
      final buffer = <int>[0xEF, 0xF0, 0xE8]; // 'при' in cp1251

      final key = parseKeyFromBuffer(buffer);

      expect(key, isNotNull, reason: 'a head that can never complete must be '
          'surfaced instead of stalling the stream');
      expect(key!.text, String.fromCharCode(0xEF));
      expect(buffer, <int>[0xF0, 0xE8], reason: 'one byte is consumed');
    });

    test('typing recovers after a bad byte', () {
      final buffer = <int>[0xEF, 0xF0, 0xE8, 0x61]; // junk + 'a'
      final keys = <String>[];
      while (true) {
        final key = parseKeyFromBuffer(buffer);
        if (key == null) break;
        keys.add(key.text);
      }

      expect(keys, contains('a'), reason: 'ASCII after junk must still arrive');
      expect(buffer, isEmpty);
    });

    test('a genuinely partial character still waits for the rest', () {
      final buffer = <int>[0xD0]; // first byte of 'п'

      expect(parseKeyFromBuffer(buffer), isNull);
      expect(buffer, <int>[0xD0], reason: 'the byte must not be eaten');

      buffer.add(0xBF);
      expect(parseKeyFromBuffer(buffer)?.text, 'п');
      expect(buffer, isEmpty);
    });

    test('a bare continuation byte is dropped, not fatal', () {
      final buffer = <int>[0xBF, 0x61]; // stray continuation, then 'a'

      expect(parseKeyFromBuffer(buffer)?.code, KeyCode.unknown);
      expect(parseKeyFromBuffer(buffer)?.text, 'a');
      expect(buffer, isEmpty);
    });
  });

  test('parseKeyFromBuffer handles printable ASCII', () {
    final b = <int>[0x61];
    final k = parseKeyFromBuffer(b);
    expect(k?.code, KeyCode.rune);
    expect(k?.text, 'a');
    expect(b, isEmpty);
  });

  test('parseKeyFromBuffer parses arrow escape sequence', () {
    final b = <int>[0x1b, 0x5b, 0x42];
    final k = parseKeyFromBuffer(b);
    expect(k?.code, KeyCode.down);
    expect(b, isEmpty);
  });

  test('parseKeyFromBuffer parses CSI Z (backtab) as shift+tab', () {
    final b = <int>[0x1b, 0x5b, 0x5a];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.tab);
    expect(k.modifiers, contains(KeyMod.shift));
    expect(k.keystroke(), 'shift+tab');
    expect(b, isEmpty);
  });

  test('parseKeyFromBuffer parses ESC+CR as alt+enter (not unknown)', () {
    // Terminals without kitty/modifyOtherKeys support (e.g. Warp's legacy
    // TUI passthrough) report Shift+Enter as ESC CR — the classic alt+enter
    // encoding. It must decode to a usable key, not fall into `unknown` and
    // silently no-op.
    final b = <int>[0x1b, 0x0d];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.enter);
    expect(k.modifiers, contains(KeyMod.alt));
    expect(k.keystroke(), 'alt+enter');
    expect(b, isEmpty);
  });
  test('parseKeyFromBuffer parses ESC+LF as alt+enter (not unknown)', () {
    // The ESC CR wire after a kernel line discipline with ICRNL on
    // translated the CR to LF before the app read it (fa issue #77) —
    // embedded PTY hosts that reset termios under the app, or where stty
    // is unavailable to clear the flag. Same alt+enter encoding, same
    // decode; ESC LF has no other standard meaning.
    final b = <int>[0x1b, 0x0a];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.enter);
    expect(k.modifiers, contains(KeyMod.alt));
    expect(k.keystroke(), 'alt+enter');
    expect(b, isEmpty);
  });

  test('parseKeyFromBuffer returns null until escape sequence complete', () {
    final b = <int>[0x1b];
    expect(parseKeyFromBuffer(b), isNull);
    expect(b, [0x1b]);
    b.addAll([0x5b, 0x41]);
    final k = parseKeyFromBuffer(b);
    expect(k?.code, KeyCode.up);
    expect(b, isEmpty);
  });

  test('parseKeyFromBuffer parses right arrow', () {
    final b = <int>[0x1b, 0x5b, 0x43];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.right);
  });

  test('parseKeyFromBuffer parses ctrl+a', () {
    final b = <int>[0x01];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.rune);
    expect(k.text, 'a');
    expect(k.modifiers, {KeyMod.ctrl});
  });

  // Issue #275: the LineEditor cluster rides raw control bytes — pin the
  // whole set the editor binds (w/u/k/y/t), not just ctrl+a.
  test('parseKeyFromBuffer parses the editor ctrl-key cluster', () {
    final cases = {0x17: 'w', 0x15: 'u', 0x0b: 'k', 0x19: 'y', 0x14: 't'};
    for (final MapEntry(:key, :value) in cases.entries) {
      final b = <int>[key];
      final k = parseKeyFromBuffer(b)!;
      expect(k.code, KeyCode.rune, reason: 'byte 0x${key.toRadixString(16)}');
      expect(k.text, value);
      expect(k.modifiers, {KeyMod.ctrl});
    }
  });

  test('parseKeyFromBuffer parses backspace', () {
    final b = <int>[0x7f];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.backspace);
  });

  test('parseKeyFromBuffer parses enter (CR)', () {
    final b = <int>[0x0d];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.enter);
  });

  test('parseKeyFromBuffer parses enter (LF, Linux/WSL terminals)', () {
    final b = <int>[0x0a];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.enter);
  });

  test('parseKeyFromBuffer parses tab', () {
    final b = <int>[0x09];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.tab);
  });

  test(
      'parseKeyFromBuffer never swallows a trailing control byte into a '
      'text run (burst input)', () {
    // A PTY/terminal delivering "ok\r" in ONE chunk: the printable run is
    // emitted first, the CR stays buffered and parses as Enter next.
    final b = <int>[0x6f, 0x6b, 0x0d];
    final text = parseKeyFromBuffer(b)!;
    expect(text.code, KeyCode.rune);
    expect(text.text, 'ok');
    expect(b, [0x0d]);
    final enter = parseKeyFromBuffer(b)!;
    expect(enter.code, KeyCode.enter);
    expect(b, isEmpty);
  });

  test(
      'parseKeyFromBuffer splits a multi-byte char from a following control '
      'byte', () {
    // "é\r" (é = 0xC3 0xA9): the rune stops before the CR.
    final b = <int>[0xc3, 0xa9, 0x0d];
    final text = parseKeyFromBuffer(b)!;
    expect(text.text, 'é');
    expect(b, [0x0d]);
  });

  test('parseKeyFromBuffer stops a text run before a tab byte', () {
    final b = <int>[0x61, 0x09];
    final text = parseKeyFromBuffer(b)!;
    expect(text.text, 'a');
    expect(b, [0x09]);
    final tab = parseKeyFromBuffer(b)!;
    expect(tab.code, KeyCode.tab);
  });

  test('parseKeyFromBuffer parses delete', () {
    final b = <int>[0x1b, 0x5b, 0x33, 0x7e];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.delete);
  });

  test(
      'parseKeyFromBuffer decodes ESC ESC as escape, keeping the second '
      'byte for the next pass', () {
    // Two Escape presses landing in one read chunk used to fall into the
    // `unknown` fallthrough and BOTH were swallowed — the abort Esc never
    // fired during a streaming run (fa issue #46). The first byte emits
    // Escape; the second re-parses as a lone ESC (the Program's
    // lone-escape timer then delivers it).
    final b = <int>[0x1b, 0x1b];
    final k = parseKeyFromBuffer(b)!;
    expect(k.code, KeyCode.escape);
    expect(b, [0x1b]);
    expect(parseKeyFromBuffer(b), isNull);
    expect(b, [0x1b]);
  });
}
