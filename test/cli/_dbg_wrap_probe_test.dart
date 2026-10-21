import 'dart:math';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

final _rng = Random(1496);

const _words = [
  'lorem', 'ipsum', 'dolor', 'sit', 'amet', 'consectetur', 'adipiscing',
  'elit', 'sed', 'do', 'eiusmod', 'tempor', 'incididunt', 'ut', 'labore',
  'et', 'dolore', 'magna', 'aliqua',
];

String asciiProse(int cells) {
  final buf = StringBuffer();
  while (buf.length < cells) {
    buf.write(_words[_rng.nextInt(_words.length)]);
    buf.write(' ');
  }
  return buf.toString().substring(0, cells);
}

// Replicates the failing test's exact measurement loop with per-run prints.
void main() {
  test('probe: per-run timings of the sustained-contention shape', () {
    const baseCells = 100000;
    const spikeUs = 30000;
    final spiked = {6, 7, 8, 9, 16, 17, 18, 19, 26, 27, 28, 29};
    var call = 0;
    int measure(void Function() body) {
      final sw = Stopwatch()..start();
      body();
      sw.stop();
      call++;
      final spike = spiked.contains(call) ? spikeUs : 0;
      final t = sw.elapsedMicroseconds;
      // ignore: avoid_print
      print('call $call: ${t / 1000.0}ms'
          '${spike > 0 ? ' (+${spikeUs / 1000}ms fake spike)' : ''}');
      return t + spike;
    }

    for (var a = 0; a < 3; a++) {
      // small
      wrapAnsiLine(asciiProse(baseCells), 80);
      var minSmall = double.infinity;
      for (var i = 0; i < 5; i++) {
        final t = measure(() => wrapAnsiLine(asciiProse(baseCells), 80)) /
            1000.0;
        if (t < minSmall) minSmall = t;
      }
      // doubled
      wrapAnsiLine(asciiProse(baseCells * 2), 80);
      var minDoubled = double.infinity;
      for (var i = 0; i < 5; i++) {
        final t =
            measure(() => wrapAnsiLine(asciiProse(baseCells * 2), 80)) /
                1000.0;
        if (t < minDoubled) minDoubled = t;
      }
      // ignore: avoid_print
      print('attempt $a: minSmall=${minSmall.toStringAsFixed(3)}ms '
          'minDoubled=${minDoubled.toStringAsFixed(3)}ms '
          'ratio=${(minDoubled / minSmall).toStringAsFixed(3)}');
    }
    expect(true, isTrue);
  });
}
