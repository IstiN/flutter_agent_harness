import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/memory/harness_llm_provider.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

List<AssistantMessageEvent> _errorTurn(String message) => [
  ErrorEvent(
    reason: StopReason.error,
    error: testAssistant(
      stopReason: StopReason.error,
      errorMessage: message,
    ),
  ),
];

/// The memory LLM adapter: fa_llm's LlmProvider over the harness streaming
/// contract, resolving the memory/smol role per call.
void main() {
  group('HarnessLlmProvider', () {
    test('chat returns the joined text of a successful stream', () async {
      final provider = HarnessLlmProvider(
        resolve: () => (
          model: testModel,
          stream: FakeStreamFunction([textTurn('durable fact')]).call,
        ),
      );
      expect(await provider.chat('hello'), 'durable fact');
    });

    test('defaultModel reflects the per-call resolution', () {
      final provider = HarnessLlmProvider(
        resolve: () => (
          model: testModel,
          stream: FakeStreamFunction([]).call,
        ),
      );
      expect(provider.defaultModel, testModel.id);
    });

    test('defaultModel is "unknown" when no slot resolves', () {
      final provider = HarnessLlmProvider(resolve: () => null);
      expect(provider.defaultModel, 'unknown');
    });

    test('system messages merge into the context system prompt', () async {
      Context? seen;
      AssistantMessageEventStream stream(
        Model m,
        Context c, {
        CancelToken? cancelToken,
      }) {
        seen = c;
        return FakeStreamFunction([textTurn('ok')])(m, c);
      }

      final provider = HarnessLlmProvider(
        resolve: () => (model: testModel, stream: stream),
      );
      await provider.chatMessages([
        const LlmMessage(role: 'system', content: 'be terse'),
        const LlmMessage(role: 'user', content: 'hi'),
        const LlmMessage(role: 'assistant', content: 'hello'),
        const LlmMessage(role: 'user', content: 'how are you'),
      ]);
      expect(seen!.systemPrompt, 'be terse');
      expect(seen!.messages, hasLength(3));
      expect(seen!.messages[0], isA<UserMessage>());
      expect(seen!.messages[1], isA<AssistantMessage>());
      expect(seen!.messages[2], isA<UserMessage>());
    });

    test('an error stream throws and invokes onCancel', () async {
      var cancelled = false;
      final provider = HarnessLlmProvider(
        resolve: () => (
          model: testModel,
          stream: FakeStreamFunction([_errorTurn('boom')]).call,
        ),
      );
      await expectLater(
        provider.chat('hi', onCancel: () => cancelled = true),
        throwsStateError,
      );
      expect(cancelled, isTrue);
    });

    test('a null slot throws StateError', () async {
      final provider = HarnessLlmProvider(resolve: () => null);
      await expectLater(provider.chat('hi'), throwsStateError);
    });
  });
}
