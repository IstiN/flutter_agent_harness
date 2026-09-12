@Tags(['integration'])
/// Headless self-config round trips (issue #29 S4: AC4/AC5/AC6). The agent
/// drives the `config` tool through the REAL `AgentCli` turn loop; AC6
/// additionally replays the fresh-boot resolution chain
/// (`parseCliArgs` -> `loadCliConfig` -> `resolveEffectiveCliArgs` ->
/// `buildCliDefaultModel`) against the file the agent wrote. Only the LLM
/// streams are faked; config files are REAL files (AC4/AC6 use
/// [LocalExecutionEnv] over temp dirs, AC5 the in-memory env like the
/// scoped-tools suite).
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

ToolCall _call(String id, String name, Map<String, Object?> arguments) =>
    ToolCall(id: id, name: name, arguments: arguments);

void main() {
  test('AC4: re-pointing memory.projectPath is picked up live by the '
      'running session', () async {
    final project = await Directory.systemTemp.createTemp('fah_ac4_proj');
    final home = await Directory.systemTemp.createTemp('fah_ac4_home');
    addTearDown(() {
      project.delete(recursive: true);
      home.delete(recursive: true);
    });
    // Skip the boot-time maintenance sweep (its stamp check is the FIRST
    // thing a memory operation does).
    final defaultStore = Directory('${project.path}/.fah/memory')
      ..createSync(recursive: true);
    File(
      '${defaultStore.path}/.last_maintenance',
    ).writeAsStringSync(DateTime.now().toIso8601String());
    final mem2 = '${project.path}/mem2';

    final env = LocalExecutionEnv(cwd: project.path);
    final io = FakeCliIO();
    final fake = FakeStreamFunction([
      toolTurn([
        _call('c1', 'config', {
          'op': 'set',
          'key': 'memory.projectPath',
          'value': mem2,
        }),
      ]),
      toolTurn([
        _call('c2', 'config', {'op': 'check'}),
      ]),
      toolTurn([
        _call('c3', 'memory_add', {'text': 'lives in the new store'}),
      ]),
      textTurn('done'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '${project.path}/sessions',
        homeDir: home.path,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa>'));

    // Turn 1: the set lands in the project config file.
    io.sendLine('go');
    await waitForIt(() => fake.calls >= 2, reason: 'config set turn to finish');
    final projectConfig = File('${project.path}/.fah/config.yaml');
    expect(projectConfig.existsSync(), isTrue);
    // The REAL consumer parses the file the agent wrote.
    expect(loadProjectMemoryConfig(project.path)?.projectPath, mem2);
    // Nothing was written to the project file before the turn: it was
    // created by the set (minimal project file, E1).

    // Turn 2: the agent's mandatory check runs clean.
    io.sendLine('check');
    await waitForIt(() => fake.calls >= 3, reason: 'check turn to finish');
    final report = await ConfigService(env: env, homeDir: home.path).check();
    expect(report.ok, isTrue, reason: '${report.errors}');

    // Turn 3: the SAME session's memory controller writes to the new store
    // — no restart.
    io.sendLine('remember');
    await waitForIt(() => fake.calls >= 4, reason: 'memory_add turn to finish');
    final newStore = Directory(mem2);
    expect(
      newStore.existsSync(),
      isTrue,
      reason: 'the live re-read swapped the store to the new path',
    );
    await waitForIt(
      () => newStore.listSync(recursive: true).isNotEmpty,
      reason: 'the memory entry to land in the new store',
    );

    io.sendLine('/exit');
    await run;
    await io.close();
  });

  test('AC5: disabling a tool via the config tool applies after /tools '
      'reload', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final fake = FakeStreamFunction([
      toolTurn([
        _call('c1', 'config', {
          'op': 'set',
          'key': 'tools.web_search',
          'value': 'false',
        }),
      ]),
      textTurn('done'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions-a',
        homeDir: '/home/u',
        webSearchConfig: WebSearchConfig(),
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa>'));

    Set<String> offeredTools() =>
        cli.agent.state.tools.map((tool) => tool.name).toSet();
    expect(offeredTools(), containsAll(['web_search', 'web_fetch']));

    io.sendLine('disable web search');
    await waitForIt(() => fake.calls >= 2, reason: 'config set turn');
    final projectConfig =
        (await env.readTextFile('/work/.fah/config.yaml')).valueOrNull ?? '';
    expect(projectConfig, contains('web_search: false'));

    io.sendLine('/tools reload');
    await waitForIt(
      () => io.out.toString().contains('availability reloaded'),
      reason: '/tools reload',
    );
    expect(
      offeredTools(),
      isNot(contains('web_search')),
      reason: 'the tombstone hides web_search from the registry',
    );
    expect(offeredTools(), isNot(contains('web_fetch')));

    io.sendLine('/exit');
    await run;
    await io.close();
  });

  test('AC6: provider switch via the config tool boots headless, and a '
      'broken intermediate state is caught by check', () async {
    final project = await Directory.systemTemp.createTemp('fah_ac6_proj');
    final home = await Directory.systemTemp.createTemp('fah_ac6_home');
    addTearDown(() {
      project.delete(recursive: true);
      home.delete(recursive: true);
    });
    final env = LocalExecutionEnv(cwd: project.path);
    const mockUrl = 'http://127.0.0.1:8932/v1';
    const customProviders =
        '[{"name":"local-mock","apiType":"openai","baseUrl":"$mockUrl",'
        '"modelId":"mock-model"}]';

    // The agent (as the skill teaches) writes the provider entry, then
    // flips provider/model/baseUrl, then runs the mandatory check.
    final io = FakeCliIO();
    final fake = FakeStreamFunction([
      toolTurn([
        _call('c1', 'config', {
          'op': 'set',
          'key': 'customProviders',
          'value': customProviders,
        }),
        _call('c2', 'config', {
          'op': 'set',
          'key': 'provider',
          'value': 'openai-completions',
        }),
        _call('c3', 'config', {
          'op': 'set',
          'key': 'model',
          'value': 'mock-model',
        }),
        _call('c4', 'config', {
          'op': 'set',
          'key': 'baseUrl',
          'value': mockUrl,
        }),
        _call('c5', 'config', {'op': 'check'}),
      ]),
      textTurn('switched'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '${project.path}/sessions',
        homeDir: home.path,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa>'));
    io.sendLine('switch us to the local mock provider');
    await waitForIt(
      () => fake.calls >= 2,
      reason: 'the five config calls to settle',
    );
    io.sendLine('/exit');
    await run;
    await io.close();

    // The agent's mandatory check ran; the file it left behind validates.
    final service = ConfigService(env: env, homeDir: home.path);
    final report = await service.check();
    expect(report.ok, isTrue, reason: '${report.errors}');
    // Fresh headless boot over the file the agent wrote: the real config
    // load + restore chain picks the custom endpoint up.
    final saved = loadCliConfig(home.path);
    expect(saved.customProviders, hasLength(1));
    expect(saved.customProviders.single.name, 'local-mock');
    expect(saved.customProviders.single.baseUrl, mockUrl);
    final parsed = parseCliArgs(['-p', 'hi']) as CliArgs;
    final effective = resolveEffectiveCliArgs(parsed, saved);
    expect(effective.provider, 'openai-completions');
    final model = buildCliDefaultModel(
      effective.provider,
      modelId: effective.args.model,
      baseUrl: effective.args.baseUrl,
    );
    expect(model.id, 'mock-model');
    expect(model.baseUrl, mockUrl);

    // The broken intermediate the skill must never persist: an entry
    // without a baseUrl is refused with a named diagnostic and nothing is
    // written; if a bad state lands through another channel, `fa config
    // check` names it.
    final good = await File('${home.path}/.fah/config.yaml').readAsString();
    await expectLater(
      service.set(
        'customProviders',
        '[{"name":"broken","apiType":"openai","modelId":"m"}]',
      ),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('baseUrl'),
        ),
      ),
    );
    expect(await File('${home.path}/.fah/config.yaml').readAsString(), good);

    const badYaml = '''
customProviders:
  - name: broken
    apiType: openai
''';
    await File('${home.path}/.fah/config.yaml').writeAsString(badYaml);
    final broken = await service.check();
    expect(broken.ok, isFalse);
    expect(broken.errors.map((e) => e.message).join('\n'), contains('baseUrl'));
  });
}
