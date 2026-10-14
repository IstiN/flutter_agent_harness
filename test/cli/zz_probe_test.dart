import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'agent_cli_test_support.dart';

void main() {
  test('probe boot', timeout: const Timeout(Duration(minutes: 3)), () async {
    final io = FakeCliIO();
    final ob = io;
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('bench-target');
    await seed.appendMessage(UserMessage.text('TASK hi'));
    await seed.appendCustomEntry(
      customType: obligationsLedgerRecordType,
      data: [
        {
          'id': 'obl-1',
          'kind': 'owner-rule',
          'text': 'always run tests',
          'sourceRecordId': 'r1',
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'status': 'open',
        },
      ],
    );
    await seed.appendMessage(
      AssistantMessage(
        content: [const ToolCall(id: 'c1', name: 'read', arguments: {})],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.utc(2026),
      ),
    );
    await seed.appendMessage(
      ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'read',
        content: [const TextContent(text: 'seed tool result')],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await seed.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
    }
    var calls = 0;
    final agent = AgentCli(
      config: AgentCliConfig(
        model: Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 200000,
          maxTokens: 4096,
        ),
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'bench-target',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
      ),
      io: io,
      environment: const {'FAH_COMPACT_TRIGGER_TOKENS': '24000'},
      streamFunction: (model, context, {cancelToken}) {
        calls++;
        final stream = AssistantMessageEventStream();
        for (final event in textTurn('answer $calls')) {
          stream.push(event);
        }
        stream.end();
        return stream;
      },
    );
    final run = agent.run();
    await waitForIt(
      () => io.out.toString().isNotEmpty || calls > 0,
      reason: 'any boot output or model call',
    );
    io.sendLine('go');
    await waitForIt(
      () => calls >= 1 && !agent.isBusy,
      reason: 'first turn answered (calls=$calls out=${io.out.toString().length})',
    );
    io.sendLine('/exit');
    await run;
    // ignore: avoid_print
    print('calls=$calls transcriptLen=${io.out.toString().length}');
  });
}
