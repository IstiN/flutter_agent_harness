/// Perf gate for issue #262 (the card's DoD): opening a ~100 MB / 30k-record
/// session through the REAL headless CLI open path must project the ledger in
/// under a second and finish the whole open well under four.
///
/// The fixture is generated dynamically (deterministic content, streamed to a
/// temp file) and opened through `fa trajectory view` — the same rendering
/// entry the integration tests drive. Phased timings come from the CLI's own
/// FA_TIMING telemetry (issue #262 AC0): `parse` (storage read + JSONL
/// decode), `build` (one-pass trajectory projection — the phase that used to
/// be O(n²) via per-append snapshot copies), and `render` (O(n) printing).
/// The wall clock of the PROCESS also includes the Dart VM/kernel compile and
/// is deliberately NOT asserted — budgets cover the open pipeline itself.
///
/// Pre-fix the per-append rebuild measured ~64 s of projection at 30k
/// records (tool/perf262.dart). The 1 s build budget RED-blocks any
/// regression back to O(n²).
@TestOn('vm')
@Tags(['integration', 'perf'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

/// Records appended per turn (user + assistant + 2 tool results).
const _recordsPerTurn = 4;

/// Turns in the fixture: 1 boot + 4 per turn = 30 001 records.
const _turns = 7500;

/// Filler per tool result: average record lands near the patient
/// file's ~10 KB (314 MB / 30.5k records); ~100 MB total fixture.
const _toolPaddingBytes = 6100;

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

MessageRecord _result(int t, int n, String parentId, String filler) =>
    MessageRecord(
      id: 'rec-$t-r$n',
      parentId: parentId,
      timestamp: _at(t * 10 + n),
      message: ToolResultMessage(
        toolCallId: 'rec-$t-c$n',
        toolName: 'read',
        content: [TextContent(text: 'out $n $filler')],
        isError: false,
        timestamp: _at(t * 10 + n),
      ),
    );

Future<void> main() async {
  late Directory tempHome;
  late Directory sessionsRoot;
  late String sessionId;
  late File sessionFile;

  setUpAll(() async {
    tempHome = Directory.systemTemp.createTempSync('fa_perf_gate_home_');
    sessionsRoot = Directory.systemTemp.createTempSync('fa_perf_gate_sess_');
    final repo = JsonlSessionRepo(
      fs: LocalExecutionEnv(cwd: tempHome.path),
      sessionsRoot: sessionsRoot.path,
    );
    sessionId = 'perf-gate-262';
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: tempHome.path, id: sessionId),
    );
    final metadata = await session.getMetadata();
    sessionFile = File(metadata.path);

    // Stream the ledger: header is already there, append record lines.
    final sink = sessionFile.openWrite(mode: FileMode.append);
    final filler = 'x' * _toolPaddingBytes;
    var prev = MessageRecord(
      id: 'rec-u0',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('boot'),
    );
    sink.write('${jsonEncode(prev.toJson())}\n');
    for (var t = 1; t <= _turns; t++) {
      final user = MessageRecord(
        id: 'rec-$t-u',
        parentId: prev.id,
        timestamp: _at(t * 10),
        message: UserMessage.text('question $t'),
      );
      final assistant = MessageRecord(
        id: 'rec-$t-a',
        parentId: user.id,
        timestamp: _at(t * 10 + 1),
        message: AssistantMessage(
          content: [
            ThinkingContent(thinking: 'thought $t'),
            ToolCall(id: 'rec-$t-c1', name: 'read', arguments: {}),
            ToolCall(id: 'rec-$t-c2', name: 'bash', arguments: {}),
            TextContent(text: 'answer $t'),
          ],
          api: 'anthropic-messages',
          provider: 'anthropic',
          model: 'claude-test',
          usage: const Usage(
            input: 10,
            output: 5,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 15,
            cost: UsageCost(total: 0),
          ),
          stopReason: StopReason.stop,
          timestamp: _at(t * 10 + 1),
        ),
      );
      final r1 = _result(t, 1, assistant.id, filler);
      final r2 = _result(t, 2, r1.id, filler);
      final chunk = StringBuffer();
      for (final record in [user, assistant, r1, r2]) {
        chunk
          ..write(jsonEncode(record.toJson()))
          ..write('\n');
      }
      sink.write(chunk);
      prev = r2;
    }
    await sink.flush();
    await sink.close();
  });

  tearDownAll(() async {
    tempHome.deleteSync(recursive: true);
    sessionsRoot.deleteSync(recursive: true);
  });

  test('30k-record session opens through the real CLI path within budget',
      () async {
    final sizeMb = sessionFile.lengthSync() / (1024 * 1024);
    expect(sizeMb, greaterThan(80), reason: 'fixture must be ~100 MB class');
    final result = await Process.run('dart', [
      'run',
      'bin/fah.dart',
      'trajectory',
      'view',
      sessionId,
      '--session-root',
      sessionsRoot.path,
    ], environment: {
      'FA_TIMING': '1',
      'HOME': tempHome.path,
      'OPENAI_API_KEY': 'mock',
    });
    expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    // Content actually rendered through the real path: the last turn's
    // assistant row must be in the ledger output.
    expect(result.stdout, contains('answer $_turns'));

    final timing = RegExp(
      r'trajectory timing: parse=(\d+)ms build=(\d+)ms render=(\d+)ms total=(\d+)ms records=(\d+)',
    ).firstMatch(result.stderr);
    expect(timing, isNotNull, reason: 'stderr: ${result.stderr}');
    final parseMs = int.parse(timing!.group(1)!);
    final buildMs = int.parse(timing.group(2)!);
    final renderMs = int.parse(timing.group(3)!);
    final totalMs = int.parse(timing.group(4)!);
    final records = int.parse(timing.group(5)!);
    expect(records, 1 + _turns * _recordsPerTurn);
    // The card's budget: ledger projection (where the O(n²) lived) under
    // 1 s. Render is O(n) printing and reported, not budgeted.
    expect(buildMs, lessThanOrEqualTo(1000));
    // Whole open pipeline (parse + projection + render) well under 36 s.
    expect(totalMs, lessThanOrEqualTo(4000));
    // ignore: avoid_print
    print(
      'perf-gate: ${sizeMb.toStringAsFixed(1)} MB, parse=${parseMs}ms '
      'build=${buildMs}ms render=${renderMs}ms total=${totalMs}ms',
    );
  });
}
