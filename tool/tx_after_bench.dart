import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';

void main() {
  // Build a 2000-line mixed transcript identical in shape to the baseline.
  final raw = <String>[];
  for (var i = 0; i < 2000; i++) {
    switch (i % 10) {
      case 0:
        raw.add('## Section $i');
      case 1:
        raw.add(
          '- bullet item with `inline code` and '
          'a [link](https://example.com/a/b) tail',
        );
      case 2 || 3 || 4:
        raw.add(
          'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do '
          'eiusmod tempor incididunt ut labore **et dolore** magna aliqua — '
          'line $i of the assistant narrative stream.',
        );
      case 5:
        raw.add('```dart');
      case 6 || 7:
        raw.add('final x = compute(seed: $i); // 中文注释 🚀 emoji tail');
      case 8:
        raw.add('```');
      default:
        raw.add('| col a | col b | col c $i |');
    }
  }
  final tx = TranscriptMarkdown(width: 100);
  tx.sync(raw); // initial load = one full pass (baseline equivalent)

  var sink = 0;
  final sw = Stopwatch();

  // (a) GROW pass — what a streaming flush pays when output arrives.
  var grows = 0;
  sw.start();
  for (var b = 0; b < 100; b++) {
    raw.addAll([
      '**Burst $b** prose tail with `code` spans and a [link](https://x.y).',
      '```dart',
      'run(seed: $b);',
      '```',
      '',
    ]);
    tx.sync(raw);
    sink += tx.wrappedRows.length;
    grows++;
  }
  sw.stop();
  final growUsPerFlush = sw.elapsedMicroseconds / grows;

  // (b) CACHE-HIT pass — every keystroke's implicit re-render path when no
  // new output arrived between two key events (typing while idle-stream).
  sw.reset();
  const hits = 3000;
  for (var k = 0; k < hits; k++) {
    tx.sync(raw);
    sink += tx.lineStartRows.length;
  }
  sw.stop();
  print(
    'AFTER(grow)   : ${growUsPerFlush.toStringAsFixed(0)} µs/flush '
    '(baseline full pass: 26960 µs)',
  );
  print(
    'AFTER(cache-hit): '
    '${(sw.elapsedMicroseconds / hits).toStringAsFixed(2)} µs/sync',
  );
  if (sink == -1) throw StateError('unreachable');
}
