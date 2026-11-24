// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the hand-over call's ladder (AC4, UT-21, E13/E26): ONE
/// nudge after tool calls with the SAME prefix and tools, ONE ×2 budget
/// retry after `length`, an exhausted ladder is a failure that changes
/// no engine, and the call's shape rides the zone under sessionAffine.

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _model = Model(
  id: 'gpt-4o',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  contextWindow: 128000,
  maxTokens: 16384,
);

AssistantMessage _answer(
  String text, {
  StopReason reason = StopReason.stop,
  List<ToolCall>? calls,
  Usage? usage,
}) => AssistantMessage(
  content: [
    TextContent(text: text),
    ...?calls,
  ],
  api: 'openai-completions',
  provider: 'openai',
  model: 'gpt-4o',
  usage: usage ?? Usage.zero,
  stopReason: reason,
  timestamp: DateTime.utc(2026),
);

AssistantMessageEventStream _stream(AssistantMessage message) {
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: message));
  stream.push(DoneEvent(reason: message.stopReason, message: message));
  stream.end();
  return stream;
}

/// A fake provider answering [replies] in order and recording every
/// request with the zone shape it rode.
final class _Fake {
  _Fake(this.replies);
  final List<AssistantMessage> replies;
  final contexts = <Context>[];
  final shapes = <StreamCallShape?>[];
  final routing = <({String? sessionId, String? cacheRetention})?>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    shapes.add(StreamCacheRouting.callShape);
    routing.add(StreamCacheRouting.current);
    return _stream(replies[contexts.length - 1]);
  }
}

final class _Boom implements Exception {
  const _Boom();
}

void main() {
  final s0 = Context(
    systemPrompt: 'sys',
    messages: [
      UserMessage.text('m2 do it', timestamp: DateTime.utc(2026)),
      AssistantMessage(
        content: const [],
        api: 'openai-completions',
        provider: 'openai',
        model: 'gpt-4o',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      ),
    ],
    tools: const [Tool(name: 'read', description: 'd', parameters: {})],
  );
  final instruction = UserMessage.text(
    'Context: 1 of 2 tokens …',
    timestamp: DateTime.utc(2026),
  );
  final request = Context(
    systemPrompt: 'sys',
    messages: [...s0.messages, instruction],
    tools: s0.tools,
  );

  HandOverCall adapter(_Fake fake, {int maxTokens = 8192}) =>
      handOverCallAdapter(
        stream: fake.call,
        model: _model,
        cachePolicy: CompactionCachePolicy.sessionAffine(),
        maxTokens: maxTokens,
        prefixLength: s0.messages.length,
        copilotInitiator: 'agent',
      );

  group('UT-21 ladder', () {
    test('a clean answer is ONE call over S0 + the instruction', () async {
      final fake = _Fake([_answer('142-143 old')]);
      final result = await adapter(fake)(request);
      expect(result.ok, isTrue);
      expect(result.calls, 1);
      expect(result.nudges, 0);
      expect(result.budgetRetries, 0);
      expect(result.response?.content.single, isA<TextContent>());
      // AC3: the prefix is S0 as sent, the instruction is the only delta.
      expect(fake.contexts.single.messages.length, s0.messages.length + 1);
      expect(fake.contexts.single.messages.last.toJson(), instruction.toJson());
      expect(fake.contexts.single.tools, same(s0.tools));
      expect(fake.contexts.single.systemPrompt, 'sys');
      // tool_choice none, explicit budget, breakpoint on S0's last message,
      // pinned initiator — under the session's own (null) routing.
      final shape = fake.shapes.single!;
      expect(shape.toolChoice, 'none');
      expect(shape.maxTokens, 8192);
      expect(shape.prefixLength, s0.messages.length);
      expect(shape.copilotInitiator, 'agent');
      expect(fake.routing.single, (sessionId: null, cacheRetention: null));
    });

    test(
      'tool calls → ONE nudge, same prefix and tools, no tool-less retry',
      () async {
        final fake = _Fake([
          _answer(
            '',
            reason: StopReason.toolUse,
            calls: const [ToolCall(id: 'c1', name: 'read', arguments: {})],
          ),
          _answer('5 old logs'),
        ]);
        final result = await adapter(fake)(request);
        expect(result.ok, isTrue);
        expect(result.calls, 2);
        expect(result.nudges, 1);
        expect(result.response?.content.single, isA<TextContent>());
        final first = fake.contexts[0].messages;
        final second = fake.contexts[1].messages;
        expect(second.length, first.length + 1);
        expect(
          [for (final m in second.take(first.length)) m.toJson()],
          [for (final m in first) m.toJson()],
        );
        expect((second.last as UserMessage).content, handOverNudgeText);
        expect(fake.contexts[1].tools, same(s0.tools));
        // The tool-call answer itself never enters the request.
        expect(
          second.whereType<AssistantMessage>().expand((m) => m.content),
          everyElement(isNot(isA<ToolCall>())),
        );
        // The nudge keeps the shape (prefix still S0's length).
        expect(fake.shapes[1]!.prefixLength, s0.messages.length);
      },
    );

    test('tool calls again after the nudge → exhausted, a failure', () async {
      final fake = _Fake([
        _answer(
          '',
          reason: StopReason.toolUse,
          calls: const [ToolCall(id: 'c1', name: 'read', arguments: {})],
        ),
        _answer(
          '',
          reason: StopReason.toolUse,
          calls: const [ToolCall(id: 'c2', name: 'read', arguments: {})],
        ),
      ]);
      final result = await adapter(fake)(request);
      expect(result.ok, isFalse);
      expect(result.calls, 2);
      expect(result.nudges, 1);
      expect(result.failure, isA<CompactionException>());
      expect('${result.failure}', contains('ladder exhausted'));
    });

    test(
      'E26 `length` → ONE retry with the budget doubled, same request',
      () async {
        final fake = _Fake([
          _answer('cut of', reason: StopReason.length),
          _answer('full text'),
        ]);
        final result = await adapter(fake)(request);
        expect(result.ok, isTrue);
        expect(result.calls, 2);
        expect(result.budgetRetries, 1);
        expect(fake.shapes[0]!.maxTokens, 8192);
        expect(fake.shapes[1]!.maxTokens, 16384);
        expect(
          [for (final m in fake.contexts[1].messages) m.toJson()],
          [for (final m in fake.contexts[0].messages) m.toJson()],
        );
      },
    );

    test('E26 `length` twice → exhausted, nothing usable', () async {
      final fake = _Fake([
        _answer('cut', reason: StopReason.length),
        _answer('cut again', reason: StopReason.length),
      ]);
      final result = await adapter(fake)(request);
      expect(result.ok, isFalse);
      expect(result.calls, 2);
      expect('${result.failure}', contains('output budget twice'));
    });

    test('the ladder is bounded at three round-trips', () async {
      final fake = _Fake([
        _answer(
          '',
          reason: StopReason.toolUse,
          calls: const [ToolCall(id: 'c1', name: 'read', arguments: {})],
        ),
        _answer('cut', reason: StopReason.length),
        _answer('done'),
      ]);
      final result = await adapter(fake)(request);
      expect(result.ok, isTrue);
      expect(result.calls, 3);
      expect(result.nudges, 1);
      expect(result.budgetRetries, 1);
    });

    test('E6 a provider error / abort / throw is a failure — never a retry '
        'of another engine', () async {
      final errored = _Fake([
        AssistantMessage(
          content: const [],
          api: 'openai-completions',
          provider: 'openai',
          model: 'gpt-4o',
          usage: Usage.zero,
          stopReason: StopReason.error,
          errorMessage: 'boom',
          timestamp: DateTime.utc(2026),
        ),
      ]);
      final errorResult = await adapter(errored)(request);
      expect(errorResult.ok, isFalse);
      expect(errorResult.calls, 1);
      expect('${errorResult.failure}', contains('hand-over call failed'));
      final aborted = _Fake([_answer('', reason: StopReason.aborted)]);
      final abortResult = await adapter(aborted)(request);
      expect(abortResult.ok, isFalse);
      final throwing = handOverCallAdapter(
        stream: (model, context, {cancelToken}) => throw const _Boom(),
        model: _model,
        cachePolicy: CompactionCachePolicy.sessionAffine(),
        prefixLength: s0.messages.length,
      );
      final thrown = await throwing(request);
      expect(thrown.ok, isFalse);
      expect(thrown.failure, isA<_Boom>());
    });

    test(
      'IT-03 cache metric folds usage; no usage → null, never a fake zero',
      () async {
        final metered = _Fake([
          _answer(
            'ok',
            usage: const Usage(
              input: 100,
              output: 10,
              cacheRead: 900,
              cacheWrite: 0,
              totalTokens: 1010,
              cost: UsageCost(),
            ),
          ),
        ]);
        final sink = <Usage>[];
        final call = handOverCallAdapter(
          stream: metered.call,
          model: _model,
          cachePolicy: CompactionCachePolicy.sessionAffine(),
          prefixLength: s0.messages.length,
          onUsage: sink.add,
          onDelta: (_) {},
        );
        final result = await call(request);
        expect(result.cacheHitRatio, closeTo(0.9, 1e-9));
        expect(sink, hasLength(1));
        final unmetered = await adapter(_Fake([_answer('ok')]))(request);
        expect(unmetered.cacheHitRatio, isNull);
      },
    );
  });
}
