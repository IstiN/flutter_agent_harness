import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/trajectory_tui.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

MessageRecord _userRecord(String id, {String? parentId, String text = 'hi'}) =>
    MessageRecord(
      id: id,
      parentId: parentId,
      timestamp: _at(0),
      message: UserMessage.text(text),
    );

MessageRecord _assistantRecord(
  String id, {
  String? parentId,
  List<ContentBlock> content = const [TextContent(text: 'answer')],
  Usage? usage,
}) {
  return MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: _at(1),
    message: AssistantMessage(
      content: content,
      api: 'anthropic-messages',
      provider: 'anthropic',
      model: 'claude-test',
      usage:
          usage ??
          const Usage(
            input: 100,
            output: 20,
            cacheRead: 30,
            cacheWrite: 5,
            reasoning: 8,
            totalTokens: 163,
            cost: UsageCost(total: 0.5),
          ),
      stopReason: StopReason.stop,
      timestamp: _at(1),
    ),
  );
}

ToolCall _toolCall(String id, {String name = 'bash'}) =>
    ToolCall(id: id, name: name, arguments: const {'cmd': 'ls'});

MessageRecord _toolResultRecord(
  String id, {
  required String parentId,
  required String callId,
  String text = 'done',
}) {
  return MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: _at(6),
    message: ToolResultMessage(
      toolCallId: callId,
      toolName: 'bash',
      isError: false,
      content: [TextContent(text: text)],
      timestamp: _at(6),
    ),
  );
}

/// user → assistant(text+usage) → tool call → tool result.
TrajectorySnapshot _snapshot() => trajectorySnapshotOf([
  _userRecord('u1'),
  _assistantRecord(
    'a1',
    parentId: 'u1',
    content: [
      TextContent(text: 'answer'),
      _toolCall('c1'),
    ],
  ),
  _toolResultRecord('r1', parentId: 'a1', callId: 'c1'),
]);

void main() {
  group('trajectoryLines', () {
    test('one line per record with kind, duration, and tokens', () {
      final lines = trajectoryLines(_snapshot(), width: 200);
      expect(lines, hasLength(3));
      expect(lines[0], '#1 USER hi');
      expect(lines[1], '#2 ASSISTANT answer (1,000 ms, 163 tok)');
      expect(lines[2], '#3 TOOL bash {"cmd":"ls"} → done (5,000 ms)');
    });

    test('long text truncates to the width with an ellipsis', () {
      final snapshot = trajectorySnapshotOf([
        _userRecord('u1', text: 'x' * 200),
      ]);
      final lines = trajectoryLines(snapshot, width: 40);
      expect(lines, hasLength(1));
      expect(lines.single.length, 40);
      expect(lines.single, startsWith('#1 USER '));
      expect(lines.single, endsWith('…'));
    });

    test('caps at maxLines keeping the tail and naming the hidden count', () {
      final snapshot = trajectorySnapshotOf([
        for (var i = 0; i < trajectoryMaxLines + 50; i++)
          _userRecord('u$i', text: 'm$i'),
      ]);
      final lines = trajectoryLines(snapshot, width: 200);
      expect(lines, hasLength(trajectoryMaxLines + 1));
      expect(lines[1], startsWith('#51 USER m50'));
      expect(lines.last, startsWith('#250 USER m249'));
      expect(lines.last, startsWith('#${trajectoryMaxLines + 50} USER'));
    });

    test('empty snapshot prints a placeholder', () {
      expect(trajectoryLines(TrajectorySnapshot.empty), ['no records']);
    });
  });

  group('trajectoryCostLines', () {
    test('one row per request plus cumulative and cost columns', () {
      final snapshot = trajectorySnapshotOf([
        _userRecord('u1'),
        _assistantRecord('a1', parentId: 'u1'),
        _assistantRecord('a2', parentId: 'a1'),
      ]);
      final lines = trajectoryCostLines(snapshot);
      expect(lines[0], contains('model'));
      expect(lines[0], contains('cost'));
      expect(lines, hasLength(4));
      expect(lines[1], contains('claude-test'));
      expect(lines[1], contains('\$0.5000'));
      expect(lines[3], startsWith('session cumulative: '));
      expect(lines.last, contains('tokens 326'));
      expect(lines.last, contains('\$1.0000'));
    });

    test('omits the cost column when nothing cost anything', () {
      final snapshot = trajectorySnapshotOf([
        _userRecord('u1'),
        _assistantRecord(
          'a1',
          parentId: 'u1',
          usage: const Usage(
            input: 10,
            output: 2,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 12,
            cost: UsageCost(),
          ),
        ),
      ]);
      final lines = trajectoryCostLines(snapshot);
      expect(lines.first, isNot(contains('cost')));
      expect(lines.last, isNot(contains('cost')));
      expect(lines.last, contains('tokens 12'));
    });

    test('no requests prints a placeholder', () {
      expect(trajectoryCostLines(TrajectorySnapshot.empty), ['no requests']);
    });
  });

  group('trajectoryInspectLines', () {
    test('assistant record shows model, timing, and token sections', () {
      final snapshot = _snapshot();
      final lines = trajectoryInspectLines(snapshot, 2)!;
      expect(lines.first, '#2 ASSISTANT · turn 1 · step 1');
      expect(lines, contains('model: anthropic/claude-test'));
      expect(lines, contains('status: completed'));
      expect(lines, contains('duration: 1,000 ms'));
      expect(
        lines,
        contains(
          'tokens: input 100, output 20, reasoning 8, '
          'cache read 30, cache write 5, total 163',
        ),
      );
      expect(lines, contains('cost: \$0.5000'));
      expect(lines, contains('output: answer'));
    });

    test('tool record shows call, args, and result', () {
      final lines = trajectoryInspectLines(_snapshot(), 3)!;
      expect(lines.first, '#3 TOOL · bash');
      expect(lines, contains('call: c1'));
      expect(lines, contains('status: completed'));
      expect(lines, contains('args: {"cmd":"ls"}'));
      expect(lines, contains('result: done'));
    });

    test('out of range returns null and the caller-facing error', () {
      final snapshot = _snapshot();
      expect(trajectoryInspectLines(snapshot, 0), isNull);
      expect(trajectoryInspectLines(snapshot, 5), isNull);
      expect(
        trajectoryRangeError(9, 3),
        'trajectory: record out of '
        'range: 9 (1..3)',
      );
    });

    test('system record shows change, text, and time', () {
      final snapshot = trajectorySnapshotOf([
        ModelChangeRecord(
          id: 'm1',
          parentId: null,
          timestamp: _at(0),
          provider: 'anthropic',
          modelId: 'claude-test',
        ),
      ]);
      final lines = trajectoryInspectLines(snapshot, 1)!;
      expect(lines.first, '#1 SYSTEM');
      expect(lines, contains('change: modelChange'));
      expect(lines, contains('text: anthropic/claude-test'));
      expect(lines, contains('time: ${_at(0).toIso8601String()}'));
    });

    test('user record shows text and turn metadata', () {
      final lines = trajectoryInspectLines(_snapshot(), 1)!;
      expect(lines.first, '#1 USER');
      expect(lines, contains('text: hi'));
      expect(lines, contains('opens turn: yes'));
    });

    test('context record shows its text', () {
      final snapshot = trajectorySnapshotOf([
        CustomMessageRecord(
          id: 'c1',
          parentId: null,
          timestamp: _at(0),
          customType: 'context',
          content: 'loaded files',
          display: true,
        ),
      ]);
      final lines = trajectoryInspectLines(snapshot, 1)!;
      expect(lines.first, '#1 CONTEXT');
      expect(lines, contains('text: loaded files'));
    });

    test('compacted record shows summary and kept-from', () {
      final snapshot = trajectorySnapshotOf([
        CompactionRecord(
          id: 'k1',
          parentId: null,
          timestamp: _at(0),
          summary: 'earlier work',
          firstKeptEntryId: 'u9',
          tokensBefore: 1000,
        ),
      ]);
      final lines = trajectoryInspectLines(snapshot, 1)!;
      expect(lines.first, '#1 COMPACTED');
      expect(lines, contains('summary: earlier work'));
      expect(lines, contains('kept from: u9'));
    });

    test('failed assistant record shows the error sections', () {
      final snapshot = trajectorySnapshotOf([
        _userRecord('u1'),
        MessageRecord(
          id: 'a1',
          parentId: 'u1',
          timestamp: _at(1),
          message: AssistantMessage(
            content: const [],
            api: 'anthropic-messages',
            provider: 'anthropic',
            model: 'claude-test',
            usage: const Usage(
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 0,
              cost: UsageCost(),
            ),
            stopReason: StopReason.error,
            errorMessage: 'boom',
            timestamp: _at(1),
          ),
        ),
      ]);
      final lines = trajectoryInspectLines(snapshot, 2)!;
      expect(lines, contains('status: failed'));
      expect(lines, contains('error: boom'));
    });

    test('unanswered tool call shows running status without a result', () {
      final snapshot = trajectorySnapshotOf([
        _userRecord('u1'),
        _assistantRecord('a1', parentId: 'u1', content: [_toolCall('c9')]),
      ]);
      final lines = trajectoryInspectLines(snapshot, 3)!;
      expect(lines.first, '#3 TOOL · bash');
      expect(lines, contains('status: running'));
      expect(lines, isNot(contains('result: ')));
    });
  });

  group('TrajectoryTailer', () {
    test('renders only the suffix appended since the previous call', () {
      final tailer = TrajectoryTailer(width: 200);
      expect(tailer.tail([_userRecord('u1')]), ['#1 USER hi']);
      expect(tailer.tail([_userRecord('u1')]), isEmpty);
      expect(
        tailer.tail([
          _userRecord('u1'),
          _assistantRecord('a1', parentId: 'u1'),
        ]),
        ['#2 ASSISTANT answer (1,000 ms, 163 tok)'],
      );
    });
  });

  group('trajectoryJsonLine', () {
    test('carries index, kind, text, seconds, and tokens', () {
      final lines = trajectoryJsonLine(
        (_snapshot().records[2] as TrajectoryToolRecord),
      );
      final json = jsonDecode(lines) as Map<String, dynamic>;
      expect(json['index'], 3);
      expect(json['kind'], 'tool');
      expect(json['text'], 'bash {"cmd":"ls"} → done');
      expect(json['timeSeconds'], 5.0);
      expect(json['tokens'], isNull);
    });

    test('assistant line carries token totals', () {
      final json =
          jsonDecode(trajectoryJsonLine(_snapshot().records[1]))
              as Map<String, dynamic>;
      expect(json['kind'], 'message');
      expect(json['timeSeconds'], 1.0);
      expect(json['tokens'], 163);
    });
  });

  group('trajectorySnapshotAt', () {
    test('projects the prefix ending at record at', () {
      final records = [
        _userRecord('u1'),
        _userRecord('u2', parentId: 'u1'),
        _assistantRecord('a2', parentId: 'u2'),
      ];
      expect(trajectorySnapshotAt(records, 2)!.records, hasLength(2));
      expect(trajectorySnapshotAt(records, 1)!.records, hasLength(1));
      expect(trajectorySnapshotAt(records, 99), isNull);
      expect(trajectorySnapshotAt(records, 0), isNull);
    });
  });

  group('parseCliArgs trajectory routing', () {
    test('parses verb, session id, and flags', () {
      final args =
          parseCliArgs(['trajectory', 'view', 'abc', '--json', '--at', '2'])
              as CliArgs;
      expect(args.trajectory!.verb, 'view');
      expect(args.trajectory!.positionals, ['abc']);
      expect(args.trajectory!.json, isTrue);
      expect(args.trajectory!.at, 2);
      expect(args.isHeadless, isFalse);
    });

    test('inspect requires a numeric record operand', () {
      final args = parseCliArgs(['trajectory', 'inspect', '3']) as CliArgs;
      expect(args.trajectory!.verb, 'inspect');
      expect(args.trajectory!.positionals, ['3']);
    });

    test('unknown verb is a usage error, never a prompt', () {
      expect(
        () => parseCliArgs(['trajectory', 'vew']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('unknown trajectory verb: vew'),
          ),
        ),
      );
    });

    test('bare trajectory prints usage', () {
      expect(
        () => parseCliArgs(['trajectory']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('--at is rejected outside view', () {
      expect(
        () => parseCliArgs(['trajectory', 'cost', '--at', '2']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('only applies to'),
          ),
        ),
      );
    });

    test('inspect without a number is a usage error', () {
      expect(
        () => parseCliArgs(['trajectory', 'inspect']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('inspect'),
          ),
        ),
      );
    });

    test('unknown flags stay errors inside the subcommand', () {
      expect(
        () => parseCliArgs(['trajectory', 'view', '--model', 'x']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('--help inside the subcommand wins', () {
      expect(
        parseCliArgs(['trajectory', 'view', '--help']),
        isA<CliArgsHelp>(),
      );
      expect(parseCliArgs(['trajectory', '-h']), isA<CliArgsHelp>());
    });

    test('--cwd and --session-root apply to the run config', () {
      final args =
          parseCliArgs([
                'trajectory',
                'view',
                '--cwd',
                '/w',
                '--session-root',
                '/s',
              ])
              as CliArgs;
      expect(args.cwd, '/w');
      expect(args.sessionRoot, '/s');
    });

    test('value flags reject a missing or non-numeric value', () {
      expect(
        () => parseCliArgs(['trajectory', 'view', '--cwd']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parseCliArgs(['trajectory', 'view', '--at']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parseCliArgs(['trajectory', 'view', '--at', 'two']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('more than two positionals is a usage error', () {
      expect(
        () => parseCliArgs(['trajectory', 'inspect', '1', 's1', 's2']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('unexpected argument: s2'),
          ),
        ),
      );
    });

    test('inspect rejects a non-numeric record number', () {
      expect(
        () => parseCliArgs(['trajectory', 'inspect', 'many']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('requires a record number'),
          ),
        ),
      );
    });
  });

  group('resolveTrajectorySession', () {
    late MemoryExecutionEnv env;
    late JsonlSessionRepo repo;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    });

    test('omitted id resolves the most recent session', () async {
      final older = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final newer = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final resolved = await resolveTrajectorySession(repo, null);
      expect(
        (await resolved!.getMetadata()).id,
        (await newer.getMetadata()).id,
      );
      expect(resolved, isNot(older));
    });

    test('exact id and session-name matches resolve', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final metadata = await session.getMetadata();
      await session.appendSessionName('widgets');
      final byId = await resolveTrajectorySession(repo, metadata.id);
      expect((await byId!.getMetadata()).id, metadata.id);
      final byName = await resolveTrajectorySession(repo, 'widgets');
      expect((await byName!.getMetadata()).id, metadata.id);
    });

    test('unknown id resolves nothing', () async {
      await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      expect(await resolveTrajectorySession(repo, 'nope'), isNull);
    });
  });

  group('/trajectory in the REPL', () {
    test('view prints the ledger rows of the live session', () async {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final run = cli.run();
      io.sendLine('hello');
      // 'turn 1' in the post-run status row: the settled-turn marker
      // (plain 'ok' would match the boot row's '0tok').
      await waitForIt(
        () => io.out.toString().contains('· turn 1 ·'),
        reason: 'the prompt turn settles',
      );
      io.sendLine('/trajectory view');
      await waitForIt(
        () => io.out.toString().contains('#2 ASSISTANT'),
        reason: 'the assistant ledger row appears',
      );
      final out = io.out.toString();
      expect(out, contains('#1 USER hello'));
      io.sendLine('/trajectory inspect 99');
      await waitForIt(
        () => io.out.toString().contains('trajectory: record out of range'),
      );
      expect(io.out.toString(), contains('(1..2)'));
      io.sendLine('/exit');
      await run;
    });

    test('tail follows the session until interrupted; cost prints', () async {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final run = cli.run();
      io.sendLine('hello');
      await waitForIt(
        () => io.out.toString().contains('· turn 1 ·'),
        reason: 'the prompt turn settles',
      );
      io.sendLine('/trajectory tail');
      await waitForIt(
        () => io.out.toString().contains('following session records'),
        reason: 'the tail banner appears',
      );
      await waitForIt(
        () => io.out.toString().contains('#2 ASSISTANT'),
        reason: 'the first poll renders the live rows',
      );
      io.interrupt();
      io.sendLine('/trajectory cost');
      await waitForIt(
        () =>
            io.out.toString().contains('session cumulative') ||
            io.out.toString().contains('no requests'),
        reason: 'the interrupt ended the tail and cost printed',
      );
      io.sendLine('/exit');
      await run;
    });
  });
}
