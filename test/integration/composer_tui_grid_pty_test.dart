// Issue #467 grid integration suite (owner-directed): the REAL CLI runs in
// a PTY against a scripted mock LLM (multi-second tool call keeps the busy
// ticker ticking), the screen is rendered by a real terminal emulator (the
// in-repo xterm — the dart twin of the pyte probe), and assertions run on
// the RENDERED GRID at 100x40 AND narrow 80x24:
//
//   1. a long composed input soft-wraps across rows;
//   2. the footer/status row appears EXACTLY once, on its own bottom row,
//      never merged with the composer or the ticker row;
//   3. the ticker row updates IN PLACE — the grid diff between two ticks
//      touches only the busy row, and inside it only the spinner glyph and
//      the seconds cell;
//   4. zero foreign/bleed-through rows mid-run (the composer region carries
//      only composer content).
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

const _composed =
    'please check whether the composer wraps this very long line correctly '
    'across several terminal rows without ever sliding the beginning of the '
    'sentence out of view at any point during a long busy run ok';

void main() {
  for (final (columns, rowsCount) in [(100, 40), (80, 24)]) {
    test('grid integrity mid-run at ${columns}x$rowsCount', () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_467_grid_');
      // Short cwd so the status row's tail (ctx · tokens · turn · model)
      // is visible even at 80 columns — the row is fit-truncated from the
      // tail and a long workspace path would hide the asserted markers.
      final workspace = Directory('/tmp/fa467ws')
        ..createSync(recursive: true);
      addTearDown(() => workspace.deleteSync(recursive: true));
      final server = await MockLlmServer.start()
        ..enqueueToolCall('bash', '{"command": "sleep 15"}')
        ..enqueueText('sleep finished');
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
      harness.sendText('run the long sleep now');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText('· submit', timeout: const Duration(seconds: 20));

      // Compose the long line mid-run, then let two 1 Hz ticks repaint.
      for (var i = 0; i < _composed.length; i += 10) {
        harness.sendText(
          _composed.substring(i, i + 10 > _composed.length
              ? _composed.length
              : i + 10),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final gridA = _grid(harness);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final gridB = _grid(harness);

      // ── (1) the composed line soft-wraps across rows ───────────────────
      final rule = '─' * columns;
      final rules = <int>[
        for (var i = 0; i < gridA.length; i++)
          if (gridA[i].trim() == rule) i,
      ];
      expect(rules.length, greaterThanOrEqualTo(2), reason: 'input frame');
      final region = gridA
          .sublist(rules[rules.length - 2] + 1, rules.last)
          .map((l) => l.trimRight())
          .toList();
      expect(region.length, greaterThanOrEqualTo(3),
          reason: 'wrapped, not one row: ${region.join(" | ")}');
      final visible = region.map((l) => l.replaceAll(' ', '')).join();
      expect(visible, _composed.replaceAll(' ', ''));
      expect(region.first.trimLeft().startsWith('please '), isTrue);

      // ── (2) the status row: EXACTLY once, own bottom row, never merged ──
      final statusRows = [
        for (final row in gridA)
          if (row.contains(' · turn ')) row,
      ];
      expect(statusRows.length, 1,
          reason: 'status rendered exactly once; screen:\n'
              '${gridA.where((l) => l.trim().isNotEmpty).join("\n")}');
      final statusRow = statusRows.single.trimRight();
      // Merging with the composer would put composed text left of the cwd.
      expect(statusRow.trimLeft().startsWith('/'), isTrue,
          reason: 'status opens with the cwd, not composer text');
      expect(statusRow, contains('ctx '));
      expect(statusRow, contains('mock-model'));
      // Own bottom row: the status is the LAST non-blank grid row and the
      // row right above it is the input zone's bottom rule.
      var last = gridA.length - 1;
      while (last > 0 && gridA[last].trim().isEmpty) {
        last--;
      }
      expect(gridA[last].contains(' · turn '), isTrue,
          reason: 'status is the bottom row');
      expect(gridA[last - 1].trim(), rule,
          reason: 'a full-width rule separates the composer from the status');

      // ── (3) the ticker updates IN PLACE ─────────────────────────────────
      expect(gridB.length, gridA.length, reason: 'no row count drift');
      var changedRows = 0;
      var busyIdx = -1;
      for (var i = 0; i < gridA.length; i++) {
        if (gridA[i] != gridB[i]) {
          changedRows++;
          busyIdx = i;
        }
      }
      expect(changedRows, 1, reason: 'only the busy row may change');
      String masked(String row) => row
          .substring(row.indexOf(' ') + 1) // drop the spinner glyph
          .replaceAll(RegExp(r'\d'), '#');
      final busyA = gridA[busyIdx];
      final busyB = gridB[busyIdx];
      expect(busyA.isNotEmpty, isTrue);
      expect(masked(busyA), masked(busyB),
          reason: 'inside the busy row only spinner + seconds may move:\n'
              '$busyA\n$busyB');
      // And it really is the ticker row.
      expect(busyA, contains('· submit'));

      // ── (4) zero foreign rows in the composer region ────────────────────
      for (final row in region) {
        expect(row, isNot(contains('· submit')));
        expect(row, isNot(contains('sh-1')));
        expect(row, isNot(contains('sleep finished')));
        expect(row.runes.length, lessThanOrEqualTo(columns));
      }
    });
  }

  /// NEW AC (owner evidence #3, RED first): mid-run with a 500+ char tool
  /// row AND a 300-char composed line, the frame must stay EXACTLY
  /// [rowsCount] tall across consecutive ticks — zero hardware-wrapped
  /// rows anywhere, no board-snapshot residue, status pinned to the bottom.
  for (final (columns, rowsCount) in [(100, 40), (80, 24)]) {
    test('zero wrapped rows with overlong tool output at '
        '$columns x$rowsCount', () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_467_wrap_');
      final ascii520 = 'gh issue create --title "${'x' * 500}"';
      final cjkCommand = 'echo 終${'終' * 60}終'; // wide glyphs: unit-clip trap
      String jq(String s) =>
          '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
      final server = await MockLlmServer.start()
        // The 500+ char tool row FIRST: it must be on screen while the
        // composed line sits in the composer (the documented simultaneity).
        ..enqueueToolCall('bash', '{"command": ${jq(ascii520)}}')
        // The long sleep keeps the run alive through the whole sampling
        // window that follows.
        ..enqueueToolCall('bash', '{"command": "sleep 20"}')
        ..enqueueToolCall('bash', '{"command": ${jq(cjkCommand)}}')
        ..enqueueText('all done');
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
      final workspace = Directory('/tmp/fa467ws2')..createSync(recursive: true);
      addTearDown(() => workspace.deleteSync(recursive: true));

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

      // Start the run with a SHORT message, then compose the 300-char
      // line mid-run WITHOUT submitting it — the AC watches the composer
      // hold the wrapped draft while the run ticks (the AC3 flow).
      final composed300 = 'wrap me ' * 43; // 301 chars — several wrapped rows
      harness.sendText('run the long sleep now');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText(
        '· submit',
        timeout: const Duration(seconds: 20),
      );
      harness.sendText(composed300.substring(0, 300));
      await Future<void>.delayed(const Duration(milliseconds: 2500));

      final grids = <List<String>>[
        _grid(harness),
        await Future<void>.delayed(
          const Duration(milliseconds: 1200),
        ).then((_) => _grid(harness)),
        await Future<void>.delayed(
          const Duration(milliseconds: 1200),
        ).then((_) => _grid(harness)),
      ];

      for (var tick = 0; tick < grids.length; tick++) {
        final grid = grids[tick];
        expect(grid.length, rowsCount,
            reason: 'tick $tick: frame height drifted — a row wrapped');
        // The status stays the BOTTOM row: any wrap above pushes it off.
        expect(grid[rowsCount - 1].contains(' · turn '), isTrue,
            reason: 'tick $tick: status not at the bottom — drift');
        for (final row in grid) {
          expect(row.runes.length, lessThanOrEqualTo(columns));
        }
        // Board residue: a live job id is painted at most once, and no two
        // board rows are identical (a longer previous snapshot must not
        // survive a repaint).
        final boardIds = [
          for (final row in grid)
            if (row.contains('↳ ')) row.substring(0, row.indexOf(' ·')),
        ];
        expect(boardIds.toSet().length, boardIds.length,
            reason: 'tick $tick: duplicated board rows (ghost snapshot)');
      }
      // The composed line survived intact through the run.
      final rules = [
        for (var i = 0; i < grids.last.length; i++)
          if (grids.last[i].trim() == '─' * columns) i,
      ];
      final region = grids.last
          .sublist(rules[rules.length - 2] + 1, rules.last)
          .map((l) => l.replaceAll(' ', ''))
          .join();
      expect(region, composed300.substring(0, 300).replaceAll(' ', ''));
    });
  }
}

/// The rendered screen: right-trimmed rows, blank rows dropped at the tail
/// only by the assertions that need them (grid math keeps positions).
List<String> _grid(FaCliHarness harness) => [
  for (final line in harness.viewportLines) line.trimRight(),
];
