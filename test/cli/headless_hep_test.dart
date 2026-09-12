/// Headless HEP (`--output events`) integration through the real
/// [AgentCli.runHeadless] — issue #155.
///
/// Pins the backend-mode contract at the CLI layer: the HepWriter emits the
/// ordered frame stream, attachments ride the first user message, SIGINT
/// abort yields a `cancelled` frame (and, with the events profile, the
/// partial transcript persists), compaction surfaces frames, and WITHOUT
/// the writer stdout stays byte-identical prose (REG).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// Window 800: the ~700-token answer pushes the post-turn transcript over
/// the compaction threshold (same shape as the auto-compact suite).
const _tinyWindow = Model(
  id: 'tiny',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 800,
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


/// A turn that hangs until cancelled, then reports aborted.
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

/// Headless IO with the stdout/stderr channel split.
class _HeadlessIO implements CliIO {
  final _interrupts = StreamController<void>.broadcast();
  final out = StringBuffer();
  final diag = StringBuffer();
  var eventsMode = false;

  @override
  bool get isInteractive => false;

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) {
    if (!eventsMode) out.write(text);
  }

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
  late _HeadlessIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = _HeadlessIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    Model model = _model,
    bool persistAbortedPartials = false,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        persistAbortedPartials: persistAbortedPartials,
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

  test('events run: header first, ordered frames, stdout stays empty', () async {
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
    // The host wraps the IO for stdout purity (bin/fah.dart does the
    // same in events mode): deltas ride frames, prose rides diagnostics.
    io.eventsMode = true;
    final frames = <String>[];
    final hep = HepWriter(emit: frames.add, fahVersion: 'test');

    final code = await cli.runHeadless(
      'read notes.txt',
      hep: hep,
    );

    expect(code, 0);
    // Stdout carries NOTHING but the HEP stream: the writer owns stdout;
    // prose goes to the diagnostics channel only.
    expect(io.out.toString(), isEmpty);

    final parsed = [
      for (final line in frames) jsonDecode(line) as Map<String, dynamic>,
    ];
    expect(parsed.first['type'], 'hep_header');
    expect(parsed.first['session'], isNotNull);
    expect(parsed.first['hep'], 'v1');
    expect(parsed.first['fah'], 'test');
    expect(parsed.map((f) => f['type']), containsAllInOrder([
      'hep_header',
      'agent_start',
      'message_start',
      'tool_start',
      'turn_done',
      'turn_done',
    ]));
    // The last frame is the final turn_done with the assistant text.
    final last = parsed.last;
    expect(last['type'], 'turn_done');
    expect(last['message'], 'done reading');
    // The session persisted like any headless run.
    final messages = (await sessionEntries()).whereType<MessageRecord>();
    expect(messages, isNotEmpty);
  });

  test('REG: without a HepWriter stdout stays prose (no frames)', () async {
    final fake = FakeStreamFunction([textTurn('plain answer')]);
    final cli = cliFor(fake.call);

    final code = await cli.runHeadless('hi');

    expect(code, 0);
    expect(io.out.toString(), 'plain answer\n');
    expect(
      io.out.toString().split('\n').every((line) {
        if (line.trim().isEmpty) return true;
        try {
          final decoded = jsonDecode(line);
          return decoded is! Map<String, dynamic>;
        } on FormatException {
          return true;
        }
      }),
      isTrue,
      reason: 'stdout must stay human prose without --output events',
    );
  });

  test('attachments ride the first user message as image blocks', () async {
    final fake = FakeStreamFunction([textTurn('seen')]);
    final cli = cliFor(fake.call);

    final code = await cli.runHeadless(
      'what is in the photo',
      images: const [
        ImageContent(data: 'cGhvdG8=', mimeType: 'image/jpeg'),
      ],
    );

    expect(code, 0);
    final request = fake.contexts.single;
    final user = request.messages.whereType<UserMessage>().first;
    final blocks = user.content as List<ContentBlock>;
    final image = blocks.singleWhere((b) => b is ImageContent) as ImageContent;
    expect(image.data, 'cGhvdG8=');
    expect(image.mimeType, 'image/jpeg');
    // The prompt text rides alongside.
    expect(
      blocks.whereType<TextContent>().single.text,
      'what is in the photo',
    );
  });

  test('interrupt mid-run: cancelled frame, exit 130, partial persisted',
      () async {
    final fake = _AbortableStreamFunction();
    final cli = cliFor(fake.call, persistAbortedPartials: true);
    final frames = <String>[];
    final hep = HepWriter(emit: frames.add, fahVersion: 'test');

    final run = cli.runHeadless('hang', hep: hep);
    await _waitFor(() => fake.started, reason: 'stream started');
    io.interrupt();

    expect(await run, 130);
    expect(frames.last, contains('"type":"cancelled"'));
    // The aborted partial assistant message persisted to the JSONL (the
    // backend-mode cancel contract) — and the user message always does.
    final messages = (await sessionEntries()).whereType<MessageRecord>();
    expect(messages.first.message.role, 'user');
    expect(messages.last.message.role, 'assistant');
  });

  test('compaction over threshold emits compaction_start/end frames',
      () async {
    final fake = FakeStreamFunction([
      textTurn('a' * 2800),
      textTurn('AUTO SUMMARY'),
    ]);
    final cli = cliFor(fake.call, model: _tinyWindow);
    final frames = <String>[];
    final hep = HepWriter(emit: frames.add, fahVersion: 'test');

    final code = await cli.runHeadless('q', hep: hep);

    expect(code, 0);
    final types = [
      for (final line in frames)
        (jsonDecode(line) as Map<String, dynamic>)['type'] as String,
    ];
    expect(types, contains('compaction_start'));
    final end = frames
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .firstWhere((f) => f['type'] == 'compaction_end');
    expect(end['tokens_freed'] as int, greaterThanOrEqualTo(0));
    // Frames stay balanced.
    expect(
      types.where((t) => t == 'compaction_start').length,
      types.where((t) => t == 'compaction_end').length,
    );
  });

  test('unknown session key on a clean root starts a fresh session',
      () async {
    // First run seeds one session in the root.
    final seedFake = FakeStreamFunction([textTurn('seed')]);
    final seedCli = cliFor(seedFake.call);
    await seedCli.runHeadless('seed prompt');

    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final before = await repo.list(cwd: '/work');
    expect(before, hasLength(1));
    final seededId = before.first.id;

    // Second run with an UNKNOWN key on the same root: a fresh session
    // with that name — never the seeded session's file.
    final fake = FakeStreamFunction([textTurn('fresh')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'u:42',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final code = await cli.runHeadless('second prompt');

    expect(code, 0);
    final after = await repo.list(cwd: '/work');
    expect(after, hasLength(2));
    expect(after.map((s) => s.id), contains(seededId));
    final named = await repo.open(
      after.firstWhere((s) => s.id != seededId),
    );
    expect(await named.getSessionName(), 'u:42');
  });
}
