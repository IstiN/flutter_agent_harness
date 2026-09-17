// Chip reservation (issue #519 AC1): a paste chip's rows (chips + hint)
// are reserved in the input-zone height math, so attaching or removing a
// chip never moves the composer zone and the frame never spills past the
// terminal height — the bottom chrome cannot tear (double separator /
// stale status digits like the `20 6 1` residue on 111_paste_sent.png).
library;


import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:test/test.dart';

final _chip = TuiImageAttachment(
  name: 'clipboard-1.png',
  mimeType: 'image/png',
  bytes: List.filled(12, 0),
);

FaTuiModel build({List<TuiImageAttachment> attachments = const []}) {
  return FaTuiModel(
    callbacks: FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'ready',
      prompt: 'fa> ',
    ),
    isExited: () => false,
    termWidth: 80,
    termHeight: 12,
  ).copyWith(attachments: attachments, inputText: 'hello');
}

/// The frame's physical rows (the cursor-hide suffix carries no newline).
List<String> frame(FaTuiModel m) => m.view().content.split('\n');

int _inputRow(List<String> rows) =>
    rows.indexWhere((r) => r.replaceAll(_ansi, '').contains('hello'));

final _ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)');

void main() {
  test('AC1 UT-chip-reservation: a paste chip never moves the composer '
      'zone nor grows the frame past the terminal height', () {
    final bare = build();
    final chipped = build(attachments: [_chip]);
    final sent = build(attachments: [_chip]).copyWith(attachments: const []);

    final bareRows = frame(bare);
    final chipRows = frame(chipped);
    final sentRows = frame(sent);

    // Fixture sanity: the chip and its hint really rendered.
    expect(
      chipRows.map((r) => r.replaceAll(_ansi, '')),
      containsAll([
        contains('[image: clipboard-1.png 12B]'),
        contains('chips send with your next message'),
      ]),
    );

    // The frame fills exactly the terminal: no row can land outside the
    // screen, so no bottom-chrome cell can survive a rewrite as residue.
    expect(bareRows.length, 12, reason: 'bare frame height');
    expect(chipRows.length, 12,
        reason: 'chip rows must carve out of the viewport, not add rows');
    expect(sentRows.length, 12, reason: 'removing the chip restores, never '
        'shrinks, the frame');

    // The composer zone sits at the same absolute row with or without the
    // chip — "поехавший инпут" is the shift this forbids.
    expect(_inputRow(chipRows), _inputRow(bareRows),
        reason: 'input row must not shift when a chip appears');
    expect(_inputRow(sentRows), _inputRow(bareRows),
        reason: 'input row must return to its bare position after the send');
  });
}
