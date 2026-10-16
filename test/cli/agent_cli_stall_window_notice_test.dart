// gh-1617 AC5: the stall NOTICE names the governing idle window and its
// precedence source. A configured streamIdleTimeoutMs wider than the
// backstop floor governs the run — the banner says so, so a wide
// patience never reads as a hang; unset config keeps the banner
// byte-for-byte (AC3). The kill itself is the agent's watchdog (covered
// in test/agent/run_idle_watchdog_provider_window_test.dart); this file
// owns the TUI surface.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A stream that wedges the first call until aborted (the #514 harness).
AssistantMessageEventStream wedgedCall(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final stream = AssistantMessageEventStream();
  unawaited(
    (cancelToken?.onCancel ?? Completer<void>().future).then((_) {
      stream
        ..push(
          ErrorEvent(
            reason: StopReason.aborted,
            error: testAssistant(
              stopReason: StopReason.aborted,
              errorMessage: 'Request was aborted',
            ),
          ),
        )
        ..end();
    }),
  );
  return stream;
}

Model _model({Duration? idle, String baseUrl = 'https://llama.test/v1'}) =>
    Model(
      id: 'test-model',
      api: 'openai-completions',
      provider: 'test-provider',
      baseUrl: baseUrl,
      contextWindow: 128000,
      maxTokens: 4096,
      streamIdleTimeout: idle,
    );

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late ProviderTimeoutsOverride? savedGlobal;
  late List<ProviderTuningEntry> savedEntries;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    savedGlobal = providerTimeoutsOverride;
    savedEntries = providerTuningRegistry.entries;
    providerTimeoutsOverride = null;
    providerTuningRegistry.clear();
  });

  tearDown(() async {
    providerTimeoutsOverride = savedGlobal;
    providerTuningRegistry.clear();
    providerTuningRegistry.registerAll(savedEntries);
    await io.close();
  });

  Future<AgentCli> boot(Model model) async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'sk-test',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        steeringStaleAfter: const Duration(milliseconds: 80),
      ),
      io: io,
      streamFunction: wedgedCall,
    );
    final run = cli.run();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await waitForIt(() async => (await repo.list(cwd: '/work')).isNotEmpty,
        reason: 'session persisted');
    io.sendLine('start');
    await waitForIt(() => cli.isBusy, reason: 'run started');
    // Cleanup even when an assertion fails mid-test: a dangling wedged
    // run would hang the next test's boot on the shared isolate.
    addTearDown(() async {
      try {
        io.sendLine('/exit');
        await waitForIt(() => !cli.isBusy, reason: 'run aborted on exit');
      } on Object {
        // The test already failed — never mask it with a teardown error.
      }
    });
    unawaited(run);
    return cli;
  }

  test('AC5: a configured window wider than the floor is named on the '
      'banner', () async {
    final cli = await boot(_model(idle: const Duration(minutes: 33)));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    cli.checkPendingSteeringHealthForTest();

    final out = io.out.toString();
    expect(out, contains('agent stalled'));
    expect(out, contains('idle window 1980s'));
    expect(out, contains('model override'));
    expect(out, contains('the run keeps waiting'));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('AC3: unset config keeps the banner byte-for-byte — no window '
      'naming', () async {
    final cli = await boot(_model(baseUrl: 'https://other.test/v1'));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    cli.checkPendingSteeringHealthForTest();

    final out = io.out.toString();
    expect(out, contains('agent stalled'));
    expect(out, isNot(contains('idle window')));
    expect(out, isNot(contains('the run keeps waiting')));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('AC2: a registry entry governs the banner source for its URL', () async {
    providerTuningRegistry.register(
      name: 'llama-local',
      baseUrl: 'https://llama.test/v1',
      streamIdle: const Duration(minutes: 20),
    );
    final cli = await boot(_model());
    await Future<void>.delayed(const Duration(milliseconds: 250));
    cli.checkPendingSteeringHealthForTest();

    final out = io.out.toString();
    expect(out, contains('idle window 1200s'));
    expect(out, contains('provider:llama-local'));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
