// gh-1617 review r2 (IMPORTANT): a mid-run providers-queue failover must
// re-sync `agent.state.model` exactly like the roles lane's
// `_onRolesNotice` does. The watchdog's arm-time window reads
// `state.model` (`Agent.runIdleWindow` → `explicitStreamIdleForModel`),
// so a stale boot-time entry keeps the OLD entry's
// `streamIdleTimeoutMs` patience while the NEW entry streams — and
// gh-1398 lets queue entries carry per-entry windows.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

AssistantMessage _msg(Model model) => AssistantMessage(
  content: const [],
  api: model.api,
  provider: model.provider,
  model: model.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

/// A scripted stream factory keyed by the API-key value (the queue's
/// inner provider stream): entry `queue-a` (key `a`) dies once with a
/// 502, entry `queue-b` (key `b`) serves a normal turn.
StreamFunction Function(String kind, String apiKey) failoverFactory() {
  final served = <String, int>{};
  return (kind, apiKey) => (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    if (apiKey == 'a' && (served[apiKey] ?? 0) == 0) {
      served[apiKey] = 1;
      stream
        ..push(
          ErrorEvent(
            reason: StopReason.error,
            error: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.error,
              errorMessage: '502 Bad Gateway',
              timestamp: DateTime.utc(2026),
            ),
          ),
        )
        ..end();
      return stream;
    }
    served[apiKey] = (served[apiKey] ?? 0) + 1;
    final full = _msg(model);
    stream
      ..push(StartEvent(partial: _msg(model)))
      ..push(DoneEvent(reason: StopReason.stop, message: full))
      ..end();
    return stream;
  };
}

ProviderQueueRuntime twoEntryRuntime() => ProviderQueueRuntime.build(
  ProviderQueueResolution(
    scope: ProviderQueueScope.env,
    entries: [
      ProviderQueueEntry(
        providerType: 'anthropic',
        model: 'queue-a',
        apiKeyEnv: 'K_A',
        baseUrl: 'https://a.test/v1',
      ),
      ProviderQueueEntry(
        providerType: 'anthropic',
        model: 'queue-b',
        apiKeyEnv: 'K_B',
        baseUrl: 'https://b.test/v1',
      ),
    ],
    notices: const [],
  ),
  secrets: const {'K_A': 'a', 'K_B': 'b'},
  policy: const ModelRolesRetryPolicy(retriesPerEntry: 0),
  streamFactory: failoverFactory(),
);

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test('a mid-run queue failover re-syncs agent.state.model to the '
      'streaming entry', () async {
    final runtime = twoEntryRuntime();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providersQueueRuntime: runtime,
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    // Boot sync (existing wiring): the display model starts on the head.
    expect(cli.agent.state.model.id, 'queue-a');

    final run = cli.run();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await waitForIt(
      () async => (await repo.list(cwd: '/work')).isNotEmpty,
      reason: 'session persisted',
    );
    io.sendLine('start');
    await waitForIt(() => !cli.isBusy, reason: 'run completed');
    io.sendLine('/exit');
    await run;

    // The 502 moved the sticky cursor to queue-b; the display model (and
    // with it the watchdog's arm-time window) must follow.
    expect(runtime.streamFunction.currentModel.id, 'queue-b');
    expect(cli.agent.state.model.id, 'queue-b');
  });

  test(
    'no failover: the boot-time entry stays (the sync is a no-op)',
    () async {
      final runtime = ProviderQueueRuntime.build(
        ProviderQueueResolution(
          scope: ProviderQueueScope.env,
          entries: [
            ProviderQueueEntry(
              providerType: 'anthropic',
              model: 'queue-a',
              apiKeyEnv: 'K_A',
              baseUrl: 'https://a.test/v1',
            ),
          ],
          notices: const [],
        ),
        secrets: const {'K_A': 'a'},
        streamFactory: failoverFactory(),
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providersQueueRuntime: runtime,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final run = cli.run();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await waitForIt(
        () async => (await repo.list(cwd: '/work')).isNotEmpty,
        reason: 'session persisted',
      );
      io.sendLine('start');
      await waitForIt(() => !cli.isBusy, reason: 'run completed');
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.id, 'queue-a');
    },
  );

  // gh-1781 AC2: the boot prints the queue build's skip/binding lines ONCE
  // (bin's queueBindingWarnings loop). The quota-feed rebind rebuilds the
  // same queue right after boot — re-printing the identical lines through
  // the io would double every warning on every queue boot.
  test('the boot quota-feed rebind does not re-print the queue warning '
      'channel', () async {
    final warned = <String>[];
    final runtime = ProviderQueueRuntime.build(
      ProviderQueueResolution(
        scope: ProviderQueueScope.env,
        entries: [
          ProviderQueueEntry(
            providerType: 'anthropic',
            model: 'queue-a',
            apiKeyEnv: 'K_A',
            baseUrl: 'https://a.test/v1',
          ),
          ProviderQueueEntry(
            providerType: 'anthropic',
            model: 'queue-b',
            apiKeyEnv: 'K_MISSING',
            baseUrl: 'https://b.test/v1',
          ),
        ],
        notices: const [],
      ),
      secrets: const {'K_A': 'a'},
      onBindingWarning: warned.add,
    );
    expect(warned, hasLength(1), reason: 'the boot build skipped entry #1');
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providersQueueRuntime: runtime,
        // The rebuild must see the same env view the boot saw: the same
        // two-entry queue, K_A present, K_MISSING absent — entry #1 is
        // skipped again on the rebuild, silently this time.
        providerQueueEnv: const {
          'FA_PROVIDERS_QUEUE':
              '[{"provider_type":"anthropic","provider_config":'
              '{"baseUrl":"https://a.test/v1","model":"queue-a",'
              '"apiKeyEnv":"K_A"}},'
              '{"provider_type":"anthropic","provider_config":'
              '{"baseUrl":"https://b.test/v1","model":"queue-b",'
              '"apiKeyEnv":"K_MISSING"}}]',
        },
        envVarValue: (name) => name == 'K_A' ? 'a' : null,
        secureKeys: SecureKeyCache(null),
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    await cli.attachProviderQueueQuotaFeed();
    expect(
      io.out.toString(),
      isNot(contains('provider queue skipped')),
      reason:
          'the rebind rebuilds the SAME queue the boot already '
          'rendered — no second print',
    );
  });

  // gh-1781 review r1 (IMPORTANT): the boot-time quota-feed rebind (and a
  // loud `/providers queue` edit reload) rebuilds the runtime through
  // `_queueSecrets` — whose env view carried ONLY the base key names, so
  // `collectQueueSecrets`'s rotation-stack sweep (`NAME_2`, `NAME_3`, …)
  // never fired on the rebuild: the config-level runtime silently dropped
  // to single-key rings where the boot build had the full stack. The
  // rebuild must resolve the SAME secret snapshot the boot did.
  test('the queue rebuild resolves the SAME secret snapshot as the boot — '
      'the rotation stack survives (UT-queue-secrets-rotation-stack '
      'through attachProviderQueueQuotaFeed)', () async {
    // The boot's secret snapshot: K_A from env PLUS its K_A_2 rotation
    // stack entry — the boot build wired a 2-credential ApiKeyRing.
    final runtime = ProviderQueueRuntime.build(
      ProviderQueueResolution(
        scope: ProviderQueueScope.env,
        entries: [
          ProviderQueueEntry(
            providerType: 'anthropic',
            model: 'queue-a',
            apiKeyEnv: 'K_A',
            baseUrl: 'https://a.test/v1',
          ),
        ],
        notices: const [],
      ),
      secrets: const {'K_A': 'v1', 'K_A_2': 'v2'},
      streamFactory: failoverFactory(),
    );
    final entries = runtime.resolution.entries;
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providersQueueRuntime: runtime,
        // The rebuild's env view: the same values the boot's process env
        // carried — the queue blob AND the base name plus its K_A_2 stack
        // entry. Production bin hands Platform.environment here (the view
        // the boot swept).
        providerQueueEnv: const {
          'FA_PROVIDERS_QUEUE':
              '[{"provider_type":"anthropic","provider_config":'
              '{"baseUrl":"https://a.test/v1","model":"queue-a",'
              '"apiKeyEnv":"K_A"}}]',
          'K_A': 'v1',
          'K_A_2': 'v2',
        },
        envVarValue: (name) => name == 'K_A' ? 'v1' : null,
        secureKeys: SecureKeyCache(null),
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    // The rebind under test: every queue boot takes this path (warn:
    // false) — it must resolve the boot's FULL snapshot, stack included.
    await cli.attachProviderQueueQuotaFeed();
    expect(cli.config.providersQueueRuntime, isNotNull);
    expect(
      cli.config.providersQueueRuntime!.streamFunction.currentModel.id,
      'queue-a',
      reason: 'the rebuild re-resolved the same single-entry queue',
    );
    // The same snapshot the rebuild just consumed (one `_queueSecrets`
    // call feeds both the rebind build and this probe): K_A from the
    // lookup AND K_A_2 swept from the env view. Pre-fix the map carried
    // only base names, so this expects the failing shape.
    expect(cli.queueSecretsForTest(entries), {'K_A': 'v1', 'K_A_2': 'v2'});
  });
}
