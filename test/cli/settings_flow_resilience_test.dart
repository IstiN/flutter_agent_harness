import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The interactive resilience flow (issue #393): its own file because the
/// settings-flow suite rides the 2800-line file-size gate.
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
    Model model = testModel,
    ModelsConfig? modelsConfig,
    void Function()? onModelsConfigChanged,
    CustomProviderRegistry? customProviders,
    SecureKeyCache? secureKeys,
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    http.Client? modelsHttpClient,
    Future<DapHubSnapshot?> Function()? dapHubState,
    Future<void> Function({String? url, String? name})? onDapHubConfigChanged,
    ModelRolesResolver? modelRolesResolver,
    MemoryConfig? memoryConfig,
    String? homeDir,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: env,
        homeDir: homeDir,
        sessionRoot: '/sessions',
        modelsConfig: modelsConfig,
        onModelsConfigChanged: onModelsConfigChanged,
        customProviders: customProviders,
        secureKeys: secureKeys,
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        modelsHttpClient: modelsHttpClient,
        modelRolesResolver: modelRolesResolver,
        memoryConfig: memoryConfig,
        dapHubState: dapHubState,
        onDapHubConfigChanged: onDapHubConfigChanged,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('resilience flow (issue #393)', () {
    tearDown(() => providerTimeoutsOverride = null);

    /// A resolver wired like startup builds one (a default chain, parser
    /// defaults for the retry policy) so the flow's live-install paths
    /// have a real resolver.
    ModelRolesResolver resolver() => ModelRolesResolver(
      config: ModelRolesConfig(
        roles: {
          'default': [
            const ModelRef(provider: 'anthropic', modelId: 'claude-sonnet-4'),
          ],
        },
      ),
      secrets: const {'ANTHROPIC_API_KEY': 'test-key'},
    );

    /// Seeds the USER config (the machine-level file the providerTimeouts:
    /// and retry: sections belong in, mirroring `fa config set …` global
    /// scope) and returns the cli over it.
    Future<AgentCli> seededCli(
      FakeStreamFunction fake, {
      ModelRolesResolver? modelRolesResolver,
      String yaml = 'provider: openrouter\nmodel: m1\n',
    }) async {
      await env.writeFile('/home/u/.fah/config.yaml', yaml);
      return cliFor(
        fake.call,
        homeDir: '/home/u',
        modelRolesResolver: modelRolesResolver,
      );
    }

    test(
      'AC1: the hub picker and the /settings summary carry resilience',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        io.sendLine('/settings');
        await waitForIt(
          () => io.out.toString().contains(
            'resilience: connect 180000ms, idle 300000ms, retries ×2',
          ),
        );
        io.sendLine('/exit');
        await run;

        // The hub row exists with the current effective values.
        final row = cli.settingsHubItems().firstWhere(
          (item) => item.key == 'resilience',
        );
        expect(row.label, 'Resilience');
        expect(row.description, contains('connect 180000ms'));
        expect(row.description, contains('retries ×2'));
        expect(fake.calls, 0);
      },
    );

    test('AC2: every field round-trips through the yaml file', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final roles = resolver();
      final cli = await seededCli(
        fake,
        modelRolesResolver: roles,
        yaml:
            '# machine policy\nprovider: openrouter\n'
            'roles:\n  default:\n    - anthropic/claude-sonnet-4\n'
            'retry:\n  retriesPerEntry: 1\n',
      );
      final run = cli.run();

      final flow = cli.startResilienceFlow();
      await waitForIt(() => io.out.toString().contains('resilience'));
      // Watchdog timeouts (rows 1–2).
      io.sendLine('1');
      await waitForIt(() => io.out.toString().contains('connect watchdog'));
      io.sendLine('25000');
      await waitForIt(
        () => io.out.toString().contains(
          'providerTimeouts.connectTimeoutMs = 25000',
        ),
      );
      io.sendLine('2');
      await waitForIt(() => io.out.toString().contains('stream-idle watchdog'));
      io.sendLine('45000');
      await waitForIt(
        () => io.out.toString().contains(
          'providerTimeouts.streamIdleTimeoutMs = 45000',
        ),
      );
      // Retry knobs (rows 3–7).
      io.sendLine('3');
      await waitForIt(
        () => io.out.toString().contains('retriesPerEntry (empty keeps'),
      );
      io.sendLine('3');
      await waitForIt(
        () => io.out.toString().contains('retry.retriesPerEntry = 3'),
      );
      io.sendLine('4');
      await waitForIt(
        () => io.out.toString().contains('baseDelayMs (empty keeps'),
      );
      io.sendLine('250');
      await waitForIt(
        () => io.out.toString().contains('retry.baseDelayMs = 250'),
      );
      io.sendLine('5');
      await waitForIt(
        () => io.out.toString().contains('maxBackoffMs (empty keeps'),
      );
      io.sendLine('9000');
      await waitForIt(
        () => io.out.toString().contains('retry.maxBackoffMs = 9000'),
      );
      io.sendLine('6');
      await waitForIt(
        () => io.out.toString().contains('maxWaitMs (empty keeps'),
      );
      io.sendLine('30000');
      await waitForIt(
        () => io.out.toString().contains('retry.maxWaitMs = 30000'),
      );
      io.sendLine('7');
      await waitForIt(
        () => io.out.toString().contains('keyBackoffMs (empty keeps'),
      );
      io.sendLine('45000');
      await waitForIt(
        () => io.out.toString().contains('retry.keyBackoffMs = 45000'),
      );
      io.sendLine('8'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      // The real boot parser re-reads the file.
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNotNull);
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(
        parsed.providerTimeouts!.connect,
        const Duration(milliseconds: 25000),
      );
      expect(
        parsed.providerTimeouts!.streamIdle,
        const Duration(milliseconds: 45000),
      );
      final retry = parsed.modelRoles!.retry;
      expect(retry.retriesPerEntry, 3);
      expect(retry.baseDelay, const Duration(milliseconds: 250));
      expect(retry.maxBackoff, const Duration(milliseconds: 9000));
      expect(retry.maxWait, const Duration(milliseconds: 30000));
      expect(retry.keyBackoff, const Duration(milliseconds: 45000));
      // Surgical write: the other sections survive byte-for-byte.
      expect(written, contains('# machine policy\nprovider: openrouter\n'));
      expect(written, contains('    - anthropic/claude-sonnet-4\n'));
      // Live: the published override and the resolver's policy follow
      // the file.
      expect(
        providerTimeoutsOverride!.connect,
        const Duration(milliseconds: 25000),
      );
      expect(
        providerTimeoutsOverride!.streamIdle,
        const Duration(milliseconds: 45000),
      );
      expect(roles.config.retry.retriesPerEntry, 3);
      expect(roles.config.retry.baseDelay, const Duration(milliseconds: 250));
      expect(fake.calls, 0);
    });

    test(
      'AC3: timeout edits apply to new requests via the published override',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(fake);
        final run = cli.run();

        final flow = cli.startResilienceFlow();
        await waitForIt(() => io.out.toString().contains('resilience'));
        io.sendLine('1');
        await waitForIt(() => io.out.toString().contains('connect watchdog'));
        io.sendLine('1000');
        await waitForIt(
          () => io.out.toString().contains('(applies to new requests'),
        );
        io.sendLine('8'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        // The watchdogs read the override per request — already live.
        expect(
          effectiveProviderConnectTimeout,
          const Duration(milliseconds: 1000),
        );
        expect(effectiveProviderStreamIdleTimeout, providerStreamIdleTimeout);
        expect(fake.calls, 0);
      },
    );

    test(
      'AC3: retry edits apply to new failures through a running resolver',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final roles = resolver();
        final cli = await seededCli(
          fake,
          modelRolesResolver: roles,
          yaml: 'roles:\n  default:\n    - anthropic/claude-sonnet-4\n',
        );
        final run = cli.run();

        final flow = cli.startResilienceFlow();
        await waitForIt(() => io.out.toString().contains('resilience'));
        io.sendLine('3');
        await waitForIt(
          () => io.out.toString().contains('retriesPerEntry (empty keeps'),
        );
        io.sendLine('5');
        await waitForIt(
          () => io.out.toString().contains('applies to new failures'),
        );
        io.sendLine('8'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        expect(roles.config.retry.retriesPerEntry, 5);
        expect(fake.calls, 0);
      },
    );

    test(
      'AC3: retry edits without a resolver wait for the next boot',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(
          fake,
          yaml: 'roles:\n  default:\n    - anthropic/claude-sonnet-4\n',
        );
        final run = cli.run();

        final flow = cli.startResilienceFlow();
        await waitForIt(() => io.out.toString().contains('resilience'));
        io.sendLine('3');
        await waitForIt(
          () => io.out.toString().contains('retriesPerEntry (empty keeps'),
        );
        io.sendLine('5');
        await waitForIt(
          () => io.out.toString().contains('(applies at next boot)'),
        );
        io.sendLine('8'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        // Still persisted — the next boot builds the resolver from it.
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
        expect(parsed.modelRoles!.retry.retriesPerEntry, 5);
        expect(fake.calls, 0);
      },
    );

    test('AC4: invalid values show the parser error, no write', () async {
      const seed =
          'provider: openrouter\n'
          'roles:\n  default:\n    - anthropic/claude-sonnet-4\n'
          'retry:\n  retriesPerEntry: 1\n';
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(fake, yaml: seed);
      final run = cli.run();

      final flow = cli.startResilienceFlow();
      await waitForIt(() => io.out.toString().contains('resilience'));
      // A timeout that is not a positive integer.
      io.sendLine('1');
      await waitForIt(() => io.out.toString().contains('connect watchdog'));
      io.sendLine('abc');
      await waitForIt(
        () => io.out.toString().contains(
          '"providerTimeouts.connectTimeoutMs" must be a positive integer '
          '(milliseconds)',
        ),
      );
      // A negative retry count.
      io.sendLine('3');
      await waitForIt(
        () => io.out.toString().contains('retriesPerEntry (empty keeps'),
      );
      io.sendLine('-1');
      await waitForIt(
        () => io.out.toString().contains(
          '"retry.retriesPerEntry" must be a non-negative integer',
        ),
      );
      io.sendLine('8'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), contains('not saved:'));
      // Byte-identical: nothing was written.
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, seed);
      expect(fake.calls, 0);
    });

    test('AC4: retry without a roles section is refused, no write', () async {
      const seed = 'provider: openrouter\nmodel: m1\n';
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(fake, yaml: seed);
      final run = cli.run();

      final flow = cli.startResilienceFlow();
      await waitForIt(
        () => io.out.toString().contains('resilience'),
        reason: 'menu',
      ).timeout(const Duration(seconds: 15), onTimeout: () => fail('menu'));
      io.sendLine('3');
      await waitForIt(
        () => io.out.toString().contains('retriesPerEntry (empty keeps'),
        reason: 'prompt',
      ).timeout(const Duration(seconds: 15), onTimeout: () => fail('prompt'));
      io.sendLine('5');
      await waitForIt(
        () => io.out.toString().contains('not saved'),
        reason: 'refusal',
      ).timeout(const Duration(seconds: 15), onTimeout: () => fail('refusal'));
      io.sendLine('8'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      // Byte-identical: nothing was written, and the parser's own error
      // surfaced verbatim.
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, seed);
      expect(io.out.toString(), contains('no "roles" section in config'));
      expect(fake.calls, 0);
    });

    test('E1: absent sections — the flow writes a fresh block', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u'); // no file at all
      final run = cli.run();

      final flow = cli.startResilienceFlow();
      await waitForIt(() => io.out.toString().contains('resilience'));
      io.sendLine('1'); // connect watchdog — no file, no section
      await waitForIt(() => io.out.toString().contains('connect watchdog'));
      io.sendLine('25000');
      await waitForIt(
        () => io.out.toString().contains(
          'providerTimeouts.connectTimeoutMs = 25000',
        ),
      );
      io.sendLine('8'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(
        parsed.providerTimeouts!.connect,
        const Duration(milliseconds: 25000),
      );
      expect(fake.calls, 0);
    });

    test('E2: unreadable config — clear error, nothing written', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();
      // A directory where the user config should be.
      await env.createDir('/home/u');
      await env.createDir('/home/u/.fah');
      await env.createDir('/home/u/.fah/config.yaml');

      final flow = cli.startResilienceFlow();
      await waitForIt(() => io.out.toString().contains('resilience'));
      io.sendLine('1');
      await waitForIt(() => io.out.toString().contains('connect watchdog'));
      io.sendLine('25000');
      await waitForIt(
        () =>
            io.out.toString().contains('cannot read /home/u/.fah/config.yaml'),
      );
      io.sendLine('8'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 0);
    });

    test('E3: reload-after-write picks up a concurrent hand edit', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final roles = resolver();
      final cli = await seededCli(
        fake,
        modelRolesResolver: roles,
        yaml: 'roles:\n  default:\n    - anthropic/claude-sonnet-4\n',
      );
      final run = cli.run();

      final flow = cli.startResilienceFlow();
      await waitForIt(() => io.out.toString().contains('resilience'));
      // A concurrent editor (the agent's own config save) lands between
      // the menu render and the flow's write.
      await env.writeFile(
        '/home/u/.fah/config.yaml',
        'roles:\n  default:\n    - anthropic/claude-sonnet-4\n'
            'retry:\n  retriesPerEntry: 4\n'
            'providerTimeouts:\n  streamIdleTimeoutMs: 4321\n',
      );
      io.sendLine('1'); // connect watchdog
      await waitForIt(() => io.out.toString().contains('connect watchdog'));
      io.sendLine('1234');
      await waitForIt(
        () => io.out.toString().contains(
          'providerTimeouts.connectTimeoutMs = 1234',
        ),
      );
      io.sendLine('4'); // baseDelayMs — also reloads the retry policy
      await waitForIt(
        () => io.out.toString().contains('baseDelayMs (empty keeps'),
      );
      io.sendLine('250');
      await waitForIt(
        () => io.out.toString().contains('retry.baseDelayMs = 250'),
      );
      io.sendLine('8'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      // What's live is what's on disk: BOTH the concurrent edit and the
      // flow's own writes.
      expect(
        providerTimeoutsOverride!.connect,
        const Duration(milliseconds: 1234),
      );
      expect(
        providerTimeoutsOverride!.streamIdle,
        const Duration(milliseconds: 4321),
      );
      expect(roles.config.retry.retriesPerEntry, 4);
      expect(roles.config.retry.baseDelay, const Duration(milliseconds: 250));
      expect(fake.calls, 0);
    });
  });
}
