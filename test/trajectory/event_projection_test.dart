import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot_builder.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

Usage _usage({int input = 0, int output = 0, int? reasoning}) => Usage(
  input: input,
  output: output,
  cacheRead: 0,
  cacheWrite: 0,
  reasoning: reasoning,
  totalTokens: input + output,
  cost: const UsageCost(),
);

MessageRecord _userRecord(String id, {String? parentId, String text = 'hi'}) =>
    MessageRecord(
      id: id,
      parentId: parentId,
      timestamp: _at(0),
      message: UserMessage.text(text, timestamp: _at(0)),
    );

MessageRecord _assistantRecord(
  String id, {
  String? parentId,
  List<ContentBlock> content = const [TextContent(text: 'answer')],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage? usage,
  DateTime? timestamp,
}) {
  return MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: timestamp ?? _at(1),
    message: AssistantMessage(
      content: content,
      api: 'anthropic-messages',
      provider: 'anthropic',
      model: 'claude-test',
      usage: usage ?? _usage(input: 100, output: 20, reasoning: 8),
      stopReason: stopReason,
      errorMessage: errorMessage,
      timestamp: timestamp ?? _at(1),
    ),
  );
}

MessageRecord _toolResultRecord(
  String id, {
  required String parentId,
  required String callId,
  String text = 'done',
  bool isError = false,
  DateTime? timestamp,
}) {
  return MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: timestamp ?? _at(6),
    message: ToolResultMessage(
      toolCallId: callId,
      toolName: 'bash',
      content: [TextContent(text: text)],
      isError: isError,
      timestamp: timestamp ?? _at(6),
    ),
  );
}

AssistantMessage _streamMessage({
  required List<ContentBlock> content,
  Usage usage = const Usage(
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: UsageCost(),
  ),
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'anthropic-messages',
    provider: 'anthropic',
    model: 'claude-test',
    usage: usage,
    stopReason: stopReason,
    timestamp: _at(1),
  );
}

void main() {
  group('assistant record projection', () {
    test('populates blocks, details, usage, and timing', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      final snapshot = builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          content: [
            ThinkingContent(thinking: 'pondering'),
            const TextContent(text: 'the answer'),
            ToolCall(id: 'c1', name: 'bash', arguments: const {'cmd': 'ls'}),
          ],
        ),
      );
      final record = snapshot.records[1] as TrajectoryAssistantRecord;
      expect(record.sourceBlocks, hasLength(3));
      expect(record.sourceBlocks[0].type, 'thinking');
      expect(record.sourceBlocks[0].content, 'pondering');
      expect(record.sourceBlocks[1].type, 'text');
      expect(record.sourceBlocks[2].type, 'tool-call');
      expect(record.sourceBlocks[2].callId, 'c1');
      expect(record.sourceBlocks[2].toolName, 'bash');
      expect(record.outputBlocks.map((b) => b.type), [
        'thinking',
        'text',
        'tool-call',
      ]);
      expect(record.outputDetail, 'the answer');
      expect(record.thinkingDetail, 'pondering');
      expect(record.displayText, '');
      expect(record.usage!.input, 100);
      expect(record.reasoningTokens, 8);
      expect(record.completedTime, _at(1));
      expect(record.timeSeconds, const Duration(seconds: 1));
      expect(record.isError, isFalse);
    });

    test('tool-call-only messages carry the fallback label', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        _assistantRecord(
          'a1',
          content: [ToolCall(id: 'c1', name: 'bash', arguments: const {})],
        ),
      );
      final record = snapshot.records.first as TrajectoryAssistantRecord;
      expect(record.displayText, 'Tool call only');
      expect(record.outputDetail, isNull);
    });

    test('image-only messages carry an image count label', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        _assistantRecord(
          'a1',
          content: [const ImageContent(data: 'aa', mimeType: 'image/png')],
        ),
      );
      final record = snapshot.records.first as TrajectoryAssistantRecord;
      expect(record.displayText, 'Images ×1');
      expect(record.sourceBlocks.single.type, 'image');
      expect(record.sourceBlocks.single.attachmentName, 'image/png');
    });

    test('user rows keep source blocks and request detail', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        MessageRecord(
          id: 'u1',
          parentId: null,
          timestamp: _at(0),
          message: UserMessage(
            content: [
              const TextContent(text: 'look'),
              const ImageContent(data: 'bb', mimeType: 'image/jpeg'),
            ],
            timestamp: _at(0),
          ),
        ),
      );
      final record = snapshot.records.single as TrajectoryUserRecord;
      expect(record.sourceBlocks.map((b) => b.type), ['text', 'image']);
      expect(record.inputDetail, 'look');
      expect(record.text, 'look');
    });

    test('tool durations clamp negative gaps to zero', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_assistantRecord('a1', timestamp: _at(6)));
      final snapshot = builder.append(
        _toolResultRecord('r1', parentId: 'a1', callId: 'ghost-call'),
      );
      expect(snapshot.records, hasLength(1));
    });

    test('compaction rows carry a bounded preview and full summary', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        CompactionRecord(
          id: 'cp1',
          parentId: null,
          timestamp: _at(2),
          summary: 'summary text',
          firstKeptEntryId: 'u5',
          tokensBefore: 900,
        ),
      );
      final record = snapshot.records.single as TrajectoryCompactedRecord;
      expect(record.text, 'summary text');
      expect(record.summary, 'summary text');
    });
  });

  group('request roll-up', () {
    test('numbers requests session-globally and folds cumulative usage', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          usage: _usage(input: 10, output: 1),
        ),
      );
      builder.append(
        CompactionRecord(
          id: 'cp1',
          parentId: 'a1',
          timestamp: _at(2),
          summary: 'so far',
          firstKeptEntryId: 'u1',
          tokensBefore: 900,
        ),
      );
      builder.append(_userRecord('u2', parentId: 'cp1', text: 'next'));
      final snapshot = builder.append(
        _assistantRecord(
          'a2',
          parentId: 'u2',
          timestamp: _at(3),
          usage: _usage(input: 20, output: 2),
        ),
      );
      expect(snapshot.requests, hasLength(3));
      final first = snapshot.requests[0];
      expect(first.seq, 1);
      expect(first.purpose, TrajectoryRequestPurpose.assistant);
      expect(first.turn, 1);
      expect(first.step, 1);
      expect(first.provider, 'anthropic');
      expect(first.model, 'claude-test');
      expect(first.status, TrajectoryRequestStatus.completed);
      expect(first.usage!.input, 10);
      expect(first.cumulativeUsage!.input, 10);
      final compaction = snapshot.requests[1];
      expect(compaction.seq, 2);
      expect(compaction.purpose, TrajectoryRequestPurpose.compaction);
      expect(compaction.step, 0);
      expect(compaction.usage, isNull);
      expect(compaction.cumulativeUsage!.input, 10);
      final second = snapshot.requests[2];
      expect(second.seq, 3);
      expect(second.turn, 2);
      expect(second.usage!.input, 20);
      expect(second.cumulativeUsage!.input, 30);
      expect(second.cumulativeUsage!.output, 3);
    });

    test('failed stop reasons map to failed requests', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      final snapshot = builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          stopReason: StopReason.error,
          errorMessage: 'boom',
        ),
      );
      expect(snapshot.requests.single.status, TrajectoryRequestStatus.failed);
      final record = snapshot.records.last as TrajectoryAssistantRecord;
      expect(record.isError, isTrue);
      expect(record.errorMessage, 'boom');
    });
  });

  group('applyEvent live tail', () {
    test('start and update build the partial and a running request', () {
      final builder = TrajectorySnapshotBuilder();
      final start = builder.applyEvent(
        MessageStartEvent(_streamMessage(content: const [])),
      );
      expect(start.partial, isNotNull);
      expect(start.partial!.turn, 0);
      expect(start.partial!.step, 1);
      expect(start.requests.single.status, TrajectoryRequestStatus.running);
      final update = builder.applyEvent(
        MessageUpdateEvent(
          message: _streamMessage(
            content: const [
              TextContent(text: 'hel'),
              ToolCall(
                id: 'c1',
                name: 'bash',
                arguments: {},
                partialArguments: '{"c',
              ),
            ],
          ),
          assistantMessageEvent: TextDeltaEvent(
            contentIndex: 0,
            delta: 'hel',
            partial: _streamMessage(content: const [TextContent(text: 'hel')]),
          ),
        ),
      );
      expect(update.partial!.blocks.map((b) => (b.type, b.content)), [
        ('text', 'hel'),
        ('tool-call', '{"c'),
      ]);
    });

    test('streaming to MessageEnd equals the one-shot append', () {
      final finalMessage = _streamMessage(
        content: [
          const TextContent(text: 'hello'),
          ToolCall(id: 'c1', name: 'bash', arguments: const {'cmd': 'ls'}),
        ],
        usage: _usage(input: 100, output: 20, reasoning: 8),
      );
      final streamedBuilder = TrajectorySnapshotBuilder();
      streamedBuilder.applyEvent(
        MessageStartEvent(_streamMessage(content: const [])),
      );
      streamedBuilder.applyEvent(
        MessageUpdateEvent(
          message: _streamMessage(
            content: const [TextContent(text: 'hel')],
            usage: Usage(
              input: 10,
              output: 2,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 12,
              cost: const UsageCost(),
            ),
          ),
          assistantMessageEvent: TextDeltaEvent(
            contentIndex: 0,
            delta: 'hel',
            partial: _streamMessage(content: const [TextContent(text: 'hel')]),
          ),
        ),
      );
      final streamed = streamedBuilder.applyEvent(
        MessageEndEvent(finalMessage),
      );
      expect(streamed.partial, isNull);
      final oneshot = TrajectorySnapshotBuilder().append(
        MessageRecord(
          id: 'a1',
          parentId: null,
          timestamp: _at(1),
          message: finalMessage,
        ),
      );

      expect(streamed.records, hasLength(oneshot.records.length));
      for (var i = 0; i < streamed.records.length; i++) {
        final streamedRecord = streamed.records[i];
        final oneshotRecord = oneshot.records[i];
        expect(streamedRecord.kind, oneshotRecord.kind);
        expect(streamedRecord.index, oneshotRecord.index);
      }
      final streamedMessage = streamed.records[0] as TrajectoryAssistantRecord;
      final oneshotMessage = oneshot.records[0] as TrajectoryAssistantRecord;
      expect(streamedMessage.turn, oneshotMessage.turn);
      expect(streamedMessage.step, oneshotMessage.step);
      expect(streamedMessage.outputDetail, oneshotMessage.outputDetail);
      expect(streamedMessage.usage!.input, oneshotMessage.usage!.input);
      expect(streamedMessage.completedTime, oneshotMessage.completedTime);
      final streamedTool = streamed.records[1] as TrajectoryToolRecord;
      final oneshotTool = oneshot.records[1] as TrajectoryToolRecord;
      expect(streamedTool.callId, oneshotTool.callId);
      expect(streamedTool.argsRaw, oneshotTool.argsRaw);
      expect(streamed.requests.single.seq, oneshot.requests.single.seq);
      expect(streamed.requests.single.status, oneshot.requests.single.status);
      expect(
        streamed.requests.single.usage!.input,
        oneshot.requests.single.usage!.input,
      );
    });

    test('a real record replaces the streamed rows for its turn:step', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.applyEvent(MessageStartEvent(_streamMessage(content: const [])));
      final finalMessage = _streamMessage(
        content: const [TextContent(text: 'hello')],
        usage: _usage(input: 100, output: 20),
      );
      builder.applyEvent(MessageEndEvent(finalMessage));
      final snapshot = builder.append(_assistantRecord('a1', parentId: 'u1'));
      final messages = snapshot.records
          .whereType<TrajectoryAssistantRecord>()
          .toList();
      expect(messages, hasLength(1));
      expect(messages.single.messageId, 'a1');
      expect(messages.single.index, 2);
      expect(snapshot.recordLocations['a1'], 1);
      // The finalized row measures from the real user record, not from the
      // mirrored row that briefly consumed the cursor.
      expect(messages.single.timeSeconds, const Duration(seconds: 1));
    });

    test('event tool results settle the tool row and running call', () {
      final builder = TrajectorySnapshotBuilder();
      builder.applyEvent(MessageStartEvent(_streamMessage(content: const [])));
      builder.applyEvent(
        MessageEndEvent(
          _streamMessage(
            content: [
              ToolCall(id: 'c1', name: 'bash', arguments: const {'cmd': 'ls'}),
            ],
            usage: _usage(input: 10, output: 2),
          ),
        ),
      );
      final settled = builder.applyEvent(
        MessageEndEvent(
          ToolResultMessage(
            toolCallId: 'c1',
            toolName: 'bash',
            content: const [TextContent(text: 'files')],
            isError: false,
            timestamp: _at(6),
          ),
        ),
      );
      final tool = settled.records[1] as TrajectoryToolRecord;
      expect(tool.result, 'files');
      expect(tool.timeSeconds, const Duration(seconds: 5));
      expect(settled.runningCalls, isEmpty);
    });

    test('tool execution start registers a running call', () {
      final builder = TrajectorySnapshotBuilder();
      builder.applyEvent(MessageStartEvent(_streamMessage(content: const [])));
      final snapshot = builder.applyEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c9',
          toolName: 'grep',
          args: {},
          timestamp: _at(3),
        ),
      );
      final call = snapshot.runningCalls.single;
      expect(call.callId, 'c9');
      expect(call.name, 'grep');
      expect(call.turn, 0);
      expect(call.step, 1);
      expect(call.startedAt, _at(3));
      final settled = builder.append(
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: _at(2),
          message: ToolResultMessage(
            toolCallId: 'c9',
            toolName: 'grep',
            content: const [TextContent(text: 'x')],
            isError: false,
            timestamp: _at(2),
          ),
        ),
      );
      expect(settled.runningCalls, isEmpty);
    });

    test('ignores non-message events gracefully', () {
      final builder = TrajectorySnapshotBuilder();
      final first = builder.applyEvent(const TurnStartEvent());
      final second = builder.applyEvent(AgentEndEvent(const []));
      expect(second.records, isEmpty);
      expect(second.requests, isEmpty);
      expect(second.runningCalls, isEmpty);
      expect(second.partial, isNull);
      expect(second.revision, greaterThan(first.revision));
    });
  });
}
