/// Issue #1079 slice 5 — the flutter_app shell adopts the shared builder.
///
/// The app host's own profile (`flutter-app`) and its builder wiring are
/// pinned here, at the SDK level, with the same shapes the app passes in
/// production: a secrets/session-var env chain (no sandbox layer), the
/// file fabric over the session root with the opt-in hub dropped at
/// run-narrowing, the app-platform extension in the canonical tail
/// position, and the task/subagent complex over the shared manager.
///
/// The registry contract mirrors the app's own floor suite
/// (`flutter_app/test/agent_service_tool_floor_test.dart`, issue #692):
/// process/transport-backed surfaces stay ABSENT, sandbox-runnable ones
/// STAY — now enforced at the builder level, where the wiring decisions
/// are made.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'host_hiding.dart';

// ---------------------------------------------------------------------------
// the app-shaped fixture
// ---------------------------------------------------------------------------

final _env = MemoryExecutionEnv(cwd: '/work');

const _sessionsRoot = '/work/sessions';

/// The messaging root the app computes today (and the builder must
/// reproduce): sessions root + encoded cwd + `/messages`.
String get _expectedMessagesRoot =>
    '$_sessionsRoot/${encodeSessionCwd(_env.cwd)}/messages';

/// The app-platform extension: the host's own tool families (dynamic
/// messages, the platform bridges) as DECLARED builder-gated surface.
HostExtension _appPlatformExtension() => HostExtension(
  name: 'app-platform',
  tools: [
    AgentTool(
      name: 'dynamic_message',
      label: 'dynamic_message',
      description: 'Interactive dynamic messages (issue #102).',
      parameters: {
        'type': 'object',
        'properties': {
          'kind': {'type': 'string'},
        },
        'required': ['kind'],
      },
      execute: (arguments, cancelToken, onUpdate) async =>
          ToolExecutionResult.text('presented'),
    ),
    AgentTool(
      name: 'calendar_events',
      label: 'calendar_events',
      description: 'System calendar read (the fah/calendar bridge).',
      parameters: const {'type': 'object', 'properties': {}, 'required': []},
      execute: (arguments, cancelToken, onUpdate) async =>
          ToolExecutionResult.text('[]'),
    ),
  ],
  profileStates: {
    // The app host wires its own profile; the platform bridges are this
    // shell's surface.
    'flutter-app': const CapabilityOnState(),
    for (final profile in builtInProfiles.keys)
      profile: const CapabilityOffState(
        'the app-platform tools are a flutter-app shell surface; declare '
        'your own extension for this host',
      ),
  },
);

AgentCoreServices _appServices({
  List<HostExtension> extensions = const [],
  WebSearchConfig? webSearch = const WebSearchConfig(),
}) {
  final fabric = SwappableMessagingRepository(
    FileMessagingRepository(
      env: _env,
      root: _expectedMessagesRoot,
      decodeSessionCwd: decodeSessionCwd,
      homeDir: null,
    ),
  );
  return AgentCoreServices(
    baseEnv: _env,
    sessionEnvVars: () => {'FAH_SESSION_ID': 's1'},
    webSearch: webSearch,
    shellJobsFactory: (coreEnv) => ShellJobRegistry(env: coreEnv),
    configServiceFactory: (coreEnv) =>
        ConfigService(env: coreEnv, homeDir: '/home'),
    memory: MemoryController(env: _env),
    onMemoryChanged: () {},
    scheduledMessages: ScheduledMessageQueue(
      env: _env,
      repo: () => fabric,
      root: () => _expectedMessagesRoot,
    ),
    onAsk: (questions) async => null,
    onRequestSecret: (name, reason) async => null,
    // Presence markers for the cells the builder registers no tool for
    // (the extension carries the surface): the app's dynamic-messages
    // machinery and its shipped on-device inference runtimes.
    dynamicMessageSink: Object(),
    onDeviceProviderFactory: Object(),
    extensions: extensions,
    subagents: SubagentServices(
      // The heartbeat kill switch: the app host arms no digest cadence
      // (no timer, no deliveries) — the delivery path exists for when a
      // host opts in.
      notifyHeartbeat: (digest) {},
      heartbeatMinutes: () => 0,
      stallMinutes: () => 0,
    ),
    sessionRoot: _sessionsRoot,
  );
}

/// Wires the app host over the fixture (extension included by default —
/// the production shape).
WiredAgentCore _wireApp({List<HostExtension>? extensions}) => wireAgentCore(
  profile: flutterAppHostProfile,
  services: _appServices(extensions: extensions ?? [_appPlatformExtension()]),
);

// ---------------------------------------------------------------------------
// the profile — the app host's honest today-state
// ---------------------------------------------------------------------------

void main() {
  group('flutter-app profile (slice 5: the app host declares its matrix)', () {
    test('it declares every capability without throwing (E2 completeness)', () {
      // HostCapabilityProfile.new rejects incomplete tables loudly; a
      // successful construction IS the completeness proof.
      expect(flutterAppHostProfile.name, 'flutter-app');
    });

    test('the wired set matches the app host reality', () {
      final states = flutterAppHostProfile.states;
      // Wired today: config sections, compaction, load modes, approval,
      // skills, the fabric (file + opt-in hub), background jobs, the
      // on-device providers, JS apps, extensions, web search, subagents.
      for (final capability in [
        HostCapability.configSections,
        HostCapability.compaction,
        HostCapability.loadModes,
        HostCapability.messagingFabric,
        HostCapability.approvalGate,
        HostCapability.skills,
        HostCapability.backgroundShellJobs,
        HostCapability.onDeviceProviders,
        HostCapability.jsApps,
        HostCapability.hostExtensionApi,
        HostCapability.webSearch,
        HostCapability.subagents,
      ]) {
        expect(
          flutterAppHostProfile.isWired(capability),
          isTrue,
          reason: '${capability.id} is wired on the app host today',
        );
      }
      // Off today, each with its honest reason.
      for (final capability in [
        HostCapability.mcp,
        HostCapability.sandboxEnv,
        HostCapability.sqliteLspDap,
        HostCapability.visionTranscribe,
        HostCapability.checkpointRewind,
        HostCapability.browserBridge,
        HostCapability.jsExtensions,
      ]) {
        expect(
          states[capability],
          isA<CapabilityOffState>(),
          reason: '${capability.id} is off on the app host today',
        );
        expect(
          states[capability]!.reason,
          isNotEmpty,
          reason: '${capability.id} off without a reason — never silent',
        );
      }
    });

    test('the fabric wires file + hub (the opt-in agent network)', () {
      final fabric =
          flutterAppHostProfile.stateFor(HostCapability.messagingFabric)
              as CapabilityTransportState;
      expect(fabric.transports, {'file', 'hub'});
      expect(fabric.reason, isNotEmpty);
    });

    test('AC7: off capabilities are invisible on the app plan', () {
      final wired = _wireApp(extensions: const []);
      for (final capability in [
        HostCapability.mcp,
        HostCapability.sandboxEnv,
        HostCapability.sqliteLspDap,
        HostCapability.visionTranscribe,
        HostCapability.checkpointRewind,
        HostCapability.browserBridge,
        HostCapability.jsExtensions,
      ]) {
        expectCapabilityHidden(wired.plan, capability);
      }
      // The web-search family stays surfaced (the app passes the config).
      expect(
        wired.plan.planFor(HostCapability.webSearch),
        isA<WiredCapability>(),
      );
    });

    test('the marker-backed cells stay wired at run (js apps, on-device '
        'providers) and narrow honestly without their markers', () {
      // The app shape carries both markers: the cells stay wired.
      final wired = _wireApp();
      expect(
        wired.plan.planFor(HostCapability.jsApps),
        isA<WiredCapability>(),
        reason: 'the dynamic-messages marker keeps js_apps wired',
      );
      expect(
        wired.plan.planFor(HostCapability.onDeviceProviders),
        isA<WiredCapability>(),
      );
      // Without them run-narrowing turns the cells off — a named state,
      // never a silent promise (the bare wiring passes no markers).
      final narrowed = wireAgentCore(
        profile: flutterAppHostProfile,
        services: AgentCoreServices(
          baseEnv: _env,
          extensions: const [],
          sessionRoot: _sessionsRoot,
          subagents: SubagentServices(
            notifyHeartbeat: (digest) {},
            heartbeatMinutes: () => 0,
          ),
        ),
      );
      final jsApps =
          narrowed.plan.profile.stateFor(HostCapability.jsApps)
              as CapabilityOffState;
      expect(jsApps.reason, contains('dynamicMessageSink'));
    });
  });

  group(
    'app host wiring (slice 5: the shell constructs through the builder)',
    () {
      test('the env chain is base → session vars (no sandbox layer)', () {
        final wired = _wireApp();
        expect(wired.sandboxEnv, isNull, reason: 'the app wires no cube layer');
        expect(wired.networkGate, isNull);
        // The session-vars wrapper sits on top of the host's base env —
        // the same two-layer chain the app builds by hand today.
        expect(wired.env, isA<SessionVarsExecutionEnv>());
      });

      test('the fabric is the file layer over the session root; the hub '
          'transport drops honestly without a hub service', () {
        final wired = _wireApp();
        expect(wired.fileFabric, isNotNull);
        expect(wired.messagesRoot, _expectedMessagesRoot);
        // Run-narrowing dropped the hub (no hubFabric provided at boot —
        // the agent network controller swaps it in on opt-in): the plan
        // wires {file} only, and the run profile's state names why.
        final fabricPlan =
            wired.plan.planFor(HostCapability.messagingFabric)
                as WiredCapability;
        expect(fabricPlan.transports, {'file'});
        final runState =
            wired.plan.profile.stateFor(HostCapability.messagingFabric)
                as CapabilityTransportState;
        expect(runState.transports, {'file'});
        expect(runState.reason, contains('hub'));
        // The raw file layer is reachable for the host's hub controller
        // (issue #402 swap path).
        expect(wired.fileLayer, isA<FileMessagingRepository>());
      });

      test('a mounted project scopes the messaging root by sessionCwd, '
          'not the container cwd (the app mount flow)', () {
        final fabric = SwappableMessagingRepository(
          FileMessagingRepository(
            env: _env,
            root: _expectedMessagesRoot,
            decodeSessionCwd: decodeSessionCwd,
            homeDir: null,
          ),
        );
        final wired = wireAgentCore(
          profile: flutterAppHostProfile,
          services: AgentCoreServices(
            baseEnv: _env,
            extensions: const [],
            scheduledMessages: ScheduledMessageQueue(
              env: _env,
              repo: () => fabric,
              root: () => _expectedMessagesRoot,
            ),
            subagents: SubagentServices(
              notifyHeartbeat: (digest) {},
              heartbeatMinutes: () => 0,
            ),
            sessionRoot: '/mnt/project/.fah/sessions',
            // The mounted host path — NOT env.cwd (/work).
            sessionCwd: '/mnt/project',
          ),
        );
        expect(
          wired.messagesRoot,
          '/mnt/project/.fah/sessions/'
          '${encodeSessionCwd('/mnt/project')}/messages',
        );
      });

      test(
        'the task/subagent complex assembles; children draw the safe pool',
        () {
          final wired = _wireApp();
          expect(wired.subagentManager, isNotNull);
          expect(wired.taskConfig, isNotNull);
          // Canonical order: the monitoring surface, then `task` LAST.
          final surface = wired.taskSurface.map((tool) => tool.name).toList();
          expect(surface.last, 'task');
          expect(
            surface,
            containsAll(['task_status', 'task_send', 'task_cancel']),
          );
          // Children draw the core + extension pool — never the task surface.
          final childNames = wired.taskConfig!.childTools
              .map((tool) => tool.name)
              .toList();
          expect(childNames, contains('bash_job'));
          expect(childNames, contains('dynamic_message'));
          expect(childNames, isNot(contains('task')));
          expect(childNames, isNot(contains('task_status')));
        },
      );

      test('the registry floor (issue #692) holds at the builder level', () {
        final wired = _wireApp();
        final stack = wired.buildAgentStack(
          streamFunction: (model, context, {cancelToken}) =>
              throw UnsupportedError('test'),
          spec: const AgentWiringSpec(model: _testModel, systemPrompt: 'p'),
        );
        final names = stack.registry.tools.map((tool) => tool.name).toList();
        // Absent: process/transport-backed surfaces (the app never wires
        // them — the CLI owns those registrations).
        expect(names, isNot(contains('lsp')));
        expect(names.any((name) => name.startsWith('mcp__')), isFalse);
        expect(names, isNot(contains('checkpoint')));
        expect(names, isNot(contains('rewind')));
        expect(names, isNot(contains('browser_navigate')));
        expect(names, isNot(contains('inspect_image')));
        expect(names, isNot(contains('generate_image')));
        // Present: the sandbox-runnable core + the app extension tail.
        expect(names, contains('bash'));
        expect(names, contains('bash_job'));
        expect(names, contains('web_search'));
        expect(names, contains('ask'));
        expect(names, contains('request_secret'));
        expect(names, contains('schedule_message'));
        expect(names, containsAll(['memory_add', 'memory_search']));
        expect(names, contains('dynamic_message'));
        expect(names, contains('calendar_events'));
      });

      test('the extension rides the canonical tail position; core first', () {
        final wired = _wireApp();
        final names = wired.tools.map((tool) => tool.name).toList();
        // The app extension's tools come after the SDK core and before the
        // gated task surface (which lives outside [tools]).
        expect(names.indexOf('dynamic_message'), greaterThan(0));
        expect(
          names.indexOf('dynamic_message'),
          greaterThan(names.indexOf('request_secret')),
          reason: 'extensions splice after the SDK core',
        );
        expect(names, isNot(contains('task')));
      });

      test(
        'E7: an app extension colliding with a core id throws at build time',
        () {
          final colliding = HostExtension(
            name: 'bad-extension',
            tools: [
              AgentTool(
                name: 'web_search',
                label: 'web_search',
                description: 'Collides with the SDK core.',
                parameters: const {
                  'type': 'object',
                  'properties': {},
                  'required': [],
                },
                execute: (arguments, cancelToken, onUpdate) async =>
                    ToolExecutionResult.text('mine'),
              ),
            ],
            profileStates: {
              'flutter-app': const CapabilityOnState(),
              for (final profile in builtInProfiles.keys)
                profile: const CapabilityOffState('not this host'),
            },
          );
          expect(
            () => _wireApp(extensions: [colliding]),
            throwsA(
              isA<HostWiringException>().having(
                (error) => error.message,
                'message',
                allOf(contains('web_search'), contains('bad-extension')),
              ),
            ),
          );
        },
      );

      test('E8: a profile-off extension hides with its reason surfaced', () {
        final foreign = HostExtension(
          name: 'cli-plugins',
          tools: [],
          profileStates: {
            'flutter-app': const CapabilityOffState(
              'plugin registration is a CLI-shell surface',
            ),
            for (final profile in builtInProfiles.keys)
              profile: const CapabilityOnState(),
          },
        );
        final wired = _wireApp(extensions: [foreign]);
        final wiredExtension = wired.extensions.single;
        expect(wiredExtension.isHidden, isTrue);
        expect(wiredExtension.hiddenReason, contains('CLI-shell surface'));
        expect(wiredExtension.tools, isEmpty);
      });

      test('buildAgentStack wires the app spec onto the agent', () {
        final wired = _wireApp();
        var relieved = false;
        final stack = wired.buildAgentStack(
          streamFunction: (model, context, {cancelToken}) =>
              throw UnsupportedError('test'),
          spec: AgentWiringSpec(
            model: _testModel,
            systemPrompt: 'the composed app prompt',
            contextWindowCap: 8192,
            overWindowRelief: (overWindow) {
              relieved = true;
              return Future.value(null);
            },
          ),
        );
        expect(stack.agent.state.model.id, _testModel.id);
        expect(stack.agent.state.systemPrompt, 'the composed app prompt');
        expect(stack.agent.contextWindowCap, 8192);
        expect(relieved, isFalse, reason: 'relief arms lazily');
        // The registry assembles core → task surface (monitoring, then
        // `task`) — the wired core's tools first, byte-identical order.
        expect(stack.registry.tools.map((tool) => tool.name).toList(), [
          for (final tool in wired.tools) tool.name,
          for (final tool in wired.taskSurface) tool.name,
        ]);
      });
    },
  );
}

/// A stand-in model for the stack spec (never called — the stream function
/// throws before any request).
const _testModel = Model(
  provider: 'test',
  id: 'test-model',
  api: 'openai-completions',
  baseUrl: 'https://example.test',
  contextWindow: 8192,
  maxTokens: 1024,
);
