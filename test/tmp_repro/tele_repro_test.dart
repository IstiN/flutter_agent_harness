import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hosts/host_agent_wiring.dart';

int calls = 0;

void main() async {
  final sink = _Sink();
  final services = AgentCoreServices(
    baseEnv: MemoryExecutionEnv(cwd: '/w'),
    sessionEnvVars: () => {},
    sandbox: const SandboxServices(),
    snapshots: HashlineSnapshotStore(),
    webSearch: WebSearchConfig(),
    shellJobsFactory: (coreEnv) => ShellJobRegistry(env: coreEnv),
    configServiceFactory: (coreEnv) => null,
    memory: MemoryController(env: MemoryExecutionEnv(cwd: '/w')),
    scheduledMessages: ScheduledMessageQueue(
      env: MemoryExecutionEnv(cwd: '/w'),
      repo: () => throw UnimplementedError(),
      root: () => '/tmp/fah-tele-repro/messages',
    ),
    onAsk: (q) async => null,
    onRequestSecret: (n, r) async => null,
    media: MediaToolServices(mainApiKey: () => 'key'),
    mainMailbox: () => 'main',
    sessionRoot: '/tmp/fah-tele-repro',
    telemetry: sink,
  );
  final wired = wireAgentCore(profile: cliProfile, services: services);
  final stack = wired.buildAgentStack(
    spec: AgentWiringSpec(
      model: const Model(
        id: 'test-model',
        label: 't',
        provider: 'test-provider',
        baseUrl: 'https://api.test/v1',
        apiKey: 'k',
      ),
      systemPrompt: 's',
    ),
    streamFunction: (model, context, {cancelToken}) {
      calls++;
      final stream = AssistantMessageEventStream();
      final partial = AssistantMessage(
        content: const [TextContent(text: 'hi')],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      stream.push(StartEvent(partial: partial));
      stream.push(DoneEvent(reason: StopReason.stop, message: partial));
      return stream;
    },
  );
  await stack.agent.prompt('hi');
  print('stream calls: $calls');
}

final class _Sink implements AgentTelemetrySink {
  @override
  void record(AgentTelemetryEvent event) {
    print('EVENT ${event.kind} stop=${event.stopReason} err=${event.isError} '
        'msg=${event.message} errType=${event.errorType}');
  }
}
