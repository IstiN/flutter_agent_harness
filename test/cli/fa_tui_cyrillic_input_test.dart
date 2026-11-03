/// Russian (any non-ASCII) typing into the TUI composer and prompt sheets
/// through a chunk-batching ConPTY terminal (Alacritty): the vendored
/// parser emits one rune per key, and the insert gates accept
/// multi-character printable texts. Before the fix a batched key ('пр' —
/// two Cyrillic keystrokes coalesced into one stdin read) was dropped
/// whole by the `length == 1` gates, so Russian typed into Alacritty
/// vanished (fa #1982 follow-up).
library;

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:test/test.dart';

FaTuiModel model() => FaTuiModel(
  callbacks: FaTuiCallbacks(
    onSubmit: (_, {images = const []}) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => 'test',
    prompt: 'fa> ',
  ),
  isExited: () => false,
  termHeight: 12,
);

FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

/// The key stream a ConPTY delivers for [text] typed on a Russian layout:
/// every Cyrillic keystroke is 2 UTF-8 bytes and Alacritty coalesces
/// bursts, so the decoder emits one KeyPressMsg per rune from ONE stdin
/// chunk — the wire shape that used to lose characters.
List<Msg> chunkedKeys(String text) => [
  for (final rune in text.runes)
    KeyPressMsg(TeaKey(code: KeyCode.rune, text: String.fromCharCode(rune))),
];

void main() {
  group('composer accepts multi-character printable keys (ConPTY bursts)', () {
    test("a batched 'пр' key inserts BOTH characters", () {
      final m = send(
        model(),
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: 'пр')),
      );

      expect(m.inputText, 'пр');
    });

    test("the whole word 'привет' in one chunk types completely", () {
      var m = model();
      for (final msg in chunkedKeys('привет')) {
        m = send(m, msg);
      }

      expect(m.inputText, 'привет');
    });

    test('mixed ASCII+Cyrillic chunk types in order', () {
      var m = model();
      for (final msg in chunkedKeys('fa-привет')) {
        m = send(m, msg);
      }

      expect(m.inputText, 'fa-привет');
    });

    test('a control-char text payload is still ignored', () {
      // Terminals that attach a text payload to a control key must not
      // print it — the printable-runes filter keeps the guard.
      final m = send(
        model(),
        KeyPressMsg(TeaKey(code: KeyCode.enter, text: '\r')),
      );

      expect(m.inputText, isEmpty);
    });

    test('a command chord is still ignored (catch-all insert guard)', () {
      // ctrl+a carries the BASE LETTER in text (dart_tui decoder) — the
      // macOS Cmd+Left "aaaa" regression guard must survive the gate swap.
      final m = send(
        model(),
        KeyPressMsg(
          const TeaKey(code: KeyCode.rune, text: 'a', modifiers: {KeyMod.ctrl}),
        ),
      );

      expect(m.inputText, isEmpty);
    });
  });

  group('prompt sheet accepts multi-character printable keys', () {
    FaTuiModel sheet() => model().copyWith(
      prompt: TuiPromptState(SecretPromptSpec(name: 'KEY', reason: 'r')),
    );

    test("a batched 'пр' keystroke lands in the sheet", () {
      final m = send(
        sheet(),
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: 'пр')),
      );

      expect(m.prompt?.secretValue, 'пр');
    });

    test("typing a whole Russian word into the key sheet", () {
      var m = sheet();
      for (final msg in chunkedKeys('привет')) {
        m = send(m, msg);
      }

      expect(m.prompt?.secretValue, 'привет');
    });
  });
}
