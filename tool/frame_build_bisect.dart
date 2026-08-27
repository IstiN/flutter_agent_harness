// Bisects the 260ms frame-build on a 150k-token session: times each
// view-build suspect on the exact message shape the repro driver uses.
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/compaction/token_estimation.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/types.dart';

void main() {
  final messages = <Message>[];
  final transcriptLines = <String>[];
  for (var i = 0; i < 300; i++) {
    final body = ' слово' * (2000 ~/ 6);
    messages.add(
      UserMessage.text('${i % 2 == 0 ? 'ctx line' : 'answer'} $i: $body'),
    );
    transcriptLines.add('${i % 2 == 0 ? 'ctx line' : 'answer'} $i: $body');
  }

  // 1) estimateContextTokens over the whole settled context.
  for (var attempt = 0; attempt < 3; attempt++) {
    final sw = Stopwatch()..start();
    final tokens = estimateContextTokens(messages).tokens;
    print('estimateContextTokens: ${sw.elapsedMilliseconds}ms ($tokens tok)');
  }

  // 2) full markdown pass over the transcript (the OLD non-incremental cost).
  final sw2 = Stopwatch()..start();
  final formatted = AnsiMarkdown(width: 120).formatAll(transcriptLines);
  print(
    'formatAll(${transcriptLines.length} lines): '
    '${sw2.elapsedMilliseconds}ms -> ${formatted.length} lines',
  );

  // 3) wrap + starts index over the formatted lines.
  final sw3 = Stopwatch()..start();
  var sink = 0;
  final starts = <int>[];
  var row = 0;
  for (final line in formatted) {
    starts.add(row);
    final wrapped = wrapAnsiLine(line, 120);
    row += wrapped.length;
    sink += wrapped.length;
  }
  print('wrap+starts: ${sw3.elapsedMilliseconds}ms rows=$row sink=$sink');

  // 4) TranscriptMarkdown.sync under streaming appends: (a) appends with
  // trailing newlines (new lines), (b) appends WITHOUT newlines (the last
  // line grows — does the identity-boundary force full rebuilds?).
  final tx = TranscriptMarkdown(width: 120);
  tx.sync(transcriptLines);
  for (final mode in ['new-lines', 'grow-last']) {
    // Re-sync the same source a few times: warm.
    for (var i = 0; i < 3; i++) {
      tx.sync(transcriptLines);
    }
    final sw = Stopwatch()..start();
    if (mode == 'new-lines') {
      var grown = transcriptLines;
      for (var i = 0; i < 20; i++) {
        grown = [...grown, 'tail line $i with some text'];
        tx.sync(grown);
      }
    } else {
      var src = [...transcriptLines];
      var last = src.removeLast();
      for (var i = 0; i < 20; i++) {
        last = '$last +chunk$i';
        tx.sync([...src, last]);
      }
    }
    print(
      'sync($mode) 20 appends: ${sw.elapsedMilliseconds}ms '
      '(resumed=${TranscriptMarkdown.debugResumedPasses} '
      'rebuilds=${TranscriptMarkdown.debugFullRebuilds})',
    );
  }
  exit(0);
}
