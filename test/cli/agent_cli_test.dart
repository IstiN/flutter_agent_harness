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
  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final out = StringBuffer();

  /// Tests flip this to exercise the non-interactive approval path.
  @override
  bool isInteractive = true;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  void interrupt() => _interrupts.add(null);

  Future<void> close() async {
    // The close future only completes once a listener received the done
    // event; tests that never ran the CLI have no listener, so don't await.
    unawaited(_lines.close());
    await _interrupts.close();
  }
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
    String? providerKind,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: envOverride ?? env,
        sessionRoot: '/sessions',
        envVarIsSet: envVarIsSet,
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
    expect(output, contains('model: test-model (test-api)'));
    expect(output, contains('cwd: /work'));
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

    await _waitFor(() => io.out.toString().contains('Type /help'));
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

    await _waitFor(() => io.out.toString().contains('Type /help'));
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

    await _waitFor(() => io.out.toString().contains('Type /help'));
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

      await _waitFor(() => io.out.toString().contains('Type /help'));
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

    await _waitFor(() => io.out.toString().contains('Type /help'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('endpoint: http://127.0.0.1:8932'));
    // Local servers (llama.cpp, Ollama, LM Studio) need no key — warning
    // about a missing one would be noise.
    expect(output, isNot(contains('key:')));
  });

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

  test('unknown slash commands print an error', () async {
    final fake = _FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/bogus');
    await _waitFor(() => io.out.toString().contains('unknown command: /bogus'));
    io.sendLine('/exit');
    await run;
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
        _textTurn('wrapping up'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('go');
      await _waitFor(() => fake.calls == 4 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      // Live context: checkpoint prefix + verbatim report + final answer.
      final messages = cli.agent.state.messages;
      expect(messages, hasLength(5));
      expect((messages[3] as UserMessage).content, report);

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
    expect(output, contains('fah · test-model · 15tok · \$0.0010 · turn 1'));
  });
}
