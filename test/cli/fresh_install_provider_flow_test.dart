// Issue #969: a fresh install — nothing configured, no key anywhere — must
// open the guided add-provider wizard (the same flow `/provider custom`
// opens) before the first prompt, instead of booting into the default
// provider's "no key set" banner noise. Covers the pure boot decision
// (`freshInstallProviderState`) and the REPL routing through the injected
// `freshInstallProviderFlow` flag (FakeCliIO — no PTY).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
// `freshInstallProviderState` lives in src/cli/startup.dart (dart:io side),
// exported from io.dart like the rest of the boot-resolution phases.
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    bool freshInstallProviderFlow = false,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    Future<void> Function(String providerKind, String apiKey)?
    onProviderChanged,
    SecureKeyCache? secureKeys,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        freshInstallProviderFlow: freshInstallProviderFlow,
        modelsFetcher: modelsFetcher,
        onProviderChanged: onProviderChanged,
        secureKeys: secureKeys,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('freshInstallProviderState (the executable boot decision)', () {
    test('fresh: no saved providers, no env keys, empty store', () {
      expect(
        freshInstallProviderState(
          customProviders: const [],
          keys: SecureKeyCache(FakeSecureKeyStore()),
          env: const {},
        ),
        isTrue,
      );
    });

    test('a catalog env key — or its rotation stack — is not fresh', () {
      final keys = SecureKeyCache(FakeSecureKeyStore());
      expect(
        freshInstallProviderState(
          customProviders: const [],
          keys: keys,
          env: const {'ANTHROPIC_API_KEY': 'sk-ant'},
        ),
        isFalse,
      );
      expect(
        freshInstallProviderState(
          customProviders: const [],
          keys: keys,
          env: const {'ANTHROPIC_API_KEY_2': 'sk-ant-2'},
        ),
        isFalse,
      );
    });

    test('a secure-store key is not fresh', () async {
      final store = FakeSecureKeyStore()..map['OPENAI_API_KEY'] = 'sk-x';
      final keys = SecureKeyCache(store);
      await keys.preload(['OPENAI_API_KEY']);
      expect(
        freshInstallProviderState(
          customProviders: const [],
          keys: keys,
          env: const {},
        ),
        isFalse,
      );
    });

    test('a saved custom provider is not fresh', () {
      expect(
        freshInstallProviderState(
          customProviders: [
            CustomProviderEntry(
              name: 'proxy',
              apiType: 'openai',
              baseUrl: 'https://proxy.example.com/v1',
              modelId: 'm1',
            ),
          ],
          keys: SecureKeyCache(FakeSecureKeyStore()),
          env: const {},
        ),
        isFalse,
      );
    });
  });

  test('fresh boot opens the add-provider wizard before the first prompt '
      'and lands the chosen connection', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
    final store = FakeSecureKeyStore();
    final keys = SecureKeyCache(store);
    await keys.probe();
    final cli = cliFor(
      fake.call,
      freshInstallProviderFlow: true,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      onProviderChanged: (kind, key) async => changes.add((kind, key)),
      secureKeys: keys,
    );
    final run = cli.run();

    // The wizard is the FIRST interactive thing: it opens at boot, before
    // any input — the api-type picker is its first question.
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('1'); // openai-like
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://proxy.example.com/v1');
    await waitForIt(
      () => io.out.toString().contains('provider name (empty ='),
    );
    io.sendLine('work');
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('sk-fresh-key-1');
    await waitForIt(
      () => io.out.toString().contains('no model list from the endpoint'),
    );
    io.sendLine('proxy-model');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    // The wizard completes OUTSIDE the dispatch loop — the loop is parked
    // reading the next line when the last answer lands, so only the flow's
    // own completion can restore the idle prompt (round-1 review: it never
    // reappeared and the user had to submit a line blind). On a fresh boot
    // the prompt has never printed before this point, so its first
    // appearance here proves the redraw.
    await waitForIt(() => io.out.toString().contains('fa>'));
    io.sendLine('/exit');
    await run;

    final model = cli.agent.state.model;
    expect(model.provider, 'openai');
    expect(model.baseUrl, 'https://proxy.example.com/v1');
    expect(model.id, 'proxy-model');
    // Name-scoped slot: the typed key binds to the new entry.
    expect(store.map['FA_KEY_PROXY_EXAMPLE_COM_WORK'], 'sk-fresh-key-1');
    expect(io.out.toString(), isNot(contains('sk-fresh-key-1')));
    expect(changes, hasLength(1));
  });

  test('cancelling the boot wizard (Ctrl-C) keeps the default boot usable '
      'and restores the idle prompt', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
    final store = FakeSecureKeyStore();
    final keys = SecureKeyCache(store);
    await keys.probe();
    final cli = cliFor(
      fake.call,
      freshInstallProviderFlow: true,
      onProviderChanged: (kind, key) async => changes.add((kind, key)),
      secureKeys: keys,
    );
    final run = cli.run();

    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.interrupt(); // Ctrl-C on the first question
    await waitForIt(
      () => io.out.toString().contains('custom provider setup cancelled'),
    );
    // The cancel path restores the prompt too — without the redraw the
    // REPL looks dead until the user submits a line blind.
    await waitForIt(() => io.out.toString().contains('fa>'));

    // Nothing applied: no provider switch, no persisted key. The REPL is
    // still usable — /exit goes through the normal path.
    expect(changes, isEmpty);
    expect(store.map, isEmpty);
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), isNot(contains('switched provider')));
  });

  test('a boot without the fresh-install flag never opens the wizard',
      () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa>'));
    expect(io.out.toString(), isNot(contains('custom provider setup')));
    io.sendLine('/exit');
    await run;
  });

  test('piped input (non-interactive io) never enters the wizard', () async {
    io.isInteractive = false;
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, freshInstallProviderFlow: true);
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('[Model]'));
    expect(io.out.toString(), isNot(contains('custom provider setup')));
    io.sendLine('/exit');
    await run;
  });
}
