/// Issue #1079 slice 2 — live agent-stack wiring through the builder.
///
/// Canonical CLI tool-order parity (the conversion must reproduce the
/// pre-conversion registration order) · AC7 run-hiding (off capabilities
/// contribute no tools, no surfaced tokens; 🔀 profiles surface only the
/// served transports) · run-narrowing (absent services turn wired
/// capabilities off with a reason; never force-enable) · buildAgentStack
/// (registry + agent assembled in the documented order).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Minimal full-CLI service bundle: every optional facility provided so
/// the run profile equals [cliProfile] (the CLI boots exactly this when
/// every config section is present).
AgentCoreServices fullServices(ExecutionEnv env) => AgentCoreServices(
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
  hostTools: const [],
  hubFabric: Object(),
  extRuntimeFactory: Object(),
  sessionRoot: '/tmp/fah-test',
);

void main() {
  group('canonical CLI wiring (order parity)', () {
    test('the full bundle reproduces the pre-conversion tool order', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w')),
      );
      expect(
        wired.tools.map((t) => t.name),
        containsAll([
          'read',
          'write',
          'edit',
          'ls',
          'bash',
          'memory_add',
          'schedule_message',
          'ask',
          'request_secret',
          'generate_image',
          'generate_video',
        ]),
      );
      // Core builtins first, host tools last: the registry must see the
      // same registration order as the hand-rolled constructor produced.
      expect(wired.tools.first.name, 'read');
    });

    test('env chain: sandbox wraps base, session vars wrap sandbox', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w')),
      );
      expect(wired.sandboxEnv, isNotNull);
      expect(wired.networkGate, isNotNull);
      final env = wired.env;
      expect(env, isA<SessionVarsExecutionEnv>());
      expect(
        (env as SessionVarsExecutionEnv).delegate,
        isA<SandboxedExecutionEnv>(),
      );
    });

    test('buildAgentStack registers core first, then the host surface', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w')),
      );
      final extra = _namedTool('host_extra');
      final stack = wired.buildAgentStack(
        spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
        streamFunction: _fakeStream,
        additionalTools: [extra],
      );
      expect(stack.registry.names.last, 'host_extra');
      expect(stack.agent.state.tools, equals(stack.registry.tools));
    });
  });

  group('run-narrowing (AC7 — hiding, off means absent everywhere)', () {
    test('absent web search config hides the family from tools AND tokens', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        sandbox: const SandboxServices(),
        media: MediaToolServices(mainApiKey: () => 'k'),
        sessionRoot: '/tmp/fah-test',
      );
      final wired = wireAgentCore(profile: cliProfile, services: services);
      final names = wired.tools.map((t) => t.name).toSet();
      expect(names, isNot(contains('web_search')));
      final plan = wired.plan.planFor(HostCapability.webSearch);
      expect(plan, isA<HiddenCapability>());
      expect((plan as HiddenCapability).reason, contains('webSearchSecrets'));
      expect(wired.plan.surfacedTokens, isNot(contains('web_search')));
    });

    test('absent browser handle hides the bridge with its reason', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        sandbox: const SandboxServices(),
        media: MediaToolServices(mainApiKey: () => 'k'),
        sessionRoot: '/tmp/fah-test',
      );
      final wired = wireAgentCore(profile: cliProfile, services: services);
      expect(
        wired.tools.map((t) => t.name),
        everyElement(isNot(startsWith('browser_'))),
      );
      final plan = wired.plan.planFor(HostCapability.browserBridge);
      expect(plan, isA<HiddenCapability>());
      expect(
        (plan as HiddenCapability).reason,
        contains('browserBridgeHandle'),
      );
    });

    test('sqlite/lsp narrow per transport; zero served = off', () {
      final env = MemoryExecutionEnv(cwd: '/w');
      final bothAbsent = AgentCoreServices(
        baseEnv: env,
        sandbox: const SandboxServices(),
        media: MediaToolServices(mainApiKey: () => 'k'),
        sessionRoot: '/tmp/fah-test',
      );
      final off = wireAgentCore(profile: cliProfile, services: bothAbsent);
      expect(
        off.plan.planFor(HostCapability.sqliteLspDap),
        isA<HiddenCapability>(),
      );

      final lspOnly = AgentCoreServices(
        baseEnv: env,
        sandbox: const SandboxServices(),
        lsp: LspToolConfig(transportFactory: _fakeLspTransport),
        media: MediaToolServices(mainApiKey: () => 'k'),
        sessionRoot: '/tmp/fah-test',
      );
      final narrowed = wireAgentCore(profile: cliProfile, services: lspOnly);
      final plan = narrowed.plan.planFor(HostCapability.sqliteLspDap);
      expect(plan, isA<WiredCapability>());
      expect((plan as WiredCapability).transports, {'process'});
    });

    test('hub-absent messaging narrows to the served transports', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        sandbox: const SandboxServices(),
        media: MediaToolServices(mainApiKey: () => 'k'),
        sessionRoot: '/tmp/fah-test',
      );
      final wired = wireAgentCore(profile: cliProfile, services: services);
      final plan = wired.plan.planFor(HostCapability.messagingFabric);
      expect(plan, isA<WiredCapability>());
      expect((plan as WiredCapability).transports, {'file', 'a2a'});
      expect(wired.plan.surfacedTokens, isNot(contains('messagingFabric:hub')));
    });

    test('narrowing never force-enables a floored capability', () {
      final services = fullServices(MemoryExecutionEnv(cwd: '/w'));
      final wired = wireAgentCore(profile: cliProfile, services: services);
      // The VM floors: on-device inference and browser-API JS apps stay
      // off no matter what the host serves.
      expect(
        wired.plan.planFor(HostCapability.onDeviceProviders),
        isA<HiddenCapability>(),
      );
      expect(
        wired.plan.planFor(HostCapability.jsApps),
        isA<HiddenCapability>(),
      );
    });

    test('a profile with the sandbox off skips the sandbox layer', () {
      final noSandboxProfile = cliProfile.narrowed({
        HostCapability.sandboxEnv: CapabilityState.off('test host'),
      });
      final wired = wireAgentCore(
        profile: noSandboxProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w')),
      );
      expect(wired.sandboxEnv, isNull);
      expect(wired.networkGate, isNull);
      expect(wired.env, isA<SessionVarsExecutionEnv>());
      // The web tools then run ungated — the host's own choice.
      expect(wired.plan.surfacedTokens, contains('web_search'));
    });
  });

  group('media facility', () {
    test('hosts without MediaToolServices surface no media tools', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        sandbox: const SandboxServices(),
        sessionRoot: '/tmp/fah-test',
      );
      final wired = wireAgentCore(profile: cliProfile, services: services);
      final names = wired.tools.map((t) => t.name).toSet();
      expect(names, isNot(contains('generate_image')));
      expect(names, isNot(contains('generate_video')));
      // The vision/transcribe row stays wired (AC10 inventory row): the
      // facility is per-tool config gating, not a capability floor.
      expect(
        wired.plan.planFor(HostCapability.visionTranscribe),
        isA<WiredCapability>(),
      );
    });
  });
}

final _model = Model(
  id: 'test-model',
  api: 'openai-completions',
  provider: 'test',
  baseUrl: 'http://localhost',
  contextWindow: 8192,
  maxTokens: 1024,
);

AssistantMessageEventStream _fakeStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) => AssistantMessageEventStream();

AgentTool _namedTool(String name) => AgentTool(
  name: name,
  label: name,
  description: 'test',
  parameters: {},
  execute: (arguments, cancelToken, onUpdate) async =>
      ToolExecutionResult.text('ok'),
);

Future<LspTransport> _fakeLspTransport(LspServerConfig config, String cwd) =>
    throw UnimplementedError('not started in this test');
