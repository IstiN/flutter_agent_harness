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
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
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

/// Scripted [StreamFunction] replaying pre-recorded turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  var calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
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

/// A [CliIO] with the headless channel split: [write] is the pipeable
/// primary stream (stdout), [writeln] is diagnostics (stderr). Never
/// interactive, like the real headless terminal IO.
class _HeadlessFakeCliIO implements CliIO {
  final _interrupts = StreamController<void>.broadcast();
  final out = StringBuffer();
  final diag = StringBuffer();

  @override
  bool get isInteractive => false;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => diag.write('$text\n');

  void interrupt() => _interrupts.add(null);

  Future<void> close() => _interrupts.close();
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
  late _HeadlessFakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = _HeadlessFakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
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

  test('streams the answer to the write channel only, exit 0', () async {
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

    final code = await cli.runHeadless('read notes.txt');

    expect(code, 0);
    // Stdout is exactly the assistant text (+ its trailing newline) — no
    // tool indicators, banner, or prompt markers pollute the pipe.
    expect(io.out.toString(), 'done reading\n');
    // Diagnostics carry the tool one-liners.
    expect(io.diag.toString(), contains('[read] path="notes.txt"'));
    expect(io.diag.toString(), contains('[read] done'));
    expect(io.diag.toString(), isNot(contains('fah — flutter_agent_harness')));
    expect(io.diag.toString(), isNot(contains('fah> ')));

    // The session persists like a REPL run: user, tool call/result, answer.
    final entries = await sessionEntries();
    final messages = entries.whereType<MessageRecord>().toList();
    expect(messages.first.message.role, 'user');
    expect(messages.where((r) => r.message is ToolResultMessage), hasLength(1));
    final assistant = messages.last.message as AssistantMessage;
    expect(
      assistant.content.whereType<TextContent>().single.text,
      'done reading',
    );
  });

  test('provider error exits 1 with the error on diagnostics only', () async {
    final fake = _FakeStreamFunction([
      [
        StartEvent(partial: _assistant()),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(
            stopReason: StopReason.error,
            errorMessage: 'provider boom',
          ),
        ),
      ],
    ]);
    final cli = cliFor(fake.call);

    final code = await cli.runHeadless('hi');

    expect(code, 1);
    expect(io.out.toString(), isEmpty);
    expect(io.diag.toString(), contains('error: provider boom'));
  });

  test(
    'connection-refused error appends the endpoint hint on diagnostics',
    () async {
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

      final code = await cli.runHeadless('hi');

      expect(code, 1);
      expect(io.out.toString(), isEmpty);
      expect(
        io.diag.toString(),
        contains(
          'error: Connection refused — check the endpoint in '
          '~/.fah/config.yaml (baseUrl: https://example.test) or pass '
          '--base-url',
        ),
      );
    },
  );

  test('Ctrl-C abort exits 130', () async {
    final fake = _AbortableStreamFunction();
    final cli = cliFor(fake.call);

    final run = cli.runHeadless('hang');
    await _waitFor(() => fake.started, reason: 'stream started');
    io.interrupt();

    expect(await run, 130);
    expect(io.out.toString(), isEmpty);
  });
}
