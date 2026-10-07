/// Issue #1079 slice 4 — the declared host-extension surface
/// (`HostExtensionApi`): E6 matrix declarations at birth, E7 build-time
/// collision rejection with both registrants named, E8 profile-off
/// hiding with the reason surfaced, and the additive-only core
/// invariance contract (AC9/UT-5 — the only route to "replace" a core
/// tool is a colliding id, and E7 slams it).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AgentTool _tool(String name) => AgentTool(
  name: name,
  label: name,
  description: 'test',
  parameters: {},
  execute: (arguments, cancelToken, onUpdate) async =>
      ToolExecutionResult.text('ok'),
);

/// All seven built-in profiles `on`; [offOn] (when given) `off` with a
/// reason instead.
Map<String, CapabilityState> _states({String? offOn}) => {
  for (final profile in builtInProfiles.keys)
    profile: profile == offOn
        ? const CapabilityOffState('not on this host')
        : const CapabilityOnState(),
};

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

void main() {
  group('E6 — extension matrix declared at birth', () {
    test('a missing built-in profile is rejected, extension and profile '
        'named', () {
      expect(
        () => HostExtension(
          name: 'yoclip',
          tools: [_tool('yoclip_cut')],
          profileStates: {
            for (final profile in builtInProfiles.keys)
              if (profile != 'ios') profile: const CapabilityOnState(),
          },
        ),
        throwsA(
          isA<HostProfileViolation>()
              .having((e) => e.message, 'message', contains('yoclip'))
              .having((e) => e.message, 'message', contains('"ios"')),
        ),
      );
    });

    test('a transport state is rejected — tool extensions have no '
        'transport dimension', () {
      expect(
        () => HostExtension(
          name: 'yoclip',
          profileStates: {
            ..._states(),
            'cli': const CapabilityTransportState({'file'}, 'why not'),
          },
        ),
        throwsA(isA<HostProfileViolation>()),
      );
    });

    test('an off state without a reason is rejected (off is never '
        'silent)', () {
      expect(
        () => HostExtension(
          name: 'yoclip',
          profileStates: {..._states(), 'cli': const CapabilityOffState(' ')},
        ),
        throwsA(isA<HostProfileViolation>()),
      );
    });

    test('a duplicate tool id inside one extension is rejected', () {
      expect(
        () => HostExtension(
          name: 'yoclip',
          tools: [_tool('yoclip_cut'), _tool('yoclip_cut')],
          profileStates: _states(),
        ),
        throwsA(
          isA<HostProfileViolation>().having(
            (e) => e.message,
            'message',
            contains('yoclip_cut'),
          ),
        ),
      );
    });

    test('every built-in profile declared constructs', () {
      expect(
        HostExtension(
          name: 'yoclip',
          tools: [_tool('yoclip_cut')],
          profileStates: _states(),
        ),
        isA<HostExtension>(),
      );
    });
  });

  group('E7 — collisions rejected at build time', () {
    test('an extension id colliding with the SDK core throws naming both '
        'registrants (the negative-API pin: there is NO override point '
        'for a core tool)', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        extensions: [
          HostExtension(
            name: 'yoclip',
            tools: [_tool('read')],
            profileStates: _states(),
          ),
        ],
      );
      expect(
        () => wireAgentCore(profile: cliProfile, services: services),
        throwsA(
          isA<HostWiringException>()
              .having((e) => e.message, 'message', contains('"read"'))
              .having((e) => e.message, 'message', contains('the SDK core'))
              .having((e) => e.message, 'message', contains('yoclip')),
        ),
      );
    });

    test('two extensions colliding with each other throw naming both', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        extensions: [
          HostExtension(
            name: 'yoclip',
            tools: [_tool('yoclip_cut')],
            profileStates: _states(),
          ),
          HostExtension(
            name: 'yotrim',
            tools: [_tool('yoclip_cut')],
            profileStates: _states(),
          ),
        ],
      );
      expect(
        () => wireAgentCore(profile: cliProfile, services: services),
        throwsA(
          isA<HostWiringException>()
              .having((e) => e.message, 'message', contains('yoclip'))
              .having((e) => e.message, 'message', contains('yotrim')),
        ),
      );
    });

    test('an extension id colliding with the gated task surface throws '
        'naming both', () {
      final services = _subagentServices(
        extensions: [
          HostExtension(
            name: 'yoclip',
            tools: [_tool('task_status')],
            profileStates: _states(),
          ),
        ],
      );
      expect(
        () => wireAgentCore(profile: cliProfile, services: services),
        throwsA(
          isA<HostWiringException>()
              .having((e) => e.message, 'message', contains('task_status'))
              .having((e) => e.message, 'message', contains('task surface'))
              .having((e) => e.message, 'message', contains('yoclip')),
        ),
      );
    });
  });

  group('E8 — off means hidden with a surfaced reason', () {
    test('a profile-off extension contributes no tools and surfaces its '
        'reason', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: AgentCoreServices(
          baseEnv: MemoryExecutionEnv(cwd: '/w'),
          extensions: [
            HostExtension(
              name: 'yoclip',
              tools: [_tool('yoclip_cut')],
              profileStates: _states(offOn: cliProfile.name),
            ),
          ],
        ),
      );
      expect(wired.tools.map((t) => t.name), isNot(contains('yoclip_cut')));
      expect(wired.extensions, hasLength(1));
      final outcome = wired.extensions.single;
      expect(outcome.extension.name, 'yoclip');
      expect(outcome.isHidden, isTrue);
      expect(outcome.hiddenReason, 'not on this host');
      expect(outcome.tools, isEmpty);
    });

    test('an on extension wires its tools in the canonical tail position', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: AgentCoreServices(
          baseEnv: MemoryExecutionEnv(cwd: '/w'),
          extensions: [
            HostExtension(
              name: 'yoclip',
              tools: [_tool('yoclip_cut')],
              profileStates: _states(),
            ),
          ],
        ),
      );
      final names = wired.tools.map((t) => t.name).toList();
      expect(names, contains('yoclip_cut'));
      expect(names.last, 'yoclip_cut');
      final outcome = wired.extensions.single;
      expect(outcome.isHidden, isFalse);
      expect(outcome.hiddenReason, isNull);
      expect(outcome.tools.single.name, 'yoclip_cut');
    });

    test('a profile with hostExtensionApi off hides every declared '
        'extension with the cell reason (the cell is enforced, E8)', () {
      final custom = HostCapabilityProfile(
        name: 'locked-embed',
        states: {
          for (final capability in HostCapability.values)
            capability: capability == HostCapability.hostExtensionApi
                ? const CapabilityOffState('no third-party tools in this embed')
                : const CapabilityOnState(),
        },
      );
      final wired = wireAgentCore(
        profile: custom,
        services: AgentCoreServices(
          baseEnv: MemoryExecutionEnv(cwd: '/w'),
          extensions: [
            HostExtension(
              name: 'yoclip',
              tools: [_tool('yoclip_cut')],
              profileStates: _states(),
            ),
          ],
        ),
      );
      expect(wired.tools.map((t) => t.name), isNot(contains('yoclip_cut')));
      expect(wired.extensions, hasLength(1));
      final outcome = wired.extensions.single;
      expect(outcome.isHidden, isTrue);
      expect(outcome.hiddenReason, 'no third-party tools in this embed');
    });

    test('a custom profile without a state is a wire-time E6 violation', () {
      // The cell rides ON: E6 binds when the extension surface wires —
      // a profile that turns the CELL off hides the surface wholesale
      // with the cell reason (E8, the test above) and the per-extension
      // matrix is never consulted, so this profile keeps the cell on
      // (everything else off) to exercise the wire-time half of E6.
      final custom = HostCapabilityProfile(
        name: 'yoclip-host',
        states: {
          for (final capability in HostCapability.values)
            capability: capability == HostCapability.hostExtensionApi
                ? const CapabilityOnState()
                : const CapabilityOffState('custom embed floor'),
        },
      );
      expect(
        () => wireAgentCore(
          profile: custom,
          services: AgentCoreServices(
            baseEnv: MemoryExecutionEnv(cwd: '/w'),
            extensions: [
              HostExtension(
                name: 'yoclip',
                tools: [_tool('yoclip_cut')],
                profileStates: _states(),
              ),
            ],
          ),
        ),
        throwsA(
          isA<HostWiringException>()
              .having((e) => e.message, 'message', contains('yoclip'))
              .having((e) => e.message, 'message', contains('yoclip-host')),
        ),
      );
    });
  });

  group('AC9 — extension hosts get byte-identical core wiring', () {
    test('the extension is the ONLY delta: core tools, env chain, and '
        'plan are identical with and without it', () {
      AgentCoreServices services({HostExtension? extension}) =>
          AgentCoreServices(
            baseEnv: MemoryExecutionEnv(cwd: '/w'),
            sessionEnvVars: () => {},
            sandbox: const SandboxServices(),
            sessionRoot: '/tmp/fah-test',
            extensions: [?extension],
          );
      final yoclip = HostExtension(
        name: 'yoclip',
        tools: [_tool('yoclip_cut')],
        profileStates: _states(),
      );
      final plain = wireAgentCore(profile: cliProfile, services: services());
      final extended = wireAgentCore(
        profile: cliProfile,
        services: services(extension: yoclip),
      );
      // Core tool list identical; the extension appends exactly itself.
      expect(extended.tools.map((t) => t.name), [
        ...plain.tools.map((t) => t.name),
        'yoclip_cut',
      ]);
      // Same env-chain shape (base → sandbox → session vars).
      expect(extended.env.runtimeType, plain.env.runtimeType);
      // Same per-capability plan (capability, wired/hidden, transports).
      expect(
        extended.plan.entries
            .map((e) => (e.capability, e.runtimeType))
            .toList(),
        plain.plan.entries.map((e) => (e.capability, e.runtimeType)).toList(),
      );
      // The core behaviors stay SDK-owned: no spec field, no service, no
      // extension member carries compaction/memory/session overrides —
      // the built stack differs ONLY in the registry's extra tool.
      final plainStack = plain.buildAgentStack(
        spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
        streamFunction: _fakeStream,
      );
      final extendedStack = extended.buildAgentStack(
        spec: AgentWiringSpec(model: _model, systemPrompt: 's'),
        streamFunction: _fakeStream,
      );
      expect(extendedStack.registry.names, [
        ...plainStack.registry.names,
        'yoclip_cut',
      ]);
    });

    test('extension tools ride the child tool pool like the core surface', () {
      final wired = wireAgentCore(
        profile: cliProfile,
        services: _subagentServices(
          extensions: [
            HostExtension(
              name: 'yoclip',
              tools: [_tool('yoclip_cut')],
              profileStates: _states(),
            ),
          ],
        ),
      );
      expect(
        wired.taskConfig!.childTools.map((t) => t.name),
        contains('yoclip_cut'),
      );
    });
  });
}

/// Minimal subagent-capable bundle: enough for the gated task surface to
/// assemble so the E7/AC9 assertions can aim at it.
AgentCoreServices _subagentServices({
  List<HostExtension> extensions = const [],
}) => AgentCoreServices(
  baseEnv: MemoryExecutionEnv(cwd: '/w'),
  sessionRoot: '/tmp/fah-test',
  hubFabric: const _HubRepo(),
  mainMailbox: () => 'main',
  extensions: extensions,
  subagents: SubagentServices(
    homeDir: '/tmp/fah-test',
    machineName: 'test-machine',
    notifyHeartbeat: (_) {},
    // Kill switch: no heartbeat timer arms under tests.
    heartbeatMinutes: () => 0,
  ),
);

/// Hub-transport stand-in: never driven — the builder only composes it as
/// the fabric's hub primary and stores the mailbox merge callback.
final class _HubRepo implements MessagingRepository {
  const _HubRepo();

  @override
  Object noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not driven in this test');
}
