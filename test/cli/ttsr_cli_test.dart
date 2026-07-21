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

List<AssistantMessageEvent> _textTurnChunks(List<String> chunks) {
  final empty = _assistant();
  final events = <AssistantMessageEvent>[
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
  ];
  var text = '';
  for (final chunk in chunks) {
    text += chunk;
    events.add(
      TextDeltaEvent(
        contentIndex: 0,
        delta: chunk,
        partial: _assistant(content: [TextContent(text: text)]),
      ),
    );
  }
  events.add(
    DoneEvent(
      reason: StopReason.stop,
      message: _assistant(content: [TextContent(text: text)]),
    ),
  );
  return events;
}

/// Scripted [StreamFunction] honoring the cancel token like a real provider.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;

  int calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
    final stream = AssistantMessageEventStream();
    final events = turns.removeAt(0);
    unawaited(() async {
      AssistantMessage? lastPartial;
      for (final event in events) {
        if (cancelToken?.isCancelled ?? false) {
          final base = lastPartial ?? _assistant();
          stream.push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: base.copyWith(
                stopReason: StopReason.aborted,
                errorMessage: 'Operation aborted',
              ),
            ),
          );
          stream.end();
          return;
        }
        stream.push(event);
        lastPartial = event.partial;
        await Future<void>.delayed(Duration.zero);
      }
      stream.end();
    }());
    return stream;
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

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  TtsrConfig configWith(List<TtsrRule> rules) {
    return TtsrConfig(
      settings: const TtsrSettings(retryDelay: Duration.zero),
      rules: rules,
    );
  }

  TtsrRule consoleRule() {
    return TtsrRule(
      name: 'no-console',
      patterns: [r'console\.log\('],
      body: 'Do not use console.log; use the logger.',
    );
  }

  Future<List<SessionRecord>> sessionEntries() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    if (sessions.isEmpty) return const [];
    final session = await repo.open(sessions.first);
    return session.getEntries();
  }

  test('no ttsr config: no controller is attached', () {
    final fake = _FakeStreamFunction([]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    expect(cli.ttsr, isNull);
  });

  test(
    'rule violation aborts, injects, retries, and persists records',
    () async {
      final fake = _FakeStreamFunction([
        _textTurnChunks(['I will use con', 'sole.log(', ') here']),
        _textTurnChunks(['Switched to the logger.']),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _model,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          ttsr: configWith([consoleRule()]),
        ),
        io: io,
        streamFunction: fake.call,
      );
      expect(cli.ttsr, isNotNull);

      unawaited(cli.run());
      await _waitFor(() => io.out.toString().contains('fa> '));
      io.sendLine('add logging');
      await _waitFor(
        () => io.out.toString().contains('Switched to the logger.'),
        reason: 'corrected retry output',
      );
      // The prompt reappears only after run-end persistence completed.
      await _waitFor(
        () => 'fa> '.allMatches(io.out.toString()).length >= 2,
        reason: 'run settled and persisted',
      );
      expect(fake.calls, 2);

      final output = io.out.toString();
      expect(output, contains('[ttsr] rule violation: no-console — retrying'));
      // The TTSR abort is not rendered as a failure.
      expect(output, isNot(contains('aborted:')));

      // Run-end persistence: the injection landed as records, the violating
      // partial never did (discard mode).
      final entries = await sessionEntries();
      expect(
        entries.whereType<CustomMessageRecord>().where(
          (r) => r.customType == ttsrInjectionCustomType,
        ),
        hasLength(1),
      );
      expect(
        entries.whereType<CustomRecord>().where(
          (r) => r.customType == ttsrInjectionRecordType,
        ),
        hasLength(1),
      );
      final plainMessages = entries.whereType<MessageRecord>().toList();
      expect(
        plainMessages.any(
          (r) => r.message.toJson().toString().contains('console.log('),
        ),
        isFalse,
      );
      // The reminder is not persisted as a plain user message either.
      expect(
        plainMessages.any(
          (r) => r.message.toJson().toString().contains('<system-interrupt'),
        ),
        isFalse,
      );
    },
  );

  test('invalid rule regexes are reported at startup', () {
    final fake = _FakeStreamFunction([]);
    AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        ttsr: configWith([
          TtsrRule(name: 'broken', patterns: const ['[unclosed'], body: 'b'),
          consoleRule(),
        ]),
      ),
      io: io,
      streamFunction: fake.call,
    );
    expect(io.out.toString(), contains('[ttsr]'));
    expect(io.out.toString(), contains('invalid regex'));
  });
}
