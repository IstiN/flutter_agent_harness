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
  test('the interactive host defaults to advisory supervision; a headless run '
      'defaults to autonomous (issue review)', () {
    // gh-1054 review: auto-cancelling under a present human is the
    // ticket's non-goal — the REPL/TUI default is advisory; `fa run`
    // (unattended) keeps the autonomous default. No explicit config in
    // either construction.
    AgentCli cli({required bool headless}) => AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'k',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        headlessRun: headless,
      ),
      io: FakeCliIO(),
      streamFunction: FakeStreamFunction(const []).call,
    );
    expect(
      cli(headless: false).agent.stuckTool!.followUp,
      StuckFollowUpMode.advisory,
      reason: 'a human is present in the REPL/TUI — advise only',
    );
    expect(
      cli(headless: true).agent.stuckTool!.followUp,
      StuckFollowUpMode.autonomous,
      reason: 'fa run is unattended — the autonomous default',
    );
    // An explicit agent.stuckTool wins in both.
    final explicit = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'k',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        stuckTool: const StuckToolConfig(
          followUp: StuckFollowUpMode.autonomous,
        ),
      ),
      io: FakeCliIO(),
      streamFunction: FakeStreamFunction(const []).call,
    );
    expect(explicit.agent.stuckTool!.followUp, StuckFollowUpMode.autonomous);
  });

  test(
    'the stuck record bypasses no secrets: liveness records are redacted '
    'through the host pipeline (issue review)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const secret = 'sk-test-secret-abc123';
      final env = MemoryExecutionEnv(cwd: '/work', shell: HangingShell());
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'k',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          stuckTool: _stuckTool,
          redactionPipeline: RedactionPipeline(registeredSecrets: [secret]),
        ),
        io: io,
        streamFunction: FakeStreamFunction([
          toolTurn(const [
            ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: {
                'command': 'curl -H "Authorization: Bearer $secret" https://x',
              },
            ),
          ]),
          textTurn('moved on'),
        ]).call,
      );
      final exitCode = await cli.runHeadless('run the thing');
      expect(exitCode, 0);
      final records = await livenessRecords(env);
      expect(
        records.where((r) => r.customType == toolHeartbeatRecordType),
        isNotEmpty,
      );
      final raw = records.map((r) => r.data.toString()).join('\n');
      expect(raw, isNot(contains(secret)), reason: 'no raw secret in records');
      expect(raw, contains('[REDACTED:'), reason: 'masked, not dropped');
    },
  );

  test(
    'a supervisor-driven background conversion does not blame a steering '
    'message (issue review)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work', shell: _ConvertShell());
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'k',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          stuckTool: _stuckTool,
        ),
        io: io,
        streamFunction: FakeStreamFunction(_turns()).call,
      );
      final exitCode = await cli.runHeadless('run the long thing');
      expect(exitCode, 0, reason: 'the turn continues past the conversion');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      final session = await repo.open(sessions.first);
      final messages = await session.buildContextMessages();
      final texts = [
        for (final message in messages)
          if (message is ToolResultMessage)
            [
              for (final block in message.content)
                if (block is TextContent) block.text,
            ].join(),
      ];
      final handback = texts.where(
        (t) => t.contains('moved to background job'),
      );
      expect(handback, isNotEmpty, reason: 'the retry was converted');
      expect(
        handback.join('\n'),
        isNot(contains('steering message arrived')),
        reason: 'no steering arrived — the supervisor moved it',
      );
      expect(
        handback.join('\n'),
        contains('stuck-call supervisor converted it'),
        reason: 'the hand-back names the real cause',
      );
      final records = await livenessRecords(env);
      expect([
        for (final r in records)
          if (r.customType == toolStuckRecordType) (r.data as Map)['action'],
      ], contains('background_convert'));
    },
  );
}

/// A jobs-capable shell whose background jobs hang until stopped — the
/// wedge behind the supervisor-driven background-conversion scenario.
class _ConvertShell implements Shell, BackgroundShell {
  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'No shell is available in this environment',
      ),
    );
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    return Ok(_ConvertJob(id: id, command: command, logPath: logPath));
  }
}

final class _ConvertJob implements ShellJob {
  _ConvertJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

  var _stopped = false;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_stopped;
  @override
  int? get exitCode => _stopped ? 9 : null;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => _stopped ? 'cancelled' : null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }
}
