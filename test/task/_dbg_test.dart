@TestOn('vm')
library;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

void main() {
  test('debug boundary', () async {
    final model = Model(
      id: 'm', api: 'test-api', provider: 'p', baseUrl: 'https://e.test',
      contextWindow: 4000, maxTokens: 4096,
    );
    AssistantMessage ast({required int input, required int cacheRead, required int totalTokens, List<ContentBlock> content = const [], StopReason stop = StopReason.stop}) =>
        AssistantMessage(content: content, api: 'a', provider: 'p', model: 'm',
          usage: Usage(input: input, output: 0, cacheRead: cacheRead, cacheWrite: 0, totalTokens: totalTokens, cost: const UsageCost()),
          stopReason: stop, timestamp: DateTime.utc(2026));
    var requests = 0;
    AssistantMessageEventStream call(Model m, Context c, {CancelToken? cancelToken}) {
      requests++;
      final stream = AssistantMessageEventStream();
      final isJudge = (c.systemPrompt ?? '').contains('context-hygiene judge');
      final isCp = (c.systemPrompt ?? '').contains('context checkpoint assistant');
      final text = isJudge ? '[]' : (isCp ? 'cp' : 'turn $requests');
      final stop = isJudge || isCp ? StopReason.stop : StopReason.toolUse;
      final u = Usage(
        input: (!isJudge && !isCp && requests == 2) ? 100 : 0,
        output: 0,
        cacheRead: (!isJudge && !isCp && requests == 2) ? 3400 : 0,
        cacheWrite: 0,
        totalTokens: (!isJudge && !isCp && requests == 2) ? 100 : 0,
        cost: const UsageCost());
      final msg = AssistantMessage(
        content: [TextContent(text: text)],
        api: 'a', provider: 'p', model: 'm',
        usage: u,
        stopReason: stop, timestamp: DateTime.utc(2026));
      stream.push(StartEvent(partial: msg));
      stream.push(TextDeltaEvent(contentIndex: 0, delta: text, partial: msg));
      stream.push(DoneEvent(reason: stop, message: msg));
      stream.end();
      return stream;
    }
    final manager = SubagentManager(parentSessionId: 'ps', clock: () => DateTime.utc(2026))..mailboxPrefix = 'ps';
    final env = MemoryExecutionEnv(cwd: '/w');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/s');
    final executor = TaskExecutor(
      childTools: [
        AgentTool(name: 'read', description: 'r', tier: ApprovalTier.read,
          execute: (a, c, o) async => ToolExecutionResult.text('fat:${'x' * 2400}')),
      ],
      streamFunction: () => call,
      model: () => model,
      registry: TaskAgentRegistry([const TaskAgentDefinition(name: 'w', description: 'w', systemPrompt: 'w')]),
      semaphore: Semaphore(2),
      store: AgentOutputStore(),
      subagentManager: manager,
      childSessionFactory: (p, c) => repo.create(JsonlSessionCreateOptions(cwd: '/w', metadata: {'agent': 'subagent', 'id': c, 'parent': p, 'model': 'm'})),
      childSessionOpener: jsonlChildSessionOpener(env),
    );
    final result = await executor.runSpawn(item: const TaskItem(name: 'd', agent: 'w', task: 'grow'), index: 0, context: '');
    // ignore: avoid_print
    print('status=${result.status} err=${result.error}');
    // ignore: avoid_print
    print('requests=$requests est=${manager['d']!.estTokens} obs=${manager['d']!.observedTokens} win=${manager['d']!.windowTokens} compactions=${manager['d']!.compactions}');
    expect(true, isTrue);
  });
}
