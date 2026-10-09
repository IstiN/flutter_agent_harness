// gh-1426 IT-1: the CLI /settings → Model capabilities flow — the caps
// persist exactly the resolver's override keys, a corrupt value writes
// nothing, removal drops emptied blocks, and the override survives a
// catalog refresh (kimi-style survival).
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

  /// Occurrences of [needle] in the transcript. Re-rendered menus repeat
  /// identical text, so the SECOND render is matched by count, not by
  /// `contains` (which resolves on the stale first render).
  int countOf(String needle) =>
      io.out.toString().split(needle).length - 1;

  /// Waits until [needle] has appeared [n] times in the transcript.
  Future<void> waitForCount(String needle, int n) => waitForIt(
    () => countOf(needle) >= n,
    reason: '$needle ×$n',
  );

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
    // The caps menu re-renders with the pinned value shown in the row.
    await waitForIt(
      () => io.out.toString().contains('Max output tokens — 65536 tokens'),
    );
    io.sendLine('3'); // thinking level
    await waitForIt(
      () => io.out.toString().contains('thinking level'),
    );
    io.sendLine('5'); // high
    await waitForIt(
      () => io.out.toString().contains('models.overrides.'
          'zai.glm-5.3-flash.thinkingLevel = high'),
    );
    await waitForIt(
      () => io.out.toString().contains('Thinking level — high'),
    );
    // The omit row names its adapter scope (gh-1426 rework): the flag is
    // read by the openai-completions adapter only — a google/anthropic pin
    // would do nothing.
    await waitForIt(
      () => io.out.toString().contains(
        'Omit max-output field — off (openai-completions only)',
      ),
    );
    io.sendLine('6'); // done (caps loop — 5 is Remove now, Done shifted)
    // The flow menu re-renders identical text: match the second render.
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu: 1 set, 2 the pinned entry, 3 Done)
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
    io.sendLine('5'); // done (caps loop — no entry pinned, Done is row 5)
    // The flow menu re-renders identical text: match the second render.
    await waitForCount('Pin or edit', 2);
    io.sendLine('2'); // done (flow menu)
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
    // The remove returns to the flow menu (second render of the title).
    await waitForCount('Pin or edit', 2);
    io.sendLine('2'); // done (flow menu — the entry row is gone)
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
    // The whole `models:` block dropped with the last override — absent
    // section or empty overrides both read as "nothing pinned".
    expect(parsed.models?.overrides.isEmpty ?? true, isTrue);
  });

  test('unpinning thinkingLevel (off) removes ONLY that field', () async {
    const seed = '''
provider: openrouter
models:
  overrides:
    zai:
      glm-5.3-flash:
        maxTokens: 65536
        thinkingLevel: high
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
    io.sendLine('3'); // thinking level
    await waitForIt(() => io.out.toString().contains('thinking level'));
    io.sendLine('1'); // off → the FIELD remove (the entry survives)
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.zai.glm-5.3-flash.thinkingLevel removed',
      ),
    );
    // The caps menu re-renders with the field shown unpinned.
    await waitForIt(
      () => io.out.toString().contains(
        'Thinking level — not pinned (no thinking requested)',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, isNotNull);
    // The surgical field remove: maxTokens survives, thinkingLevel is gone.
    expect(written, contains('maxTokens: 65536'));
    expect(written, isNot(contains('thinkingLevel')));
    final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
    final pinned = parsed.models!.overrides.lookup('zai', 'glm-5.3-flash');
    expect(pinned?.maxTokens, 65536);
    expect(pinned?.thinkingLevel, isNull);
    // The live layer picked the unpin up (E6 reload-after-write).
    final live = modelCapabilityOverrides?.lookup('zai', 'glm-5.3-flash');
    expect(live?.maxTokens, 65536);
    expect(live?.thinkingLevel, isNull);
    // AC3 survival: the rebuilt model keeps the surviving cap and drops
    // the unpinned level (the zai catalog has no thinking default).
    final model = buildCatalogModel('zai', 'glm-5.3-flash');
    expect(model.maxTokens, 65536);
    expect(model.thinkingLevel, isNull);
  });

  test('unpinning on a host without a user config prints and writes nothing',
      () async {
    const seed = '''
models:
  overrides:
    zai:
      glm-5.3-flash:
        thinkingLevel: high
''';
    final memoryModels = ModelsConfig.fromYaml(
      (loadYaml(seed) as Map)['models'],
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, modelsConfig: memoryModels); // no homeDir
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('3'); // thinking level
    await waitForIt(() => io.out.toString().contains('thinking level'));
    io.sendLine('1'); // off → the remove hits the missing config path
    await waitForIt(
      () => io.out.toString().contains(
        'model capabilities: no user config on this host — not saved',
      ),
    );
    io.sendLine('6'); // done (caps loop — the pin is still there)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    // Nothing changed in memory either.
    final pinned = memoryModels.overrides.lookup('zai', 'glm-5.3-flash');
    expect(pinned?.thinkingLevel, 'high');
  });

  test('unpinning with an unreadable config file prints and writes nothing',
      () async {
    const seed = '''
models:
  overrides:
    zai:
      glm-5.3-flash:
        thinkingLevel: high
''';
    // homeDir set but NO config.yaml on disk → the read fails.
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
    io.sendLine('2'); // the entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('3'); // thinking level
    await waitForIt(() => io.out.toString().contains('thinking level'));
    io.sendLine('1'); // off → the read error path
    await waitForIt(
      () => io.out.toString().contains(
        'cannot read /home/u/.fah/config.yaml',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;
  });

  test('unpinning that would leave an invalid models block saves NOTHING',
      () async {
    // The FILE carries an invalid sibling field (maxTokens below the
    // answer floor) next to the pinned level; the in-memory model is the
    // valid twin so the flow renders. Removing the level must leave the
    // invalid block — the boot validator rejects it, nothing is written.
    const fileSeed = '''
provider: openrouter
models:
  overrides:
    zai:
      glm-5.3-flash:
        maxTokens: -5
        thinkingLevel: high
''';
    await env.writeFile('/home/u/.fah/config.yaml', fileSeed);
    const memorySeed = '''
models:
  overrides:
    zai:
      glm-5.3-flash:
        maxTokens: 65536
        thinkingLevel: high
''';
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml(
        (loadYaml(memorySeed) as Map)['models'],
      ),
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('3'); // thinking level
    await waitForIt(() => io.out.toString().contains('thinking level'));
    io.sendLine('1'); // off → the post-remove validation rejects the file
    await waitForIt(
      () => io.out.toString().contains('not saved:'),
    );
    // The caps menu re-renders with the level STILL pinned.
    await waitForIt(
      () => io.out.toString().contains('Thinking level — high'),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    // Byte-identical file: the failed remove wrote nothing.
    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, fileSeed);
  });
}
