/// The Ctrl+V paste flow at the model level (issue #276): a wired reader
/// turns the keystroke into a chip, failures print their named reason,
/// slash/bang submits keep the chips while plain submits consume them and
/// hand the images to the host callback.
library;

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
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
}
