// Issue #496 (RED first): after submitting a message the text stayed in the
// composer input row, duplicating the sent echo. Root cause this grid test
// pins down: the painted frame can exceed the physical screen (the viewport
// floors at 0 while pinned-echo/job-board/queue chrome keeps painting), so
// the frame truncates/scrolls, the real composer rows never reach the glass
// and STALE rows below the painted region keep the submitted text + cursor.
//
// Grid contract (owner issue #496), asserted on the RENDERED grid at
// 100x40 AND 80x24 mid-run:
//   (1) the composer input row holds ONLY the cursor — zero submitted text;
//   (2) the sent echo appears EXACTLY ONCE, directly above the ticker row;
//   (3) the ticker updates IN PLACE (between two 1 Hz ticks only the
//       spinner glyph and the seconds cell move, on the busy row alone);
//   (4) the footer is on its own last row, above it the input-frame rule;
//   (5) zero wrapped/overlapping rows: the frame is exactly the screen
//       height and no row exceeds the width.
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

const _message = 'тестовое сообщение';

/// Bulk that overflows the old budget: 33 queued follow-ups render 35 rows
/// of queue block (header + rows + hint) — with the busy chrome this exceeds
/// the physical height, which is exactly the owner's overrun shape.
const _queueFillers = 33;

void main() {
  for (final (columns, rowsCount) in [(100, 40), (80, 24)]) {
    test('composer echo stays out of the input row at $columns x$rowsCount',
        () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_496_');
      // Short cwd so the footer's tail markers stay visible at 80 columns.
      final workspace = Directory('/tmp/fa496ws')..createSync(recursive: true);
      addTearDown(() => workspace.deleteSync(recursive: true));
      final server = await MockLlmServer.start()
        // Turn 1 seeds the job board with a collapsed turn of inline
        // foreground jobs (the owner's "running forever" shape).
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueText('seeds done')
        // Turn 2 is the probe submit's own run: a long tool call keeps the
        // ticker alive while the queue fills and the frames are sampled.
        ..enqueueToolCall('bash', '{"command": "sleep 25"}')
        ..enqueueText('probe turn done');
      addTearDown(server.stop);
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
''');

      final harness = await FaCliHarness.spawn(
        workingDirectory: workspace.path,
        extraEnv: {'HOME': tempHome.path},
        columns: columns,
        rows: rowsCount,
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();

      // Seed turn: instant tool jobs, then idle again.
      harness.sendText('seed the job board');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText(
        'seeds done',
        timeout: const Duration(seconds: 40),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // THE SUBMIT under test: starts its own run — the echo lands in the
      // history directly above the busy row, and the composer must go
      // cursor-only from here on.
      harness.sendText(_message);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText(
        '· submit',
        timeout: const Duration(seconds: 20),
      );

      // Fill the queue mid-run: the old frame overflowed the screen here.
      for (var i = 1; i <= _queueFillers; i++) {
        harness.sendText('hold the queue ${i.toString().padLeft(2, '0')}');
        await Future<void>.delayed(const Duration(milliseconds: 40));
        harness.sendEnter();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await harness.waitForText(
        'queued (',
        timeout: const Duration(seconds: 15),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final gridA = _grid(harness);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final gridB = _grid(harness);

      String dump(List<String> grid) => grid
          .asMap()
          .entries
          .map((e) => '${e.key.toString().padLeft(2)}|${e.value}')
          .join('\n');

      // ── (5a) the frame is EXACTLY the screen: zero overrun rows ────────
      expect(gridA.length, rowsCount,
          reason: 'frame must fit the screen; painted:\n${dump(gridA)}');
      for (final row in gridA) {
        expect(row.runes.length, lessThanOrEqualTo(columns),
            reason: 'row exceeds the width:\n${dump(gridA)}');
      }

      // ── (4) footer on its own last row, rule above it ───────────────────
      var last = gridA.length - 1;
      while (last > 0 && gridA[last].trim().isEmpty) {
        last--;
      }
      expect(gridA[last], contains(' · turn '),
          reason: 'footer is the last row:\n${dump(gridA)}');
      expect(gridA[last - 1].trim(), '─' * columns,
          reason: 'the input frame rule separates composer and footer');

      // ── (1) composer input row: cursor only, zero submitted text ────────
      final rule = '─' * columns;
      final rules = <int>[
        for (var i = 0; i < gridA.length; i++)
          if (gridA[i].trim() == rule) i,
      ];
      expect(rules.length, greaterThanOrEqualTo(2),
          reason: 'input frame rules visible:\n${dump(gridA)}');
      final composerRegion =
          gridA.sublist(rules[rules.length - 2] + 1, rules.last);
      expect(composerRegion, <String>[''],
          reason: 'the input row is a single EMPTY row (physical cursor '
              'only — never the submitted text):\n${dump(gridA)}');

      // ── (2) the sent echo appears EXACTLY ONCE, above the ticker ────────
      final busyRows = <int>[
        for (var i = 0; i < gridA.length; i++)
          if (gridA[i].contains('· submit')) i,
      ];
      expect(busyRows, hasLength(1),
          reason: 'exactly one ticker row:\n${dump(gridA)}');
      final echoRows = <int>[
        for (var i = 0; i < gridA.length; i++)
          if (gridA[i].contains(_message)) i,
      ];
      expect(echoRows, [busyRows.single - 1],
          reason: 'the submitted text appears exactly once, on the row '
              'directly above the ticker:\n${dump(gridA)}');

      // ── (3) the ticker updates IN PLACE ─────────────────────────────────
      expect(gridB.length, gridA.length, reason: 'no row count drift');
      var changed = 0;
      var busyIdx = -1;
      for (var i = 0; i < gridA.length; i++) {
        if (gridA[i] != gridB[i]) {
          changed++;
          busyIdx = i;
        }
      }
      expect(changed, 1,
          reason: 'only the busy row may move between ticks:\n'
              'A:\n${dump(gridA)}\nB:\n${dump(gridB)}');
      expect(busyIdx, busyRows.single);
      String masked(String row) => row
          .substring(row.indexOf(' ') + 1)
          .replaceAll(RegExp(r'\d'), '#');
      expect(masked(gridA[busyIdx]), masked(gridB[busyIdx]),
          reason: 'inside the ticker only spinner + seconds move');
    });
  }
}

/// The rendered screen: right-trimmed rows (grid math keeps positions).
List<String> _grid(FaCliHarness harness) => [
  for (final line in harness.viewportLines) line.trimRight(),
];
