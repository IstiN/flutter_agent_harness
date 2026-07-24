import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// A catalog-backed cloud model, for the banner's key-status line.
const _cloudModel = Model(
  id: 'claude-sonnet-4-5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  contextWindow: 200000,
  maxTokens: 8192,
);

/// A model on a custom endpoint: the provider flips to `openai` (see
/// `buildCliDefaultModel`) while the key lookup stays by provider kind.
const _customEndpointModel = Model(
  id: 'local-model',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'http://127.0.0.1:8932',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage? usage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage ?? Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text, {Usage? usage}) {
  final empty = _assistant();
  final partial = _assistant(
    content: [TextContent(text: text)],
    usage: usage,
  );
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// Scripted [StreamFunction] replaying pre-recorded turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];
  final models = <Model>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    models.add(model);
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [StreamFunction] turn that hangs until cancelled, then reports aborted.
class _AbortableStreamFunction {
  var started = false;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    started = true;
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: _assistant()));
    cancelToken?.onCancel.then((_) {
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: _assistant(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream;
  }
}

/// A [Shell] that blocks until [release] completes the gate.
class _GatedShell implements Shell {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

/// A [Shell] that echoes the command and returns canned output.
class _FakeShell implements Shell {
  _FakeShell({this.stdout = '', this.stderr = '', this.exitCode = 0});

  final String stdout;
  final String stderr;
  final int exitCode;
  final commands = <String>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    return Ok(
      ShellExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode),
    );
  }
}

/// In-memory [CliIO]: scripted input lines, captured output.
class FakeCliIO implements CliIO {
  @override
  int columns = 80;

  @override
  int rows = 24;

  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  /// Tests flip this to exercise the non-interactive approval path.
  @override
  bool isInteractive = true;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  bool get supportsRawMode => true;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  void sendKey(KeyEvent key) => _keys.add(key);

  void interrupt() => _interrupts.add(null);

  Future<void> close() async {
    // The close future only completes once a listener received the done
    // event; tests that never ran the CLI have no listener, so don't await.
    unawaited(_lines.close());
    unawaited(_keys.close());
    await _interrupts.close();
  }
}

/// In-memory [SecureKeyStore] with a toggleable availability flag.
class _FakeSecureKeyStore implements SecureKeyStore {
  _FakeSecureKeyStore({this.available = true});

  bool available;
  bool failWrites = false;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    if (failWrites) throw StateError('keychain write failed (exit 45)');
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

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
    Model model = _model,
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
    'default system prompt uses fah branding and forbids pi/Claude names',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final cli = cliFor(fake.call);
      final prompt = cli.systemPrompt;
      expect(prompt, contains('You are fah'));
      expect(prompt, contains('also called fa'));
      expect(
        prompt.toLowerCase(),
        contains('never refer to yourself as pi, claude'),
      );
    },
  );

  test('registers inspect_image tool when visionConfig is provided', () {
    final fake = _FakeStreamFunction([]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: _model,
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
    final fake = _FakeStreamFunction([]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: _model,
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
    final fake = _FakeStreamFunction([_textTurn('Hello world')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('hi');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
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
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      model: _cloudModel,
      providerKind: 'anthropic',
      envVarIsSet: (name) => name == 'ANTHROPIC_API_KEY',
    );
    final run = cli.run();

    await _waitFor(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('endpoint: https://api.anthropic.com'));
    expect(output, contains('key: ANTHROPIC_API_KEY'));
    expect(output, isNot(contains('no key set')));
  });

  test('banner warns when no key env var is set for the provider', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      model: _cloudModel,
      providerKind: 'anthropic',
      envVarIsSet: (_) => false,
    );
    final run = cli.run();

    await _waitFor(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains('key: no key set (want ANTHROPIC_API_KEY)'),
    );
  });

  test('banner has no key line for providers without key env vars', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call, providerKind: 'test-kind');
    final run = cli.run();

    await _waitFor(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('endpoint: https://example.test'));
    expect(output, isNot(contains('key:')));
  });

  test(
    'banner key status tracks the provider kind on custom endpoints',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        model: _customEndpointModel,
        envVarIsSet: (name) => name == 'OPENROUTER_API_KEY',
      );
      final run = cli.run();

      await _waitFor(() => io.out.toString().contains('[Model]'));
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
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      model: _customEndpointModel,
      envVarIsSet: (_) => false,
    );
    final run = cli.run();

    await _waitFor(() => io.out.toString().contains('[Model]'));
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
      final fake = _FakeStreamFunction([
        // 1. The parent delegates a background agent.
        _toolTurn([
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
        _textTurn('delegated the survey'),
        // 3. The background child agent produces its result.
        _textTurn('survey says: all quiet'),
        // 4. The async-result re-wake reacts to the injected notification.
        _textTurn('noted, survey integrated'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('delegate it');
      await _waitFor(() => fake.calls == 4 && !cli.isBusy);
      io.sendLine('/tasks');
      await _waitFor(() => io.out.toString().contains('background agents:'));
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
      final fake = _FakeStreamFunction([_textTurn('deploying now')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await _waitFor(
        () =>
            cli.systemPrompt.contains('follow the repo rules') &&
            cli.systemPrompt.contains('<name>deploy</name>'),
      );
      io.sendLine('/skill:deploy ship it');
      await _waitFor(() => fake.calls == 1 && !cli.isBusy);
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
    final fake = _FakeStreamFunction([
      _toolTurn([
        ToolCall(
          id: 'c1',
          name: 'read',
          arguments: const {'path': 'notes.txt'},
        ),
      ]),
      _textTurn('done reading'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('read it');
    await _waitFor(() => fake.calls == 2 && !cli.isBusy);
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
    final shell = _GatedShell();
    final gatedEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
    final fake = _FakeStreamFunction([
      _toolTurn([
        ToolCall(id: 'c1', name: 'bash', arguments: const {'command': 'sleep'}),
      ]),
      _textTurn('final'),
    ]);
    final cli = cliFor(fake.call, envOverride: gatedEnv);
    final run = cli.run();

    io.sendLine('run');
    await _waitFor(() => fake.calls == 1);
    // The bash tool is blocked on the gate, so the run is mid-flight.
    io.sendLine('steer me');
    shell.release();
    await _waitFor(() => fake.calls == 2 && !cli.isBusy);
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
    final fake = _AbortableStreamFunction();
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('long task');
    await _waitFor(() => fake.started);
    io.interrupt();
    await _waitFor(() => !cli.isBusy);
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
    final fake = _FakeStreamFunction([_textTurn('hi', usage: usage)]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/stats');
    await _waitFor(() => io.out.toString().contains('cost:'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('turns: 1'));
    expect(output, contains('input tokens: 10'));
    expect(output, contains('output tokens: 5'));
    expect(output, contains('total tokens: 15'));
    expect(output, contains(r'cost: $0.0010'));
  });

  test('/model prints and switches the model', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/model');
    await _waitFor(() => io.out.toString().contains('model: test-model'));
    io.sendLine('/model new-model');
    await _waitFor(
      () => io.out.toString().contains('switched model to new-model'),
    );
    io.sendLine('go');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(fake.models.single.id, 'new-model');
    expect(fake.contexts.single.systemPrompt, isNotNull);
  });

  test('/provider prints the active provider and the catalog', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/provider');
    await _waitFor(() => io.out.toString().contains('supported providers:'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('provider: test-provider (test-api)'));
    expect(output, contains('endpoint: https://example.test'));
    expect(output, contains('openrouter — https://openrouter.ai/api/v1'));
    expect(output, contains('anthropic — https://api.anthropic.com'));
    expect(output, contains('use /provider <name> [baseUrl] [token]'));
  });

  test('/provider <name> switches provider, endpoint, and env key', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      envVarValue: (name) => name == 'ANTHROPIC_API_KEY' ? 'env-key-123' : null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider anthropic');
    await _waitFor(
      () => io.out.toString().contains('switched provider to anthropic'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    final model = cli.agent.state.model;
    expect(model.provider, 'anthropic');
    expect(model.api, 'anthropic-messages');
    expect(model.baseUrl, 'https://api.anthropic.com');
    expect(model.id, 'test-model', reason: 'the model id is kept');
    expect(cli.providerKind, 'anthropic');
    expect(output, contains('endpoint: https://api.anthropic.com'));
    expect(output, contains('key: ANTHROPIC_API_KEY'));
    expect(output, isNot(contains('env-key-123')));
    expect(output, contains('model unchanged: test-model'));
    expect(changes, [('anthropic', 'env-key-123')]);
  });

  test('/provider with a custom baseUrl runs keyless', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1');
    await _waitFor(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    final model = cli.agent.state.model;
    expect(model.provider, 'openai');
    expect(model.api, 'openai-completions');
    expect(model.baseUrl, 'http://127.0.0.1:1/v1');
    expect(cli.providerKind, 'openai-completions');
    expect(output, contains('key: none (keyless endpoint)'));
    expect(changes, [('openai-completions', '')]);
  });

  test('/provider accepts an explicit session token', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1 tok-1234567890');
    await _waitFor(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('key: provided'));
    expect(output, isNot(contains('tok-1234567890')));
    expect(changes, [('openai-completions', 'tok-1234567890')]);
  });

  test('/provider rejects an unknown provider without state changes', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/provider bogus');
    await _waitFor(() => io.out.toString().contains('unknown provider: bogus'));
    io.sendLine('/provider a b c d');
    await _waitFor(() => io.out.toString().contains('usage: /provider <name>'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(
      output,
      contains('supported providers: openrouter, openai, anthropic, google'),
    );
    expect(cli.agent.state.model.provider, 'test-provider');
    expect(cli.providerKind, 'openai-completions');
  });

  test('/key lists key sources without exposing values', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final store = _FakeSecureKeyStore()
      ..map['GOOGLE_API_KEY'] = 'google-key-123';
    final cache = SecureKeyCache(store);
    await cache.preload(const ['GOOGLE_API_KEY']);
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      envVarIsSet: (name) => name == 'OPENROUTER_API_KEY',
    );
    final run = cli.run();

    io.sendLine('/key');
    await _waitFor(
      () => io.out.toString().contains('secure storage: fake store'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('OPENROUTER_API_KEY: env'));
    expect(output, contains('GOOGLE_API_KEY: fake store'));
    expect(output, contains('ANTHROPIC_API_KEY: not set'));
    expect(output, isNot(contains('google-key-123')));
  });

  test(
    '/key set stores, redacts, and updates the active provider key',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final store = _FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final stored = <(String, String)>[];
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        onSecretStored: (name, value) => stored.add((name, value)),
      );
      final run = cli.run();

      io.sendLine('/key set OPENAI_API_KEY sk-new-key-456');
      await _waitFor(
        () => io.out.toString().contains('saved OPENAI_API_KEY to fake store'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(store.map['OPENAI_API_KEY'], 'sk-new-key-456');
      expect(stored, [('OPENAI_API_KEY', 'sk-new-key-456')]);
      expect(output, isNot(contains('sk-new-key-456')));
      // openai-completions resolves OPENROUTER_API_KEY/OPENAI_API_KEY, so the
      // freshly stored key is picked up without a restart.
      expect(output, contains('active provider key updated'));
    },
  );

  test('/key set reports when secure storage is unavailable', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final store = _FakeSecureKeyStore(available: false);
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/key set OPENAI_API_KEY sk-new-key-456');
    await _waitFor(
      () => io.out.toString().contains('secure storage unavailable'),
    );
    io.sendLine('/exit');
    await run;

    expect(store.map, isEmpty);
  });

  test(
    '/key set reports a failing keychain write instead of crashing',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final store = _FakeSecureKeyStore()..failWrites = true;
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(fake.call, secureKeys: cache);
      final run = cli.run();

      io.sendLine('/key set OPENAI_API_KEY sk-new-key-456');
      await _waitFor(
        () => io.out.toString().contains('could not save OPENAI_API_KEY'),
      );
      io.sendLine('/exit');
      await run;

      expect(store.map, isEmpty);
    },
  );

  test(
    '/provider token falls back to session-only when the write fails',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final changes = <(String, String)>[];
      final store = _FakeSecureKeyStore()..failWrites = true;
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        onProviderChanged: (kind, key) => changes.add((kind, key)),
      );
      final run = cli.run();

      io.sendLine('/provider openai http://127.0.0.1:1/v1 sk-token-789');
      await _waitFor(
        () => io.out.toString().contains('could not save the key'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(store.map, isEmpty);
      // Session continues keyless-to-store but with the token live.
      expect(output, contains('key: provided'));
      expect(changes, [('openai-completions', 'sk-token-789')]);
    },
  );

  test('/key delete removes the stored key', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final store = _FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    await cache.save('OPENAI_API_KEY', 'sk-stored-key');
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/key delete OPENAI_API_KEY');
    await _waitFor(() => io.out.toString().contains('removed OPENAI_API_KEY'));
    io.sendLine('/exit');
    await run;

    expect(store.map, isEmpty);
    expect(cache.read('OPENAI_API_KEY'), isNull);
  });

  test('/key validates its arguments', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final store = _FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/key set ONLYNAME');
    await _waitFor(
      () => io.out.toString().contains('usage: /key set <NAME> <value>'),
    );
    io.sendLine('/key set bad-name! value');
    await _waitFor(
      () => io.out.toString().contains('invalid key name: bad-name!'),
    );
    io.sendLine('/key frobnicate');
    await _waitFor(() => io.out.toString().contains('usage: /key [set'));
    io.sendLine('/exit');
    await run;

    expect(store.map, isEmpty);
  });

  test('/provider persists the explicit token in the secure store', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final store = _FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1 sk-token-789');
    await _waitFor(() => io.out.toString().contains('saved to fake store'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(store.map['OPENAI_API_KEY'], 'sk-token-789');
    expect(
      output,
      contains(
        'key: provided (saved to fake store; '
        'remove with /key delete OPENAI_API_KEY)',
      ),
    );
    expect(output, isNot(contains('sk-token-789')));
  });

  test('/provider custom runs the guided openai-like setup', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    await _waitFor(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await _waitFor(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('http://127.0.0.1:1/v1');
    await _waitFor(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await _waitFor(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await _waitFor(
      () => io.out.toString().contains('no model list from the endpoint'),
    );
    io.sendLine('my-local-model');
    await _waitFor(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    final model = cli.agent.state.model;
    expect(model.provider, 'openai');
    expect(model.api, 'openai-completions');
    expect(model.id, 'my-local-model');
    expect(model.baseUrl, 'http://127.0.0.1:1/v1');
    expect(output, contains('model: my-local-model'));
    expect(output, contains('key: none (keyless endpoint)'));
    expect(changes, [('openai-completions', '')]);
  });

  test('/provider custom offers the endpoint model list', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => ['m1', 'm2'],
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    await _waitFor(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await _waitFor(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://proxy.example.com/v1');
    await _waitFor(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await _waitFor(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await _waitFor(() => io.out.toString().contains('2) m2'));
    io.sendLine('2');
    await _waitFor(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(cli.agent.state.model.id, 'm2');
    expect(output, contains('model: m2'));
  });

  test('/provider custom stores the typed key in the secure store', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final store = _FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    await _waitFor(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await _waitFor(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://proxy.example.com/v1');
    await _waitFor(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await _waitFor(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('sk-flow-key-1');
    await _waitFor(
      () => io.out.toString().contains('no model list from the endpoint'),
    );
    io.sendLine('proxy-model');
    await _waitFor(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(store.map['FA_KEY_PROXY_EXAMPLE_COM'], 'sk-flow-key-1');
    expect(output, contains('key: provided (saved to fake store'));
    expect(output, isNot(contains('sk-flow-key-1')));
  });

  test('/provider custom supports anthropic-like endpoints', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider custom');
    await _waitFor(() => io.out.toString().contains('type a number:'));
    io.sendLine('2');
    await _waitFor(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://anthropic-proxy.example.com');
    await _waitFor(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await _waitFor(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await _waitFor(() => io.out.toString().contains('model id (empty keeps'));
    io.sendLine('claude-proxy-model');
    await _waitFor(
      () => io.out.toString().contains('switched provider to anthropic'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, isNot(contains('fetching models from')));
    final model = cli.agent.state.model;
    expect(model.provider, 'anthropic');
    expect(model.api, 'anthropic-messages');
    expect(model.id, 'claude-proxy-model');
    expect(cli.providerKind, 'anthropic');
  });

  test('/provider custom validates the api type and base URL', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider custom extra');
    await _waitFor(() => io.out.toString().contains('usage: /provider custom'));
    io.sendLine('/provider custom');
    await _waitFor(() => io.out.toString().contains('type a number:'));
    io.sendLine('x');
    await _waitFor(() => io.out.toString().contains('invalid selection: x'));
    io.sendLine('1');
    await _waitFor(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('localhost:8080');
    await _waitFor(() => io.out.toString().contains('invalid base URL'));
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.provider, 'test-provider');
    expect(cli.providerKind, 'openai-completions');
  });

  test('/provider custom cancels on interrupt without state changes', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider custom');
    await _waitFor(() => io.out.toString().contains('type a number:'));
    io.interrupt();
    await _waitFor(
      () => io.out.toString().contains('custom provider setup cancelled'),
    );
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.provider, 'test-provider');
    expect(cli.providerKind, 'openai-completions');
  });

  test(
    '/provider custom consumes piped answers without leaking into runs',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final cli = cliFor(fake.call, envVarValue: (_) => null);
      final run = cli.run();

      // All answers arrive before the flow asks for them (piped stdin):
      // type, url, name (empty = default), key (empty = none), model.
      io
        ..sendLine('/provider custom')
        ..sendLine('1')
        ..sendLine('http://127.0.0.1:1/v1')
        ..sendLine('')
        ..sendLine('')
        ..sendLine('my-local-model');
      await _waitFor(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.id, 'my-local-model');
      expect(fake.calls, 0, reason: 'no answer may leak into a run');
    },
  );

  test(
    '/provider custom applies the spec default URL on an empty answer',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final cli = cliFor(fake.call, envVarValue: (_) => null);
      final run = cli.run();

      io.sendLine('/provider custom');
      await _waitFor(() => io.out.toString().contains('type a number:'));
      io.sendLine('1');
      await _waitFor(
        () => io.out.toString().contains('base URL (empty = https://'),
      );
      io.sendLine('');
      await _waitFor(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('');
      await _waitFor(
        () => io.out.toString().contains('API key (empty for none):'),
      );
      io.sendLine('');
      await _waitFor(
        () => io.out.toString().contains('no model list from the endpoint'),
      );
      io.sendLine('gpt-4o-mini');
      await _waitFor(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.baseUrl, 'https://api.openai.com/v1');
      expect(cli.agent.state.model.id, 'gpt-4o-mini');
    },
  );

  test(
    '/provider custom saves the provider and switching restores its model',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final registry = CustomProviderRegistry(const []);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => ['m1', 'm2'],
      );
      final run = cli.run();

      io.sendLine('/provider custom');
      await _waitFor(() => io.out.toString().contains('type a number:'));
      io.sendLine('1');
      await _waitFor(() => io.out.toString().contains('base URL (empty ='));
      io.sendLine('http://localhost:11434/v1');
      await _waitFor(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('my-ollama');
      await _waitFor(
        () => io.out.toString().contains('API key (empty for none):'),
      );
      io.sendLine('');
      await _waitFor(() => io.out.toString().contains('2) m2'));
      io.sendLine('2');
      await _waitFor(
        () => io.out.toString().contains('saved provider my-ollama'),
      );

      final entry = registry.entries.single;
      expect(entry.name, 'my-ollama');
      expect(entry.modelId, 'm2');
      expect(entry.baseUrl, 'http://localhost:11434/v1');

      // A catalog switch clears it; switching back by name restores m2.
      io.sendLine('/provider anthropic');
      await _waitFor(
        () => io.out.toString().contains('switched provider to anthropic'),
      );
      io.sendLine('/model other-model');
      await _waitFor(
        () => io.out.toString().contains('switched model to other-model'),
      );
      io.sendLine('/provider my-ollama');
      await _waitFor(() => cli.agent.state.model.id == 'm2');

      // Per-provider model memory: /model rewrites the entry.
      io.sendLine('/model llama3.2');
      await _waitFor(
        () => io.out.toString().contains('switched model to llama3.2'),
      );
      expect(registry.find('my-ollama')!.modelId, 'llama3.2');
      io.sendLine('/exit');
      await run;
    },
  );

  test('/provider-edit updates the active custom provider', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'localhost:11434',
        apiType: 'openai',
        baseUrl: 'http://localhost:11434/v1',
        modelId: 'old-model',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
      modelsFetcher: (baseUrl, {required apiKey}) async => [
        'new-model',
        'old-model',
      ],
    );
    final run = cli.run();

    io.sendLine('/provider localhost:11434');
    await _waitFor(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/provider-edit');
    await _waitFor(
      () => io.out.toString().contains('editing provider localhost:11434'),
    );
    io.sendLine('1');
    await _waitFor(
      () => io.out.toString().contains(
        'base URL (empty = http://localhost:11434/v1)',
      ),
    );
    io.sendLine('');
    await _waitFor(
      () =>
          io.out.toString().contains('provider name (empty = localhost:11434)'),
    );
    io.sendLine('renamed-ollama');
    await _waitFor(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await _waitFor(() => io.out.toString().contains('1) new-model'));
    io.sendLine('1');
    await _waitFor(() => cli.agent.state.model.id == 'new-model');
    io.sendLine('/exit');
    await run;

    expect(registry.find('localhost:11434'), isNull);
    final entry = registry.entries.single;
    expect(entry.name, 'renamed-ollama');
    expect(entry.modelId, 'new-model');
    expect(entry.baseUrl, 'http://localhost:11434/v1');
  });

  test('/reset starts a fresh session and clears history', () async {
    final fake = _FakeStreamFunction([_textTurn('first'), _textTurn('second')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('one');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/reset');
    await _waitFor(() => io.out.toString().contains('new session started'));
    io.sendLine('two');
    await _waitFor(() => fake.calls == 2 && !cli.isBusy);
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
    final fake = _FakeStreamFunction([
      _textTurn('answer'),
      _textTurn('SUMMARY'),
      _textTurn('after'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/compact');
    await _waitFor(() => fake.calls == 2, reason: 'summarizer called');
    await _waitFor(() => io.out.toString().contains('[compacted]'));
    io.sendLine('next');
    await _waitFor(() => fake.calls == 3 && !cli.isBusy);
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
    final fake = _FakeStreamFunction([
      _textTurn('a reasonably long answer that exceeds the tiny window'),
      _textTurn('AUTO SUMMARY'),
    ]);
    final cli = cliFor(fake.call, model: tinyWindow);
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => fake.calls == 2, reason: 'summarizer called');
    await _waitFor(() => io.out.toString().contains('[auto-compacted]'));
    io.sendLine('/exit');
    await run;

    final entries = await sessionEntries();
    expect(entries.whereType<CompactionRecord>(), hasLength(1));
  });

  test('/help lists the slash commands', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/help');
    await _waitFor(() => io.out.toString().contains('/compact'));
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

  test('unknown slash commands show a filtered command menu', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/bogus');
    await _waitFor(() => io.out.toString().contains('unknown command: /bogus'));
    io.sendLine('/exit');
    await run;
  });

  test('bare / shows a numbered command menu in line mode', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/');
    await _waitFor(
      () => io.out.toString().contains('[Commands]'),
      reason: 'menu appears',
    );
    await _waitFor(() => io.out.toString().contains('1) /exit'));
    // Pick the exit command by number.
    io.sendLine('1');
    await run;

    expect(io.out.toString(), contains('Pick a command'));
  });

  test('providerStreamFunction builds adapters and rejects unknown kinds', () {
    for (final kind in ['openai-completions', 'anthropic', 'google']) {
      expect(providerStreamFunction(kind, 'k'), isA<StreamFunction>());
    }
    expect(
      () => providerStreamFunction('bogus', 'k'),
      throwsA(isA<ConfigException>()),
    );
  });

  test('renders tool errors and assistant errors', () async {
    final fake = _FakeStreamFunction([
      _toolTurn([
        ToolCall(
          id: 'c1',
          name: 'read',
          arguments: const {'path': 'missing.txt'},
        ),
      ]),
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(stopReason: StopReason.error, errorMessage: 'boom'),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await _waitFor(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('[read] error:'));
    expect(output, contains('error: boom'));
    expect(cli.agent.state.model.id, 'test-model');
  });

  test('error lines render red when color is enabled', () async {
    final fake = _FakeStreamFunction([
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(stopReason: StopReason.error, errorMessage: 'boom'),
        ),
      ],
    ]);
    final cli = AgentCli(
      useColor: true,
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();

    io.sendLine('go');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('\x1b[31merror: boom\x1b[0m'));
    // No-color mode (tests above) stays plain for stable assertions.
    expect(output, contains('error: boom'));
  });

  test('connection-refused error appends the endpoint hint (ClientException '
      'message shape)', () async {
    final fake = _FakeStreamFunction([
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(
            stopReason: StopReason.error,
            errorMessage: 'Connection refused',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
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
    final fake = _FakeStreamFunction([
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(
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
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains('check the endpoint in ~/.fah/config.yaml'),
    );
  });

  test('non-connection errors get no endpoint hint', () async {
    final fake = _FakeStreamFunction([
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(
            stopReason: StopReason.error,
            errorMessage: '401: Unauthorized',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('error: 401: Unauthorized'));
    expect(output, isNot(contains('check the endpoint')));
  });

  test('renders unserializable tool args safely', () async {
    final fake = _FakeStreamFunction([
      _toolTurn([
        ToolCall(id: 'c1', name: 'ls', arguments: {'weird': Object()}),
      ]),
      _textTurn('ok'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await _waitFor(() => fake.calls == 2 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(io.out.toString(), contains('[ls] weird=[unserializable]'));
  });

  test('/compact on an empty session reports nothing to compact', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/compact');
    await _waitFor(() => io.out.toString().contains('nothing to compact'));
    io.sendLine('/exit');
    await run;
  });

  test('compaction failure is reported and history is kept', () async {
    final fake = _FakeStreamFunction([
      _textTurn('answer'),
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(
            stopReason: StopReason.error,
            errorMessage: 'summary failed',
          ),
        ),
      ],
      _textTurn('after'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/compact');
    await _waitFor(() => io.out.toString().contains('compaction failed'));
    io.sendLine('next');
    await _waitFor(() => fake.calls == 3 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    // History was not rewritten: the next prompt still starts with 'q'.
    final first = fake.contexts[2].messages.first as UserMessage;
    expect(first.content, 'q');
    final entries = await sessionEntries();
    expect(entries.whereType<CompactionRecord>(), isEmpty);
  });

  test('registers the checkpoint and rewind tools', () {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final names = cli.agent.state.tools.map((t) => t.name);
    expect(names, containsAll(['checkpoint', 'rewind']));
  });

  test(
    'checkpoint/rewind flow prunes context and preserves the tree',
    () async {
      await env.writeFile('notes.txt', 'data');
      const report = 'FINDINGS: notes.txt holds data.';
      final fake = _FakeStreamFunction([
        _toolTurn([
          ToolCall(
            id: 'c1',
            name: 'checkpoint',
            arguments: const {'goal': 'probe notes'},
          ),
        ]),
        _toolTurn([
          ToolCall(
            id: 'c2',
            name: 'read',
            arguments: const {'path': 'notes.txt'},
          ),
        ]),
        _toolTurn([
          ToolCall(
            id: 'c3',
            name: 'rewind',
            arguments: const {'report': report},
          ),
        ]),
        // A tool call AFTER the rewind: the swapped context must accept
        // appended tool results (the unmodifiable-view regression).
        _toolTurn([
          ToolCall(
            id: 'c4',
            name: 'read',
            arguments: const {'path': 'notes.txt'},
          ),
        ]),
        _textTurn('wrapping up'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('go');
      await _waitFor(() => fake.calls == 5 && !cli.isBusy);
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
      final fake = _FakeStreamFunction([
        _toolTurn([
          ToolCall(id: 'c1', name: 'checkpoint', arguments: const {}),
        ]),
        _toolTurn([
          ToolCall(
            id: 'c2',
            name: 'rewind',
            arguments: const {'report': report},
          ),
        ]),
        _toolTurn([
          ToolCall(
            id: 'c3',
            name: 'rewind',
            arguments: const {'report': 'again'},
          ),
        ]),
        _textTurn('moving on'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('go');
      await _waitFor(() => fake.calls == 4 && !cli.isBusy);
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
    final fake = _FakeStreamFunction([
      _toolTurn([ToolCall(id: 'c1', name: 'checkpoint', arguments: const {})]),
      _textTurn('ok'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('go');
    await _waitFor(() => fake.calls == 2 && !cli.isBusy);
    expect(cli.checkpoints.activeCheckpoint, isNotNull);
    io.sendLine('/reset');
    await _waitFor(() => io.out.toString().contains('new session started'));
    expect(cli.checkpoints.activeCheckpoint, isNull);
    io.sendLine('/exit');
    await run;
  });

  test(
    '! command runs a shell command and prints stdout/stderr/exit code',
    () async {
      final shell = _FakeShell(stdout: 'hello\n', stderr: 'oops', exitCode: 2);
      final shellEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final fake = _FakeStreamFunction([]);
      final cli = cliFor(fake.call, envOverride: shellEnv);
      final run = cli.run();

      io.sendLine('!echo hi');
      await _waitFor(() => io.out.toString().contains('exit code: 2'));
      io.sendLine('/exit');
      await run;

      expect(shell.commands, ['echo hi']);
      final output = io.out.toString();
      expect(output, contains('hello'));
      expect(output, contains('oops'));
      expect(output, contains('exit code: 2'));
    },
  );

  test('/models lists known models for the active provider', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: _cloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/models');
    await _waitFor(() => io.out.toString().contains('claude-sonnet-4-5'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('models for anthropic:'));
    expect(output, contains('1) claude-sonnet-4-5'));
    expect(output, contains('use /model <n> or /model <id> to switch'));
  });

  test('/models filters known models by substring', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: _cloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/models opus');
    await _waitFor(() => io.out.toString().contains('claude-opus-4'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('1) claude-opus-4'));
    expect(output, isNot(contains('claude-haiku-4')));
  });

  test('/model picker lets the user switch by number', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: _cloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/model ?');
    await _waitFor(() => io.out.toString().contains('use /model <n>'));
    io.sendLine('/model 2');
    await _waitFor(
      () => io.out.toString().contains('switched model to claude-opus-4'),
    );
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.id, 'claude-opus-4');
  });

  test('status line is printed before idle prompts after a run', () async {
    const usage = Usage(
      input: 10,
      output: 5,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 15,
      cost: UsageCost(input: 0.0006, output: 0.0004, total: 0.001),
    );
    final fake = _FakeStreamFunction([_textTurn('hi', usage: usage)]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => fake.calls == 1 && !cli.isBusy);
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

  group('session management', () {
    test('--session creates and resumes a named session', () async {
      final fake = _FakeStreamFunction([_textTurn('hello')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _model,
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
      await _waitFor(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      expect(sessions, hasLength(1));
      final session = await repo.open(sessions.first);
      expect(await session.getSessionName(), 'work');

      final io2 = FakeCliIO();
      addTearDown(io2.close);
      final fake2 = _FakeStreamFunction([_textTurn('again')]);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: _model,
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
      await _waitFor(
        () => io2.out.toString().contains('restored session: work'),
      );
      io2.sendLine('continue');
      await _waitFor(() => fake2.calls == 1 && !cli2.isBusy);
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
      final fake = _FakeStreamFunction([]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/session-new alpha');
      await _waitFor(
        () => io.out.toString().contains("created session 'alpha'"),
      );
      io.sendLine('/rename-session beta');
      await _waitFor(
        () => io.out.toString().contains("renamed current session to 'beta'"),
      );
      io.sendLine('/sessions');
      await _waitFor(
        () => io.out.toString().contains('rename: /rename-session'),
      );
      io.sendLine('/session gamma');
      await _waitFor(
        () => io.out.toString().contains("created session 'gamma'"),
      );
      io.sendLine('/session');
      await _waitFor(() => io.out.toString().contains('session: gamma'));
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
      final fake = _FakeStreamFunction([
        _textTurn('first-answer'),
        _textTurn('second-answer'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/session alpha');
      await _waitFor(
        () => io.out.toString().contains("created session 'alpha'"),
      );
      io.sendLine('one');
      await _waitFor(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/session beta');
      await _waitFor(
        () => io.out.toString().contains("created session 'beta'"),
      );
      io.sendLine('two');
      await _waitFor(() => fake.calls == 2 && !cli.isBusy);
      io.sendLine('/session alpha');
      await _waitFor(
        () => io.out.toString().contains('restored session: alpha'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('you: one'));
      expect(output, contains('first-answer'));
      expect(output, isNot(contains('you: two')));
    });

    test('headless --session resumes a named session', () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _model,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'h',
        ),
        io: io,
        streamFunction: fake.call,
      );
      expect(await cli.runHeadless('first'), 0);

      final fake2 = _FakeStreamFunction([_textTurn('again')]);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: _model,
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
  });
}
