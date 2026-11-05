// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2059 — the extension SW host's compaction glue (src/compaction_flow.dart),
/// VM-tested because the glue is pure Dart:
///
/// - the controller resolves the SHARED extension wiring from the live model
///   (parity with a direct `resolveExtensionCompactionWiring` call) and a
///   changed cap applies on the next run;
/// - settle is gated on the shared trigger; manual runs unconditionally and
///   emits the before/after token notice (CLI parity);
/// - the relief path honors the loop-guard contract (sub-window refused,
///   over-window shrunken, run token linked) and bumps the counter seam;
/// - notices ride both channels: the `[fah][sw]` console (hostEventSink
///   debug events) and the panel system-notice sink.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../src/compaction_flow.dart';
import '../src/providers.dart' show hostEventSink;

Model _model({int contextWindow = 8000}) => Model(
  id: 'm1',
  name: 'm1',
  api: 'openai-completions',
  provider: 'test',
  baseUrl: 'http://localhost:1',
  contextWindow: contextWindow,
  maxTokens: 8192,
);

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [TextContent(text: text), ...?calls],
      api: 'openai-completions',
      provider: 'test',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

ToolResultMessage _result(String callId, String text) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'browser_read_dom',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

AssistantMessage _errorAssistant(String message) => AssistantMessage(
  content: const [],
  api: 'openai-completions',
  provider: 'test',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.error,
  errorMessage: message,
  timestamp: DateTime.utc(2026),
);

/// Scripted summarizer: `<conversation>` prompts get a prose checkpoint,
/// judge prompts get a small JSON verdict.
StreamFunction _scriptedStream() => (model, context, {cancelToken}) {
  final last = context.messages.last;
  final promptText = switch (last) {
    UserMessage() =>
      last.content is String
          ? last.content as String
          : (last.content as List<Object>)
                .whereType<TextContent>()
                .map((b) => b.text)
                .join(),
    _ => '',
  };
  final answer = promptText.contains('<conversation>')
      ? 'checkpoint: the browsing task so far'
      : '[1, 2, 3]';
  final stream = AssistantMessageEventStream();
  final partial = _assistant(answer);
  stream
    ..push(StartEvent(partial: _assistant('')))
    ..push(TextStartEvent(contentIndex: 0, partial: _assistant('')))
    ..push(TextDeltaEvent(contentIndex: 0, delta: answer, partial: partial))
    ..push(DoneEvent(reason: StopReason.stop, message: partial));
  stream.end();
  return stream;
};

/// A summarizer stream that always fails (endpoint down).
class _FailingStream {
  var calls = 0;

  StreamFunction get fn => (model, context, {cancelToken}) {
    calls++;
    final stream = AssistantMessageEventStream();
    stream.push(
      ErrorEvent(reason: StopReason.error, error: _errorAssistant('boom')),
    );
    stream.end();
    return stream;
  };
}

/// Records both notice channels (implements the host's notice interface).
class _RecordingNotices implements ExtCompactionNotices {
  final logLines = <String>[];
  final notices = <String>[];

  @override
  void Function(String text)? get noticeSinkForTest => notices.add;

  @override
  set noticeSink(void Function(String text)? sink) {}

  @override
  void log(String line) => logLines.add(line);

  @override
  void notice(String text) => notices.add(text);
}

/// A fat browsing-session fixture (incident-shaped `browser_read_dom`
/// dumps) plus a closing user ask.
Future<Session> _fatSession(
  JsonlSessionRepo repo, {
  int pairs = 3,
  int payloadChars = 16000,
  bool Function(int index)? skipPair,
}) async {
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
  await session.appendMessage(UserMessage.text('fill the form on this page'));
  for (var i = 0; i < pairs; i++) {
    await session.appendMessage(
      _assistant('step $i', calls: [
        ToolCall(id: 'c$i', name: 'browser_read_dom', arguments: {}),
      ]),
    );
    if (skipPair?.call(i) ?? false) continue;
    await session.appendMessage(
      _result('c$i', 'payload $i ${'x' * payloadChars}'),
    );
    await session.appendMessage(_assistant('analysis $i findings'));
  }
  await session.appendMessage(UserMessage.text('submit when done'));
  return session;
}

Future<AgentState> _stateFor(Session session, {Model? model}) async =>
    AgentState(
      model: model ?? _model(),
      systemPrompt: '',
      messages: [
        for (final record in await session.getEntries())
          if (record is MessageRecord) record.message,
      ],
    );

ExtCompactionController _controller(
  Session session,
  AgentState state, {
  StreamFunction? stream,
  ExtCompactionNotices? notices,
  int? Function()? contextWindowCap,
}) => ExtCompactionController(
  session: () => session,
  state: () => state,
  stream: () => stream ?? _scriptedStream(),
  notices: notices ?? _RecordingNotices(),
  contextWindowCap: contextWindowCap ?? (() => null),
);

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('wiring resolution (the glue resolves the shared contract)', () {
    test('matches a direct resolveExtensionCompactionWiring call', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      final state = await _stateFor(session);
      final controller = _controller(session, state);

      final wired = controller.wiringForTest();
      final direct = resolveExtensionCompactionWiring(mainModel: state.model);
      expect(wired.window, direct.window);
      expect(wired.conversationWindow, direct.conversationWindow);
      expect(
        wired.settings.toString(),
        direct.settings.toString(),
        reason: 'CompactionSettings has no ==; toString covers every field',
      );
      expect(wired.enabled, direct.enabled);
      expect(wired.smolModel?.id, direct.smolModel?.id);
    });

    test('a live cap change applies on the next resolution', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      final state = await _stateFor(session);
      var cap = 2000;
      final controller = _controller(session, state, contextWindowCap: () => cap);

      final before = controller.wiringForTest();
      cap = 1500;
      final after = controller.wiringForTest();

      expect(before.window, 2000);
      expect(after.window, 1500);
    });

    test('the resolved wiring stays under the model window (AC3)', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      final state = await _stateFor(session);
      final wiring = _controller(
        session,
        state,
        contextWindowCap: () => 128000,
      ).wiringForTest();

      expect(wiring.window, 128000);
      expect(
        wiring.conversationWindow,
        lessThanOrEqualTo(wiring.window),
      );
    });
  });

  group('settle path (gated on the shared trigger)', () {
    test('below the trigger: no pass, no notice', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('tiny'));
      final state = await _stateFor(session);
      final notices = _RecordingNotices();

      final receipt = await _controller(session, state, notices: notices).settle();

      expect(receipt.attempted, isFalse);
      expect(notices.logLines, isEmpty);
      expect(notices.notices, isEmpty);
    });

    test('over the trigger: compacts and lands below (smol == main)', () async {
      final session = await _fatSession(repo);
      final state = await _stateFor(session);
      final notices = _RecordingNotices();

      final receipt = await _controller(session, state, notices: notices).settle();

      expect(receipt.ran, isTrue);
      expect(receipt.success, isTrue);
      expect(notices.logLines.where((l) => l.contains('pass ')), isNotEmpty);
    });

    test('a failed summarizer surfaces a visible failure, not silence', () async {
      // Untrimmable transcript (every newest message alone exceeds the
      // keep budget): the summarizer ladder fails AND the local valve's
      // null path leaves the context over — the incident shape. The flow
      // must answer with the VISIBLE failure notice (AC5).
      final session = await _fatSession(
        repo,
        pairs: 2,
        skipPair: (_) => true, // tool results dropped → transcript stays huge
      );
      await session.appendMessage(UserMessage.text('x' * 90000));
      final state = await _stateFor(session);
      final notices = _RecordingNotices();
      final failing = _FailingStream();

      final receipt = await _controller(
        session,
        state,
        stream: failing.fn,
        notices: notices,
      ).settle();

      expect(receipt.success, isFalse);
      expect(receipt.cancelled, isFalse);
      // The transcript is intact — a failed ladder must not truncate it.
      expect(state.messages.length, greaterThan(0));
      expect(notices.notices, hasLength(1));
      expect(notices.notices.single, contains('Context compaction failed'));
    });

    test('summarizer failure on a trimmable transcript: the valve lands it',
        () async {
      final session = await _fatSession(repo);
      final state = await _stateFor(session);
      final failing = _FailingStream();

      final receipt = await _controller(
        session,
        state,
        stream: failing.fn,
      ).settle();

      // The deterministic local trim recovers where the summarizer died.
      expect(receipt.underTrigger, isTrue);
      expect(state.messages.length, greaterThan(0));
    });
  });

  group('manual path (CLI /compact parity)', () {
    test('runs unconditionally below the trigger and emits tokens', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('tiny'));
      final state = await _stateFor(session);
      final notices = _RecordingNotices();

      final receipt = await _controller(session, state, notices: notices).manual();

      expect(receipt.ran, isTrue);
      expect(notices.notices.join('\n'), contains('Context compacted'));
    });
  });

  group('relief path (the loop-guard contract)', () {
    test('over-window transcript: shrunken result, counter bumped', () async {
      final session = await _fatSession(repo, pairs: 4, payloadChars: 20000);
      final state = await _stateFor(session);
      final controller = _controller(session, state);
      final overWindow = List.of(state.messages);

      final relieved = await controller.relieveOverWindow(overWindow);

      expect(controller.reliefCountForTest, 1);
      expect(relieved, isNotNull);
      final total = _model().contextWindow;
      for (final m in relieved!) {
        expect(
          estimateTokens(m),
          lessThanOrEqualTo(total),
          reason: 'every kept message must fit the window on its own',
        );
      }
    });

    test('sub-window transcript: refused (null), counter still bumped', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('tiny'));
      final state = await _stateFor(session);
      final controller = _controller(session, state);

      final relieved = await controller.relieveOverWindow(state.messages);

      expect(controller.reliefCountForTest, 1);
      expect(relieved, isNull);
    });

    test('cancelled run token: cancelled receipt, never a failure', () async {
      final session = await _fatSession(repo);
      final state = await _stateFor(session);
      final source = CancelTokenSource();
      final controller = _controller(session, state);
      final overWindow = List.of(state.messages);

      // Cancel before the call: the deterministic abort shape.
      source.cancel('user abort');
      final relieved = await controller.relieveOverWindow(
        overWindow,
        runToken: source.token,
      );

      expect(relieved, isNull);
    });
  });

  group('notice channels (AC11)', () {
    test('log lines ride the [fah][sw] console sink; notices the panel sink',
        () async {
      final session = await _fatSession(repo);
      final state = await _stateFor(session);
      final debugEvents = <Map<String, dynamic>>[];
      final panelNotices = <String>[];
      final prev = hostEventSink;
      hostEventSink = debugEvents.add;
      addTearDown(() => hostEventSink = prev);

      final notices = ExtCompactionNotices();
      notices.noticeSink = panelNotices.add;
      // Settle feeds the console channel (pass lines); the panel system
      // notice is the manual compaction's before/after receipt (CLI parity).
      await _controller(session, state, notices: notices).settle();
      await _controller(session, state, notices: notices).manual();

      final consoleLines = debugEvents
          .map((e) => e['text'].toString())
          .where((t) => t.contains('[fah][sw]'))
          .toList();
      expect(consoleLines, isNotEmpty);
      expect(consoleLines.join('\n'), contains('pass '));
      expect(panelNotices.join('\n'), contains('Context compacted'));
    });

    test('the notice sink is swappable and starts log-only', () {
      final notices = ExtCompactionNotices();
      expect(notices.noticeSinkForTest, isNull);
      final seen = <String>[];
      notices.noticeSink = seen.add;
      notices.notice('panel sees this');
      expect(seen, ['panel sees this']);
    });
  });
}
