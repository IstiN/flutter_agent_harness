import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _msg(
  String modelId, {
  String text = '',
  StopReason stop = StopReason.stop,
  String? error,
}) {
  return AssistantMessage(
    content: text.isEmpty ? const [] : [TextContent(text: text)],
    api: 'anthropic-messages',
    provider: 'anthropic',
    model: modelId,
    usage: Usage.zero,
    stopReason: stop,
    errorMessage: error,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String modelId, String text) {
  final empty = _msg(modelId);
  final full = _msg(modelId, text: text);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: full),
    DoneEvent(reason: StopReason.stop, message: full),
  ];
}

List<AssistantMessageEvent> _rateLimitTurn(String modelId) {
  return [
    StartEvent(partial: _msg(modelId)),
    ErrorEvent(
      reason: StopReason.error,
      error: _msg(modelId, stop: StopReason.error, error: '429: rate limited'),
    ),
  ];
}

/// Scripted `streamFactory` for the resolver: turns per model id.
class _RolesFactory {
  final Map<String, List<List<AssistantMessageEvent>>> scripts;
  final calls = <String>[];
  final contexts = <Context>[];

  _RolesFactory(this.scripts);

  StreamFunction call(String kind, String apiKey) {
    return (model, context, {cancelToken}) {
      calls.add(model.id);
      contexts.add(context);
      final queue = scripts[model.id];
      if (queue == null || queue.isEmpty) {
        throw StateError('no scripted turn for ${model.id}');
      }
      final stream = AssistantMessageEventStream();
      for (final event in queue.removeAt(0)) {
        stream.push(event);
      }
      stream.end();
      return stream;
    };
  }
}

class _FakeCliIO implements CliIO {
  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  @override
  bool isInteractive = true;
  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  bool get supportsRawMode => false;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  Future<void> close() async {
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

const _placeholderModel = Model(
  id: 'placeholder',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

void main() {
  late MemoryExecutionEnv env;
  late _FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = _FakeCliIO();
  });

  tearDown(() => io.close());

  ModelRolesResolver resolverFor(
    _RolesFactory factory,
    Map<String, List<ModelRef>> roles,
  ) {
    return ModelRolesResolver(
      config: ModelRolesConfig(
        roles: roles,
        retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
      ),
      secrets: const {'ANTHROPIC_API_KEY': 'test-key'},
      streamFactory: factory.call,
    );
  }

  AgentCli cliFor(ModelRolesResolver resolver) {
    return AgentCli(
      config: AgentCliConfig(
        model: _placeholderModel,
        apiKey: 'unused',
        env: env,
        sessionRoot: '/sessions',
        modelRolesResolver: resolver,
      ),
      io: io,
    );
  }

  test('banner key status follows the resolved role provider', () async {
    final factory = _RolesFactory({
      'claude-a': [_textTurn('claude-a', 'ok')],
    });
    final resolver = resolverFor(factory, const {
      'default': [ModelRef(provider: 'anthropic', modelId: 'claude-a')],
    });
    final cli = AgentCli(
      config: AgentCliConfig(
        model: _placeholderModel,
        apiKey: 'unused',
        env: env,
        sessionRoot: '/sessions',
        modelRolesResolver: resolver,
        envVarIsSet: (_) => false,
      ),
      io: io,
    );
    final run = cli.run();

    await _waitFor(() => io.out.toString().contains('[Model]'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    // The resolved provider is anthropic; the flag provider kind
    // (openai-completions) must not leak into the key status.
    expect(output, contains('claude-a (anthropic-messages)'));
    expect(output, contains('endpoint: https://api.anthropic.com'));
    expect(output, contains('key: no key set (want ANTHROPIC_API_KEY)'));
  });

  test(
    '/model shows the roles overview with the active chain position',
    () async {
      final factory = _RolesFactory({
        'claude-a': [_rateLimitTurn('claude-a')],
        'claude-b': [_textTurn('claude-b', 'backup took over')],
      });
      final resolver = resolverFor(factory, const {
        'default': [
          ModelRef(provider: 'anthropic', modelId: 'claude-a'),
          ModelRef(provider: 'anthropic', modelId: 'claude-b'),
        ],
        'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
      });
      final cli = cliFor(resolver);
      final run = cli.run();

      io.sendLine('/model');
      await _waitFor(
        () => io.out.toString().contains('anthropic/claude-smol'),
        reason: 'roles overview printed',
      );
      io.sendLine('go');
      await _waitFor(() => factory.calls.length == 2 && !cli.isBusy);
      io.sendLine('/model');
      await _waitFor(() => io.out.toString().contains('* anthropic/claude-b'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('default:'));
      expect(output, contains('smol:'));
      // The fallback note was rendered during the run (no silent degrade).
      expect(
        output,
        contains(
          '[roles] rate limited on anthropic/claude-a — '
          'falling back to anthropic/claude-b',
        ),
      );
      expect(output, contains('backup took over'));
      expect(factory.calls, ['claude-a', 'claude-b']);
    },
  );

  test('/model <id> pins the default chain for the session', () async {
    final factory = _RolesFactory({
      'claude-a': [_textTurn('claude-a', 'a')],
      'pinned-model': [_textTurn('pinned-model', 'pinned answer')],
    });
    final resolver = resolverFor(factory, const {
      'default': [ModelRef(provider: 'anthropic', modelId: 'claude-a')],
    });
    final cli = cliFor(resolver);
    final run = cli.run();

    io.sendLine('/model pinned-model');
    await _waitFor(
      () => io.out.toString().contains('switched model to pinned-model'),
    );
    io.sendLine('go');
    await _waitFor(() => factory.calls.isNotEmpty && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(factory.calls, ['pinned-model']);
    expect(io.out.toString(), contains('pinned answer'));
  });

  test('compaction summarizes through the smol role', () async {
    final factory = _RolesFactory({
      'claude-a': [_textTurn('claude-a', 'answer')],
      'claude-smol': [_textTurn('claude-smol', 'SMOL SUMMARY')],
    });
    final resolver = resolverFor(factory, const {
      'default': [ModelRef(provider: 'anthropic', modelId: 'claude-a')],
      'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
    });
    final cli = cliFor(resolver);
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => factory.calls.length == 1 && !cli.isBusy);
    io.sendLine('/compact');
    await _waitFor(
      () => factory.calls.length == 2,
      reason: 'summarizer called',
    );
    await _waitFor(() => io.out.toString().contains('[compacted]'));
    io.sendLine('/exit');
    await run;

    // The summary call went to the smol model, not the default chain.
    expect(factory.calls, ['claude-a', 'claude-smol']);
    expect(factory.contexts.last.systemPrompt, contains('summar'));
  });

  test('a resolver without a default role keeps the legacy wiring', () async {
    final factory = _RolesFactory({
      'claude-smol': [_textTurn('claude-smol', 'SMOL SUMMARY')],
    });
    final resolver = resolverFor(factory, const {
      'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
    });
    final legacyTurns = <List<AssistantMessageEvent>>[
      _textTurn('placeholder', 'legacy answer'),
    ];
    final legacyCalls = <String>[];
    AssistantMessageEventStream legacyStream(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      legacyCalls.add(model.id);
      final stream = AssistantMessageEventStream();
      for (final event in legacyTurns.removeAt(0)) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }

    final cli = AgentCli(
      config: AgentCliConfig(
        model: _placeholderModel,
        apiKey: 'unused',
        env: env,
        sessionRoot: '/sessions',
        modelRolesResolver: resolver,
      ),
      io: io,
      streamFunction: legacyStream,
    );
    final run = cli.run();

    io.sendLine('q');
    await _waitFor(() => legacyCalls.isNotEmpty && !cli.isBusy);
    io.sendLine('/compact');
    await _waitFor(() => factory.calls.isNotEmpty, reason: 'smol summarizer');
    await _waitFor(() => io.out.toString().contains('[compacted]'));
    io.sendLine('/exit');
    await run;

    // User turns used the injected legacy stream; compaction used smol.
    expect(legacyCalls, ['placeholder']);
    expect(factory.calls, ['claude-smol']);
  });
}
