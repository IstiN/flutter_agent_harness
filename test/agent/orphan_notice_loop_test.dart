/// gh-1449 integration tests: orphan-result notices through the live agent
/// loop — one-shot across consecutive requests (IT-ONESHOT), never a
/// stand-alone user turn (AC2), and no re-report on a resumed agent
/// (IT-RESUME).
///
/// Fake provider, deterministic clock, the production shape: a context with
/// a compaction cut that orphaned a result.
library;

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

final _at = DateTime.utc(2026);

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: _at,
);

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = AssistantMessage(
    content: const [],
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: _at,
  );
  final partial = _assistant(text);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// Fake [StreamFunction]: answers every request with the same scripted text
/// and records each request payload.
class _FakeStream {
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in _textTurn('ack')) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A never-called tool executor (the Agent requires one).
Future<ToolExecutionResult> _noTools(
  ToolCall call,
  CancelToken? token,
  ToolUpdateCallback? onUpdate,
) => throw StateError('no tools in this test');

/// The production orphan shape: a compaction summary user message whose
/// cut removed a tool call but left its result behind, then a fresh user
/// turn (so the payload has a real pending input).
List<Message> _orphanContext() => [
  UserMessage.text('summary of earlier work', timestamp: _at),
  ToolResultMessage(
    toolCallId: 'bash_198',
    toolName: 'bash',
    content: [TextContent(text: 'ok')],
    timestamp: _at,
    isError: false,
  ),
  UserMessage.text('continue', timestamp: _at),
];

int _noteCount(Context context) => context.messages
    .whereType<UserMessage>()
    .map((m) => userMessageText(m.content))
    .where((t) => t.contains('[context note:'))
    .length;

void main() {
  group('IT-ONESHOT: one orphan, N consecutive requests, exactly one note', () {
    test('across runs on the same Agent', () async {
      final stream = _FakeStream();
      final agent = Agent(
        model: _model,
        streamFunction: stream.call,
        toolExecutor: _noTools,
        messages: _orphanContext(),
      );
      for (var turn = 0; turn < 4; turn++) {
        await agent.prompt('turn $turn');
      }
      // Every request carried the orphan (the transcript keeps it), but
      // the note went out exactly once.
      expect(stream.contexts, hasLength(4));
      expect(stream.contexts.map(_noteCount).toList(), [
        1,
        0,
        0,
        0,
      ], reason: 'the note must ride the FIRST request only');
    });

    test('across the pairing-heal retry inside one request', () async {
      // A provider pairing-400 triggers the self-heal retry: the second
      // attempt rebuilds the request through the same latch, so the note
      // must not duplicate.
      var calls = 0;
      final contexts = <Context>[];
      AssistantMessageEventStream flaky(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        contexts.add(
          Context(
            systemPrompt: context.systemPrompt,
            messages: List.of(context.messages),
            tools: context.tools,
          ),
        );
        final stream = AssistantMessageEventStream();
        if (calls == 1) {
          stream.push(
            ErrorEvent(
              reason: StopReason.error,
              error: AssistantMessage(
                content: const [],
                api: 'test-api',
                provider: 'test-provider',
                model: 'test-model',
                usage: Usage.zero,
                stopReason: StopReason.error,
                errorMessage:
                    '400 unexpected tool_use_id found in tool_result blocks',
                timestamp: _at,
              ),
            ),
          );
        } else {
          for (final event in _textTurn('recovered')) {
            stream.push(event);
          }
        }
        stream.end();
        return stream;
      }

      final agent = Agent(
        model: _model,
        streamFunction: flaky,
        toolExecutor: _noTools,
        messages: _orphanContext(),
      );
      await agent.prompt('go');
      expect(calls, 2);
      expect(contexts.map(_noteCount).toList(), [1, 0]);
    });
  });

  group('IT-RESUME: a restored agent does not re-report a reported orphan', () {
    test('a fresh Agent seeded with the persisted keys stays silent', () async {
      // "Session 1": report the orphan, collect the keys the loop latched
      // (the host persists them as orphan_report records).
      final first = _FakeStream();
      final original = Agent(
        model: _model,
        streamFunction: first.call,
        toolExecutor: _noTools,
        messages: _orphanContext(),
      );
      await original.prompt('turn 1');
      expect(_noteCount(first.contexts.single), 1);
      final persisted = original.reportedOrphanKeys;
      expect(
        persisted,
        contains(orphanReportKey(_orphanContext()[1] as ToolResultMessage)),
      );

      // "Session 2": a resumed process — a NEW agent over the SAME
      // transcript, seeded from the persisted orphan_report records.
      final second = _FakeStream();
      final resumed = Agent(
        model: _model,
        streamFunction: second.call,
        toolExecutor: _noTools,
        messages: _orphanContext(),
        reportedOrphanKeys: Set.of(persisted),
      );
      for (var turn = 0; turn < 2; turn++) {
        await resumed.prompt('resumed turn $turn');
      }
      expect(second.contexts.map(_noteCount).toList(), [0, 0]);
    });
  });

  group('AC2: the note is never a stand-alone user turn on the wire', () {
    test(
      'every request carries the note INSIDE an existing user message',
      () async {
        final stream = _FakeStream();
        final agent = Agent(
          model: _model,
          streamFunction: stream.call,
          toolExecutor: _noTools,
          messages: _orphanContext(),
        );
        await agent.prompt('turn 1');
        final first = stream.contexts.first;
        // The orphan is dropped from the payload and the note rides the last
        // user message as an extra text block — no message added: the
        // transcript's 4 messages minus the ghost result.
        expect(first.messages, hasLength(_orphanContext().length));
        expect(first.messages.whereType<ToolResultMessage>(), isEmpty);
        final carrier = first.messages.last as UserMessage;
        expect(carrier.content, isA<List<ContentBlock>>());
        final blocks = carrier.content as List<ContentBlock>;
        expect((blocks.first as TextContent).text, 'turn 1');
        expect((blocks.last as TextContent).text, startsWith('[context note:'));
      },
    );
  });

  group(
    'gh-2270: a refused or never-streamed request cannot consume the one-shot',
    () {
      test('AC1: an over-window refusal leaves the latch empty; the next '
          'delivered request still carries the note', () async {
        final tinyWindow = const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 100,
          maxTokens: 4096,
        );
        final latch = <String>{};
        final key = orphanReportKey(_orphanContext()[1] as ToolResultMessage);

        // R1: the orphan rides a payload far over the 100-token window; no
        // relief configured — the guard terminal-refuses BEFORE any
        // provider call. The one-shot must survive the refusal. (The
        // overflow is OLDER history, ahead of the orphan shape: an
        // overflow that is the newest user turn itself is the soft-window
        // regime, gh-2411 — no refusal.)
        final refused = _FakeStream();
        final stream1 = agentLoop(
          prompts: [UserMessage.text('x' * 40)],
          context: Context(
            messages: [
              UserMessage.text('o' * 400, timestamp: _at),
              ..._orphanContext(),
            ],
          ),
          config: AgentLoopConfig(model: tinyWindow, reportedOrphanKeys: latch),
          streamFunction: refused.call,
          toolExecutor: _noTools,
        );
        final events1 = await stream1.toList();
        final messages1 = await stream1.result as List<dynamic>;
        expect(refused.contexts, isEmpty, reason: 'the guard refused pre-wire');
        final assistant1 = messages1.whereType<AssistantMessage>().single;
        expect(assistant1.errorMessage, contains(contextWindowExhaustedMarker));
        // Nothing was reported: no latch consumption, no host-persist
        // trigger (hosts persist the orphan_report batch from the event).
        expect(latch, isEmpty);
        expect(events1.whereType<ToolPairingRepairEvent>(), isEmpty);

        // R2: the same session story (nothing was persisted), now within
        // the window — the disclosure STILL rides the outbound payload.
        final delivered = _FakeStream();
        final stream2 = agentLoop(
          prompts: [UserMessage.text('continue')],
          context: Context(messages: _orphanContext()),
          config: AgentLoopConfig(model: _model, reportedOrphanKeys: latch),
          streamFunction: delivered.call,
          toolExecutor: _noTools,
        );
        final events2 = await stream2.toList();
        expect(delivered.contexts, hasLength(1));
        expect(_noteCount(delivered.contexts.single), 1);
        expect(latch, {key});
        expect(events2.whereType<ToolPairingRepairEvent>(), hasLength(1));
      });

      test(
        'AC2: a pre-wire provider throw does not consume the latch',
        () async {
          final latch = <String>{};
          final key = orphanReportKey(_orphanContext()[1] as ToolResultMessage);
          AssistantMessageEventStream throwing(
            Model model,
            Context context, {
            CancelToken? cancelToken,
          }) {
            throw StateError('connection refused before any byte');
          }

          final stream1 = agentLoop(
            prompts: [UserMessage.text('go')],
            context: Context(messages: _orphanContext()),
            config: AgentLoopConfig(model: _model, reportedOrphanKeys: latch),
            streamFunction: throwing,
            toolExecutor: _noTools,
          );
          final messages1 = await stream1.result as List<dynamic>;
          final assistant1 = messages1.whereType<AssistantMessage>().single;
          expect(assistant1.stopReason, StopReason.error);
          expect(
            latch,
            isEmpty,
            reason: 'nothing streamed — the one-shot stands',
          );

          // The next request still discloses.
          final delivered = _FakeStream();
          final stream2 = agentLoop(
            prompts: [UserMessage.text('continue')],
            context: Context(messages: _orphanContext()),
            config: AgentLoopConfig(model: _model, reportedOrphanKeys: latch),
            streamFunction: delivered.call,
            toolExecutor: _noTools,
          );
          await stream2.result as List<dynamic>;
          expect(_noteCount(delivered.contexts.single), 1);
          expect(latch, {key});
        },
      );

      test('border: a stream that STARTED (first byte) keeps the latch even '
          'when the turn dies mid-stream', () async {
        final latch = <String>{};
        AssistantMessageEventStream diesAfterFirstByte(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: _assistant('partial…')));
          stream.end(); // closes with no terminal event — provider bug.
          return stream;
        }

        final stream1 = agentLoop(
          prompts: [UserMessage.text('go')],
          context: Context(messages: _orphanContext()),
          config: AgentLoopConfig(model: _model, reportedOrphanKeys: latch),
          streamFunction: diesAfterFirstByte,
          toolExecutor: _noTools,
        );
        final messages1 = await stream1.result as List<dynamic>;
        expect(
          (messages1.last as AssistantMessage).stopReason,
          StopReason.error,
        );
        // The model saw the note — the latch stands (first-byte rule).
        expect(latch, {
          orphanReportKey(_orphanContext()[1] as ToolResultMessage),
        });
      });
    },
  );
}
