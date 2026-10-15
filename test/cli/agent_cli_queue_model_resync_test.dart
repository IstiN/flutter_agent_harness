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
}
