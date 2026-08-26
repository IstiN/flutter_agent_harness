// TUI transcript hot-path microbenchmark.
//
// Measures the two costs paid on EVERY coalesced streaming flush
// (`FaTuiController._outputFlushInterval`, currently 50 ms):
//
//   1. markdown formatAll over the whole bounded history (maxLines cap);
//   2. ANSI-safe wrapping of every formatted line + start-row index build.
//
// Run:  dart run tool/tui_stream_bench.dart [--lines N] [--iters N]
// Numbers are for the GOAL doc deltas; CI does not gate on timing.

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';

void main(List<String> args) {
  final lines = _intArg(args, '--lines', 2000);
  final iters = _intArg(args, '--iters', 25);

  // Mixed-content history resembling a long coding session transcript:
  // prose paragraphs, headers, bullets, inline code links, fenced code
  // blocks, CJK/emoji wide chars, one table — the worst realistic case.
  final raw = <String>[];
  for (var i = 0; i < lines; i++) {
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

  var sink = 0;
  final sw = Stopwatch()..start();
  for (var iter = 0; iter < iters; iter++) {
    final formatted = AnsiMarkdown(width: 100).formatAll(raw);
    for (final line in formatted) {
      sink += wrapAnsiLine(line, 100).length;
    }
  }
  final elapsedMs = sw.elapsedMilliseconds / iters;
  sw.stop();

  // ignore: avoid_print

  if (sink == -1) throw StateError('unreachable');

  print('lines=$lines iters=$iters mixed-content transcript');
  print(
    'full formatAll+wrap pass: ${elapsedMs.toStringAsFixed(2)} ms/pass '
    '(~${(1000 / elapsedMs).toStringAsFixed(0)} passes would saturate 1 s)',
  );
  print(
    '=> per-50ms-streaming-flush budget share: '
    '${(elapsedMs / 50 * 100).toStringAsFixed(1)}% of the event loop',
  );
}

int _intArg(List<String> args, String name, int fallback) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return int.tryParse(args[index + 1]) ?? fallback;
}
