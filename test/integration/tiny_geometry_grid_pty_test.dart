// Tiny-geometry grid probe (owner screenshot, #503 follow-up): on a SHORT
// panel (~8-10 rows) during a busy run with a steering echo pinned, the
// composer input frame VANISHED — the ticker painted directly above the
// status row and the cursor landed on the status row's left edge. The
// bottom chrome must stay complete at any height the terminal reports:
// input frame rules + at least the caret row + status row, each on its own
// physical row, status exactly once at the bottom.
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  for (final rowsCount in [10, 8]) {
    test('bottom chrome complete at 100x$rowsCount mid-run with echo', () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_tiny_');
      final workspace = Directory('/tmp/fatinyws')
        ..createSync(recursive: true);
      addTearDown(() => workspace.deleteSync(recursive: true));
      final server = await MockLlmServer.start()
        ..enqueueToolCall('bash', '{"command": "sleep 20"}')
        ..enqueueText('done');
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
        columns: 100,
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

      // Pin a steering echo + start a draft, then let two ticks repaint.
      harness.sendText('steer note');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      harness.sendCtrlS();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      harness.sendText('draft');
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      final grid = [
        for (final line in harness.viewportLines) line.trimRight(),
      ];

      final screen = [
        for (var i = 0; i < grid.length; i++) 'R$i |${grid[i]}|',
      ].join('\n') + '\nRAW:\n' + harness.rawTail;
      // Status exactly once, and it is the bottom non-blank row.
      // The band: exactly once, directly above the empty gutter row
      // (#831 band layout — the rule + dim footer are retired).
      final statusRows = [
        for (final row in grid)
          if (row.trimLeft().startsWith('>_') && row.contains(' > ')) row,
      ];
      expect(statusRows.length, 1,
          reason: 'status exactly once; screen:\n$screen');
      var last = grid.length - 1;
      while (last > 0 && grid[last].trim().isEmpty) {
        last--;
      }
      expect(grid[last].trimRight().startsWith('╰─'), isTrue,
          reason: 'the empty gutter ends the frame; screen:\n$screen');
      expect(grid[last - 1], statusRows.single,
          reason: 'the band sits directly above the gutter; screen:\n$screen');
      // At these heights the transcript may shrink to nothing and the
      // draft lives only in the composer's gutter row — anywhere on the
      // glass counts; the band-clean assert above pins the separation.
      expect(
        grid.any((l) => l.contains('draft')),
        isTrue,
        reason: 'the composed draft is on the glass; screen:\n$screen',
      );
      // The draft is NOT the status row (no merge): the band carries no
      // composer text — the draft lives in the gutter row below it.
      expect(statusRows.single.contains('draft'), isFalse,
          reason: 'draft must not merge into the status band');
    });
  }
}
