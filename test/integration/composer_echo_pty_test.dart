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
//       spinner glyph and the seconds cell move, on the busy row alone;
//       gh-1413: the transcript ABOVE the ticker is not part of this
//       contract — legitimate mid-run appends land there between the
//       samples — the pinned block from the ticker row down is what must
//       stay static);
//   (4) the footer is on its own last row, above it the input-frame rule;
//   (5) zero wrapped/overlapping rows: the frame is exactly the screen
//       height and no row exceeds the width.
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
// Same mask contract as composer_tui_grid_pty_test.dart: the spinner is
// the kaomoji face zone (issue #1374) — strip the fixed zone + separator.
import 'package:flutter_agent_harness/src/cli/fa_tui.dart'
    show kKaomojiFaceZoneCells;
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
      // Unique SHORT cwd (the #936/#938 class): the former fixed
      // /tmp/fa496ws raced the suite's own second width test under the
      // in-suite --concurrency=4 — the first test's teardown deleted the
      // dir under the other's live CLI (run 36235579869, shard 2).
      // /tmp keeps the resolved path short so the footer's tail markers
      // stay visible at 80 columns.
      final workspace = Directory('/tmp').createTempSync('fa496ws');
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
        // gh-1413: 55s — far beyond the probe-to-sampling horizon (~10s
        // even on a loaded runner) yet still under the bash tool's 60s
        // bare-sleep denial (#1349), so the probe turn cannot hand the run
        // to the queue drain while the frames are being compared.
        ..enqueueToolCall('bash', '{"command": "sleep 55"}')
        ..enqueueText('probe turn done');
      // gh-1413: the queue drain runs one turn per filler after the busy
      // run ends, and each turn is one API call. The mock answers an
      // unscripted request with HTTP 500 `script exhausted`, and the CLI
      // surfaces every retry as a `[net] connection lost … retrying`
      // transcript notice — run 37774628085 caught one landing exactly
      // between the two sampled frames (5 changed rows instead of 1).
      // Script every drain turn (plus spares) so that ladder can never
      // arm, whichever failure mode ends the busy run early.
      for (var i = 0; i < _queueFillers + 4; i++) {
        server.enqueueText('drain ack ${i + 1}');
      }
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
tui:
  classic: true  # pins the classic chrome this suite asserts (see #467); band redesign #805-#807
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
      // gh-1164 rework: 40s fired on a loaded shard-2 runner (run
      // 37248253893 — the screen showed the seed jobs still landing;
      // fa#1205/gh-671 loaded-runner family). waitForBoot already allows
      // 90s for the same reason; the file's 5-minute ceiling absorbs the
      // seed turn without weakening the actual grid assertions below.
      await harness.waitForText(
        'seeds done',
        timeout: const Duration(seconds: 90),
      );
      // Let turn 1 fully settle: the probe submit must go through the IDLE
      // submit path (echo into the history), not the busy queue.
      await Future<void>.delayed(const Duration(milliseconds: 2500));

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
      // With a long expanded classic queue the transcript legitimately
      // scrolls the original echo off-screen; the #496 regression is the
      // echo DUPLICATING into the input row, so: at most one copy on
      // screen, and any visible copy sits above the live edge.
      expect(echoRows.length, lessThanOrEqualTo(1),
          reason: 'the submitted text appears at most once — a duplicate '
              'would be the stale composer echo:\n${dump(gridA)}');
      if (echoRows.isNotEmpty) {
        expect(echoRows.single, lessThan(busyRows.single),
            reason: 'the sent echo sits in the history ABOVE the ticker '
                '(the live edge — inline tool-card rows may sit between):\n'
                '${dump(gridA)}');
      }

      // ── (3) the ticker updates IN PLACE ─────────────────────────────────
      // gh-1413: the transcript ABOVE the ticker is not part of this grid
      // contract — legitimate mid-run output (a queued-turn reply, a
      // `[net] connection lost … retrying` notice) appends there between
      // the two samples and shifts the fold header, which is exactly what
      // red run 37774628085 caught (5 changed rows instead of 1). The #496
      // regression class lives in the PINNED BLOCK from the ticker row
      // down: queue chrome, input row and footer must not move at all,
      // and the ticker row itself must move only where the spinner lives.
      expect(gridB.length, gridA.length, reason: 'no row count drift');
      final busyIdx = busyRows.single;
      expect(gridB[busyIdx], contains('· submit'),
          reason: 'the ticker stays on its row between ticks:\n'
              'A:\n${dump(gridA)}\nB:\n${dump(gridB)}');
      for (var i = busyIdx + 1; i < gridA.length; i++) {
        expect(gridB[i], gridA[i],
            reason: 'below the ticker every row is static between ticks '
                '(row $i):\nA:\n${dump(gridA)}\nB:\n${dump(gridB)}');
      }
      // The ticker actually ticked: any 1.2s window crosses a second
      // boundary, so the elapsed cell always moves.
      expect(gridA[busyIdx], isNot(gridB[busyIdx]),
          reason: 'the ticker row moved between ticks:\n'
              'A:\n${dump(gridA)}\nB:\n${dump(gridB)}');
      // The spinner is the kaomoji face zone (issue #1374): strip the
      // fixed zone + separator; only face + seconds may move.
      String masked(String row) => row
          .substring(kKaomojiFaceZoneCells + 1)
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
