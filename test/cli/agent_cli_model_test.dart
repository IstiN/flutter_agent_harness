import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
    Model model = testModel,
    ExecutionEnv? envOverride,
    bool Function(String name)? envVarIsSet,
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    void Function(String providerKind, String apiKey)? onProviderChanged,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    void Function(String name, String value)? onSecretStored,
    String? providerKind,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: envOverride ?? env,
        sessionRoot: '/sessions',
        envVarIsSet: envVarIsSet,
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        onProviderChanged: onProviderChanged,
        secureKeys: secureKeys,
        customProviders: customProviders,
        onSecretStored: onSecretStored,
        providerKind: providerKind ?? 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('/model prints and switches the model', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/model');
    await waitForIt(() => io.out.toString().contains('model: test-model'));
    io.sendLine('/model new-model');
    await waitForIt(
      () => io.out.toString().contains('switched model to new-model'),
    );
    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(fake.models.single.id, 'new-model');
    expect(fake.contexts.single.systemPrompt, isNotNull);
  });

  test('/models lists known models for the active provider', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/models');
    await waitForIt(() => io.out.toString().contains('claude-sonnet-4-5'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('models for anthropic:'));
    expect(output, contains('1) claude-sonnet-4-5'));
    expect(output, contains('use /model <n> or /model <id> to switch'));
  });

  test('/models filters known models by substring', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/models opus');
    await waitForIt(() => io.out.toString().contains('claude-opus-4'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('1) claude-opus-4'));
    expect(output, isNot(contains('claude-haiku-4')));
  });

  test('/model picker lets the user switch by number', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/model ?');
    await waitForIt(() => io.out.toString().contains('use /model <n>'));
    io.sendLine('/model 2');
    await waitForIt(
      () => io.out.toString().contains('switched model to claude-opus-4'),
    );
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.id, 'claude-opus-4');
  });

  group('parseModelsResponse', () {
    test('reads ids sorted and context windows from all known fields', () {
      final (ids, windows, _) = parseModelsResponse(
        '{"data": ['
        '{"id": "z-model", "context_length": 262144},'
        '{"id": "a-model", "context_window": 131072},'
        '{"id": "m-model", "max_context_length": 32768},'
        '{"id": "no-window"},'
        '{"id": "bad-window", "context_length": "lots"},'
        '{"id": ""}'
        ']}',
      );
      expect(ids, ['a-model', 'bad-window', 'm-model', 'no-window', 'z-model']);
      expect(windows, {'z-model': 262144, 'a-model': 131072, 'm-model': 32768});
    });

    test('reads max completion caps (flat and top_provider nested)', () {
      final (_, _, caps) = parseModelsResponse(
        '{"data": ['
        '{"id": "flat", "max_completion_tokens": 65536},'
        '{"id": "nested", "top_provider": {"max_completion_tokens": 32768}},'
        '{"id": "alt", "max_output_tokens": 16384},'
        '{"id": "none"},'
        '{"id": "nullish", "max_completion_tokens": null}'
        ']}',
      );
      expect(caps, {'flat': 65536, 'nested': 32768, 'alt': 16384});
    });

    test('tolerates an empty payload', () {
      final (ids, windows, caps) = parseModelsResponse('{"data": []}');
      expect(ids, isEmpty);
      expect(windows, isEmpty);
      expect(caps, isEmpty);
    });
  });

  group('/model-edit', () {
    test('bare shows the active limits; setting applies them', () async {
      final fake = FakeStreamFunction([textTurn('hi')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit');
      await waitForIt(() => io.out.toString().contains('contextWindow 100000'));
      io.sendLine('/model-edit contextWindow 131072');
      await waitForIt(
        () => io.out.toString().contains('model context window set to 131072'),
      );
      expect(cli.agent.state.model.contextWindow, 131072);
      expect(cli.agent.state.model.maxTokens, 4096);

      io.sendLine('/model-edit maxTokens 8192');
      await waitForIt(
        () => io.out.toString().contains('model max tokens set to 8192'),
      );
      expect(cli.agent.state.model.maxTokens, 8192);
      expect(cli.agent.state.model.contextWindow, 131072);

      io.sendLine('/exit');
      await run;
    });

    test('rejects bad input without touching the model', () async {
      final fake = FakeStreamFunction([textTurn('hi')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit contextWindow nope');
      await waitForIt(() => io.out.toString().contains('usage: /model-edit'));
      io.sendLine('/model-edit bananas 123');
      await waitForIt(() => io.out.toString().contains('usage: /model-edit'));
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.contextWindow, 100000);
      expect(cli.agent.state.model.maxTokens, 4096);
    });
  });
}
