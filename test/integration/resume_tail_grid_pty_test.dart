/// Issue #503 RED grid probes: session resume over a real PTY.
///
/// AC1: a resumed session with a known last user+assistant exchange and
/// TEN stale live-at-restart `shell_job_registry` entries shows
///   - the lost-tasks summary EXACTLY ONCE on the glass (one row — the
///     old build paints one 4-line card per lost job, a flood that
///     evicts everything else), and
///   - the last assistant message ON THE GLASS (the boot notices paint
///     BEFORE the history replay; the replay is the final paint).
///
/// The provider is never called: the session file is crafted through the
/// session repo (same pattern as pty_resume_equivalence_test.dart), the
/// CLI only boots, replays, and idles.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

const _anchor = 'FINAL-TAIL-MARKER-503 the resumed answer tail';
const _summaryMarker = 'lost on restart';

Future<(Directory, String)> _craftSession() async {
  final tempHome = Directory.systemTemp.createTempSync('fa_tui_503_');
  final project = Directory('${tempHome.path}/proj')
    ..createSync(recursive: true);
  final sessionsRoot = Directory('${tempHome.path}/.fah/sessions')
    ..createSync(recursive: true);
  final repo = JsonlSessionRepo(
    fs: LocalExecutionEnv(cwd: project.path),
    sessionsRoot: sessionsRoot.path,
  );
  const id = 'resume-tail-503';
  final session = await repo.create(
    JsonlSessionCreateOptions(cwd: project.path, id: id),
  );
  final meta = await session.getMetadata();
  final base = DateTime.utc(2026, 1, 1, 12);
  final sink = File(meta.path).openWrite(mode: FileMode.append);
  final user = MessageRecord(
    id: 'rec-1-u',
    parentId: null,
    timestamp: base,
    message: UserMessage.text('produce the anchor reply'),
  );
  final assistant = MessageRecord(
    id: 'rec-1-a',
    parentId: user.id,
    timestamp: base.add(const Duration(seconds: 1)),
    message: AssistantMessage(
      content: [TextContent(text: _anchor)],
      api: 'test-api',
      provider: 'test-provider',
      model: 'mock-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: base.add(const Duration(seconds: 2)),
    ),
  );
  final registry = CustomRecord(
    id: 'rec-2-registry',
    parentId: assistant.id,
    timestamp: base.add(const Duration(seconds: 3)),
    customType: 'shell_job_registry',
    data: [
      for (var i = 1; i <= 10; i++)
        {
          'id': 'sh-$i-stale503',
          'kind': 'bash',
          'label': 'sleep 300',
          'state': 'running',
          'turn': 1,
        },
    ],
  );
  for (final record in [user, assistant, registry]) {
    sink.write('${jsonEncode(record.toJson())}\n');
  }
  await sink.flush();
  await sink.close();
  return (tempHome, id);
}

void main() {
  for (final (columns, rowsCount) in [(80, 24), (100, 40)]) {
    test('resume tail + single lost summary at $columns x $rowsCount',
        () async {
      final (tempHome, id) = await _craftSession();
      addTearDown(() => tempHome.deleteSync(recursive: true));

      final harness = await FaCliHarness.spawn(
        workingDirectory: '${tempHome.path}/proj',
        extraEnv: {'HOME': tempHome.path},
        args: [
          '--session',
          id,
          '--session-root',
          '${tempHome.path}/.fah/sessions',
        ],
        columns: columns,
        rows: rowsCount,
      );
      addTearDown(harness.close);

      // The banner's [Model] block scrolls off a flooded 24-row glass —
      // the status row is the boot marker that always exists.
      await harness.waitForText(' · ctx ', timeout: const Duration(seconds: 90));
      await harness.waitForOutput(
        settleMs: 700,
        timeout: const Duration(seconds: 20),
      );
      final grid = [
        for (final line in harness.viewportLines) line.trimRight(),
      ];

      // ── the lost-tasks summary: EXACTLY ONCE, one row ─────────────────
      final summaryRows = [
        for (var i = 0; i < grid.length; i++)
          if (grid[i].contains(_summaryMarker)) i,
      ];
      expect(summaryRows.length, 1,
          reason: 'the lost-task flood must collapse to ONE summary row; '
              'screen:\n${grid.join('\n')}');
      final summary = grid[summaryRows.single];
      expect(summary, contains('10'),
          reason: 'the summary names the lost count: "$summary"');

      // ── the last assistant message visible on the glass ───────────────
      final anchorRows = [
        for (var i = 0; i < grid.length; i++)
          if (grid[i].contains(_anchor)) i,
      ];
      expect(anchorRows.length, 1,
          reason: 'the resumed tail (last assistant message) is on the '
              'glass exactly once; screen:\n${grid.join('\n')}');

      // ── boot order: notices BEFORE the replay, replay paints last ────
      expect(summaryRows.single < anchorRows.single, isTrue,
          reason: 'the reconciliation notice paints before the history '
              'replay; the replay is the final paint');

      // ── no individual lost cards flood the glass ─────────────────────
      final cardHeaders = [
        for (final row in grid)
          if (row.contains('bash task lost')) row,
      ];
      expect(cardHeaders, isEmpty,
          reason: 'lost cards must not flood the first screen; the summary '
              'row replaces them (details stay on /tasks); screen:\n'
              '${grid.join('\n')}');
    });
  }
}
