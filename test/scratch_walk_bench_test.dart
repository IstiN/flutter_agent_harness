// SCRATCH benchmark — NOT committed. Times windowed open +
// ensureWholeLedgerResident vs full open on a ~97 MB / 30k-record ledger
// (same shape as test/integration/trajectory/perf_open_gate_test.dart).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

void main() {
  test('walk vs full open timing', () async {
    final tmp = await Directory.systemTemp.createTemp('walkbench');
    addTearDown(() => tmp.delete(recursive: true));
    final sessionsRoot = '${tmp.path}/sessions';
    final env = LocalExecutionEnv(cwd: tmp.path);
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: tmp.path),
    );

    // 1 boot + 4 per turn x 7500 turns = 30 001 records, ~97 MB.
    final filler = 'y' * 800;
    void turn() {
      session.appendMessage(UserMessage.text('question $filler'));
    }

    final sw = Stopwatch()..start();
    for (var i = 0; i < 7500; i++) {
      await session.appendMessage(
        UserMessage.text('question $i $filler'),
      );
      await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'answer $i $filler')],
          api: 'anthropic-messages',
          provider: 'anthropic',
          model: 'claude-test',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendMessage(
        ToolResultMessage(
          toolCallId: 'c$i',
          toolName: 'bash',
          isError: false,
          content: [TextContent(text: 'out $filler')],
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendMessage(
        ToolResultMessage(
          toolCallId: 'd$i',
          toolName: 'bash',
          isError: false,
          content: [TextContent(text: 'err $filler')],
          timestamp: DateTime.utc(2026),
        ),
      );
    }
    print('seeded in ${sw.elapsedMilliseconds}ms');
    final meta = await session.getMetadata();
    final size = File(meta.path).lengthSync();
    print('ledger: ${(size / 1e6).toStringAsFixed(1)} MB');

    var t = Stopwatch()..start();
    final full = await repo.open(meta);
    final fullBranch = await full.getBranch();
    print('full open+branch: ${t.elapsedMilliseconds}ms '
        '(${fullBranch.length} records)');

    t.reset();
    final windowed = await repo.open(meta, windowed: true);
    print('windowed open: ${t.elapsedMilliseconds}ms');

    t.reset();
    await windowed.ensureWholeLedgerResident();
    print('ensureWholeLedgerResident: ${t.elapsedMilliseconds}ms');
    t.reset();
    final walkedBranch = await windowed.getBranch();
    print('getBranch after walk: ${t.elapsedMilliseconds}ms '
        '(${walkedBranch.length} records)');
    t.reset();
    await windowed.ensureWholeLedgerResident();
    print('ensureWholeLedgerResident again (no-op): '
        '${t.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
