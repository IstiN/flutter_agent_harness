import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-1577: the empty-completion classifier — pure unit tests (UT-1..UT-5).
///
/// An empty completion that follows partial content (assistant text, tool
/// activity, or a truncation signal) is a retryable provider hiccup, never a
/// settleable final answer; a clean empty keeps the one-shot-nudge semantics
/// (issue #1085 M2b); aborted/errored streams are never classified empty.
void main() {
  AssistantMessage assistant({
    List<ContentBlock> content = const [],
    StopReason stopReason = StopReason.stop,
    String? errorMessage,
  }) => AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );

  group('classifyEmptyCompletion (UT-1..UT-5, gh-1577)', () {
    test('UT-1: empty after partial text in the turn → emptyAfterPartial', () {
      final turn = [
        UserMessage.text('write the parser'),
        assistant(content: [TextContent(text: 'unsigned long N = strtoul')]),
        assistant(),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.emptyAfterPartial,
      );
    });

    test(
      'UT-2: empty after a StopReason.length message → emptyAfterPartial',
      () {
        final turn = [
          UserMessage.text('go'),
          assistant(
            content: [TextContent(text: 'partial')],
            stopReason: StopReason.length,
          ),
          assistant(),
        ];
        expect(
          classifyEmptyCompletion(turn, turn.last as AssistantMessage),
          EmptyCompletionVerdict.emptyAfterPartial,
        );
      },
    );

    test('UT-2: empty after a silent-truncation-flagged message → '
        'emptyAfterPartial', () {
      final turn = [
        UserMessage.text('go'),
        assistant(
          content: [TextContent(text: 'partial')],
          errorMessage:
              'stream ended without finish_reason — the reply may be '
              'truncated',
        ),
        assistant(),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.emptyAfterPartial,
      );
    });

    test('UT-1: empty after tool activity in the turn → emptyAfterPartial', () {
      final turn = [
        UserMessage.text('go'),
        assistant(
          content: [ToolCall(id: 'c1', name: 'bash', arguments: {})],
        ),
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'bash',
          content: [TextContent(text: 'tool error: truncated arguments')],
          isError: true,
          timestamp: DateTime.utc(2026),
        ),
        assistant(),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.emptyAfterPartial,
      );
    });

    test('UT-3: empty with no partial content anywhere → cleanEmpty', () {
      final turn = [UserMessage.text('hi'), assistant()];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.cleanEmpty,
      );
    });

    test('UT-3/E1: the partial-content window is the TURN — an old truncation '
        'from a previous turn cannot resurrect retries', () {
      final history = [
        UserMessage.text('earlier task'),
        assistant(
          content: [TextContent(text: 'truncated back then')],
          stopReason: StopReason.length,
        ),
        ToolResultMessage(
          toolCallId: 'c9',
          toolName: 'bash',
          content: [TextContent(text: 'out')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
        // A fresh logical turn begins here.
        UserMessage.text('new question'),
        assistant(),
      ];
      expect(
        classifyEmptyCompletion(history, history.last as AssistantMessage),
        EmptyCompletionVerdict.cleanEmpty,
      );
    });

    test('UT-3: aborted stop is never classified empty (guard kept)', () {
      final turn = [
        UserMessage.text('go'),
        assistant(
          content: [TextContent(text: 'partial')],
          stopReason: StopReason.length,
        ),
        assistant(stopReason: StopReason.aborted, errorMessage: 'aborted'),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.abortedOrError,
      );
    });

    test('UT-3: error stop is never classified empty (guard kept)', () {
      final turn = [
        UserMessage.text('go'),
        assistant(stopReason: StopReason.error, errorMessage: 'boom'),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.abortedOrError,
      );
    });

    test('UT-5: thinking-only WITH a tool call is not empty (ToolCall boundary '
        'survives)', () {
      final message = assistant(
        content: [
          ThinkingContent(thinking: 'reasoning...'),
          const ToolCall(id: 'c1', name: 'bash', arguments: {}),
        ],
      );
      expect(
        classifyEmptyCompletion([UserMessage.text('go'), message], message),
        EmptyCompletionVerdict.notEmpty,
      );
    });

    test('UT-5: thinking-only without text or tool calls IS empty', () {
      final message = assistant(
        content: [ThinkingContent(thinking: 'reasoning...')],
      );
      expect(
        classifyEmptyCompletion([UserMessage.text('go'), message], message),
        EmptyCompletionVerdict.cleanEmpty,
      );
    });

    test('UT-5: whitespace-only text IS empty', () {
      final message = assistant(content: [TextContent(text: '  \n\t ')]);
      expect(
        classifyEmptyCompletion([UserMessage.text('go'), message], message),
        EmptyCompletionVerdict.cleanEmpty,
      );
    });

    test('UT-5: real text is not empty', () {
      final message = assistant(content: [TextContent(text: 'answer')]);
      expect(
        classifyEmptyCompletion([UserMessage.text('go'), message], message),
        EmptyCompletionVerdict.notEmpty,
      );
    });

    test('E6: an empty message that is itself truncation-flagged is hiccup '
        'evidence on its own', () {
      final turn = [
        UserMessage.text('go'),
        assistant(
          errorMessage:
              'stream ended without finish_reason — the reply may be '
              'truncated',
        ),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.emptyAfterPartial,
      );
    });
  });

  group('emptyHiccupBackoffFor (UT-4)', () {
    test('exponential from the base, capped at the max, deterministic', () {
      const base = Duration(milliseconds: 500);
      const max = Duration(seconds: 8);
      expect(
        emptyHiccupBackoffFor(attempt: 0, baseDelay: base, maxBackoff: max),
        const Duration(milliseconds: 500),
      );
      expect(
        emptyHiccupBackoffFor(attempt: 1, baseDelay: base, maxBackoff: max),
        const Duration(milliseconds: 1000),
      );
      expect(
        emptyHiccupBackoffFor(attempt: 2, baseDelay: base, maxBackoff: max),
        const Duration(milliseconds: 2000),
      );
      expect(
        emptyHiccupBackoffFor(attempt: 3, baseDelay: base, maxBackoff: max),
        const Duration(milliseconds: 4000),
      );
      // The cap holds for absurd attempt numbers.
      expect(
        emptyHiccupBackoffFor(attempt: 20, baseDelay: base, maxBackoff: max),
        max,
      );
    });
  });

  group('continuation nudge transparency (gh-1603)', () {
    test('UT-N1: the loop-injected nudge does not reset the partial-content '
        'window — a nudged retry stays a hiccup', () {
      final turn = [
        UserMessage.text('do the task'),
        assistant(
          content: [const ToolCall(id: 'c1', name: 'bash', arguments: {})],
        ),
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'bash',
          content: [TextContent(text: 'ok')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
        assistant(),
        UserMessage.text(emptyContinuationNudge),
        assistant(),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.emptyAfterPartial,
      );
    });

    test('UT-N2: a real user message still ends the window — cleanEmpty', () {
      final turn = [
        UserMessage.text('do the task'),
        assistant(
          content: [const ToolCall(id: 'c1', name: 'bash', arguments: {})],
        ),
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'bash',
          content: [TextContent(text: 'ok')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
        UserMessage.text('actually, just say hi'),
        assistant(),
      ];
      expect(
        classifyEmptyCompletion(turn, turn.last as AssistantMessage),
        EmptyCompletionVerdict.cleanEmpty,
      );
    });

    test('UT-N3: the nudge marker recognizes only the exact message', () {
      expect(
        isContinuationNudgeMessage(UserMessage.text(emptyContinuationNudge)),
        isTrue,
      );
      expect(isContinuationNudgeMessage(UserMessage.text('continue')), isFalse);
      expect(
        isContinuationNudgeMessage(
          UserMessage.text('$emptyContinuationNudge!'),
        ),
        isFalse,
      );
      expect(
        isContinuationNudgeMessage(
          assistant(content: [TextContent(text: emptyContinuationNudge)]),
        ),
        isFalse,
      );
    });

    test('UT-N4: the nudge text carries the truncation + continuation ask', () {
      expect(emptyContinuationNudge, contains('empty'));
      expect(emptyContinuationNudge, contains('truncated'));
      expect(emptyContinuationNudge, contains('continue the task'));
    });
  });

  group('emptyHiccupExhaustedError', () {
    test('names the retry count, the attempt count, and the stop reason', () {
      final message = emptyHiccupExhaustedError(
        retryCount: 3,
        attempts: 4,
        lastStopReason: StopReason.stop,
      );
      expect(message, contains('empty'));
      expect(message, contains('4 attempts'));
      expect(message, contains('3 retries'));
      expect(message, contains('stop'));
    });
  });
}
