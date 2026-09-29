/// The Ctrl+V paste flow at the model level (issue #276): a wired reader
/// turns the keystroke into a chip, failures print their named reason,
/// slash/bang submits keep the chips while plain submits consume them and
/// hand the images to the host callback.
library;

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:test/test.dart';

/// A PNG signature plus a payload — sniffable, under every cap.
final _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x01, 0x02,
];

/// Not an image under any magic the sniffer knows.
final _garbage = <int>[1, 2, 3, 4, 5, 6, 7, 8];

FaTuiModel build({
  Future<PasteboardRead> Function()? reader,
  void Function(String line, List<TuiImageAttachment> images)? onSubmit,
  List<TuiImageAttachment> attachments = const [],
  String inputText = 'hello',
  DateTime Function()? now,
}) {
  return FaTuiModel(
    callbacks: FaTuiCallbacks(
      onSubmit: (line, {images = const []}) async =>
          onSubmit?.call(line, images),
      onSteer: (messages, {images}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'test',
      prompt: 'fa> ',
      readClipboardImage: reader,
    ),
    isExited: () => false,
    termHeight: 12,
    now: now,
  ).copyWith(attachments: attachments, inputText: inputText);
}

void main() {
  test('ctrl+v with a wired reader attaches a chip', () async {
    var model = build(reader: () async => PasteboardImage(_png));
    final (next, cmd) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    model = next as FaTuiModel;
    // The keystroke produced the async read; its result message carries
    // the image into a chip.
    final followUp = await cmd?.call();
    if (followUp != null) {
      model = model.update(followUp).$1 as FaTuiModel;
    }

    expect(model.attachments, hasLength(1));
    expect(model.attachments.first.chip, '[image: clipboard-1.png 12B]');
    expect(model.view().content, contains('[image: clipboard-1.png 12B]'));
  });

  test('an unavailable pasteboard prints its named reason', () async {
    var model = build(
      reader: () async =>
          const PasteboardUnavailable('no pasteboard on this host'),
    );
    final (next, cmd) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    model = next as FaTuiModel;
    final followUp = await cmd?.call();
    if (followUp != null) {
      model = model.update(followUp).$1 as FaTuiModel;
    }

    expect(model.attachments, isEmpty);
    expect(
      model.outputLines.join('\n'),
      contains('no pasteboard on this host'),
    );
  });

  test('non-image clipboard bytes print the named error', () async {
    var model = build(reader: () async => PasteboardImage(_garbage));
    final (next, cmd) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    model = next as FaTuiModel;
    final followUp = await cmd?.call();
    if (followUp != null) {
      model = model.update(followUp).$1 as FaTuiModel;
    }

    expect(model.outputLines.join('\n'), contains('magic bytes'));
  });

  test('ctrl+v without a reader prints the unavailable hint', () async {
    var model = build();
    final (next, cmd) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    model = next as FaTuiModel;
    expect(cmd, isNull, reason: 'no reader: a synchronous note, no work');
    expect(model.attachments, isEmpty);
    expect(model.outputLines.join('\n'), contains('clipboard'));
  });

  test('a plain submit consumes the chips and passes them to the host',
      () async {
    final submitted = <(String, List<TuiImageAttachment>)>[];
    var model = build(
      attachments: [
        TuiImageAttachment(
          name: 'clipboard-1.png',
          mimeType: 'image/png',
          bytes: _png,
        ),
      ],
      onSubmit: (line, images) => submitted.add((line, images)),
    );
    final (next, cmd) = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = next as FaTuiModel;

    expect(model.attachments, isEmpty, reason: 'chips are consumed');
    await cmd?.call();
    expect(submitted, hasLength(1));
    expect(submitted.single.$1, 'hello');
    expect(submitted.single.$2, hasLength(1));
  });

  test('a slash submit keeps the chips for the next message', () {
    var model = build(
      attachments: [
        TuiImageAttachment(
          name: 'clipboard-1.png',
          mimeType: 'image/png',
          bytes: _png,
        ),
      ],
      inputText: '/help',
    );
    final (next, cmd) = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = next as FaTuiModel;

    expect(model.attachments, hasLength(1), reason: 'slash keeps chips (E2)');
  });

  test('a theme swap repaints without losing composer state', () {
    var model = build();
    model = model.update(const ThemeSwappedMsg()).$1 as FaTuiModel;
    expect(model.inputText, 'hello');
    expect(model.view().content, contains('hello'));
  });

  // --- Issue #1067: any paste action probes the clipboard for images ---

  test('an empty bracketed paste with a clipboard image attaches a chip',
      () async {
    var model = build(reader: () async => PasteboardImage(_png), inputText: '');
    final (next, cmd) = model.update(PasteMsg(''));
    model = next as FaTuiModel;
    expect(cmd, isNotNull, reason: 'the paste fires the clipboard probe');
    final followUp = await cmd?.call();
    model = model.update(followUp!).$1 as FaTuiModel;

    expect(model.attachments, hasLength(1));
    expect(model.attachments.first.chip, '[image: clipboard-1.png 12B]');
  });

  test('a text bracketed paste inserts the text AND attaches the image',
      () async {
    var model = build(reader: () async => PasteboardImage(_png), inputText: '');
    final (next, cmd) = model.update(PasteMsg('pasted text'));
    model = next as FaTuiModel;
    expect(model.inputText, 'pasted text',
        reason: 'text insertion is unchanged');
    final followUp = await cmd?.call();
    model = model.update(followUp!).$1 as FaTuiModel;

    expect(model.inputText, 'pasted text', reason: 'attach is additive');
    expect(model.attachments, hasLength(1));
  });

  test('a bracketed paste without an image stays silent — no chip, no note',
      () async {
    var model = build(
      reader: () async =>
          const PasteboardUnavailable('no pasteboard on this host'),
      inputText: '',
    );
    final linesBefore = model.outputLines.length;
    final (next, cmd) = model.update(PasteMsg('plain words'));
    model = next as FaTuiModel;
    final followUp = await cmd?.call();
    model = model.update(followUp!).$1 as FaTuiModel;

    expect(model.inputText, 'plain words');
    expect(model.attachments, isEmpty);
    expect(model.outputLines.length, linesBefore,
        reason: 'failed probes never print on a normal text paste');
  });

  test('a bracketed paste without a wired reader inserts text, no probe', () {
    var model = build(inputText: '');
    final (next, cmd) = model.update(PasteMsg('plain words'));
    model = next as FaTuiModel;

    expect(cmd, isNull);
    expect(model.inputText, 'plain words');
  });

  test('prompt mode never probes — pastes stay plain text (AC4)', () {
    var model = build(reader: () async => PasteboardImage(_png)).copyWith(
      prompt: TuiPromptState(TextPromptSpec(question: 'Pick')),
    );
    final (next, cmd) = model.update(PasteMsg('secret-key'));
    model = next as FaTuiModel;

    expect(cmd, isNull, reason: 'no clipboard probe in prompt mode');
    expect(model.prompt, isNotNull, reason: 'paste went to the prompt buffer');
    expect(model.attachments, isEmpty);
  });

  test('ctrl+v and the bracketed paste of one action attach ONE chip',
      () async {
    var t = 1000;
    var model = build(
      reader: () async => PasteboardImage(_png),
      now: () => DateTime.fromMillisecondsSinceEpoch(t),
      inputText: '',
    );
    // One user paste in a bracketed-paste terminal: the key event AND the
    // paste message both arrive. Only the first path fires a probe.
    final (m1, keyCmd) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    final (m2, pasteCmd) = (m1 as FaTuiModel).update(PasteMsg(''));
    expect(pasteCmd, isNull,
        reason: 'the twin path never spawns a second subprocess read');
    final keyResult = await keyCmd?.call();
    final (m3, _) = (m2 as FaTuiModel).update(keyResult!);

    expect((m3 as FaTuiModel).attachments, hasLength(1));
  });

  test('a bracketed-paste twin after a slow read still spawns no probe',
      () async {
    var t = 1000;
    var model = build(
      reader: () async => PasteboardImage(_png),
      now: () => DateTime.fromMillisecondsSinceEpoch(t),
      inputText: '',
    );
    // The key-event probe fires at t=1000 but its result lands late; the
    // twin PasteMsg arrives at t=1400 — inside the gesture window — and
    // must not probe again regardless of result timing.
    final (m1, keyCmd) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    t = 1400;
    final (m2, pasteCmd) = (m1 as FaTuiModel).update(PasteMsg(''));
    expect(pasteCmd, isNull);
    final keyResult = await keyCmd?.call();
    final (m3, _) = (m2 as FaTuiModel).update(keyResult!);

    expect((m3 as FaTuiModel).attachments, hasLength(1));
  });

  test('a second paste after the gesture window probes and attaches again',
      () async {
    var t = 1000;
    var model = build(
      reader: () async => PasteboardImage(_png),
      now: () => DateTime.fromMillisecondsSinceEpoch(t),
      inputText: '',
    );
    final (m1, cmd1) = model.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    t = 1100;
    final firstResult = await cmd1?.call();
    final (m2, _) = (m1 as FaTuiModel).update(firstResult!);
    expect((m2 as FaTuiModel).attachments, hasLength(1));

    // A deliberate second paste much later attaches its own chip.
    t = 1700; // beyond the 500ms gesture window
    final (m3, cmd2) = m2.update(
      KeyPressMsg(
        const TeaKey(code: KeyCode.rune, text: 'v', modifiers: {KeyMod.ctrl}),
      ),
    );
    final secondResult = await cmd2?.call();
    final (m4, _) = (m3 as FaTuiModel).update(secondResult!);

    expect((m4 as FaTuiModel).attachments, hasLength(2));
  });

  test('an oversized image on an EMPTY paste names the failure (image intent)',
      () async {
    var model = build(
      reader: () async =>
          PasteboardImage(List.filled(maxPasteImageBytes + 1, 0)),
      inputText: '',
    );
    final (next, cmd) = model.update(PasteMsg(''));
    model = next as FaTuiModel;
    final followUp = await cmd?.call();
    model = model.update(followUp!).$1 as FaTuiModel;

    expect(model.attachments, isEmpty);
    expect(
      model.outputLines.join('\n'),
      contains('clipboard image too large'),
    );
  });

  test('an oversized image on a text paste stays silent', () async {
    var model = build(
      reader: () async =>
          PasteboardImage(List.filled(maxPasteImageBytes + 1, 0)),
      inputText: '',
    );
    final linesBefore = model.outputLines.length;
    final (next, cmd) = model.update(PasteMsg('plain words'));
    model = next as FaTuiModel;
    final followUp = await cmd?.call();
    model = model.update(followUp!).$1 as FaTuiModel;

    expect(model.inputText, 'plain words');
    expect(model.attachments, isEmpty);
    expect(model.outputLines.length, linesBefore,
        reason: 'a normal text paste never prints clipboard errors');
  });
}
