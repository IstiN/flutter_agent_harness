// tool/tx_bisect_probe.dart — exact-lens replication of the chunked burst
// test to isolate the first divergent sync step.
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';

void run(int chunk) {
  final doc = [
    '# Report',
    'prose lead',
    '| kpi | v | note |',
    '| --- | -: | ---- |',
    '| 見出し | 42 | ok 🚀 |',
    '| other | -7 | `x \\| y` |',
    '',
    '| t1 | t2 |',
    '| -- | -- |',
    'trailer **b**',
  ];
  final s = TranscriptMarkdown(width: 60);
  for (var i = 0; i < doc.length; i += chunk) {
    final end = i + chunk > doc.length ? doc.length : i + chunk;
    final src = doc.sublist(0, end);
    final inc = s.sync(src);
    final one = AnsiMarkdown(width: 60).formatAll(src);
    if (inc.join('\n') != one.join('\n')) {
      print('FIRST DIVERGENCE chunk=$chunk n=$end');
      print('--- INC ---');
      for (var k = 0; k < inc.length; k++) {
        print('$k: ${inc[k].replaceAll('\x1b', '<E>')}');
      }
      print('--- ONE ---');
      for (var k = 0; k < one.length; k++) {
        print('$k: ${one[k].replaceAll('\x1b', '<E>')}');
      }
      return;
    }
  }
  print('chunk=$chunk all steps equal');
}

void main() {
  run(2);
  run(3);
  run(7);

  // Front-trim-while-open exact test sequence:
  print('=== C trimmed-open exact ===');
  final growing = ['old intro A', 'old intro B', '| h | g |', '| - | - |', '| 1 | 2 |'];
  final s = TranscriptMarkdown(width: 60);
  s.sync(growing);
  final trimmedOpen = [...growing.skip(2), '| r3 | long-cell-value |'];
  var out = s.sync(trimmedOpen);
  var one = AnsiMarkdown(width: 60).formatAll(trimmedOpen);
  print('step1 equal=${out.join('\n') == one.join('\n')}');
  if (out.join('\n') != one.join('\n')) {
    for (var k = 0; k < out.length; k++) {
      print('INC $k: ${out[k].replaceAll('\x1b', '<E>')}');
    }
    for (var k = 0; k < one.length; k++) {
      print('ONE $k: ${one[k].replaceAll('\x1b', '<E>')}');
    }
  }
  final resumed = [...trimmedOpen, '| r4 | v |', 'close.'];
  out = s.sync(resumed);
  one = AnsiMarkdown(width: 60).formatAll(resumed);
  print('step2 equal=${out.join('\n') == one.join('\n')}');
  if (out.join('\n') != one.join('\n')) {
    print('--- INC ---');
    for (var k = 0; k < out.length; k++) {
      print('$k: ${out[k].replaceAll('\x1b', '<E>')}');
    }
    print('--- ONE ---');
    for (var k = 0; k < one.length; k++) {
      print('$k: ${one[k].replaceAll('\x1b', '<E>')}');
    }
  }
}
