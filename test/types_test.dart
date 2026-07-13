import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('Usage', () {
    test('zero constant has zeroed fields', () {
      expect(Usage.zero.input, 0);
      expect(Usage.zero.output, 0);
      expect(Usage.zero.cacheRead, 0);
      expect(Usage.zero.cacheWrite, 0);
      expect(Usage.zero.totalTokens, 0);
      expect(Usage.zero.cost.total, 0);
    });

    test('copyWith replaces only given fields', () {
      final usage = Usage.zero.copyWith(
        input: 100,
        output: 50,
        reasoning: 10,
        cost: const UsageCost(input: 0.001, total: 0.003),
      );
      expect(usage.input, 100);
      expect(usage.output, 50);
      expect(usage.reasoning, 10);
      expect(usage.cacheRead, 0);
      expect(usage.cost.input, 0.001);
      expect(usage.cost.output, 0);
    });

    test('cacheWrite1h and reasoning are optional', () {
      final usage = Usage.zero.copyWith(cacheWrite1h: 5);
      expect(usage.cacheWrite1h, 5);
      expect(Usage.zero.cacheWrite1h, isNull);
      expect(Usage.zero.reasoning, isNull);
    });
  });

  group('UsageCost', () {
    test('copyWith replaces only given fields', () {
      final cost = const UsageCost().copyWith(output: 0.5, total: 0.5);
      expect(cost.output, 0.5);
      expect(cost.total, 0.5);
      expect(cost.input, 0);
      expect(cost.cacheRead, 0);
      expect(cost.cacheWrite, 0);
    });
  });

  group('ContentBlock', () {
    test('TextContent copyWith', () {
      final text = const TextContent(text: 'a', textSignature: 'sig');
      expect(text.copyWith(text: 'b').text, 'b');
      expect(text.copyWith(text: 'b').textSignature, 'sig');
      expect(text.copyWith(textSignature: 'x').text, 'a');
    });

    test('ThinkingContent copyWith and redacted flag', () {
      final thinking = const ThinkingContent(
        thinking: 'hmm',
        thinkingSignature: 's',
        redacted: true,
      );
      final copy = thinking.copyWith(thinking: 'aha', redacted: false);
      expect(copy.thinking, 'aha');
      expect(copy.redacted, isFalse);
      expect(copy.thinkingSignature, 's');
      expect(thinking.copyWith(thinkingSignature: 's2').thinking, 'hmm');
      expect(const ThinkingContent(thinking: 'x').redacted, isFalse);
    });

    test('ToolCall copyWith', () {
      final call = const ToolCall(
        id: 'c1',
        name: 'search',
        arguments: {},
        partialArguments: '{"q":',
      );
      final done = call.copyWith(
        arguments: {'q': 'dart'},
        thoughtSignature: 'ts',
      );
      expect(done.id, 'c1');
      expect(done.name, 'search');
      expect(done.arguments, {'q': 'dart'});
      expect(done.thoughtSignature, 'ts');
      expect(done.partialArguments, '{"q":');
      expect(call.copyWith(id: 'c2').name, 'search');
    });
  });

  group('AssistantMessage', () {
    test('copyWith replaces only given fields', () {
      final now = DateTime.utc(2026);
      final message = AssistantMessage(
        content: const [],
        api: 'openai-completions',
        provider: 'openrouter',
        model: 'auto',
        responseModel: 'anthropic/claude',
        responseId: 'resp_1',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: now,
      );
      final copy = message.copyWith(
        content: [const TextContent(text: 'hi')],
        stopReason: StopReason.length,
        errorMessage: 'oops',
        timestamp: now.add(const Duration(seconds: 1)),
      );
      expect((copy.content.single as TextContent).text, 'hi');
      expect(copy.stopReason, StopReason.length);
      expect(copy.errorMessage, 'oops');
      expect(copy.api, 'openai-completions');
      expect(copy.provider, 'openrouter');
      expect(copy.model, 'auto');
      expect(copy.responseModel, 'anthropic/claude');
      expect(copy.responseId, 'resp_1');
      expect(copy.usage, same(Usage.zero));
      expect(copy.timestamp, now.add(const Duration(seconds: 1)));
      expect(
        message.copyWith(api: 'anthropic-messages').api,
        'anthropic-messages',
      );
      expect(message.copyWith(provider: 'anthropic').provider, 'anthropic');
      expect(message.copyWith(model: 'gpt-x').model, 'gpt-x');
      expect(message.copyWith(responseModel: 'm').responseModel, 'm');
      expect(message.copyWith(responseId: 'r').responseId, 'r');
      expect(
        message.copyWith(usage: Usage.zero.copyWith(input: 1)).usage.input,
        1,
      );
      expect(message.errorMessage, isNull);
    });
  });

  group('StopReason', () {
    test('has pi\'s exact value set', () {
      expect(StopReason.values, [
        StopReason.stop,
        StopReason.length,
        StopReason.toolUse,
        StopReason.error,
        StopReason.aborted,
      ]);
    });
  });

  group('thinking events', () {
    test('carry contentIndex, payload, and partial', () {
      final partial = AssistantMessage(
        content: const [ThinkingContent(thinking: 'hmm')],
        api: 'a',
        provider: 'p',
        model: 'm',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      final start = ThinkingStartEvent(contentIndex: 0, partial: partial);
      final delta = ThinkingDeltaEvent(
        contentIndex: 0,
        delta: 'hm',
        partial: partial,
      );
      final end = ThinkingEndEvent(
        contentIndex: 0,
        content: 'hmm',
        partial: partial,
      );
      expect(start.partial, same(partial));
      expect(delta.delta, 'hm');
      expect(delta.contentIndex, 0);
      expect(end.content, 'hmm');
      expect(end.partial, same(partial));
    });
  });
}
