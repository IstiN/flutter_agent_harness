import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Model _model() => Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test',
  baseUrl: 'https://example.com',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant(String text, {String? errorMessage}) =>
    AssistantMessage(
      content: [if (text.isNotEmpty) TextContent(text: text)],
      api: 'test-api',
      provider: 'test',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
      errorMessage: errorMessage,
    );

/// Streams [deltas] as text-delta events, then a done message with the
/// joined text — the shape `completeOnce`'s onDelta tap forwards.
StreamFunction _deltaResponse(List<String> deltas) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final joined = deltas.join();
    final partial = _assistant(joined);
    stream.push(StartEvent(partial: partial));
    for (final delta in deltas) {
      stream.push(
        TextDeltaEvent(contentIndex: 0, delta: delta, partial: partial),
      );
    }
    stream.push(DoneEvent(reason: StopReason.stop, message: _assistant(joined)));
    stream.end();
    return stream;
  };
}

void main() {
  group('completeOnceSystemPrompt', () {
    test('folds system messages into the briefing', () {
      final prompt = completeOnceSystemPrompt([
        (role: 'system', content: 'be terse'),
        (role: 'user', content: 'hi'),
        (role: 'system', content: 'stay safe'),
      ]);
      expect(prompt, contains('tiny assistant'));
      expect(prompt, contains('be terse'));
      expect(prompt, contains('stay safe'));
      expect(prompt.contains('hi'), isFalse);
    });

    test('is the bare briefing without system messages', () {
      expect(
        completeOnceSystemPrompt([(role: 'user', content: 'hi')]),
        isNot(contains('hi')),
      );
    });
  });

  group('completeOnceConversation', () {
    test('rebuilds assistant entries provider-identically', () {
      final conversation = completeOnceConversation([
        (role: 'user', content: 'one'),
        (role: 'assistant', content: 'two'),
      ], _model());
      expect(conversation, hasLength(2));
      expect(conversation[0], isA<UserMessage>());
      expect((conversation[0] as UserMessage).content, 'one');
      final assistant = conversation[1] as AssistantMessage;
      expect(
        assistant.content.whereType<TextContent>().single.text,
        'two',
      );
      expect(assistant.model, 'test-model');
    });

    test('drops roles that are neither user nor assistant', () {
      expect(
        completeOnceConversation([
          (role: 'tool', content: 'noise'),
          (role: 'user', content: 'one'),
        ], _model()),
        hasLength(1),
      );
    });

    test('empty input yields an empty conversation', () {
      expect(completeOnceConversation([], _model()), isEmpty);
    });
  });

  group('completeOnceText', () {
    test('joins the last assistant message text blocks', () {
      expect(
        completeOnceText([
          UserMessage.text('q'),
          _assistant('part 1\npart 2'),
        ]),
        'part 1\npart 2',
      );
    });

    test('surfaces the assistant error when no text came back', () {
      expect(
        () => completeOnceText([_assistant('', errorMessage: 'boom')]),
        throwsStateError,
      );
    });

    test('no completion returned without an assistant last message', () {
      expect(() => completeOnceText([]), throwsStateError);
      expect(() => completeOnceText([UserMessage.text('q')]), throwsStateError);
      expect(
        () => completeOnceText([_assistant('')]),
        throwsStateError,
      );
    });
  });

  group('tailMessagePairs', () {
    test('tails to the last [tail] messages as (role, text) pairs', () {
      final pairs = AgentService.tailMessagePairs([
        UserMessage.text('  first  '),
        _assistant('second'),
        UserMessage.text('third'),
      ], 2);
      expect(pairs, [
        ('assistant', 'second'),
        ('user', 'third'),
      ]);
    });

    test('tail beyond the list keeps everything; empty stays empty', () {
      expect(AgentService.tailMessagePairs([UserMessage.text('a')], 20), [
        ('user', 'a'),
      ]);
      expect(AgentService.tailMessagePairs(const [], 5), isEmpty);
    });
  });

  group('ensureSendableSubagent', () {
    SubagentHandle handle(SubagentStatus status) => SubagentHandle(
      id: 'sub',
      name: 'sub',
      agentType: 'task',
      sessionId: 'sub.jsonl',
      createdAt: '2026-01-01T00:00:00Z',
    )..status = status;

    test('live-or-idle children are sendable', () {
      AgentService.ensureSendableSubagent(
        handle(SubagentStatus.running),
        'sub',
      );
      AgentService.ensureSendableSubagent(handle(SubagentStatus.idle), 'sub');
    });

    test('failed and aborted children are refused', () {
      expect(
        () => AgentService.ensureSendableSubagent(
          handle(SubagentStatus.failed),
          'sub',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cannot send to failed subagent "sub"',
          ),
        ),
      );
      expect(
        () => AgentService.ensureSendableSubagent(
          handle(SubagentStatus.aborted),
          'sub',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cannot send to aborted subagent "sub"',
          ),
        ),
      );
    });
  });

  group('completeOnce (end to end over a fake stream)', () {
    test('returns the completion and forwards deltas', () async {
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'test-model',
          baseUrl: 'https://example.test',
          apiKey: 'test-key',
        ),
        env: MemoryExecutionEnv(cwd: '/'),
        streamFunction: _deltaResponse(['he', 'llo']),
      );
      addTearDown(service.dispose);
      final deltas = <String>[];
      final text = await service.completeOnce([
        (role: 'system', content: 'be terse'),
        (role: 'user', content: 'hi'),
      ], onDelta: deltas.add);
      expect(text, 'hello');
      expect(deltas.join(), 'hello');
    });

    test('refuses a conversation without a user message', () async {
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'test-model',
          baseUrl: 'https://example.test',
          apiKey: 'test-key',
        ),
        env: MemoryExecutionEnv(cwd: '/'),
        streamFunction: _deltaResponse(['x']),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.completeOnce([]),
        throwsStateError,
      );
    });
  });
}
