/// Issue #1079 slice 2 — live agent-stack wiring through the builder.
/// Slice 3 — the builder-owned task/subagent/fabric complex: the gated
/// task surface rides the stack after the host tools (canonical order),
/// stays OUT of the child-safe core list, and disappears with its
/// capability (off = absent from tools AND tokens, no orphan handles).
///
/// Canonical CLI tool-order parity (the conversion must reproduce the
/// pre-conversion registration order) · AC7 run-hiding (off capabilities
/// contribute no tools, no surfaced tokens; 🔀 profiles surface only the
/// served transports) · run-narrowing (absent services turn wired
/// capabilities off with a reason; never force-enable) · buildAgentStack
/// (registry + agent assembled in the documented order).
library;

import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Minimal full-CLI service bundle: every optional facility provided so
/// the run profile equals [cliProfile] (the CLI boots exactly this when
/// every config section is present). The #1322 seams default to absent —
/// pass them to exercise the wired path.
AgentCoreServices fullServices(
  ExecutionEnv env, {
  AgentTelemetrySink? telemetry,
  HostKeyResolver? keyResolver,
  void Function(String hint)? onKeySlotDrift,
}) => AgentCoreServices(
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
  telemetry: telemetry,
  keyResolver: keyResolver,
  onKeySlotDrift: onKeySlotDrift,
  subagents: SubagentServices(
    homeDir: '/tmp/fah-test',
    machineName: 'test-machine',
    notifyHeartbeat: (_) {},
    // Kill switch: no heartbeat timer arms under tests.
    heartbeatMinutes: () => 0,
  ),
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

  group('headless host-callback tools (ask / request_secret)', () {
    test(
      'null callbacks still register the tools (graceful in-tool failure)',
      () {
        // CLI parity: the pre-conversion shell registered ask and
        // request_secret UNCONDITIONALLY — a null callback is the tools'
        // documented headless mode (executing throws a StateError the loop
        // converts into "cannot answer questions" / "cannot request
        // secrets"). Dropping the tools instead surfaces a bare
        // "Tool ask not found", which is the regression this pins.
        final services = AgentCoreServices(
          baseEnv: MemoryExecutionEnv(cwd: '/w'),
          sandbox: const SandboxServices(),
          media: MediaToolServices(mainApiKey: () => 'k'),
          sessionRoot: '/tmp/fah-test',
        );
        final wired = wireAgentCore(profile: cliProfile, services: services);
        final names = wired.tools.map((t) => t.name);
        expect(names, contains('ask'));
        expect(names, contains('request_secret'));
        // And the headless mode still resolves gracefully per tool.
        final ask = wired.tools.firstWhere((t) => t.name == 'ask');
        expect(
          () => ask.execute(
            const {
              'questions': [
                {'question': 'q'},
              ],
            },
            null,
            null,
          ),
          throwsA(isA<StateError>()),
        );
        final secret = wired.tools.firstWhere(
          (t) => t.name == 'request_secret',
        );
        expect(
          () => secret.execute(
            const {'name': 'GITHUB_TOKEN', 'reason': 'needed'},
            null,
            null,
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
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

  group('issue #1322 host seams (telemetry + key resolution)', () {
    test('services.telemetry wires the sink in one field', () async {
      final sink = InMemoryTelemetrySink();
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w'), telemetry: sink),
      );
      final stack = wired.buildAgentStack(
        spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
        streamFunction: _textTurnStream,
      );
      await stack.agent.prompt('hi');
      expect(
        sink.events.map((e) => e.kind),
        containsAll([
          AgentTelemetryEventKind.requestStart,
          AgentTelemetryEventKind.firstToken,
          AgentTelemetryEventKind.runEnd,
        ]),
      );
      // The agent runs through the WRAPPED stream function — the host's
      // own function still receives the call underneath.
      expect(_textTurnCalls, 1);
    });

    test('a pinned key slot fires the drift warning at stack build', () {
      final hints = <String>[];
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(
          MemoryExecutionEnv(cwd: '/w'),
          keyResolver: HostKeyResolver(
            envRead: (name) => null,
            storeRead: (name) =>
                name == 'FA_KEY_API_KIMI_COM_IRA_1' ? 'sk-ira' : null,
            knownSlotNames: const ['FA_KEY_API_KIMI_COM_IRA_1'],
          ),
          onKeySlotDrift: hints.add,
        ),
      );
      wired.buildAgentStack(
        spec: AgentWiringSpec(
          model: const Model(
            id: 'kimi-k2',
            api: 'openai-completions',
            provider: 'kimi',
            baseUrl: 'https://api.kimi.com',
            contextWindow: 8192,
            maxTokens: 1024,
          ),
          systemPrompt: 's',
        ),
        streamFunction: _fakeStream,
      );
      expect(hints, hasLength(1));
      expect(
        hints.single,
        allOf(
          contains('FA_KEY_API_KIMI_COM_IRA_1'),
          contains('/key set FA_KEY_API_KIMI_COM <value>'),
        ),
      );
    });

    test('no resolver, no telemetry → byte-identical legacy wiring', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w')),
      );
      final stack = wired.buildAgentStack(
        spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
        streamFunction: _fakeStream,
      );
      // Same surface as before #1322: the host's stream function rides
      // the agent unwrapped, no telemetry attached.
      expect(identical(stack.agent.streamFunction, _fakeStream), isTrue);
    });

    test('services.resolveKey answers before the session binds', () {
      final services = fullServices(
        MemoryExecutionEnv(cwd: '/w'),
        keyResolver: HostKeyResolver(
          envRead: (name) => null,
          storeRead: (name) =>
              name == 'FA_KEY_API_KIMI_COM' ? 'sk-canonical' : null,
        ),
      );
      final resolution = services.resolveKey(
        provider: 'kimi',
        baseUrl: 'https://api.kimi.com',
      );
      expect(resolution!.slotName, 'FA_KEY_API_KIMI_COM');
      expect(resolution.driftHint, isNull);
    });
  });

  group('env chain for fs-touching tools (review #1230 decision)', () {
    test(
      'vision reads and browser screenshot saves clamp through the cube',
      () async {
        final base = MemoryExecutionEnv(cwd: '/work');
        // Outside the workspace: the RAW env the pre-conversion CLI handed
        // these tools reads this file fine — the decorated chain must not.
        expect((await base.createDir('/etc')).isOk, isTrue);
        expect((await base.writeFile('/etc/secret.png', 'raw')).isOk, isTrue);
        final screenshotEnvs = <ExecutionEnv>[];
        final wired = wireAgentCore(
          profile: cliProfile,
          services: AgentCoreServices(
            baseEnv: base,
            sessionEnvVars: () => {},
            sandbox: const SandboxServices(
              spec: CubeSpec(
                name: 'clamp',
                tools: CubeToolPolicy(allow: {'git'}),
                filesystem: CubeFsPolicy(workspace: '/work'),
              ),
            ),
            vision: const InspectImageConfig(modelId: 'vision', apiKey: 'k'),
            transcribe: const TranscribeAudioConfig(apiKey: 'k'),
            media: MediaToolServices(mainApiKey: () => 'k'),
            shellJobsFactory: (coreEnv) => ShellJobRegistry(env: coreEnv),
            browserController: _ShotController(Uint8List(8)),
            saveBrowserScreenshot: (coreEnv, png) async {
              screenshotEnvs.add(coreEnv);
              return '/work/generated/browser-1.png';
            },
            sessionRoot: '/tmp/fah-test',
          ),
        );

        // ONE env object everywhere: the service seams and the tool
        // closures all receive wired.env — never the raw base env.
        expect(screenshotEnvs, isEmpty);
        // The vision tool REALLY reads through the guard: an
        // outside-workspace path is permission-denied where the raw base
        // env reads it — the exact bypass the decorated chain closes.
        final inspect = wired.tools.firstWhere(
          (t) => t.name == 'inspect_image',
        );
        await expectLater(
          inspect.execute(const {'path': '/etc/secret.png'}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              // The guard HIDES outside-workspace paths (notFound), and
              // names itself: only the cube guard produces this denial.
              allOf(contains('notFound'), contains('fa_cube[clamp]:')),
            ),
          ),
        );
        expect((await base.readBinaryFile('/etc/secret.png')).isOk, isTrue);

        // And the browser save rides the same chain end-to-end: executing
        // the tool hands its screenshot to the service callback over
        // wired.env.
        final shot = wired.tools.firstWhere(
          (t) => t.name == 'browser_screenshot',
        );
        final saved = await shot.execute(const {}, null, null);
        expect(saved.content.first, isA<TextContent>());
        expect(identical(screenshotEnvs.single, wired.env), isTrue);
        expect(screenshotEnvs.single, isNot(same(base)));
      },
    );
  });

  group('task/subagent complex (slice 3 — builder-owned jobs)', () {
    test(
      'full bundle: gated task surface rides AFTER the host tools; core tools stay child-safe',
      () {
        final wired = wireAgentCore(
          profile: cliProfile,
          services: fullServices(MemoryExecutionEnv(cwd: '/w')),
        );
        // The core list is the child tool pool: the executor strips only
        // `task` itself, so NO monitoring/task tool may ride in it.
        final coreNames = wired.tools.map((t) => t.name).toSet();
        for (final childUnsafe in [
          'task',
          'task_status',
          'task_send',
          'task_resume',
          'task_cancel',
          'agent_directory',
          'reply',
          'agent_message',
        ]) {
          expect(coreNames, isNot(contains(childUnsafe)));
        }
        // The gated surface: monitoring first, `task` LAST (canonical
        // pre-conversion order).
        expect(wired.taskSurface, isNotEmpty);
        expect(wired.taskSurface.first.name, 'task_status');
        expect(wired.taskSurface.last.name, 'task');
        // Registry order: core → host tools → monitoring → task → extras.
        final stack = wired.buildAgentStack(
          spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
          streamFunction: _fakeStream,
          additionalTools: [_namedTool('host_extra')],
        );
        final names = stack.registry.names;
        expect(names.indexOf('host_extra'), greaterThan(names.indexOf('task')));
        expect(names, containsAll(['task_status', 'agent_directory', 'task']));
      },
    );

    test('wired handles expose the assembled complex for the shell', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: fullServices(MemoryExecutionEnv(cwd: '/w')),
      );
      expect(wired.messagesRoot, contains('/tmp/fah-test'));
      expect(wired.fileFabric, isNotNull);
      expect(wired.fabric, isNotNull);
      expect(wired.subagentManager, isNotNull);
      expect(wired.subagentManager!.selfId, 'main');
      expect(wired.taskConfig, isNotNull);
      expect(wired.taskConfig!.subagentManager, same(wired.subagentManager));
      expect(wired.a2aManager, isNotNull);
      expect(wired.subagentHeartbeat, isNotNull);
    });

    test(
      'hub fabric composes over the file layer; hub-absent stays bare file',
      () {
        final env = MemoryExecutionEnv(cwd: '/w');
        final withHub = wireAgentCore(
          profile: cliProfile,
          services: fullServices(env),
        );
        expect(withHub.fabric, isA<FallbackMessagingRepository>());
        final noHubServices = AgentCoreServices(
          baseEnv: env,
          sandbox: const SandboxServices(),
          media: MediaToolServices(mainApiKey: () => 'k'),
          sessionRoot: '/tmp/fah-test',
          subagents: SubagentServices(
            notifyHeartbeat: (_) {},
            heartbeatMinutes: () => 0,
          ),
        );
        final withoutHub = wireAgentCore(
          profile: cliProfile,
          services: noHubServices,
        );
        expect(withoutHub.fabric, isA<SwappableMessagingRepository>());
        expect(withoutHub.fabric, isNot(isA<FallbackMessagingRepository>()));
      },
    );

    test(
      'profile with subagents off hides the whole surface — tools AND tokens',
      () {
        final profile = cliProfile.narrowed({
          HostCapability.subagents: CapabilityState.off('test host'),
        });
        final wired = wireAgentCore(
          profile: profile,
          services: fullServices(MemoryExecutionEnv(cwd: '/w')),
        );
        expect(wired.taskSurface, isEmpty);
        expect(wired.subagentManager, isNull);
        expect(wired.taskConfig, isNull);
        final stack = wired.buildAgentStack(
          spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
          streamFunction: _fakeStream,
        );
        expect(stack.registry.names, isNot(contains('task')));
        expect(stack.registry.names, isNot(contains('agent_directory')));
        expect(wired.plan.surfacedTokens, isNot(contains('task')));
        expect(wired.plan.surfacedTokens, isNot(contains('agent_directory')));
      },
    );

    test(
      'absent subagent bundle run-narrows the capability off (reason names the gap)',
      () {
        final wired = wireAgentCore(
          profile: cliProfile,
          services: AgentCoreServices(
            baseEnv: MemoryExecutionEnv(cwd: '/w'),
            sandbox: const SandboxServices(),
            media: MediaToolServices(mainApiKey: () => 'k'),
            sessionRoot: '/tmp/fah-test',
          ),
        );
        final plan = wired.plan.planFor(HostCapability.subagents);
        expect(plan, isA<HiddenCapability>());
        expect((plan as HiddenCapability).reason, contains('subagentServices'));
        expect(wired.taskSurface, isEmpty);
        expect(wired.subagentManager, isNull);
      },
    );

    test('hub-only run keeps the wired hub — no silent fabric discard', () {
      // A transport-narrowed profile (the mobile shape: hub, no file
      // layer) must still get its WIRED hub as the fabric — the file
      // transport's absence discards only the file layer, never the
      // whole fabric.
      const hub = _HubRepo();
      final profile = cliProfile.narrowed({
        HostCapability.messagingFabric: CapabilityTransportState({
          'hub',
        }, 'test hub-only host'),
      });
      final wired = wireAgentCore(
        profile: profile,
        services: AgentCoreServices(
          baseEnv: MemoryExecutionEnv(cwd: '/w'),
          sandbox: const SandboxServices(),
          media: MediaToolServices(mainApiKey: () => 'k'),
          hubFabric: hub,
          mainMailbox: () => 'main',
          sessionRoot: '/tmp/fah-test',
          subagents: SubagentServices(
            notifyHeartbeat: (_) {},
            heartbeatMinutes: () => 0,
          ),
        ),
      );
      expect(
        wired.plan.planFor(HostCapability.messagingFabric),
        isA<WiredCapability>(),
      );
      expect(wired.fabric, same(hub));
      expect(wired.fileFabric, isNull);
      expect(wired.messagesRoot, isNull);
    });

    test('hub wired without a mainMailbox resolver fails loudly (E1)', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        sandbox: const SandboxServices(),
        media: MediaToolServices(mainApiKey: () => 'k'),
        sessionRoot: '/tmp/fah-test',
        hubFabric: const _HubRepo(),
        // No mainMailbox: the hub merge seam is unnamed — must be a loud
        // E1 build failure, never a silent null-resolver crash at mail
        // time.
        subagents: SubagentServices(
          notifyHeartbeat: (_) {},
          heartbeatMinutes: () => 0,
        ),
      );
      expect(
        () => wireAgentCore(profile: cliProfile, services: services),
        throwsA(
          isA<HostWiringException>().having(
            (e) => e.message,
            'message',
            contains('mainMailbox'),
          ),
        ),
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

/// A scripted completed text turn — counts the calls so the telemetry
/// wrap provably delegates to the host's own stream function.
var _textTurnCalls = 0;
AssistantMessageEventStream _textTurnStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  _textTurnCalls++;
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
}

AgentTool _namedTool(String name) => AgentTool(
  name: name,
  label: name,
  description: 'test',
  parameters: {},
  execute: (arguments, cancelToken, onUpdate) async =>
      ToolExecutionResult.text('ok'),
);

/// Screenshot-only controller: the env-chain pin drives just the
/// `browser_screenshot` tool; every other bridge member is never called.
final class _ShotController implements BrowserController {
  _ShotController(this.png);

  final Uint8List png;

  @override
  bool get attached => true;

  @override
  void Function(bool attached)? onAvailabilityChanged;

  @override
  Future<Uint8List> screenshot({int? tabId}) async => png;

  @override
  Object noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not driven in this test');
}

Future<LspTransport> _fakeLspTransport(LspServerConfig config, String cwd) =>
    throw UnimplementedError('not started in this test');

/// Hub-transport stand-in: never driven — the builder only composes it as
/// the fabric's hub primary and stores the mailbox merge callback.
final class _HubRepo implements MessagingRepository {
  const _HubRepo();

  @override
  Object noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not driven in this test');
}
