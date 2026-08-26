// tool/table_eyeball.dart — human-eye dump of table rendering frames.
//
// Prints, for three representative scenarios, what the USER would see at
// each streaming flush: the raw bytes (escapes shown as ⟨ESC⟩) next to the
// stripped glyphs, so misalignment/duplication is checkable by eye.
//
//   dart run tool/table_eyeball.dart > /tmp/table_eyeball.txt

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';

String visible(String s) => s.replaceAll('\x1b', '⟨ESC⟩');

void section(String title) {
  print('');
  print('=' * 72);
  print(title);
  print('=' * 72);
}

void frame(int n, List<String> lines) {
  print('--- frame $n (stripped) ---');
  for (final l in lines) {
    final bare = l.replaceAll(RegExp('\x1B\\[[0-9;]*[A-Za-z]'), '');
    print(bare);
  }
}

void main() {
  section('SCENARIO 1: simple table grows row by row (width 60)');
  final tx1 = TranscriptMarkdown(width: 60);
  final doc1 = [
    '| name | qty |',
    '| ---- | --- |',
    '| alpha | 12 |',
    '| beta | 345 |',
    'after',
  ];
  for (var n = 1; n <= doc1.length; n++) {
    frame(n, tx1.sync(doc1.sublist(0, n)));
  }

  section('SCENARIO 2: column widens LATE (cell wider than header)');
  final tx2 = TranscriptMarkdown(width: 70);
  final doc2 = [
    '| a | b |',
    '| - | - |',
    '| short | x |',
    '| this cell is much wider than the header | y |',
    '| pad | z |',
    'after',
  ];
  for (var n = 1; n <= doc2.length; n++) {
    frame(n, tx2.sync(doc2.sublist(0, n)));
  }

  section('SCENARIO 3: CJK + emoji cells (display-width alignment)');
  final tx3 = TranscriptMarkdown(width: 60);
  final doc3 = [
    '| 名前 | 説明 | status |',
    '| :--- | ---: | :-: |',
    '| 中文テスト | короткая 🚀 | ok |',
    '| x | 説明が長いセルです | 🎉 |',
    'after',
  ];
  for (var n = 1; n <= doc3.length; n++) {
    frame(n, tx3.sync(doc3.sublist(0, n)));
  }

  section('SCENARIO 4: malformed table (no separator) -> raw fallback');
  final tx4 = TranscriptMarkdown(width: 60);
  final doc4 = ['| just | pipes |', '| and | more |', 'resume prose'];
  for (var n = 1; n <= doc4.length; n++) {
    frame(n, tx4.sync(doc4.sublist(0, n)));
  }

  section('PARITY LEDGER (raw-with-ESC bytes) scenario 2 final frame');
  final raw = tx2.sync(doc2);
  print(visible(raw.join('\n')));
}
