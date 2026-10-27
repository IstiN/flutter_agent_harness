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
    Model? model,
    Future<void> Function(Model model)? onModelChanged,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model ?? testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        homeDir: homeDir,
        sessionRoot: '/sessions',
        modelsConfig: modelsConfig ?? ModelsConfig(),
        modelRolesResolver: modelRolesResolver,
        modelsFetcher: modelsFetcher,
        onModelChanged: onModelChanged,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// The 1-based picker row for catalog provider [name] in the flow's
  /// provider step (saved entries first — none here — then the enabled
  /// catalog order).
  int providerRow(String name) => enabledProviderNames().indexOf(name) + 1;

  /// Occurrences of [needle] in the transcript. Re-rendered menus repeat
  /// identical text, so the SECOND render is matched by count, not by
  /// `contains` (which resolves on the stale first render).
  int countOf(String needle) => io.out.toString().split(needle).length - 1;

  /// Waits until [needle] has appeared [n] times in the transcript.
  Future<void> waitForCount(String needle, int n) =>
      waitForIt(() => countOf(needle) >= n, reason: '$needle ×$n');

  test('AC3: caps persist exactly the resolver override keys', () async {
    const seed = '# my config\nprovider: openrouter\nmodel: m1\n';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsFetcher: (baseUrl, {required apiKey}) async => ['glm-5.3-flash'],
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('1'); // pin or edit an override
    await waitForIt(
      () => io.out.toString().contains('model capabilities — provider'),
    );
    io.sendLine('${providerRow('zai')}'); // the zai catalog row
    await waitForIt(() => io.out.toString().contains("model id (empty keeps"));
    io.sendLine('glm-5.3-flash'); // manual entry (the zai kind has no list)
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('2'); // max output tokens
    await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
    io.sendLine('5'); // the 65536 preset (4096…65536, Custom… last)
    await waitForIt(
      () => io.out.toString().contains('models.overrides.zai.glm-5.3-flash'),
    );
    // The caps menu re-renders with the pinned value as the EFFECTIVE one,
    // sourced 'pinned' (issue #1515 AC3: effective value + source layer).
    await waitForIt(
      () => io.out.toString().contains('Max output tokens — 65536 (pinned)'),
    );
    io.sendLine('3'); // thinking level
    await waitForIt(() => io.out.toString().contains('thinking level'));
    // The omp-style selector: per-level budget metadata and the CURRENT
    // level preselected (nothing pinned yet — `off` carries the marker).
    await waitForIt(
      () => io.out.toString().contains('16384-token thinking budget'),
    );
    await waitForIt(
      () => io.out.toString().contains('Off — no thinking requested (current)'),
    );
    io.sendLine('5'); // high
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.'
        'zai.glm-5.3-flash.thinkingLevel = high',
      ),
    );
    await waitForIt(() => io.out.toString().contains('Thinking level — high'));
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

  test(
    'a below-floor value prints the parser error and writes NOTHING',
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
      io.sendLine(
        '7',
      ); // Custom… (floor-trimmed ladder: 6 presets, then free input)
      await waitForIt(
        () => io.out.toString().contains('contextWindow in tokens (min 16384'),
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
    },
  );

  test('the pre-write parse guard refuses a malformed edited doc', () async {
    // A file already carrying a duplicate mapping key: the upsert edit
    // itself succeeds, but the edited text must not be persisted — the
    // PARSE sits inside the guard (gh-1787) and the write is refused
    // with a print, never a throw up the flow.
    const duplicatedSeed = '''
provider: openrouter
model: m1
note: first
note: second
''';
    await env.writeFile('/home/u/.fah/config.yaml', duplicatedSeed);
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, homeDir: '/home/u');
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('1'); // pin or edit an override
    await waitForIt(
      () => io.out.toString().contains('model capabilities — provider'),
    );
    io.sendLine('${providerRow('zai')}');
    await waitForIt(() => io.out.toString().contains('model id (empty keeps'));
    io.sendLine('glm-5.3-flash');
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    io.sendLine('2'); // max output tokens
    await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
    io.sendLine('5'); // the 65536 preset
    await waitForIt(
      () => io.out.toString().contains('Duplicate mapping key'),
      reason: 'the parse guard names the yaml error',
    );
    await waitForIt(() => io.out.toString().contains('not saved:'));
    io.sendLine('5'); // done (caps loop — no entry pinned, Done is row 5)
    await waitForCount('Pin or edit', 2);
    io.sendLine('2'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    // AC4: the malformed file is untouched — nothing was persisted.
    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, duplicatedSeed);
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
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
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
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
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
    // The caps menu re-renders with the field shown unpinned — the
    // effective level with its source layer (issue #1515 AC3).
    await waitForIt(
      () => io.out.toString().contains('Thinking level — off (default)'),
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

  test(
    'unpinning on a host without a user config prints and writes nothing',
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
    },
  );

  test(
    'unpinning with an unreadable config file prints and writes nothing',
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
        modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
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
        () =>
            io.out.toString().contains('cannot read /home/u/.fah/config.yaml'),
      );
      io.sendLine('6'); // done (caps loop)
      await waitForCount('Pin or edit', 2);
      io.sendLine('3'); // done (flow menu)
      await flow;
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'unpinning that would leave an invalid models block saves NOTHING',
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
      await waitForIt(() => io.out.toString().contains('not saved:'));
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
    },
  );

  test(
    'the hub carries ONE model-limits row with the effective summary',
    () async {
      // Issue #1515 AC1: the standalone "Model parameters" row is retired;
      // the Model capabilities row describes the ACTIVE model's effective
      // caps, not a pin count.
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
      final items = cli.settingsHubItems();
      expect(items.where((item) => item.key == 'model-edit'), isEmpty);
      final caps = items.singleWhere((item) => item.key == 'model-caps');
      expect(caps.label, 'Model capabilities');
      // testModel: 100000 ctx (not K-aligned → raw), 4096 out, no thinking.
      expect(caps.description, '100000 ctx · 4K out · thinking off');
      // Handler symmetry: the retired row's handler is gone with it.
      expect(
        items.map((item) => item.key).toSet(),
        cli.settingsPickerHandlerKeysForTest(),
      );
    },
  );

  test('pinning an override for the ACTIVE model applies live', () async {
    // Issue #1515 AC5: the pin lands in models.overrides AND rebuilds the
    // live model immediately (the retired /model-edit live-mutation
    // semantics, now durable). Proven through the line-mode /model-edit
    // status print, which reads the live model.
    const seed = '''
provider: openrouter
models:
  overrides:
    test-provider:
      test-model:
        maxTokens: 65536
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the test-provider/test-model entry row
    await waitForIt(
      () =>
          io.out.toString().contains('capabilities — test-provider/test-model'),
    );
    io.sendLine('1'); // context window
    await waitForIt(
      () => io.out.toString().contains('contextWindow in tokens'),
    );
    io.sendLine('4'); // the 131072 preset (floor-trimmed ladder, row 4)
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.test-provider.test-model.contextWindow = 131072',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu — 2 is the still-pinned entry row)
    await flow;

    // The pin landed in the live layer...
    expect(
      modelCapabilityOverrides
          ?.lookup('test-provider', 'test-model')
          ?.contextWindow,
      131072,
    );
    // ...and the ACTIVE model carries it right now (no reboot).
    io.sendLine('/model-edit');
    await waitForIt(() => io.out.toString().contains('contextWindow 131072'));
    io.sendLine('/exit');
    await run;
  });

  test('a pin rides the role-slot layer: the rebuild cannot swap it', () async {
    // Review round: the rebuild must resolve through the FULL chain —
    // a roles chain entry with explicit caps is the resolver's layer 2;
    // resolving without it silently swaps the un-pinned fields.
    const seed = '''
provider: openrouter
models:
  overrides:
    zai:
      glm-5.3-flash:
        thinkingLevel: high
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final resolver = ModelRolesResolver(
      config: ModelRolesConfig(
        roles: const {
          'default': [
            ModelRef(
              provider: 'zai',
              modelId: 'glm-5.3-flash',
              contextWindow: 500000,
              keyless: true,
            ),
          ],
        },
        retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
      ),
      secrets: const {},
      streamFactory: (kind, apiKey) => FakeStreamFunction([]).call,
    );
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
      modelRolesResolver: resolver,
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the zai/glm-5.3-flash entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — zai/glm-5.3-flash'),
    );
    // The row shows the ROLE window as the effective one.
    await waitForIt(
      () =>
          io.out.toString().contains('Context window — 500000 (role override)'),
    );
    io.sendLine('2'); // max output tokens
    await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
    io.sendLine('5'); // the 65536 preset
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.zai.glm-5.3-flash.maxTokens = 65536',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu — 2 is the pinned entry row)
    await flow;
    // The live rebuild kept the ROLE window and moved only maxTokens.
    io.sendLine('/model-edit');
    await waitForIt(() => io.out.toString().contains('contextWindow 500000'));
    await waitForIt(() => io.out.toString().contains('maxTokens 65536'));
    io.sendLine('/exit');
    await run;
  });

  test('unpinning drops the stale userPin from the window registry', () async {
    // Review round: the registry must agree with the rebuilt model in
    // BOTH directions — a pin publishes userPin, an unpin drops the
    // entry (children and the meter fall back to the carried window).
    const seed = '''
provider: openrouter
models:
  overrides:
    test-provider:
      test-model:
        contextWindow: 131072
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the entry row
    await waitForIt(
      () =>
          io.out.toString().contains('capabilities — test-provider/test-model'),
    );
    io.sendLine('5'); // remove this override (returns to the flow menu)
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.test-provider.test-model removed',
      ),
    );
    await waitForCount('Pin or edit', 2);
    io.sendLine('2'); // done (flow menu — the entry row is gone)
    await flow;

    // The rebuild fell back to the catalog/documented window, and the
    // registry entry the pin had earned is GONE (nothing republishes a
    // pin that no longer stands).
    expect(cli.contextWindowRegistry.windowFor(testModel), isNull);
    io.sendLine('/model-edit');
    await waitForIt(() => io.out.toString().contains('contextWindow 128000'));
    io.sendLine('/exit');
    await run;
  });

  test('the live rebuild carries the catalog image cap', () async {
    // Review round: the constructor rebuild must not drop Model.maxImages
    // — the image registry reads it off the live model, and losing it
    // silently widens the ceiling to the global default.
    const seed = '''
provider: openrouter
models:
  overrides:
    google:
      gemini-4-argon:
        contextWindow: 131072
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    Model? rebuilt;
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
      model: buildCatalogModel('google', 'gemini-4-argon'),
      onModelChanged: (model) async => rebuilt = model,
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the google/gemini-4-argon entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — google/gemini-4-argon'),
    );
    io.sendLine('2'); // max output tokens
    await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
    io.sendLine('5'); // the 65536 preset
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.google.gemini-4-argon.maxTokens = 65536',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    // The host-visible rebuilt model: maxTokens moved, maxImages stayed.
    expect(rebuilt, isNotNull);
    expect(rebuilt?.maxTokens, 65536);
    expect(rebuilt?.maxImages, catalogMaxImages['gemini-4-argon']);
  });

  test('the lowest window preset pins exactly the parse floor', () async {
    // Review round 2: the ladder was trimmed to the parse floor (4K/8K
    // were dead rows — the validated upsert rejects below 16384); row 1
    // must land right on the boundary.
    const seed = '''
provider: openrouter
models:
  overrides:
    test-provider:
      test-model:
        maxTokens: 65536
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the entry row
    await waitForIt(
      () =>
          io.out.toString().contains('capabilities — test-provider/test-model'),
    );
    io.sendLine('1'); // context window
    await waitForIt(
      () => io.out.toString().contains('contextWindow in tokens'),
    );
    io.sendLine('1'); // 16384 — the compaction reserve itself
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.test-provider.test-model.contextWindow = 16384',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    expect(
      modelCapabilityOverrides
          ?.lookup('test-provider', 'test-model')
          ?.contextWindow,
      16384,
    );
    io.sendLine('/exit');
    await run;
  });

  test('gh-1787 repro: maxTokens 65536 lands beside a host-rendered quoted '
      'contextWindow pin (the copilot incident)', () async {
    // The incident's on-disk state: the contextWindow write landed
    // first and the host's whole-file persist re-rendered the overrides
    // block with jsonEncode'd keys (ModelCapabilityOverrides.toYaml).
    // The SECOND write (max output 65536) used to miss the quoted keys,
    // insert a duplicate bare chain, and die on the pre-write loadYaml
    // with `YamlException: Duplicate mapping key` — the raw stack trace
    // the transcript showed, with the maxTokens write never landing.
    const seed = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        contextWindow: 204800
''';
    await env.writeFile('/home/u/.fah/config.yaml', seed);
    final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      homeDir: '/home/u',
      modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
      model: const Model(
        id: 'gemini-4-argon',
        api: 'copilot',
        provider: 'copilot',
        baseUrl: 'https://api.githubcopilot.com/',
        contextWindow: 204800,
        maxTokens: 16384,
      ),
    );
    final run = cli.run();

    final flow = cli.startModelCapsFlow();
    await waitForIt(() => io.out.toString().contains('model capabilities'));
    io.sendLine('2'); // the copilot/gemini-4-argon entry row
    await waitForIt(
      () => io.out.toString().contains('capabilities — copilot/gemini-4-argon'),
    );
    io.sendLine('2'); // max output tokens
    await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
    io.sendLine('5'); // the 65536 preset
    await waitForIt(
      () => io.out.toString().contains(
        'models.overrides.copilot.gemini-4-argon.maxTokens = 65536',
      ),
    );
    io.sendLine('6'); // done (caps loop)
    await waitForCount('Pin or edit', 2);
    io.sendLine('3'); // done (flow menu)
    await flow;
    io.sendLine('/exit');
    await run;

    // AC1: the maxTokens write LANDED beside the surviving pin — the
    // file parses as ONE entry carrying BOTH fields.
    final written = (await env.readTextFile(
      '/home/u/.fah/config.yaml',
    )).valueOrNull;
    expect(written, isNotNull);
    final doc = loadYaml(written!) as YamlMap;
    final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
    expect(overrides.length, 1);
    final caps = (overrides['copilot'] as YamlMap)['gemini-4-argon'] as YamlMap;
    expect(caps['maxTokens'], 65536);
    expect(caps['contextWindow'], 204800);
    // The live layer picked the write up (E6 reload-after-write).
    expect(
      modelCapabilityOverrides?.lookup('copilot', 'gemini-4-argon')?.maxTokens,
      65536,
    );
  });

  test(
    'pinning one field keeps the boot-carried caps of the live model',
    () async {
      // Review round 2: a model whose caps came from a layer the resolver
      // cannot see (FA_PROVIDER_CONFIG preconfig, merged into the built
      // model at boot) must not have its untouched dimensions swapped to
      // catalog defaults when an unrelated field is pinned — display AND
      // rebuild read the carried value.
      const seed = '''
provider: openrouter
models:
  overrides:
    test-provider:
      test-model:
        maxTokens: 16384
''';
      await env.writeFile('/home/u/.fah/config.yaml', seed);
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        modelsConfig: ModelsConfig.fromYaml((loadYaml(seed) as Map)['models']),
        // The shape the preconfig build produces: declared caps on the
        // booted model, no resolver layer backing them.
        model: const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 5000,
          maxTokens: 32768,
        ),
      );
      final run = cli.run();

      final flow = cli.startModelCapsFlow();
      await waitForIt(() => io.out.toString().contains('model capabilities'));
      io.sendLine('2'); // the entry row
      await waitForIt(
        () => io.out.toString().contains(
          'capabilities — test-provider/test-model',
        ),
      );
      // The display advertises the CARRIED window before any edit.
      await waitForIt(
        () => io.out.toString().contains('Context window — 5000 (carried)'),
      );
      io.sendLine('2'); // max output tokens
      await waitForIt(() => io.out.toString().contains('maxTokens in tokens'));
      io.sendLine('5'); // the 65536 preset
      await waitForIt(
        () => io.out.toString().contains(
          'models.overrides.test-provider.test-model.maxTokens = 65536',
        ),
      );
      io.sendLine('6'); // done (caps loop)
      await waitForCount('Pin or edit', 2);
      io.sendLine('3'); // done (flow menu)
      await flow;
      // The rebuild moved ONLY maxTokens — the carried window survives.
      io.sendLine('/model-edit');
      await waitForIt(() => io.out.toString().contains('contextWindow 5000'));
      await waitForIt(() => io.out.toString().contains('maxTokens 65536'));
      io.sendLine('/exit');
      await run;
    },
  );
}
