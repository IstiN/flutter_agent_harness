@TestOn('vm')
library;

/// gh-2492 C2 belt — the trim valve honours the segment pins.
///
/// `localTrimValve` is the mechanical last resort behind four tiers (the
/// resume boot cap, the over-window continuation, the emergency relief,
/// the summarizer-down fallback). For a task child its cut must never
/// take the pinned records — the task prompt and the newest steering —
/// out of the live context: they re-home right after the trim marker
/// like the pinned boundary summaries and the unanswered mail already
/// do. REG-6: the pins change no predicate — mail still classifies as
/// synthetic, and a pinned steering record behind the cut is carried as
/// DATA.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/agent/auto_compactor.dart'
    show localTrimValve;
import 'package:test/test.dart';

AssistantMessage _answer(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(String id) => ToolResultMessage(
  toolCallId: id,
  toolName: 'read',
  content: [TextContent(text: 'result ${'r' * 300}')],
  isError: false,
  timestamp: DateTime.utc(2026),
);

String _textOf(Message message) {
  final content = switch (message) {
    UserMessage(:final content) => content,
    _ => null,
  };
  return content is String ? content : '';
}

const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 200,
  keepRecentTokens: 600,
);

void main() {
  group('localTrimValve pinned messages (gh-2492 C2 belt)', () {
    test('the pinned task prompt and newest steering behind the cut are '
        'carried right after the marker', () {
      final prompt = UserMessage.text(
        'Complete the assignment below: ${'a' * 200}',
      );
      final steering = UserMessage.text('from parent-main: steer to plan B');
      final messages = <Message>[
        prompt,
        _answer('ack'),
        for (var i = 0; i < 8; i++) ...[
          UserMessage.text('filler question $i ${'q' * 300}'),
          _answer('filler answer $i'),
          _result('call$i'),
        ],
        steering,
        UserMessage.text('tail question ${'t' * 200}'),
      ];
      final trimmed = localTrimValve(
        messages: messages,
        reason: 'test',
        window: 5000,
        settings: _settings,
        overheadTokens: 0,
        pinnedMessages: [prompt, steering],
      );
      expect(trimmed, isNotNull);
      final texts = [
        for (final message in trimmed!.messages)
          if (message is UserMessage) _textOf(message),
      ];
      // The pinned prompt re-homes behind the marker (its original head
      // position was cut away).
      expect(texts.first.startsWith('[context trimmed locally:'), isTrue);
      expect(
        texts.where((text) => text.contains('Complete the assignment')),
        hasLength(1),
        reason: 'the pinned prompt is carried exactly once',
      );
      expect(
        texts.where((text) => text.contains('steer to plan B')),
        hasLength(1),
        reason: 'the pinned steering is carried exactly once',
      );
      expect(trimmed.dropped, greaterThan(0));
    });

    test('a pinned message inside the kept region is not duplicated', () {
      final steering = UserMessage.text('from parent-main: newest steering');
      final messages = <Message>[
        UserMessage.text('head ${'h' * 400}'),
        for (var i = 0; i < 8; i++) ...[
          UserMessage.text('filler $i ${'q' * 300}'),
          _result('call$i'),
        ],
        steering,
        UserMessage.text('tail ${'t' * 300}'),
      ];
      final trimmed = localTrimValve(
        messages: messages,
        reason: 'test',
        window: 5000,
        settings: _settings,
        overheadTokens: 0,
        pinnedMessages: [steering],
      );
      expect(trimmed, isNotNull);
      final texts = [
        for (final message in trimmed!.messages)
          if (message is UserMessage) _textOf(message),
      ];
      expect(
        texts.where((text) => text.contains('newest steering')),
        hasLength(1),
        reason: 'a pinned message inside the kept region stays put',
      );
    });

    test('with no pinned messages the valve is byte-identical to before', () {
      final messages = <Message>[
        UserMessage.text('head ${'h' * 400}'),
        for (var i = 0; i < 8; i++) ...[
          UserMessage.text('filler $i ${'q' * 300}'),
          _result('call$i'),
        ],
        UserMessage.text('tail ${'t' * 300}'),
      ];
      final without = localTrimValve(
        messages: messages,
        reason: 'test',
        window: 5000,
        settings: _settings,
        overheadTokens: 0,
      );
      final withEmpty = localTrimValve(
        messages: messages,
        reason: 'test',
        window: 5000,
        settings: _settings,
        overheadTokens: 0,
        pinnedMessages: const [],
      );
      expect(without, isNotNull);
      expect(withEmpty, isNotNull);
      expect(withEmpty!.dropped, without!.dropped);
      expect(withEmpty.messages.length, without.messages.length);
    });
  });
}
