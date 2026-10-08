// gh-1426 IT-1: the CLI /settings → Model capabilities flow — the caps
// persist exactly the resolver's override keys, a corrupt value writes
// nothing, removal drops emptied blocks, and the override survives a
// catalog refresh (kimi-style survival).
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
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
    ModelsConfig? modelsConfig,
    ModelRolesResolver? modelRolesResolver,
    String? homeDir,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        homeDir: homeDir,
        sessionRoot: '/sessions',
        modelsConfig: modelsConfig ?? ModelsConfig(),
        modelRolesResolver: modelRolesResolver,
        modelsFetcher: modelsFetcher,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// The 1-based picker row for catalog provider [name] in the flow's
  /// provider step (saved entries first — none here — then the enabled
  /// catalog order).
  int providerRow(String name) =>
      enabledProviderNames().indexOf(name) + 1;

  test('AC3: caps persist exactly the resolver override keys', () async {
    const seed = '# my config\nprovider: openrouter\nmodel: m1\n';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsFetcher: (baseUrl, {required apiKey}) async =>
          ['glm-5.3-flash'],
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('1'); // pin or edit an override
    await waitForIt(
      () => io.out.toString().contains('model capabilities — provider'),
    );
    io.sendLine('${providerRow('zai')}'); // the zai catalog row
    await waitForIt(
      () => io.out.toString().contains("model id (empty keeps"),
    );
    io.sendLine('glm-5.3-flash'); // manual entry (the zai kind has no list)
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('2'); // max output tokens
    await waitForIt(
      () => io.out.toString().contains('maxTokens in tokens'),
    );
    io.sendLine('65536');
    await waitForIt(
      () => io.out.toString().contains('models.overrides.zai.glm-5.3-flash'),
    );
    io.sendLine('3'); // thinking level
    await waitForIt(
      () => io.out.toString().contains('thinking level'),
    );
    io.sendLine('5'); // high
    await waitForIt(
      () => io.out.toString().contains('thinkingLevel = high'),
    );
    io.sendLine('5'); // done (caps loop)
    await waitForIt(() => io.out.toString().contains('Pin or edit'));
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, isNotNull);
    // Surgical write: the unrelated sections survive byte-for-byte.
    expect(written, contains('# my config\nprovider: openrouter\n'));
    // The real boot parser re-reads the file: exactly the resolver keys.
    final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
    final pinned = parsed.models!.overrides.lookup('zai', 'glm-5.3-flash');
    expect(pinned?.maxTokens, 65536);
    expect(pinned?.thinkingLevel, 'high');
    expect(pinned?.contextWindow, isNull);
    expect(pinned?.omitMaxOutputTokens, isNull);
    // The live layer picked the write up (E6 reload-after-write).
    expect(
      modelCapabilityOverrides?.lookup('zai', 'glm-5.3-flash')?.maxTokens,
      65536,
    );
    // AC3 refresh survival: the pinned cap reaches a fresh model build.
    final model = buildCatalogModel('zai', 'glm-5.3-flash');
    expect(model.maxTokens, 65536);
    expect(model.thinkingLevel, 'high');
  });

  test('a below-floor value prints the parser error and writes NOTHING',
      () async {
    const seed = 'provider: openrouter\nmodel: m1\n';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsFetcher: (baseUrl, {required apiKey}) async => ['glm-5.3-flash'],
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('1');
    await waitForIt(
      () => io.out.toString().contains('model capabilities — provider'),
    );
    io.sendLine('${providerRow('zai')}');
    await waitForIt(
      () => io.out.toString().contains("model id (empty keeps"),
    );
    io.sendLine('glm-5.3-flash');
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('1'); // context window
    await waitForIt(
      () => io.out.toString().contains('contextWindow in tokens'),
    );
    io.sendLine('100'); // below the 16384 reserve
    await waitForIt(() => io.out.toString().contains('not saved'));
    io.sendLine('4'); // done (caps loop)
    await waitForIt(() => io.out.toString().contains('Pin or edit'));
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, 'provider: openrouter\nmodel: m1\n');
  });

  test('removing the last override drops the emptied yaml blocks', () async {
    const seed = '''
provider: openrouter
models:
  overrides:
    zai:
      glm-5.3-flash:
        maxTokens: 65536
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml(
        (loadYaml(seed) as Map)['models'],
      ),
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the zai/glm-5.3-flash entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('5'); // remove this override
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.zai.glm-5.3-flash removed',
      ),
    );
    io.sendLine('1'); // done (the override is gone — only Done remains)
    await waitForIt(() => io.out.toString().contains('Pin or edit'));
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, isNotNull);
    expect(written, isNot(contains('overrides')));
    expect(written, isNot(contains('glm-5.3-flash')));
    expect(written, contains('provider: openrouter'));
    final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
    expect(parsed.models!.overrides.isEmpty, isTrue);
  });
}
