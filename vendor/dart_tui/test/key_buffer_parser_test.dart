import 'package:dart_tui/src/key_buffer_parser.dart';
import 'package:dart_tui/src/msg.dart';
import 'package:test/test.dart';

void main() {
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
}
