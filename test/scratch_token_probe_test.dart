// SCRATCH PROBE — measures the host_agent_wiring telemetry fixture's request
// estimate. Deleted before finalizing; not part of the deliverable.
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final class _HubRepo implements MessagingRepository {
  const _HubRepo();

  @override
  Object noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not driven in this test');
}

AgentCoreServices _fullServices(ExecutionEnv env) => AgentCoreServices(
  baseEnv: env,
  sessionEnvVars: () => {},
  sandbox: const SandboxServices(),
  snapshots: HashlineSnapshotStore(),
  webSearch: WebSearchConfig(),
  shellJobsFactory: (coreEnv) => ShellJobRegistry(env: coreEnv),
  configServiceFactory: (coreEnv) => null,
  memory: MemoryController(env: env),
  scheduledMessages: ScheduledMessageQueue(
    env: env,
    repo: () => throw UnimplementedError('not driven in this test'),
    root: () => '/tmp/fah-test/messages',
  ),
  onAsk: (questions) async => null,
  onRequestSecret: (name, reason) async => null,
  media: MediaToolServices(mainApiKey: () => 'key'),
  hubFabric: const _HubRepo(),
  mainMailbox: () => 'main',
  extRuntimeFactory: Object(),
  sessionRoot: '/tmp/fah-test',
  subagents: SubagentServices(
    homeDir: '/tmp/fah-test',
    machineName: 'test-machine',
    notifyHeartbeat: (_) {},
    heartbeatMinutes: () => 0,
  ),
);

void main() {
  test('probe: request estimate at the 8192 fixture window', () {
    final wired = wireAgentCore(
      profile: cliProfile,
      services: _fullServices(MemoryExecutionEnv(cwd: '/w')),
    );
    final stack = wired.buildAgentStack(
      spec: AgentWiringSpec(
        model: const Model(
          id: 'test-model',
          api: 'openai-completions',
          provider: 'test',
          baseUrl: 'http://localhost',
          contextWindow: 8192,
          maxTokens: 1024,
        ),
        systemPrompt: 's',
      ),
      streamFunction: (model, context, {cancelToken}) =>
          AssistantMessageEventStream(),
    );
    final tools = stack.agent.state.tools;
    final tokens = estimateRequestTokens(
      [UserMessage.text('hi')],
      systemPrompt: 's',
      tools: tools,
    );
    // ignore: avoid_print
    print('PROBE tools=${tools.length} tokens=$tokens over=${tokens - 8192}');
    for (final t in tools) {
      final e = estimateRequestTokens(const [], systemPrompt: t.description);
      // ignore: avoid_print
      print('PROBE tool=${t.name} est=$e chars=${t.description.length}');
    }
  });
}
