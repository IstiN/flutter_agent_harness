import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';
import 'agent_cli_steering_persistence_test.dart'
    show waitForSessions, waitForItAsync;

/// A [Shell] whose exec never returns and honors nothing — the mock wedge
/// behind the stuck-call scenarios (gh-1054 AC1/AC4).
class HangingShell implements Shell {
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    await Completer<void>().future;
    throw StateError('hangs forever');
  }
}

/// The scripted turns: one hanging bash call, then the recovery answer.
List<List<AssistantMessageEvent>> _turns() => [
  toolTurn(const [
    ToolCall(
      id: 'c1',
      name: 'bash',
      // A tiny declared timeout keeps the derived threshold (2× declared,
      // floored) inside the test window.
      arguments: {'command': 'long-thing', 'timeout': 0.06},
    ),
  ]),
  textTurn('moved on and answered'),
];

const _stuckTool = StuckToolConfig(
  floor: Duration(milliseconds: 240),
  declaredTimeoutFactor: 2,
  heartbeatInterval: Duration(milliseconds: 60),
  cancelGrace: Duration(milliseconds: 120),
);

AgentCli buildCli(
  MemoryExecutionEnv env,
  FakeStreamFunction stream,
  FakeCliIO io,
) {
  return AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      stuckTool: _stuckTool,
    ),
    io: io,
    streamFunction: stream.call,
  );
}

/// The persisted liveness records of the first session, in file order.
Future<List<CustomRecord>> livenessRecords(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await session.getEntries();
  return [
    for (final record in records)
      if (record is CustomRecord &&
          (record.customType == toolHeartbeatRecordType ||
              record.customType == toolStuckRecordType))
        record,
  ];
}

/// A comparable shape of a liveness record with timing stripped (the two
/// modes cannot be elapsed-identical, only record-identical).
Map<String, Object?> normalized(CustomRecord record) {
  final data = Map<String, Object?>.from(record.data as Map);
  data['elapsedMs'] = '<elapsed>';
  // The escalation detail embeds the measured duration — timing, not shape.
  if (data['detail'] is String) data['detail'] = '<detail>';
  if (data['args'] is String) data['args'] = 'long-thing';
  return {'type': record.customType, 'data': data};
}

void main() {
  test(
    'AC1+AC4: headless run persists heartbeats and the escalation into the '
    'session JSONL; AC5: the REPL produces the same record sequence',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // ---- headless drive ----
      final headlessEnv = MemoryExecutionEnv(
        cwd: '/work',
        shell: HangingShell(),
      );
      await headlessEnv.writeFile('/work/.fah/memory/.last_maintenance', '');
      final headlessIo = FakeCliIO();
      final headlessCli = buildCli(
        headlessEnv,
        FakeStreamFunction(_turns()),
        headlessIo,
      );
      final exitCode = await headlessCli.runHeadless('run the long thing');
      expect(exitCode, 0, reason: 'the run continues past the escalation');

      final headlessRecords = await livenessRecords(headlessEnv);
      final headlessHeartbeats = headlessRecords
          .where((r) => r.customType == toolHeartbeatRecordType)
          .toList();
      final headlessStuck = headlessRecords
          .where((r) => r.customType == toolStuckRecordType)
          .toList();

      // AC1: heartbeats at the configured cadence while the call ran.
      expect(headlessHeartbeats.length, greaterThanOrEqualTo(2));
      expect(
        headlessHeartbeats.every((r) => (r.data as Map)['tool'] == 'bash'),
        isTrue,
      );
      expect(
        headlessHeartbeats.every(
          (r) => (r.data as Map)['args'] == 'long-thing',
        ),
        isTrue,
      );

      // AC4: the escalation record names the call, elapsed, and action.
      final actions = [
        for (final r in headlessStuck) (r.data as Map)['action'],
      ];
      expect(actions, contains('cancel_retry'));
      expect(actions, contains('escalate'));
      final escalation = headlessStuck
          .where((r) => (r.data as Map)['action'] == 'escalate')
          .single;
      expect(((escalation.data as Map)['detail'] as String), contains('bash'));

      // The tool result the model saw is marked, error-shaped.
      final repo = JsonlSessionRepo(fs: headlessEnv, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      final session = await repo.open(sessions.first);
      final messages = await session.buildContextMessages();
      final toolResults = messages.whereType<ToolResultMessage>().toList();
      expect(toolResults, hasLength(1));
      expect(toolResults.single.isError, isTrue);
      final resultText = [
        for (final block in toolResults.single.content)
          if (block is TextContent) block.text,
      ].join();
      expect(resultText, contains('[stuck-call escalation]'));

      // ---- REPL drive (AC5 parity) ----
      final replEnv = MemoryExecutionEnv(cwd: '/work', shell: HangingShell());
      await replEnv.writeFile('/work/.fah/memory/.last_maintenance', '');
      final replIo = FakeCliIO();
      final replCli = buildCli(replEnv, FakeStreamFunction(_turns()), replIo);
      final run = replCli.run();
      await waitForSessions(replEnv);
      replIo.sendLine('run the long thing');
      await waitForItAsync(
        () async =>
            (await livenessRecords(replEnv)).length >= headlessRecords.length,
        reason: 'the REPL run persists the same liveness records',
      );
      replIo.sendLine('/exit');
      await run;

      final replRecords = await livenessRecords(replEnv);
      expect(
        [for (final r in replRecords) normalized(r)],
        [for (final r in headlessRecords) normalized(r)],
        reason:
            'AC5: headless and the TUI produce the same session records '
            '(timing aside)',
      );
    },
  );
}
