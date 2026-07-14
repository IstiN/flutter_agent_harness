import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('AgentCli modes and prompt templates', () {
    late MemoryExecutionEnv env;
    late _FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv();
      io = _FakeCliIO();
    });

    tearDown(() => io.close());

    AgentCli cliFactory({
      String initialMode = 'code',
      List<String> promptDirs = const [],
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
          promptTemplateDirs: promptDirs,
        ),
        io: io,
        streamFunction: streamFunction ?? _emptyStream,
      );
    }

    test('defaults to code mode system prompt', () {
      final cli = cliFactory();
      expect(cli.currentMode.name, 'code');
      expect(cli.systemPrompt, contains('You are fah'));
      expect(cli.agent.state.systemPrompt, cli.systemPrompt);
    });

    test('initialMode selects architect mode', () {
      final cli = cliFactory(initialMode: 'architect');
      expect(cli.currentMode.name, 'architect');
      expect(cli.systemPrompt, contains('architect mode'));
    });

    test('/mode shows current mode and available modes', () async {
      final cli = cliFactory();
      final run = cli.run();
      io.sendLine('/mode');
      await _waitFor(() => io.out.toString().contains('mode: code'));
      io.sendLine('/exit');
      await run;
      expect(io.out.toString(), contains('modes: architect, code, review'));
    });

    test('/architect switches mode and system prompt', () async {
      final cli = cliFactory();
      final run = cli.run();
      io.sendLine('/architect');
      await _waitFor(
        () => io.out.toString().contains('switched mode to architect'),
      );
      expect(cli.currentMode.name, 'architect');
      expect(cli.agent.state.systemPrompt, contains('architect mode'));
      io.sendLine('/exit');
      await run;
    });

    test('/review switches mode and system prompt', () async {
      final cli = cliFactory();
      final run = cli.run();
      io.sendLine('/review');
      await _waitFor(
        () => io.out.toString().contains('switched mode to review'),
      );
      expect(cli.currentMode.name, 'review');
      expect(cli.agent.state.systemPrompt, contains('code review mode'));
      io.sendLine('/exit');
      await run;
    });

    test('/code returns to coding mode', () async {
      final cli = cliFactory(initialMode: 'architect');
      final run = cli.run();
      io.sendLine('/code');
      await _waitFor(() => io.out.toString().contains('switched mode to code'));
      expect(cli.currentMode.name, 'code');
      io.sendLine('/exit');
      await run;
    });

    test('unknown mode prints error', () async {
      final cli = cliFactory();
      final run = cli.run();
      io.sendLine('/mode unknown');
      await _waitFor(() => io.out.toString().contains('unknown mode: unknown'));
      io.sendLine('/exit');
      await run;
    });

    test('loads and expands prompt templates', () async {
      await env.writeFile('/prompts/explain.md', 'Explain \$1 like I am five.');
      String? capturedPrompt;
      final cli = cliFactory(
        promptDirs: ['/prompts'],
        streamFunction: (model, context, {cancelToken}) {
          final userMessages = context.messages.whereType<UserMessage>();
          if (userMessages.isNotEmpty) {
            capturedPrompt = userMessages.last.content as String?;
          }
          return _singleTextResponse('ok')(
            model,
            context,
            cancelToken: cancelToken,
          );
        },
      );
      final run = cli.run();
      io.sendLine('/explain recursion');
      await _waitFor(
        () => capturedPrompt == 'Explain recursion like I am five.',
      );
      io.sendLine('/exit');
      await run;
      expect(capturedPrompt, equals('Explain recursion like I am five.'));
    });

    test('unknown slash command still prints error', () async {
      final cli = cliFactory();
      final run = cli.run();
      io.sendLine('/unknown');
      await _waitFor(
        () => io.out.toString().contains('unknown command: /unknown'),
      );
      io.sendLine('/exit');
      await run;
    });
  });
}

class _FakeCliIO implements CliIO {
  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final out = StringBuffer();

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
