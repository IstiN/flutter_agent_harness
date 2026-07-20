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

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
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

/// Scripted [StreamFunction] replaying pre-recorded turns and capturing the
/// contexts it receives (so tests can inspect the tool results the model
/// was handed).
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// In-memory [CliIO]: scripted input lines, captured output, settable
/// interactivity.
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

/// A [Shell] that succeeds immediately, echoing the command back.
class _FakeShell implements Shell {
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return Ok(
      ShellExecResult(stdout: 'ran: $command', stderr: '', exitCode: 0),
    );
  }
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

Map<String, dynamic> _askArgs({bool multiSelect = false}) {
  return {
    'questions': [
      {
        'question': 'Which auth method?',
        'options': [
          {'label': 'JWT', 'description': 'Bearer tokens.'},
          {'label': 'OAuth2'},
          {'label': 'Session cookies'},
        ],
        'recommended': 0,
        if (multiSelect) 'multiSelect': true,
      },
    ],
  };
}

void main() {
  late MemoryExecutionEnv env;
  late _FakeCliIO io;
  late _FakeStreamFunction stream;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work', shell: _FakeShell());
    io = _FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(List<List<AssistantMessageEvent>> turns) {
    stream = _FakeStreamFunction(turns);
    return AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  ToolCall askCall(Map<String, dynamic> arguments, {String id = 'tc-1'}) {
    return ToolCall(id: id, name: 'ask', arguments: arguments);
  }

  /// The text of the ask tool result the model received in its second turn.
  String askResultText() {
    final results = stream.contexts[1].messages.whereType<ToolResultMessage>();
    return results.last.content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join();
  }

  group('interactive menu', () {
    test(
      'renders options with the recommended marker; a number selects',
      () async {
        final cli = cliFor([
          _toolTurn([askCall(_askArgs())]),
          _textTurn('answered'),
        ]);
        final run = cli.run();
        io.sendLine('please ask');
        await _waitFor(
          () => io.out.toString().contains('[ask] 1-3 = select'),
          reason: 'menu printed',
        );
        final menu = io.out.toString();
        expect(menu, contains('[ask] Which auth method?'));
        expect(menu, contains('1) JWT — Bearer tokens. (Recommended)'));
        expect(menu, contains('2) OAuth2'));
        io.sendLine('2');
        await _waitFor(() => io.out.toString().contains('answered'));
        expect(askResultText(), 'User selected: OAuth2');
        expect(io.out.toString(), contains('[ask] done'));
        io.sendLine('/exit');
        await run;
      },
    );

    test('empty input switches to free-text entry', () async {
      final cli = cliFor([
        _toolTurn([askCall(_askArgs())]),
        _textTurn('answered'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(() => io.out.toString().contains('[ask] 1-3 = select'));
      io.sendLine('');
      await _waitFor(
        () => io.out.toString().contains('type your answer'),
        reason: 'free-text prompt',
      );
      io.sendLine('use mTLS with rotation');
      await _waitFor(() => io.out.toString().contains('answered'));
      expect(
        askResultText(),
        'User provided custom input: use mTLS with rotation',
      );
      io.sendLine('/exit');
      await run;
    });

    test('a non-number line is taken as the free-text answer', () async {
      final cli = cliFor([
        _toolTurn([askCall(_askArgs())]),
        _textTurn('answered'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(() => io.out.toString().contains('[ask] 1-3 = select'));
      io.sendLine('just use JWT');
      await _waitFor(() => io.out.toString().contains('answered'));
      expect(askResultText(), 'User provided custom input: just use JWT');
      io.sendLine('/exit');
      await run;
    });

    test('an out-of-range number re-prompts', () async {
      final cli = cliFor([
        _toolTurn([askCall(_askArgs())]),
        _textTurn('answered'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(() => io.out.toString().contains('[ask] 1-3 = select'));
      io.sendLine('9');
      await _waitFor(() => io.out.toString().contains('no option 9'));
      io.sendLine('1');
      await _waitFor(() => io.out.toString().contains('answered'));
      expect(askResultText(), 'User selected: JWT');
      io.sendLine('/exit');
      await run;
    });

    test('multi-select toggles via m and confirms with d', () async {
      final cli = cliFor([
        _toolTurn([askCall(_askArgs(multiSelect: true))]),
        _textTurn('answered'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(
        () => io.out.toString().contains('m = multi-select'),
        reason: 'menu with multi hint',
      );
      io.sendLine('m');
      await _waitFor(
        () => io.out.toString().contains('numbers toggle'),
        reason: 'toggle mode',
      );
      io.sendLine('1 3');
      await _waitFor(() => io.out.toString().contains('(selected: 1, 3)'));
      // Toggling 3 off again, then 2 on.
      io.sendLine('3 2');
      await _waitFor(() => io.out.toString().contains('(selected: 1, 2)'));
      io.sendLine('d');
      await _waitFor(() => io.out.toString().contains('answered'));
      expect(askResultText(), 'User selected: JWT, OAuth2');
      io.sendLine('/exit');
      await run;
    });

    test('! cancels: a cancelled result, not an error', () async {
      final cli = cliFor([
        _toolTurn([askCall(_askArgs())]),
        _textTurn('recovered'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(() => io.out.toString().contains('[ask] 1-3 = select'));
      io.sendLine('!');
      await _waitFor(() => io.out.toString().contains('recovered'));
      expect(askResultText(), contains('cancelled'));
      expect(io.out.toString(), contains('[ask] done'));
      expect(io.out.toString(), isNot(contains('[ask] error')));
      io.sendLine('/exit');
      await run;
    });

    test('multiple questions are answered in turn with progress', () async {
      final cli = cliFor([
        _toolTurn([
          askCall({
            'questions': [
              {
                'question': 'Which storage?',
                'options': [
                  {'label': 'SQLite'},
                  {'label': 'PostgreSQL'},
                ],
              },
              {
                'question': 'Which cache?',
                'options': [
                  {'label': 'memory'},
                  {'label': 'redis'},
                ],
              },
            ],
          }),
        ]),
        _textTurn('answered'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(() => io.out.toString().contains('(1/2)'));
      io.sendLine('2');
      await _waitFor(() => io.out.toString().contains('(2/2)'));
      io.sendLine('1');
      await _waitFor(() => io.out.toString().contains('answered'));
      expect(
        askResultText(),
        'User answers:\n'
        '1. Which storage?: PostgreSQL\n'
        '2. Which cache?: memory',
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('non-interactive input', () {
    test('ask fails with a "cannot answer" error result', () async {
      io.isInteractive = false;
      final cli = cliFor([
        _toolTurn([askCall(_askArgs())]),
        _textTurn('adapted'),
      ]);
      final run = cli.run();
      io.sendLine('please ask');
      await _waitFor(() => io.out.toString().contains('adapted'));
      final out = io.out.toString();
      expect(out, contains('[ask] error:'));
      expect(out, contains('cannot answer questions'));
      io.sendLine('/exit');
      await run;
    });
  });
}
