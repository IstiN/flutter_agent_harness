/// Issue #862: the tool-misuse circuit breaker — unit coverage of the state
/// machine and IT-3: a scripted model repeating the same malformed call gets
/// a corrective note in the next request payload at 3 identical failures and
/// an execution-refusing honest error at 6, while the transcript stays clean.

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

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn whose assistant message repeats ONE malformed tool call.
List<AssistantMessageEvent> _badCallTurn(String id, String toolName) {
  final call = ToolCall(id: id, name: toolName, arguments: const {});
  final empty = _assistant();
  final partial = _assistant(
    content: [call],
    stopReason: StopReason.toolUse,
  );
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

/// Fake [StreamFunction]: replays scripted turns, records every request
/// payload it was called with.
class _FakeStream {
  _FakeStream(this.turns);

  final List<List<AssistantMessageEvent>> turns;
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
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

Tool _tool(String name) => Tool(
  name: name,
  description: 'Runs the flaky operation. Takes one required parameter.',
  parameters: const {
    'type': 'object',
    'properties': {
      'target': {'type': 'string'},
    },
    'required': ['target'],
  },
);

void main() {
  group('ToolMisuseBreaker state machine', () {
    test('arms a corrective note at the 3rd identical failure, once', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      expect(breaker.observeFailure('edit', args, 'boom'), isFalse);
      expect(breaker.observeFailure('edit', args, 'boom'), isFalse);
      expect(breaker.observeFailure('edit', args, 'boom'), isTrue);
      expect(breaker.drainPendingNote(), contains('3 consecutive times'));
      // The note fires ONCE per key.
      expect(breaker.drainPendingNote(), isNull);
      expect(breaker.observeFailure('edit', args, 'boom'), isFalse);
    });

    test('a different error restarts the consecutive count', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      breaker.observeFailure('edit', args, 'boom one');
      breaker.observeFailure('edit', args, 'boom one');
      // Different error text = a different failure: count restarts.
      expect(breaker.observeFailure('edit', args, 'boom two'), isFalse);
      expect(breaker.refusalFor('edit', args), isNull);
    });

    test('marks the identical call stopped at the 6th failure and the loop '
        'refusal names the misuse', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      for (var i = 0; i < 6; i++) {
        breaker.observeFailure('edit', args, 'boom');
      }
      final refusal = breaker.refusalFor('edit', args);
      expect(refusal, isNotNull);
      expect(refusal, contains('6 consecutive times'));
      expect(refusal, contains('Change the arguments'));
    });

    test('E2: counters are per tool, not global', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      breaker.observeFailure('edit', args, 'boom');
      breaker.observeFailure('edit', args, 'boom');
      expect(breaker.observeFailure('read', args, 'boom'), isFalse);
      expect(breaker.observeFailure('edit', args, 'boom'), isTrue);
    });

    test('a success clears that tool\'s consecutive-failure state', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      breaker.observeFailure('edit', args, 'boom');
      breaker.observeFailure('edit', args, 'boom');
      breaker.observeSuccess('edit');
      expect(breaker.refusalFor('edit', args), isNull);
      // Two more failures stay below the note threshold.
      expect(breaker.observeFailure('edit', args, 'boom'), isFalse);
    });

    test('aborted calls never count', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      for (var i = 0; i < 3; i++) {
        expect(
          breaker.observeFailure('edit', args, 'Operation aborted'),
          isFalse,
        );
      }
      expect(breaker.refusalFor('edit', args), isNull);
      expect(breaker.drainPendingNote(), isNull);
    });

    test('beginRun wipes counters, notes, and stopped keys', () {
      final breaker = ToolMisuseBreaker();
      final args = {'target': 'x'};
      for (var i = 0; i < 6; i++) {
        breaker.observeFailure('edit', args, 'boom');
      }
      breaker.beginRun();
      expect(breaker.refusalFor('edit', args), isNull);
      expect(breaker.drainPendingNote(), isNull);
    });
  });

  group('IT-3: breaker over the real agent loop (AC6)', () {
    test('3 identical validation failures arm the corrective note in the '
        'NEXT request payload; 6 stop executing the identical call',
        () async {
      final breaker = ToolMisuseBreaker();
      var executions = 0;
      final registry = ToolRegistry([
        AgentTool(
          name: 'flaky',
          description: 'Runs the flaky operation.',
          parameters: _tool('flaky').parameters,
          execute: (args, cancelToken, onUpdate) async {
            executions++;
            return ToolExecutionResult.text('ran');
          },
        ),
      ]);
      // Eight malformed turns (missing the required `target` param), then
      // the model gives up.
      final fake = _FakeStream([
        for (var i = 1; i <= 8; i++) _badCallTurn('c$i', 'flaky'),
        _textTurn('giving up'),
      ]);

      final stream = agentLoop(
        prompts: [UserMessage.text('do the thing')],
        context: Context(
          messages: const [],
          tools: [_tool('flaky')],
        ),
        config: AgentLoopConfig(model: _model, toolMisuseBreaker: breaker),
        streamFunction: fake.call,
        toolExecutor: registry.executor,
      );
      final messages = await stream.result;

      // Request payloads: the first 8 requests answer tool turns, the 9th
      // the final text turn.
      expect(fake.contexts.length, 9);

      // Failures 1-2 arm nothing; failure 3 arms the note — visible in the
      // request AFTER the 3rd failure, as a trailing user message.
      String payloadNote(int requestIndex) {
        final messages = fake.contexts[requestIndex].messages;
        for (final message in messages.reversed) {
          if (message is UserMessage &&
              '${message.content}'.contains('[tool-misuse notice]')) {
            return '${message.content}';
          }
        }
        return '';
      }

      expect(payloadNote(1), isEmpty, reason: 'one failure arms nothing');
      expect(payloadNote(2), isEmpty, reason: 'two failures arm nothing');
      final note = payloadNote(3);
      expect(note, contains('[tool-misuse notice]'));
      expect(note, contains('"flaky"'));
      expect(note, contains('3 consecutive times'));
      expect(note, contains('Tool contract (excerpt)'));
      // One note, not three: the 4th+ payloads carry no NEW note.
      expect(payloadNote(4), isEmpty);

      // The 6th failure marks the call stopped: turns 7-8 are refused
      // WITHOUT executing the tool.
      expect(executions, 0, reason: 'validation fails before every execute');
      final lastResults =
          messages.whereType<ToolResultMessage>().toList();
      expect(lastResults, hasLength(8));
      final refusalText =
          '${(lastResults.last.content.single as TextContent).text}';
      expect(refusalText, contains('refused'));
      expect(refusalText, contains('6 consecutive times'));
      expect(refusalText, contains('Change the arguments'));

      // The transcript itself never carries the note (request-only).
      final transcriptHasNote = messages.any(
        (message) =>
            message.role == 'user' &&
            message is UserMessage &&
            '${message.content}'.contains('[tool-misuse notice]'),
      );
      expect(transcriptHasNote, isFalse);
    });

    test('E5: breaker off (null) preserves pre-breaker behavior', () async {
      var executions = 0;
      final registry = ToolRegistry([
        AgentTool(
          name: 'flaky',
          description: 'Runs the flaky operation.',
          parameters: _tool('flaky').parameters,
          execute: (args, cancelToken, onUpdate) async {
            executions++;
            return ToolExecutionResult.text('ran');
          },
        ),
      ]);
      final fake = _FakeStream([
        for (var i = 1; i <= 5; i++) _badCallTurn('c$i', 'flaky'),
        _textTurn('giving up'),
      ]);

      final stream = agentLoop(
        prompts: [UserMessage.text('do the thing')],
        context: Context(messages: const [], tools: [_tool('flaky')]),
        config: AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: registry.executor,
      );
      await stream.result;

      // Every payload is byte-identical to a no-breaker run: no injected
      // user note anywhere.
      for (final context in fake.contexts) {
        expect(
          context.messages.any(
            (message) =>
                message is UserMessage &&
                '${message.content}'.contains('[tool-misuse notice]'),
          ),
          isFalse,
        );
      }
      // No refusals: validation errors every turn, exactly as before —
      // every turn still gets a (failing) tool result, never a refusal, and
      // the note never appears.
      expect(
        fake.contexts.last.messages.whereType<ToolResultMessage>().length,
        5,
      );
      expect(executions, 0);
    });
  });
}
