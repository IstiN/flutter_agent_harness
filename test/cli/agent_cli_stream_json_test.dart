import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Issue #695 IT tier (fake provider): the headless run wired with a
/// [StreamJsonWriter] emits a valid NDJSON agent-event stream — session
/// header first, `agent_settled` last, tool calls visible in real time,
/// fa-native events filtered, and the redaction the session record applies
/// riding the stream byte-identically.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli buildCli(
    FakeStreamFunction stream, {
    RedactionPipeline? redaction,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      redactionPipeline: redaction,
    ),
    io: io,
    streamFunction: stream.call,
  );

  (AgentCli, List<String>) cliWithStream(FakeStreamFunction stream) {
    final lines = <String>[];
    return (buildCli(stream), lines);
  }

  List<Map<String, dynamic>> parseLines(List<String> lines) => [
    for (final line in lines) jsonDecode(line) as Map<String, dynamic>,
  ];

  test(
    'happy path: session header first, agent_settled last, exit 0 (AC1)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = FakeStreamFunction([textTurn('Hello from the agent')]);
      final (cli, lines) = cliWithStream(stream);
      final writer = StreamJsonWriter(emit: lines.add);

      final code = await cli.runHeadless('hi', streamJson: writer);

      expect(code, 0);
      expect(lines, isNotEmpty);
      final events = parseLines(lines);
      // First line: session header.
      expect(events.first['type'], 'session');
      expect(events.first['version'], 1);
      expect(events.first['id'], isA<String>());
      expect((events.first['id'] as String).isNotEmpty, isTrue);
      expect(events.first['cwd'], '/work');
      // Last line: agent_settled.
      expect(events.last['type'], 'agent_settled');
      // Full lifecycle ordering.
      final types = [for (final e in events) e['type'] as String];
      expect(
        types,
        containsAllInOrder([
          'session',
          'agent_start',
          'turn_start',
          'message_start',
          'message_update',
          'message_end',
          'turn_end',
          'agent_end',
          'agent_settled',
        ]),
      );
      // The streamed text assembled from deltas matches the final message.
      final assembled = [
        for (final e in events.where((e) => e['type'] == 'message_update'))
          (((e['assistantMessageEvent'] as Map)['delta']) ?? '') as String,
      ].join();
      expect(assembled, 'Hello from the agent');
    },
  );

  test(
    'exit code parity: stream-json matches text mode for the same run (AC1)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Error-terminal run: both modes must report the same exit code.
      final failing = AssistantMessage(
        content: const [],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.error,
        errorMessage: 'boom',
        timestamp: DateTime.utc(2026),
      );
      final failTurns = [
        [ErrorEvent(reason: StopReason.error, error: failing)],
      ];

      final textCli = buildCli(FakeStreamFunction(failTurns));
      final textCode = await textCli.runHeadless('hi');

      final lines = <String>[];
      final streamCli = buildCli(FakeStreamFunction(failTurns));
      final streamCode = await streamCli.runHeadless(
        'hi',
        streamJson: StreamJsonWriter(emit: lines.add),
      );
      expect(streamCode, textCode);
      expect(streamCode, 1);
      // E1: the error run still ends with agent_end + agent_settled, never
      // a truncated line.
      final types = [for (final e in parseLines(lines)) e['type'] as String];
      expect(types.sublist(types.length - 2), ['agent_end', 'agent_settled']);
      final turnEnd = parseLines(
        lines,
      ).lastWhere((e) => e['type'] == 'turn_end');
      expect((turnEnd['message'] as Map)['stopReason'], 'error');
    },
  );

  test(
    'tool round trip: start (with args) precedes end (with result) (AC4)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      env.writeFile('a.txt', 'file body');
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(id: 't1', name: 'read', arguments: {'path': 'a.txt'}),
        ]),
        textTurn('done'),
      ]);
      final (cli, lines) = cliWithStream(stream);

      final code = await cli.runHeadless(
        'read it',
        streamJson: StreamJsonWriter(emit: lines.add),
      );

      expect(code, 0);
      final events = parseLines(lines);
      final types = [for (final e in events) e['type'] as String];
      final startAt = types.indexOf('tool_execution_start');
      final endAt = types.indexOf('tool_execution_end');
      expect(startAt, greaterThanOrEqualTo(0));
      expect(
        endAt,
        greaterThan(startAt),
        reason: 'tool_execution_start must precede tool_execution_end',
      );
      final start = events[startAt];
      expect(start['toolCallId'], 't1');
      expect(start['toolName'], 'read');
      expect(start['args'], {'path': 'a.txt'});
      final end = events[endAt];
      expect(end['toolCallId'], 't1');
      expect(end['isError'], false);
      final resultText = [
        for (final block in (end['result'] as Map)['content'] as List)
          if (block is Map<String, dynamic> && block['type'] == 'text')
            block['text'] as String,
      ].join();
      expect(resultText, contains('file body'));
    },
  );

  test(
    'stdout purity: fa-native events filtered, every line valid JSON (AC5)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      env.writeFile('a.txt', 'body');
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(id: 't1', name: 'read', arguments: {'path': 'a.txt'}),
        ]),
        textTurn('done'),
      ]);
      // The stdout-ownership decorator the binary applies in stream-json
      // mode: prose writes are dropped (frames carry them), writeln keeps
      // its diagnostic channel.
      final lines = <String>[];
      final owned = HepEventsIO(io);

      await AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: owned,
        streamFunction: stream.call,
      ).runHeadless('read it', streamJson: StreamJsonWriter(emit: lines.add));

      // Every stdout line is valid JSON.
      final events = parseLines(lines);
      // fa-native events never ride the stream.
      for (final e in events) {
        expect(e['type'], isNot(anyOf('model_request', 'tool_pairing_repair')));
      }
      // Assistant prose never lands via CliIO.write — the frames own it.
      expect(io.out.toString(), isNot(contains('done')));
    },
  );

  test(
    'redaction: a tool-result secret is masked exactly like the session '
    'record (AC6)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const secret = 'sk-live-abcdef1234567890';
      env.writeFile('a.txt', 'token=$secret');
      final pipeline = RedactionPipeline(registeredSecrets: const [secret]);
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(id: 't1', name: 'read', arguments: {'path': 'a.txt'}),
        ]),
        textTurn('done'),
      ]);
      final lines = <String>[];
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          // Inside cwd: MemoryFileSystem.exportSnapshot() walks the cwd
          // subtree only, so the JSONL must live under /work to be
          // visible to the record-vs-stream byte-compare below.
          sessionRoot: '/work/sessions',
          providerKind: 'openai-completions',
          redactionPipeline: pipeline,
        ),
        io: io,
        streamFunction: stream.call,
      );

      final code = await cli.runHeadless(
        'read it',
        streamJson: StreamJsonWriter(emit: lines.add),
      );
      expect(code, 0);

      // The stream never carries the raw secret...
      for (final line in lines) {
        expect(line, isNot(contains(secret)));
      }
      final end = parseLines(
        lines,
      ).firstWhere((e) => e['type'] == 'tool_execution_end');
      final streamText = [
        for (final block in (end['result'] as Map)['content'] as List)
          if (block is Map<String, dynamic> && block['type'] == 'text')
            block['text'] as String,
      ].join();

      // ...and the redaction is byte-identical to the persisted session
      // record's tool result for the same call.
      final snapshot = env.exportSnapshot();
      final sessionFiles = snapshot.files.keys
          .where((path) => path.endsWith('.jsonl'))
          .toList();
      expect(sessionFiles, isNotEmpty);
      var recordText = '';
      for (final path in sessionFiles) {
        final content = utf8.decode(snapshot.files[path]!);
        for (final line in content.split('\n')) {
          if (line.isEmpty || !line.contains('toolResult')) continue;
          try {
            final record = jsonDecode(line) as Map<String, dynamic>;
            final message = record['message'] as Map<String, dynamic>?;
            if (message == null ||
                message['role'] != 'toolResult' ||
                message['toolCallId'] != 't1') {
              continue;
            }
            recordText = [
              for (final block in message['content'] as List)
                if (block is Map<String, dynamic> && block['type'] == 'text')
                  block['text'] as String,
            ].join();
          } on FormatException {
            // Non-JSON lines (headers etc.) carry no tool result.
          }
        }
      }
      expect(
        recordText,
        isNotEmpty,
        reason: 'the session record must persist the tool result',
      );
      expect(streamText, contains('[REDACTED:'));
      expect(streamText, recordText);
    },
  );

  test(
    'aborted run still emits agent_end then agent_settled, exit 130 (E2)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final fake = AbortableStreamFunction();
      final (cli, lines) = (
        AgentCli(
          config: AgentCliConfig(
            model: testModel,
            apiKey: 'test-key',
            env: env,
            sessionRoot: '/sessions',
            providerKind: 'openai-completions',
          ),
          io: io,
          streamFunction: fake.call,
        ),
        <String>[],
      );

      final run = cli.runHeadless(
        'hang',
        streamJson: StreamJsonWriter(emit: lines.add),
      );
      await waitForIt(() => fake.started, reason: 'run to start');
      io.interrupt();
      final code = await run;

      expect(code, 130);
      final types = [for (final e in parseLines(lines)) e['type'] as String];
      expect(types.first, 'session');
      expect(types.last, 'agent_settled');
      expect(types, contains('agent_end'));
    },
  );
}
