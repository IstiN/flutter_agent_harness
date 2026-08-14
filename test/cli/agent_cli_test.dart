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

  Future<List<SessionRecord>> sessionEntries() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    if (sessions.isEmpty) return const [];
    final session = await repo.open(sessions.first);
    return session.getEntries();
  }

  test(
    'default system prompt uses Fa branding and forbids pi/Claude names',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final prompt = cli.systemPrompt;
      expect(prompt, contains('You are Fa'));
      expect(prompt, contains('also called fa'));
      expect(
        prompt.toLowerCase(),
        contains('never refer to yourself as pi, claude'),
      );
    },
  );

  test('registers inspect_image tool when visionConfig is provided', () {
    final fake = FakeStreamFunction([]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        visionConfig: InspectImageConfig(
          modelId: 'gpt-4o',
          apiKey: 'vision-key',
        ),
      ),
      io: io,
      streamFunction: fake.call,
    );
    final names = cli.agent.state.tools.map((t) => t.name);
    expect(names, contains('inspect_image'));
  });

  test('registers transcribe_audio tool when transcribeConfig is provided', () {
    final fake = FakeStreamFunction([]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        transcribeConfig: const TranscribeAudioConfig(apiKey: 'transcribe-key'),
      ),
      io: io,
      streamFunction: fake.call,
    );
    final names = cli.agent.state.tools.map((t) => t.name);
    expect(names, contains('transcribe_audio'));
  });

  test('streams assistant text live and persists the session', () async {
    final fake = FakeStreamFunction([textTurn('Hello world')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('hi');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;
    final output = io.out.toString();
    expect(output, contains('test-model (test-api)'));
    expect(output, contains('/work'));
    expect(output, contains('fa> '));
    expect(output, contains('Hello world'));
    expect(output, contains('bye'));
    final entries = await sessionEntries();
    final messages = entries.whereType<MessageRecord>().toList();
    expect(messages, hasLength(2));
    expect(messages[0].message.role, 'user');
    expect(messages[1].message.role, 'assistant');
    final assistant = messages[1].message as AssistantMessage;
    expect(
      assistant.content.whereType<TextContent>().single.text,
      'Hello world',
    );
  });

  test('banner shows the endpoint and the set key env var name', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
      envVarIsSet: (name) => name == 'ANTHROPIC_API_KEY',
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;
    final output = io.out.toString();
    expect(output, contains('endpoint: https://api.anthropic.com'));
    expect(output, contains('key: ANTHROPIC_API_KEY'));
    expect(output, isNot(contains('no key set')));
  });

  test('banner warns when no key env var is set for the provider', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
      envVarIsSet: (_) => false,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;
    expect(
      io.out.toString(),
      contains('key: no key set (want ANTHROPIC_API_KEY)'),
    );
  });

  test('banner has no key line for providers without key env vars', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, providerKind: 'test-kind');
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('endpoint: https://example.test'));
    expect(output, isNot(contains('key:')));
  });

  test(
    'banner key status tracks the provider kind on custom endpoints',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        model: testCustomEndpointModel,
        envVarIsSet: (name) => name == 'OPENROUTER_API_KEY',
      );
      final run = cli.run();

      await waitForIt(() => io.out.toString().contains('[Model]'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('endpoint: http://127.0.0.1:8932'));
      // The key lookup is by provider kind (openrouter names), not by the
      // flipped model provider (openai): no false "no key set" warning.
      expect(output, contains('key: OPENROUTER_API_KEY'));
      expect(output, isNot(contains('no key set')));
    },
  );

  test('banner skips the key warning on keyless custom endpoints', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      model: testCustomEndpointModel,
      envVarIsSet: (_) => false,
    );
    final run = cli.run();

    await waitForIt(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('endpoint: http://127.0.0.1:8932'));
    // Local servers (llama.cpp, Ollama, LM Studio) need no key — warning
    // about a missing one would be noise.
    expect(output, isNot(contains('key:')));
  });

  test(
    'background task job completes and re-enters the conversation',
    () async {
      final fake = FakeStreamFunction([
        // 1. The parent delegates a background agent.
        toolTurn([
          ToolCall(
            id: 't1',
            name: 'task',
            arguments: const {
              'context': 'repo state',
              'background': true,
              'tasks': [
                {'name': 'Scout', 'task': 'survey the repo'},
              ],
            },
          ),
        ]),
        // 2. The parent wraps up its own turn.
        textTurn('delegated the survey'),
        // 3. The background child agent produces its result.
        textTurn('survey says: all quiet'),
        // 4. The async-result re-wake reacts to the injected notification.
        textTurn('noted, survey integrated'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('delegate it');
      await waitForIt(() => fake.calls == 4 && !cli.isBusy);
      io.sendLine('/tasks');
      await waitForIt(() => io.out.toString().contains('background agents:'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // The tool ran (start/end one-liners) and the job completed…
      expect(output, contains('[task] context="repo state"'));
      expect(output, contains('[task] done'));
      expect(output, contains('[task] Scout (task) completed'));
      expect(output, contains('agent://Scout'));
      // The child's output re-entered as a steered/re-wake async-result…
      expect(output, contains('survey says: all quiet'));
      expect(output, contains('noted, survey integrated'));
      // …and /tasks lists the settled job.
      expect(output, contains('✓ Scout (task) completed'));
    },
  );

  test(
    'project context files and skills enter the system prompt; /skill: invokes',
    () async {
      await env.createDir('/work/.git');
      await env.writeFile('/work/AGENTS.md', 'follow the repo rules');
      await env.createDir('/work/.fah/skills/deploy');
      await env.writeFile(
        '/work/.fah/skills/deploy/SKILL.md',
        '---\nname: deploy\ndescription: Deploy the app\n---\n'
            'Deploy body here.\n',
      );
      final fake = FakeStreamFunction([textTurn('deploying now')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () =>
            cli.systemPrompt.contains('follow the repo rules') &&
            cli.systemPrompt.contains('<name>deploy</name>'),
      );
      io.sendLine('/skill:deploy ship it');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(
        output,
        contains('skill deploy — /work/.fah/skills/deploy/SKILL.md'),
      );
      expect(output, contains('deploying now'));
      // The skill body + args reached the model as one user message.
      final lastUser = fake.contexts.last.messages
          .whereType<UserMessage>()
          .last;
      final text = lastUser.content as String;
      expect(text, contains('Deploy body here.'));
      expect(text, contains('User request:\nship it'));
    },
  );

  test('renders tool start/end one-liners and stores tool results', () async {
    await env.writeFile('notes.txt', 'data');
    final fake = FakeStreamFunction([
      toolTurn([
        ToolCall(
          id: 'c1',
          name: 'read',
          arguments: const {'path': 'notes.txt'},
        ),
      ]),
      textTurn('done reading'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('read it');
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('[read] path="notes.txt"'));
    expect(output, contains('[read] done'));

    final entries = await sessionEntries();
    final toolResults = entries
        .whereType<MessageRecord>()
        .map((r) => r.message)
        .whereType<ToolResultMessage>()
        .toList();
    expect(toolResults, hasLength(1));
    expect(toolResults.single.toolName, 'read');
    expect(
      toolResults.single.content.whereType<TextContent>().single.text,
      'data',
    );
  });

  test('steers typed input into a running agent', () async {
    final shell = GatedShell();
    final gatedEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
    final fake = FakeStreamFunction([
      toolTurn([
        ToolCall(id: 'c1', name: 'bash', arguments: const {'command': 'sleep'}),
      ]),
      textTurn('final'),
    ]);
    final cli = cliFor(fake.call, envOverride: gatedEnv);
    final run = cli.run();

    io.sendLine('run');
    await waitForIt(() => fake.calls == 1);
    // The bash tool is blocked on the gate, so the run is mid-flight.
    io.sendLine('steer me');
    shell.release();
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final secondCallMessages = fake.contexts[1].messages;
    expect(
      secondCallMessages.any(
        (m) => m is UserMessage && m.content == 'steer me',
      ),
      isTrue,
    );
  });

  test('aborts the current run on interrupt', () async {
    final fake = AbortableStreamFunction();
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('long task');
    await waitForIt(() => fake.started);
    io.interrupt();
    await waitForIt(() => !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(io.out.toString(), contains('aborted: Operation aborted'));
  });

  test('/stats reports accumulated usage', () async {
    const usage = Usage(
      input: 10,
      output: 5,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 15,
      cost: UsageCost(input: 0.0006, output: 0.0004, total: 0.001),
    );
    final fake = FakeStreamFunction([textTurn('hi', usage: usage)]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/stats');
    await waitForIt(() => io.out.toString().contains('cost:'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('turns: 1'));
    expect(output, contains('input tokens: 10'));
    expect(output, contains('output tokens: 5'));
    expect(output, contains('total tokens: 15'));
    expect(output, contains(r'cost: $0.0010'));
  });

  test('/reset starts a fresh session and clears history', () async {
    final fake = FakeStreamFunction([textTurn('first'), textTurn('second')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('one');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/reset');
    await waitForIt(() => io.out.toString().contains('new session started'));
    io.sendLine('two');
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    expect(await repo.list(cwd: '/work'), hasLength(2));
    final secondCallMessages = fake.contexts[1].messages;
    expect(secondCallMessages, hasLength(1));
    final userMessage = secondCallMessages.single as UserMessage;
    expect(userMessage.content, 'two');
  });

  test('/compact summarizes history and replaces the context', () async {
    final fake = FakeStreamFunction([
      textTurn('answer'),
      textTurn('SUMMARY'),
      textTurn('after'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/compact');
    await waitForIt(() => fake.calls == 2, reason: 'summarizer called');
    await waitForIt(() => io.out.toString().contains('[compacted]'));
    io.sendLine('next');
    await waitForIt(() => fake.calls == 3 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final entries = await sessionEntries();
    final compactions = entries.whereType<CompactionRecord>().toList();
    expect(compactions, hasLength(1));
    expect(compactions.single.summary, 'SUMMARY');

    // The next prompt starts from the projected summary, not raw history.
    final messages = fake.contexts[2].messages;
    final first = messages.first as UserMessage;
    expect(first.content, contains('SUMMARY'));
    expect(first.content, contains('<summary>'));
  });

  test('auto-compacts after a turn over the threshold', () async {
    const tinyWindow = Model(
      id: 'tiny',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://example.test',
      contextWindow: 100,
      maxTokens: 4096,
    );
    final fake = FakeStreamFunction([
      textTurn('a reasonably long answer that exceeds the tiny window'),
      textTurn('AUTO SUMMARY'),
    ]);
    final cli = cliFor(fake.call, model: tinyWindow);
    final run = cli.run();

    io.sendLine('q');
    await waitForIt(() => fake.calls == 2, reason: 'summarizer called');
    await waitForIt(() => io.out.toString().contains('[auto-compacted]'));
    io.sendLine('/exit');
    await run;

    final entries = await sessionEntries();
    expect(entries.whereType<CompactionRecord>(), hasLength(1));
  });

  test('/help lists the slash commands', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/help');
    await waitForIt(() => io.out.toString().contains('/compact'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    for (final command in [
      '/exit',
      '/reset',
      '/compact',
      '/stats',
      '/model',
      '/help',
    ]) {
      expect(output, contains(command));
    }
  });

  test('/settings prints the current settings summary in line mode', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/settings');
    await waitForIt(() => io.out.toString().contains('provider:'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('model:'));
    expect(output, contains('approval:'));
    expect(output, contains('mode:'));
    expect(output, contains('/provider'));
  });

  test('unknown slash commands show a filtered command menu', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/bogus');
    await waitForIt(
      () => io.out.toString().contains('unknown command: /bogus'),
    );
    io.sendLine('/exit');
    await run;
  });

  test('bare / shows a numbered command menu in line mode', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/');
    await waitForIt(
      () => io.out.toString().contains('[Commands]'),
      reason: 'menu appears',
    );
    await waitForIt(() => io.out.toString().contains('1) /exit'));
    // Pick the exit command by number.
    io.sendLine('1');
    await run;

    expect(io.out.toString(), contains('Pick a command'));
  });

  test('providerStreamFunction builds adapters and rejects unknown kinds', () {
    for (final kind in ['openai-completions', 'anthropic', 'google', 'dial']) {
      expect(providerStreamFunction(kind, 'k'), isA<StreamFunction>());
    }
    expect(
      () => providerStreamFunction('bogus', 'k'),
      throwsA(isA<ConfigException>()),
    );
  });

  test('renders tool errors and assistant errors', () async {
    final fake = FakeStreamFunction([
      toolTurn([
        ToolCall(
          id: 'c1',
          name: 'read',
          arguments: const {'path': 'missing.txt'},
        ),
      ]),
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'boom',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('[read] error:'));
    expect(output, contains('error: boom'));
    expect(cli.agent.state.model.id, 'test-model');
  });

  test('error lines render red when color is enabled', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'boom',
          ),
        ),
      ],
    ]);
    final cli = AgentCli(
      useColor: true,
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('\x1b[31merror: boom\x1b[0m'));
    // No-color mode (tests above) stays plain for stable assertions.
    expect(output, contains('error: boom'));
  });

  test('connection-refused error appends the endpoint hint (ClientException '
      'message shape)', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'Connection refused',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains(
        'error: Connection refused — check the endpoint in '
        '~/.fah/config.yaml (baseUrl: https://example.test) or pass '
        '--base-url',
      ),
    );
  });

  test('connection-refused error appends the endpoint hint (SocketException '
      'toString shape)', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage:
                'ClientException with SocketException: Connection refused '
                '(OS Error: Connection refused, errno = 61), address = '
                '127.0.0.1, port = 8932, '
                'uri=http://127.0.0.1:8932/v1/chat/completions',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains('check the endpoint in ~/.fah/config.yaml'),
    );
  });

  test('401 with a different stored key warns about env shadowing', () async {
    final cache = SecureKeyCache(FakeSecureKeyStore());
    await cache.probe();
    await cache.save('OPENAI_API_KEY', 'store-key');
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage:
                '401: The API Key appears to be invalid or may '
                'have expired.',
          ),
        ),
      ],
    ]);
    final cli = cliFor(
      fake.call,
      providerKind: 'openai',
      envVarIsSet: (name) => name == 'OPENAI_API_KEY',
      envVarValue: (name) => name == 'OPENAI_API_KEY' ? 'env-key' : null,
      secureKeys: cache,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('shadows a DIFFERENT key'));
    expect(output, contains('OPENAI_API_KEY'));
  });

  test('401 without a key suggests storing one', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: '401: Unauthorized',
          ),
        ),
      ],
    ]);
    final cli = cliFor(
      fake.call,
      providerKind: 'openai',
      envVarIsSet: (_) => false,
      envVarValue: (_) => null,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    // A custom endpoint suggests its endpoint-scoped store name (what
    // /provider writes), not the shared env name.
    expect(io.out.toString(), contains('/key set FA_KEY_EXAMPLE_TEST <value>'));
  });

  test('401 with a single-source key names its origin', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'authentication_error: invalid x-api-key',
          ),
        ),
      ],
    ]);
    final cli = cliFor(
      fake.call,
      providerKind: 'openai',
      envVarIsSet: (name) => name == 'OPENAI_API_KEY',
      envVarValue: (name) => name == 'OPENAI_API_KEY' ? 'env-key' : null,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains('the key came from the environment (OPENAI_API_KEY)'),
    );
  });

  test('401 with a store-only key names the store', () async {
    final cache = SecureKeyCache(FakeSecureKeyStore());
    await cache.probe();
    await cache.save('OPENAI_API_KEY', 'store-key');
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage:
                '401: The API Key appears to be invalid or may '
                'have expired.',
          ),
        ),
      ],
    ]);
    final cli = cliFor(
      fake.call,
      providerKind: 'openai',
      envVarIsSet: (name) => name == 'OPENAI_API_KEY',
      envVarValue: (name) => name == 'OPENAI_API_KEY' ? cache.read(name) : null,
      secureKeys: cache,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains('the key came from the fake store (OPENAI_API_KEY)'),
    );
  });

  test('non-auth errors get no key hint', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'boom',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call, providerKind: 'openai');
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, isNot(contains('/key set')));
    expect(output, isNot(contains('shadows')));
  });

  test('non-connection errors get no endpoint hint', () async {
    final fake = FakeStreamFunction([
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: '401: Unauthorized',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('error: 401: Unauthorized'));
    expect(output, isNot(contains('check the endpoint')));
  });

  test('renders unserializable tool args safely', () async {
    final fake = FakeStreamFunction([
      toolTurn([
        ToolCall(id: 'c1', name: 'ls', arguments: {'weird': Object()}),
      ]),
      textTurn('ok'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(io.out.toString(), contains('[ls] weird=[unserializable]'));
  });

  test('/compact on an empty session reports nothing to compact', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/compact');
    await waitForIt(() => io.out.toString().contains('nothing to compact'));
    io.sendLine('/exit');
    await run;
  });

  test('compaction failure is reported and history is kept', () async {
    final fake = FakeStreamFunction([
      textTurn('answer'),
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'summary failed',
          ),
        ),
      ],
      textTurn('after'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/compact');
    await waitForIt(() => io.out.toString().contains('compaction failed'));
    io.sendLine('next');
    await waitForIt(() => fake.calls == 3 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    // History was not rewritten: the next prompt still starts with 'q'.
    final first = fake.contexts[2].messages.first as UserMessage;
    expect(first.content, 'q');
    final entries = await sessionEntries();
    expect(entries.whereType<CompactionRecord>(), isEmpty);
  });

  test('registers the checkpoint and rewind tools', () {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final names = cli.agent.state.tools.map((t) => t.name);
    expect(names, containsAll(['checkpoint', 'rewind']));
  });

  test(
    'checkpoint/rewind flow prunes context and preserves the tree',
    () async {
      await env.writeFile('notes.txt', 'data');
      const report = 'FINDINGS: notes.txt holds data.';
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'checkpoint',
            arguments: const {'goal': 'probe notes'},
          ),
        ]),
        toolTurn([
          ToolCall(
            id: 'c2',
            name: 'read',
            arguments: const {'path': 'notes.txt'},
          ),
        ]),
        toolTurn([
          ToolCall(
            id: 'c3',
            name: 'rewind',
            arguments: const {'report': report},
          ),
        ]),
        // A tool call AFTER the rewind: the swapped context must accept
        // appended tool results (the unmodifiable-view regression).
        toolTurn([
          ToolCall(
            id: 'c4',
            name: 'read',
            arguments: const {'path': 'notes.txt'},
          ),
        ]),
        textTurn('wrapping up'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(() => fake.calls == 5 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      // Live context: checkpoint prefix + verbatim report + post-rewind
      // tool turn + final answer.
      final messages = cli.agent.state.messages;
      expect(messages, hasLength(7));
      expect((messages[3] as UserMessage).content, report);
      expect(
        io.out.toString(),
        isNot(contains('Cannot add to an unmodifiable list')),
      );

      // The session tree carries the mark, the branch summary, the hidden
      // rewind report, and the abandoned detour.
      final entries = await sessionEntries();
      expect(entries.whereType<CheckpointRecord>(), hasLength(1));
      final branchSummary = entries.whereType<BranchSummaryRecord>().single;
      expect(branchSummary.summary, report);
      final rewindReport = entries.whereType<CustomMessageRecord>().single;
      expect(rewindReport.customType, 'rewind-report');
      expect(rewindReport.content, report);
      final readResult = entries
          .whereType<MessageRecord>()
          .map((e) => e.message)
          .whereType<ToolResultMessage>()
          .firstWhere((m) => m.toolName == 'read');
      expect(readResult.isError, isFalse);
      expect(io.out.toString(), contains('[rewind] done'));
    },
  );

  test(
    'a second rewind after a completed one guides without a Bad state crash',
    () async {
      await env.writeFile('notes.txt', 'data');
      const report = 'FINDINGS: notes.txt holds data.';
      final fake = FakeStreamFunction([
        toolTurn([ToolCall(id: 'c1', name: 'checkpoint', arguments: const {})]),
        toolTurn([
          ToolCall(
            id: 'c2',
            name: 'rewind',
            arguments: const {'report': report},
          ),
        ]),
        toolTurn([
          ToolCall(
            id: 'c3',
            name: 'rewind',
            arguments: const {'report': 'again'},
          ),
        ]),
        textTurn('moving on'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(() => fake.calls == 4 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, isNot(contains('Bad state')));
      // The result is not an error: the run continued normally.
      expect(output, contains('moving on'));
      final toolResults = (await sessionEntries())
          .whereType<MessageRecord>()
          .map((e) => e.message)
          .whereType<ToolResultMessage>()
          .toList();
      final secondRewind = toolResults.last;
      expect(secondRewind.isError, isFalse);
      expect(
        secondRewind.content.whereType<TextContent>().single.text,
        contains('already rewound'),
      );
    },
  );

  test('/reset clears the active checkpoint', () async {
    final fake = FakeStreamFunction([
      toolTurn([ToolCall(id: 'c1', name: 'checkpoint', arguments: const {})]),
      textTurn('ok'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    expect(cli.checkpoints.activeCheckpoint, isNotNull);
    io.sendLine('/reset');
    await waitForIt(() => io.out.toString().contains('new session started'));
    expect(cli.checkpoints.activeCheckpoint, isNull);
    io.sendLine('/exit');
    await run;
  });

  test(
    '! command runs a shell command and prints stdout/stderr/exit code',
    () async {
      final shell = FakeShell(stdout: 'hello\n', stderr: 'oops', exitCode: 2);
      final shellEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final fake = FakeStreamFunction([]);
      final cli = cliFor(fake.call, envOverride: shellEnv);
      final run = cli.run();

      io.sendLine('!echo hi');
      await waitForIt(() => io.out.toString().contains('exit code: 2'));
      io.sendLine('/exit');
      await run;

      expect(shell.commands, ['echo hi']);
      final output = io.out.toString();
      expect(output, contains('hello'));
      expect(output, contains('oops'));
      expect(output, contains('exit code: 2'));
    },
  );

  test(
    'bash tool executions carry FAH_ session env vars (no secrets)',
    () async {
      final shell = FakeShell(stdout: 'ok');
      final shellEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(id: 'c1', name: 'bash', arguments: const {'command': 'env'}),
        ]),
        textTurn('done'),
      ]);
      final cli = cliFor(fake.call, envOverride: shellEnv);
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(() => fake.calls == 2 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final envVars = shell.lastOptions?.env;
      expect(envVars, isNotNull);
      expect(envVars![sessionIdEnvVar], isNotEmpty);
      expect(envVars[sessionFileEnvVar], endsWith('.jsonl'));
      expect(envVars[sessionFileEnvVar], contains(envVars[sessionIdEnvVar]));
      expect(envVars[providerEnvVar], 'openai-completions');
      expect(envVars[modelEnvVar], testModel.id);
      // The vars are correlation data only — never the API key.
      for (final value in envVars.values) {
        expect(value, isNot(contains('test-key')));
      }
    },
  );

  test('status line is printed before idle prompts after a run', () async {
    const usage = Usage(
      input: 10,
      output: 5,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 15,
      cost: UsageCost(input: 0.0006, output: 0.0004, total: 0.001),
    );
    final fake = FakeStreamFunction([textTurn('hi', usage: usage)]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(
      output,
      contains(
        '/work · ctx 0% (10/100k) · 15tok · \$0.0010 · turn 1 · test-model',
      ),
    );
  });

  test('status line keeps the last real usage after a failed run', () async {
    const usage = Usage(
      input: 10,
      output: 5,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 15,
      cost: UsageCost(input: 0.0006, output: 0.0004, total: 0.001),
    );
    final fake = FakeStreamFunction([
      textTurn('hi', usage: usage),
      [
        StartEvent(partial: testAssistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'boom',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('q2');
    await waitForIt(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    // The failed run's terminal message carries Usage.zero; the ctx gauge
    // must keep the last real prompt size, not snap back to (0/...).
    final output = io.out.toString();
    final lastCtx = output.lastIndexOf('ctx 0% (');
    expect(lastCtx, isNonNegative);
    expect(output.substring(lastCtx), startsWith('ctx 0% (10/100k)'));
  });

  group('session management', () {
    test('--session creates and resumes a named session', () async {
      final fake = FakeStreamFunction([textTurn('hello')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'work',
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      expect(sessions, hasLength(1));
      final session = await repo.open(sessions.first);
      expect(await session.getSessionName(), 'work');

      final io2 = FakeCliIO();
      addTearDown(io2.close);
      final fake2 = FakeStreamFunction([textTurn('again')]);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'work',
        ),
        io: io2,
        streamFunction: fake2.call,
      );
      final run2 = cli2.run();
      // The resumed session replays its transcript after the banner.
      await waitForIt(
        () => io2.out.toString().contains('restored session: work'),
      );
      io2.sendLine('continue');
      await waitForIt(() => fake2.calls == 1 && !cli2.isBusy);
      io2.sendLine('/exit');
      await run2;

      final replay = io2.out.toString();
      expect(replay, contains('hello'));

      final messages = fake2.contexts.single.messages;
      expect(messages, hasLength(3));
      expect(messages[0], isA<UserMessage>());
      expect(messages[1], isA<AssistantMessage>());
      expect(messages[2], isA<UserMessage>());
    });

    test('slash commands create, rename, list, and switch sessions', () async {
      final fake = FakeStreamFunction([]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/session-new alpha');
      await waitForIt(
        () => io.out.toString().contains("created session 'alpha'"),
      );
      io.sendLine('/rename-session beta');
      await waitForIt(
        () => io.out.toString().contains("renamed current session to 'beta'"),
      );
      io.sendLine('/sessions');
      await waitForIt(
        () => io.out.toString().contains('rename: /rename-session'),
      );
      io.sendLine('/session gamma');
      await waitForIt(
        () => io.out.toString().contains("created session 'gamma'"),
      );
      io.sendLine('/session');
      await waitForIt(() => io.out.toString().contains('session: gamma'));
      expect(io.out.toString(), contains('rename: /rename-session'));
      io.sendLine('/exit');
      await run;

      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      // Startup session + alpha (renamed to beta) + gamma.
      expect(sessions, hasLength(3));
      final names = <String?>[];
      for (final metadata in sessions) {
        final s = await repo.open(metadata);
        names.add(await s.getSessionName());
      }
      expect(names, containsAll(['beta', 'gamma']));
    });

    test('switching back to a session replays its transcript', () async {
      final fake = FakeStreamFunction([
        textTurn('first-answer'),
        textTurn('second-answer'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/session alpha');
      await waitForIt(
        () => io.out.toString().contains("created session 'alpha'"),
      );
      io.sendLine('one');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/session beta');
      await waitForIt(
        () => io.out.toString().contains("created session 'beta'"),
      );
      io.sendLine('two');
      await waitForIt(() => fake.calls == 2 && !cli.isBusy);
      io.sendLine('/session alpha');
      await waitForIt(
        () => io.out.toString().contains('restored session: alpha'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('you: one'));
      expect(output, contains('first-answer'));
      expect(output, isNot(contains('you: two')));
    });

    test(
      'a restored session replays the full transcript, not just the tail',
      () async {
        final fake = FakeStreamFunction([
          for (var i = 1; i <= 6; i++) textTurn('a$i'),
        ]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        io.sendLine('/session alpha');
        await waitForIt(
          () => io.out.toString().contains("created session 'alpha'"),
        );
        for (var i = 1; i <= 6; i++) {
          io.sendLine('q$i');
          await waitForIt(() => fake.calls == i && !cli.isBusy);
        }
        io.sendLine('/session beta');
        await waitForIt(
          () => io.out.toString().contains("created session 'beta'"),
        );
        io.sendLine('/session alpha');
        await waitForIt(
          () => io.out.toString().contains('restored session: alpha'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        // 6 user + 6 assistant messages — all of them, including the oldest.
        expect(output, contains('restored session: alpha (12 messages)'));
        expect(output, contains('you: q1'));
        expect(output, contains('you: q6'));
      },
    );

    test('consecutive tool-call turns collapse into one replay row', () async {
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'read',
            arguments: const {'path': 'missing.txt'},
          ),
        ]),
        textTurn('done'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/session alpha');
      await waitForIt(
        () => io.out.toString().contains("created session 'alpha'"),
      );
      io.sendLine('go');
      await waitForIt(() => fake.calls == 2 && !cli.isBusy);
      io.sendLine('/session beta');
      await waitForIt(
        () => io.out.toString().contains("created session 'beta'"),
      );
      io.sendLine('/session alpha');
      await waitForIt(
        () => io.out.toString().contains('restored session: alpha'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      final collapsed = RegExp(r'^fa:  \[read\]$', multiLine: true);
      expect(collapsed.allMatches(output), hasLength(1));
      expect(output, contains('fa:  done'));
    });

    test('tool results do not break a collapsing tool-call run', () async {
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'read',
            arguments: const {'path': 'missing.txt'},
          ),
        ]),
        toolTurn([
          ToolCall(
            id: 'c2',
            name: 'edit',
            arguments: const {'path': 'missing.txt', 'patch': ''},
          ),
        ]),
        textTurn('done'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/session alpha');
      await waitForIt(
        () => io.out.toString().contains("created session 'alpha'"),
      );
      io.sendLine('go');
      await waitForIt(() => fake.calls == 3 && !cli.isBusy);
      io.sendLine('/session beta');
      await waitForIt(
        () => io.out.toString().contains("created session 'beta'"),
      );
      io.sendLine('/session alpha');
      await waitForIt(
        () => io.out.toString().contains('restored session: alpha'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // assistant([read]), result, assistant([edit]), result collapse into
      // ONE run row — the tool results between them stay invisible.
      final run_row = RegExp(r'^fa:  \[read\] \[edit\]$', multiLine: true);
      expect(run_row.allMatches(output), hasLength(1));
      expect(
        RegExp(r'^fa:  \[edit\]$', multiLine: true).allMatches(output),
        isEmpty,
      );
    });

    test('exit prints the resume command for a named session', () async {
      final fake = FakeStreamFunction([textTurn('hi')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'work',
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('q');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        contains("resume this session with: fa --session 'work'"),
      );
    });

    test(
      'exit prints the resume command and the id resumes the session',
      () async {
        final fake = FakeStreamFunction([textTurn('memorable-answer')]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        io.sendLine('q');
        await waitForIt(() => fake.calls == 1 && !cli.isBusy);
        io.sendLine('/exit');
        await run;

        // Unnamed session: the hint carries the session id.
        final hint = RegExp(
          r"resume this session with: fa --session '([0-9a-f-]+)'",
        ).firstMatch(io.out.toString());
        expect(hint, isNotNull);
        final id = hint!.group(1)!;

        // `fa --session '<id>'` picks the same session back up.
        final io2 = FakeCliIO();
        final fake2 = FakeStreamFunction([textTurn('again')]);
        final cli2 = AgentCli(
          config: AgentCliConfig(
            model: testModel,
            apiKey: 'test-key',
            env: env,
            sessionRoot: '/sessions',
            sessionName: id,
          ),
          io: io2,
          streamFunction: fake2.call,
        );
        final run2 = cli2.run();
        io2.sendLine('/exit');
        await run2;

        expect(io2.out.toString(), contains('restored session'));
        expect(io2.out.toString(), contains('memorable-answer'));
      },
    );

    test('no resume hint when the session has nothing persisted', () async {
      final fake = FakeStreamFunction([textTurn('unused')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), isNot(contains('resume this session with')));
    });

    test('headless --session resumes a named session', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'h',
        ),
        io: io,
        streamFunction: fake.call,
      );
      expect(await cli.runHeadless('first'), 0);

      final fake2 = FakeStreamFunction([textTurn('again')]);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'h',
        ),
        io: io,
        streamFunction: fake2.call,
      );
      expect(await cli2.runHeadless('second'), 0);

      final messages = fake2.contexts.single.messages;
      expect(messages, hasLength(3));
      expect(messages[0], isA<UserMessage>());
      expect(messages[1], isA<AssistantMessage>());
      expect(messages[2], isA<UserMessage>());
    });

    test('/resume reports when already on the latest session', () async {
      final fake = FakeStreamFunction([textTurn('hello')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final io2 = FakeCliIO();
      addTearDown(io2.close);
      final fake2 = FakeStreamFunction([textTurn('again')]);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
        ),
        io: io2,
        streamFunction: fake2.call,
      );
      final run2 = cli2.run();
      await waitForIt(() => io2.out.toString().contains('fa'));
      // The startup session is newer than the first run's, so /resume is
      // already there.
      io2.sendLine('/resume');
      await waitForIt(
        () => io2.out.toString().contains('already on the latest session'),
      );
      io2.sendLine('/exit');
      await run2;
    });

    test('/skills lists the discovered skills', () async {
      await env.createDir('/work/.git');
      await env.createDir('/work/.fah/skills/deploy');
      await env.writeFile(
        '/work/.fah/skills/deploy/SKILL.md',
        '---\nname: deploy\ndescription: Deploy the app\n---\n'
            'Deploy body here.\n',
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(() => cli.systemPrompt.contains('<name>deploy</name>'));
      io.sendLine('/skills');
      await waitForIt(() => io.out.toString().contains('skills:'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('deploy — Deploy the app'));
      expect(output, contains('/work/.fah/skills/deploy/SKILL.md (project)'));
    });
  });
}
