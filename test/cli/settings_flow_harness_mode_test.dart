import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The interactive harness-mode flow (issue #679): its own file because
/// the settings-flow suite rides the 2800-line file-size gate.
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
    TtsrConfig? ttsr,
    RedactionPipeline? redactionPipeline,
    int? contextWindowCap,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: env,
        homeDir: homeDir,
        ttsr: ttsr,
        redactionPipeline: redactionPipeline,
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
        contextWindowCap: contextWindowCap,
        dapHubState: dapHubState,
        onDapHubConfigChanged: onDapHubConfigChanged,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('harness mode settings flow (issue #679)', () {
    test('AC1: hub picker row and line-mode summary carry the mode', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/settings');
      await waitForIt(() => io.out.toString().contains('harness:'));
      io.sendLine('/exit');
      await run;

      final row = cli.settingsHubItems().firstWhere(
        (item) => item.key == 'harness-mode',
      );
      expect(row.label, 'Harness mode');
      expect(row.description, 'default');
      expect(io.out.toString(), contains('harness: default'));
      expect(fake.calls, 0);
    });

    test(
      'AC3: picking pi round-trips agent.mode through the yaml file',
      () async {
        const seedText = 'provider: openrouter\nmodel: m1\n';
        await env.writeFile('/home/u/.fah/config.yaml', seedText);
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startHarnessModeFlow();
        await waitForIt(
          () =>
              io.out.toString().contains('pi benchmark (4 tools, bare prompt)'),
        );
        io.sendLine('2');
        await waitForIt(() => io.out.toString().contains('agent.mode = pi'));
        io.interrupt();
        await flow;
        io.sendLine('/exit');
        await run;

        final doc =
            loadYaml(
                  (await env.readTextFile(
                    '/home/u/.fah/config.yaml',
                  )).valueOrNull!,
                )
                as YamlMap;
        expect((doc['agent'] as YamlMap)['mode'], 'pi');
        // The hub row keeps the boot-resolved mode — the running session
        // does not re-resolve mid-flight (the same honest note the
        // context-cap row carries); the pick lands at the next boot.
        final row = cli.settingsHubItems().firstWhere(
          (item) => item.key == 'harness-mode',
        );
        expect(row.description, 'default');
        expect(fake.calls, 0);
      },
    );

    test('cancelled at the menu writes nothing', () async {
      const seedText = 'provider: openrouter\n';
      await env.writeFile('/home/u/.fah/config.yaml', seedText);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startHarnessModeFlow();
      await waitForIt(
        () => io.out.toString().contains('Default (full harness)'),
      );
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;
      expect(
        (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
        seedText,
      );
      expect(fake.calls, 0);
    });
  });
}
