import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('AgentCli prompt overrides', () {
    late MemoryExecutionEnv env;
    late _FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv();
      io = _FakeCliIO();
    });

    tearDown(() => io.close());

    AgentCli cliFactory({
      String initialMode = 'code',
      String? systemPrompt,
      PromptOverrides? promptOverrides,
      StreamFunction? streamFunction,
    }) {
      return AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test',
            baseUrl: 'https://example.com',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          initialMode: initialMode,
          systemPrompt: systemPrompt,
          promptOverrides: promptOverrides,
        ),
        io: io,
        streamFunction: streamFunction ?? _emptyStream,
      );
    }

    test('no overrides keeps the built-in prompts byte-identical', () {
      final plain = cliFactory();
      final empty = cliFactory(promptOverrides: PromptOverrides.empty);
      final builtin = defaultAgentMode(env.cwd).systemPrompt;
      expect(plain.systemPrompt, builtin);
      expect(empty.systemPrompt, builtin);
      expect(plain.systemPrompt, contains('You are fah'));
    });

    test('config override replaces the code mode prompt at startup', () {
      final cli = cliFactory(
        promptOverrides: const PromptOverrides({
          'cli/mode_code': 'CUSTOM CODE PROMPT',
        }),
      );
      expect(cli.currentMode.name, 'code');
      expect(cli.systemPrompt, 'CUSTOM CODE PROMPT');
      expect(cli.agent.state.systemPrompt, 'CUSTOM CODE PROMPT');
    });

    test('the system alias overrides the code mode prompt', () {
      // `system` canonicalizes to cli/mode_code during io resolution.
      final cli = cliFactory(
        promptOverrides: const PromptOverrides({
          'cli/mode_code': 'ALIAS CODE PROMPT',
        }),
      );
      expect(cli.systemPrompt, 'ALIAS CODE PROMPT');
    });

    test('overridden mode prompts substitute {{cwd}}', () {
      final cli = cliFactory(
        promptOverrides: const PromptOverrides({
          'cli/mode_code': 'Work in {{cwd}} now.',
        }),
      );
      expect(cli.systemPrompt, 'Work in ${env.cwd} now.');
    });

    test('initialMode uses the overridden mode prompt', () {
      final cli = cliFactory(
        initialMode: 'architect',
        promptOverrides: const PromptOverrides({
          'cli/mode_architect': 'CUSTOM ARCHITECT',
        }),
      );
      expect(cli.currentMode.name, 'architect');
      expect(cli.systemPrompt, 'CUSTOM ARCHITECT');
    });

    test('mode switch applies the overridden mode prompt', () async {
      final cli = cliFactory(
        promptOverrides: const PromptOverrides({
          'cli/mode_review': 'CUSTOM REVIEW',
        }),
      );
      final run = cli.run();
      io.sendLine('/review');
      await _waitFor(
        () => io.out.toString().contains('switched mode to review'),
      );
      expect(cli.currentMode.name, 'review');
      expect(cli.agent.state.systemPrompt, 'CUSTOM REVIEW');
      io.sendLine('/code');
      await _waitFor(() => io.out.toString().contains('switched mode to code'));
      // Un-overridden modes keep their built-in prompt.
      expect(cli.agent.state.systemPrompt, contains('You are fah'));
      io.sendLine('/exit');
      await run;
    });

    test('flag system prompt beats the config override and the built-in', () {
      final cli = cliFactory(
        systemPrompt: 'FLAG PROMPT',
        promptOverrides: const PromptOverrides({
          'cli/mode_code': 'CONFIG PROMPT',
        }),
      );
      expect(cli.systemPrompt, 'FLAG PROMPT');
      expect(cli.agent.state.systemPrompt, 'FLAG PROMPT');
    });

    test('headless run sends the flag system prompt to the provider', () async {
      String? capturedSystemPrompt;
      final cli = cliFactory(
        systemPrompt: 'FLAG HEADLESS PROMPT',
        streamFunction: (model, context, {cancelToken}) {
          capturedSystemPrompt = context.systemPrompt;
          return _singleTextResponse('ok')(model, context);
        },
      );
      final code = await cli.runHeadless('hi');
      expect(code, 0);
      expect(capturedSystemPrompt, 'FLAG HEADLESS PROMPT');
    });

    test(
      'headless run sends the config-overridden prompt to the provider',
      () async {
        String? capturedSystemPrompt;
        final cli = cliFactory(
          promptOverrides: const PromptOverrides({
            'cli/mode_code': 'CONFIG HEADLESS PROMPT',
          }),
          streamFunction: (model, context, {cancelToken}) {
            capturedSystemPrompt = context.systemPrompt;
            return _singleTextResponse('ok')(model, context);
          },
        );
        final code = await cli.runHeadless('hi');
        expect(code, 0);
        expect(capturedSystemPrompt, 'CONFIG HEADLESS PROMPT');
      },
    );

    test('compaction summarizes with the overridden prompts', () async {
      final contexts = <Context>[];
      final cli = cliFactory(
        promptOverrides: const PromptOverrides({
          'compaction/summary_system': 'CUSTOM SUMMARY SYSTEM',
          'compaction/summary': 'CUSTOM SUMMARY INSTRUCTIONS',
        }),
        streamFunction: (model, context, {cancelToken}) {
          contexts.add(context);
          return _singleTextResponse('summary text')(model, context);
        },
      );
      final run = cli.run();
      io.sendLine('hello');
      await _waitFor(() => contexts.isNotEmpty);
      // Let the run settle: a command sent while streaming would be steered
      // into the agent instead of handled.
      await _waitFor(() => !cli.isBusy);
      io.sendLine('/compact');
      await _waitFor(() => io.out.toString().contains('[compacted]'));
      io.sendLine('/exit');
      await run;
      // The summarization call carries the overridden system prompt, and the
      // overridden instructions end the request prompt.
      final summarization = contexts.where(
        (context) => context.systemPrompt == 'CUSTOM SUMMARY SYSTEM',
      );
      expect(summarization, hasLength(1));
      final request = summarization.single.messages.single as UserMessage;
      expect(request.content as String, contains('<conversation>'));
      expect(
        (request.content as String).endsWith('CUSTOM SUMMARY INSTRUCTIONS'),
        isTrue,
      );
      // The main run still used the built-in mode prompt.
      expect(contexts.first.systemPrompt, contains('You are fah'));
    });

    test('compaction without overrides uses the built-in prompts', () async {
      final contexts = <Context>[];
      final cli = cliFactory(
        streamFunction: (model, context, {cancelToken}) {
          contexts.add(context);
          return _singleTextResponse('summary text')(model, context);
        },
      );
      final run = cli.run();
      io.sendLine('hello');
      await _waitFor(() => contexts.isNotEmpty);
      await _waitFor(() => !cli.isBusy);
      io.sendLine('/compact');
      await _waitFor(() => io.out.toString().contains('[compacted]'));
      io.sendLine('/exit');
      await run;
      final summarization = contexts.where(
        (context) => context.systemPrompt == summarizationSystemPrompt,
      );
      expect(summarization, hasLength(1));
      final request = summarization.single.messages.single as UserMessage;
      expect((request.content as String).endsWith(summarizationPrompt), isTrue);
    });
  });
}

class _FakeCliIO implements CliIO {
  @override
  int columns = 80;

  @override
  int rows = 24;

  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  @override
  bool get isInteractive => true;
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
  void writeln(String text) => out.writeln(text);

  void sendLine(String line) => _lines.add(line);

  Future<void> close() async {
    unawaited(_lines.close());
    await _interrupts.close();
  }
}

Future<void> _waitFor(bool Function() predicate, {int attempts = 50}) async {
  for (var i = 0; i < attempts; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('predicate never became true');
}

AssistantMessageEventStream _emptyStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) => AssistantMessageEventStream();

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}
