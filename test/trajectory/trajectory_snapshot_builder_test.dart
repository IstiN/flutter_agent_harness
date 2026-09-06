import 'dart:convert';

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

MessageRecord _userRecord(String id, {String? parentId, String text = 'hi'}) =>
    MessageRecord(
      id: id,
      parentId: parentId,
      timestamp: _at(0),
      message: UserMessage.text(text),
    );

MessageRecord _assistantRecord(
  String id, {
  String? parentId,
  List<ContentBlock> content = const [TextContent(text: 'answer')],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage? usage,
}) {
  return MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: _at(1),
    message: AssistantMessage(
      content: content,
      api: 'anthropic-messages',
      provider: 'anthropic',
      model: 'claude-test',
      usage:
          usage ??
          const Usage(
            input: 100,
            output: 20,
            cacheRead: 30,
            cacheWrite: 5,
            reasoning: 8,
            totalTokens: 163,
            cost: UsageCost(),
          ),
      stopReason: stopReason,
      errorMessage: errorMessage,
      timestamp: _at(1),
    ),
  );
}

ToolCall _toolCall(
  String id, {
  String name = 'bash',
  Map<String, dynamic>? args,
  String? parentCallId,
}) => ToolCall(
  id: id,
  name: name,
  arguments: args ?? const {'cmd': 'ls'},
  parentCallId: parentCallId,
);

MessageRecord _toolResultRecord(
  String id, {
  required String parentId,
  required String callId,
  String text = 'done',
  bool isError = false,
}) {
  return MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: _at(6),
    message: ToolResultMessage(
      toolCallId: callId,
      toolName: 'bash',
      content: [TextContent(text: text)],
      isError: isError,
      timestamp: _at(6),
    ),
  );
}

void main() {
  group('mapping rules', () {
    test('user message maps to a user record that opens the turn', () {
      final snapshot = TrajectorySnapshotBuilder().append(_userRecord('u1'));
      final record = snapshot.records.single as TrajectoryUserRecord;
      expect(record.kind, TrajectoryCellKind.user);
      expect(record.text, 'hi');
      expect(record.opensTurn, isTrue);
      expect(record.previewMarkdown, 'hi');
      expect(record.startedAt, _at(0));
    });

    test('assistant message maps to a message record with usage facts', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      final snapshot = builder.append(_assistantRecord('a1', parentId: 'u1'));
      final record = snapshot.records.last as TrajectoryAssistantRecord;
      expect(record.kind, TrajectoryCellKind.message);
      expect(record.messageId, 'a1');
      expect(record.provider, 'anthropic');
      expect(record.model, 'claude-test');
      expect(record.inputTokens, 100);
      expect(record.cacheReadTokens, 30);
      expect(record.cacheWriteTokens, 5);
      expect(record.outputTokens, 20);
      expect(record.reasoningTokens, 8);
      expect(record.completedTime, _at(1));
      expect(record.isError, isFalse);
      expect(record.turn, 1);
      expect(record.step, 1);
    });

    test('failed assistant stop reason surfaces as an error', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      final snapshot = builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          stopReason: StopReason.error,
          errorMessage: 'boom',
        ),
      );
      final record = snapshot.records.last as TrajectoryAssistantRecord;
      expect(record.isError, isTrue);
      expect(record.errorMessage, 'boom');
    });

    test('assistant tool calls create tool records after the message', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      final snapshot = builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          content: [
            const TextContent(text: 'running'),
            _toolCall('c1'),
            _toolCall('c2', name: 'read'),
          ],
        ),
      );
      expect(snapshot.records, hasLength(4));
      final assistant = snapshot.records[1] as TrajectoryAssistantRecord;
      expect(assistant.step, 1);
      final first = snapshot.records[2] as TrajectoryToolRecord;
      expect(first.kind, TrajectoryCellKind.tool);
      expect(first.callId, 'c1');
      expect(first.parentCallId, isNull);
      expect(first.name, 'bash');
      expect(first.argsRaw, '{"cmd":"ls"}');
      expect(first.result, '');
      expect(first.recordId, 'tool\u0000call\u0000c1');
      final second = snapshot.records[3] as TrajectoryToolRecord;
      expect(second.callId, 'c2');
      expect(second.name, 'read');
    });

    test('nested tool calls map to subtool records bound to their parent', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          content: [
            const TextContent(text: 'running'),
            _toolCall('c1'),
            _toolCall('c1-1', name: 'read', parentCallId: 'c1'),
          ],
        ),
      );
      final snapshot = builder.append(
        _toolResultRecord('r1', parentId: 'a1', callId: 'c1'),
      );
      final settled = builder.append(
        _toolResultRecord('r2', parentId: 'a1', callId: 'c1-1'),
      );
      expect(snapshot.records, hasLength(4));
      final parent = snapshot.records[2] as TrajectoryToolRecord;
      expect(parent.kind, TrajectoryCellKind.tool);
      expect(parent.parentCallId, isNull);
      final nested = settled.records[3] as TrajectoryToolRecord;
      expect(nested.kind, TrajectoryCellKind.subtool);
      expect(nested.callId, 'c1-1');
      expect(nested.parentCallId, 'c1');
      expect(nested.index, parent.index + 1);
      // The result binding went through withResult and kept the link.
      expect(nested.result, 'done');
    });

    test('ToolCall serializes parentCallId only when set', () {
      final nested = _toolCall('c1-1', parentCallId: 'c1');
      expect(nested.toJson()['parentCallId'], 'c1');
      expect(ToolCall.fromJson(nested.toJson()).parentCallId, 'c1');
      final top = _toolCall('c1');
      expect(top.toJson().containsKey('parentCallId'), isFalse);
      expect(ToolCall.fromJson(top.toJson()).parentCallId, isNull);
    });

    test('tool result updates the matching tool record', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      builder.append(
        _assistantRecord('a1', parentId: 'u1', content: [_toolCall('c1')]),
      );
      final snapshot = builder.append(
        _toolResultRecord('r1', parentId: 'a1', callId: 'c1', text: 'files'),
      );
      expect(snapshot.records, hasLength(3));
      final tool = snapshot.records[2] as TrajectoryToolRecord;
      expect(tool.result, 'files');
      expect(tool.resultPreviewMarkdown, 'files');
      expect(tool.isError, isFalse);
      expect(tool.timeSeconds, const Duration(seconds: 5));
      expect(tool.index, 3);
      expect(tool.recordId, 'tool\u0000call\u0000c1');
    });

    test('failed tool result marks the tool record', () {
      final builder = TrajectorySnapshotBuilder()..append(_userRecord('u1'));
      builder.append(
        _assistantRecord('a1', parentId: 'u1', content: [_toolCall('c1')]),
      );
      final snapshot = builder.append(
        _toolResultRecord('r1', parentId: 'a1', callId: 'c1', isError: true),
      );
      expect((snapshot.records[2] as TrajectoryToolRecord).isError, isTrue);
    });

    test('tool result for an unknown call is ignored', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        _toolResultRecord('r1', parentId: 'a1', callId: 'ghost'),
      );
      expect(snapshot.records, isEmpty);
      expect(snapshot.revision, 1);
    });

    test('compaction record maps to a compacted record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        CompactionRecord(
          id: 'cp1',
          parentId: null,
          timestamp: _at(2),
          summary: 'so far',
          firstKeptEntryId: 'u5',
          tokensBefore: 900,
        ),
      );
      final record = snapshot.records.single as TrajectoryCompactedRecord;
      expect(record.kind, TrajectoryCellKind.compacted);
      expect(record.summary, 'so far');
      expect(record.firstKeptEntryId, 'u5');
      expect(record.interrupted, isFalse);
      expect(record.startedAt, _at(2));
    });

    test('branch summary maps to a standalone compacted record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        BranchSummaryRecord(
          id: 'bs1',
          parentId: null,
          timestamp: _at(2),
          fromId: 'u3',
          summary: 'detour',
        ),
      );
      final record = snapshot.records.single as TrajectoryCompactedRecord;
      expect(record.kind, TrajectoryCellKind.compacted);
      expect(record.summary, 'detour');
      expect(record.firstKeptEntryId, isNull);
    });

    test('model change maps to a system record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        ModelChangeRecord(
          id: 'm1',
          parentId: null,
          timestamp: _at(0),
          provider: 'openai',
          modelId: 'gpt-test',
        ),
      );
      final record = snapshot.records.single as TrajectorySystemRecord;
      expect(record.kind, TrajectoryCellKind.system);
      expect(record.change, TrajectorySystemChange.modelChange);
      expect(record.text, 'openai/gpt-test');
      expect(record.time, _at(0));
    });

    test('active tools change maps to a system record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        ActiveToolsChangeRecord(
          id: 't1',
          parentId: null,
          timestamp: _at(0),
          activeToolNames: const ['bash', 'read'],
        ),
      );
      final record = snapshot.records.single as TrajectorySystemRecord;
      expect(record.change, TrajectorySystemChange.toolsChange);
      expect(record.text, 'bash, read');
    });

    test('thinking level change maps to a system record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        ThinkingLevelChangeRecord(
          id: 'tl1',
          parentId: null,
          timestamp: _at(0),
          thinkingLevel: 'high',
        ),
      );
      final record = snapshot.records.single as TrajectorySystemRecord;
      expect(record.change, TrajectorySystemChange.thinkingLevelChange);
      expect(record.text, 'high');
    });

    test('checkpoint maps to a system record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        CheckpointRecord(
          id: 'ck1',
          parentId: null,
          timestamp: _at(0),
          messageCount: 4,
          goal: 'explore auth',
        ),
      );
      final record = snapshot.records.single as TrajectorySystemRecord;
      expect(record.change, TrajectorySystemChange.checkpoint);
      expect(record.text, 'explore auth');
    });

    test('displayed context custom message maps to a context record', () {
      final snapshot = TrajectorySnapshotBuilder().append(
        CustomMessageRecord(
          id: 'cm1',
          parentId: null,
          timestamp: _at(0),
          customType: 'context',
          content: 'project instructions',
          display: true,
        ),
      );
      final record = snapshot.records.single as TrajectoryContextRecord;
      expect(record.kind, TrajectoryCellKind.context);
      expect(record.text, 'project instructions');
      expect(record.previewMarkdown, 'project instructions');
      expect(record.startedAt, _at(0));
    });

    test('hidden custom messages and non-ledger records are skipped', () {
      final builder = TrajectorySnapshotBuilder();
      final hidden = CustomMessageRecord(
        id: 'cm2',
        parentId: null,
        timestamp: _at(0),
        customType: 'context',
        content: 'hidden',
        display: false,
      );
      final skipped = [
        hidden,
        LabelRecord(
          id: 'l1',
          parentId: null,
          timestamp: _at(0),
          targetId: 'u1',
          label: 'keep',
        ),
        SessionInfoRecord(
          id: 'si1',
          parentId: null,
          timestamp: _at(0),
          name: 'session',
        ),
        LeafRecord(
          id: 'lf1',
          parentId: null,
          timestamp: _at(0),
          targetId: 'u1',
        ),
        CustomRecord(
          id: 'cu1',
          parentId: null,
          timestamp: _at(0),
          customType: 'misc',
        ),
      ];
      for (final record in skipped) {
        builder.append(record);
      }
      final snapshot = builder.build();
      expect(snapshot.records, isEmpty);
      // Skipped records still advance the revision: one per append.
      expect(snapshot.revision, skipped.length);
    });
  });

  group('turn and step assignment', () {
    test('a second prompt after a turn opens turn two', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.append(_assistantRecord('a1', parentId: 'u1'));
      builder.append(_toolResultRecord('r1', parentId: 'a1', callId: 'ghost'));
      builder.append(_userRecord('u2', parentId: 'r1', text: 'go on'));
      final snapshot = builder.append(_assistantRecord('a2', parentId: 'u2'));
      final user2 = snapshot.records[2] as TrajectoryUserRecord;
      expect(user2.opensTurn, isTrue);
      final assistant2 = snapshot.records[3] as TrajectoryAssistantRecord;
      expect(assistant2.turn, 2);
      expect(assistant2.step, 1);
    });

    test('assistant steps increment within a turn', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.append(_assistantRecord('a1', parentId: 'u1'));
      final snapshot = builder.append(_assistantRecord('a2', parentId: 'a1'));
      expect((snapshot.records[1] as TrajectoryAssistantRecord).step, 1);
      expect((snapshot.records[2] as TrajectoryAssistantRecord).step, 2);
      expect((snapshot.records[2] as TrajectoryAssistantRecord).turn, 1);
    });

    test('consecutive user messages merge into one turn', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.append(_userRecord('u2', parentId: 'u1', text: 'attachment'));
      final snapshot = builder.append(_assistantRecord('a1', parentId: 'u2'));
      expect((snapshot.records[1] as TrajectoryUserRecord).opensTurn, isFalse);
      final assistant = snapshot.records[2] as TrajectoryAssistantRecord;
      expect(assistant.turn, 1);
      expect(assistant.step, 1);
    });
  });

  group('snapshot semantics', () {
    test('fresh builder yields the empty snapshot with revision zero', () {
      final snapshot = TrajectorySnapshotBuilder().build();
      expect(snapshot.records, isEmpty);
      expect(snapshot.requests, isEmpty);
      expect(snapshot.callSchemas, isEmpty);
      expect(snapshot.runningCalls, isEmpty);
      expect(snapshot.partial, isNull);
      expect(snapshot.recordLocations, isEmpty);
      expect(snapshot.revision, 0);
      expect(TrajectorySnapshot.empty.revision, 0);
    });

    test('indexes are 1-based and stable, and locations map record ids', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.append(_assistantRecord('a1', parentId: 'u1'));
      builder.append(
        _assistantRecord('a2', parentId: 'a1', content: [_toolCall('c1')]),
      );
      final snapshot = builder.build();
      expect(snapshot.records.map((record) => record.index).toList(), [
        1,
        2,
        3,
        4,
      ]);
      expect(snapshot.recordLocations['u1'], 0);
      expect(snapshot.recordLocations['a1'], 1);
      expect(snapshot.recordLocations['tool\u0000call\u0000c1'], 3);
    });

    test('append returns a fresh snapshot and earlier ones stay frozen', () {
      final builder = TrajectorySnapshotBuilder();
      final first = builder.append(_userRecord('u1'));
      expect(first.revision, 1);
      final second = builder.append(_assistantRecord('a1', parentId: 'u1'));
      expect(second.revision, 2);
      expect(identical(first, second), isFalse);
      expect(first.records, hasLength(1));
      expect(second.records, hasLength(2));
      expect(first.revision, 1, reason: 'earlier snapshots are immutable');
    });

    test('build does not advance the revision', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      final before = builder.build().revision;
      expect(builder.build().revision, before);
    });

    test('reset clears records and revision', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      builder.reset();
      final snapshot = builder.build();
      expect(snapshot.records, isEmpty);
      expect(snapshot.revision, 0);
      final after = builder.append(_userRecord('u2'));
      expect(after.records.single.index, 1);
    });
  });

  group('kind dispatch', () {
    test('tool record with a parent call id is a subtool', () {
      const record = TrajectoryToolRecord(
        index: 1,
        recordId: 'tool\u0000call\u0000c9',
        callId: 'c9',
        parentCallId: 'c1',
        name: 'grep',
        argsRaw: '{}',
      );
      expect(record.kind, TrajectoryCellKind.subtool);
    });
  });

  group('tool start times and request details', () {
    const detail = TrajectoryRequestDetail(
      messageCount: 2,
      systemPromptChars: 40,
      toolCount: 1,
      toolNames: ['bash'],
      messages: [
        TrajectoryRequestMessageSummary(
          role: 'user',
          chars: 11,
          preview: 'list files',
        ),
        TrajectoryRequestMessageSummary(
          role: 'toolResult',
          chars: 6,
          preview: 'files',
        ),
      ],
    );

    AssistantMessage streamMessage(
      DateTime timestamp, {
      List<ContentBlock> content = const [],
      StopReason stopReason = StopReason.stop,
      String? errorMessage,
    }) => AssistantMessage(
      content: content,
      api: 'anthropic-messages',
      provider: 'anthropic',
      model: 'claude-test',
      usage: const Usage(
        input: 10,
        output: 2,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 12,
        cost: UsageCost(),
      ),
      stopReason: stopReason,
      errorMessage: errorMessage,
      timestamp: timestamp,
    );

    test('replayed tool rows start when the assistant issued the call', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      final snapshot = builder.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          content: [
            const TextContent(text: 'running'),
            _toolCall('c1'),
          ],
        ),
      );
      final tool = snapshot.records.last as TrajectoryToolRecord;
      expect(tool.startedAt, _at(1), reason: 'assistant record timestamp');
      final settled = builder.append(
        _toolResultRecord('r1', parentId: 'a1', callId: 'c1'),
      );
      final settledTool = settled.records.last as TrajectoryToolRecord;
      expect(settledTool.startedAt, _at(1), reason: 'withResult keeps it');
      expect(settledTool.result, 'done');
      expect(settledTool.timeSeconds, const Duration(seconds: 5));
    });

    test('live tool start stamps the row and the running call', () {
      final builder = TrajectorySnapshotBuilder();
      builder.applyEvent(
        MessageEndEvent(UserMessage.text('hi', timestamp: _at(0))),
      );
      builder.applyEvent(
        MessageEndEvent(
          streamMessage(
            _at(1),
            content: [
              ToolCall(id: 'c1', name: 'bash', arguments: const {'cmd': 'ls'}),
            ],
          ),
        ),
      );
      final snapshot = builder.applyEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c1',
          toolName: 'bash',
          args: const {},
          timestamp: _at(3),
        ),
      );
      expect((snapshot.records[2] as TrajectoryToolRecord).startedAt, _at(3));
      expect(snapshot.runningCalls.single.startedAt, _at(3));
    });

    test('a persisted model_request_summary survives a JSONL round-trip', () {
      final summary = CustomRecord(
        id: 'cu9',
        parentId: 'u1',
        timestamp: _at(0),
        customType: 'model_request_summary',
        data: detail.toJson(),
      );
      final restored = SessionRecord.fromJson(
        jsonDecode(jsonEncode(summary.toJson())) as Map<String, dynamic>,
      );
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      final snapshot = builder.append(restored as CustomRecord);
      expect(snapshot.records, hasLength(1), reason: 'record stays hidden');
      final replayed = builder.append(_assistantRecord('a1', parentId: 'u1'));
      expect(
        (replayed.records[1] as TrajectoryAssistantRecord).requestDetail
            ?.toJson(),
        detail.toJson(),
      );
    });

    test('compacted rows measure their duration from the ledger cursor', () {
      final builder = TrajectorySnapshotBuilder();
      builder.append(_userRecord('u1'));
      final snapshot = builder.append(
        CompactionRecord(
          id: 'cp1',
          parentId: 'u1',
          timestamp: _at(5),
          summary: 'summary of history',
          firstKeptEntryId: 'r1',
          tokensBefore: 100,
        ),
      );
      final record = snapshot.records.last as TrajectoryCompactedRecord;
      expect(record.timeSeconds, const Duration(seconds: 5));
      expect(record.startedAt, _at(5));
    });
  });

  group('scripted multi-turn session', () {
    test('tool rows carry startedAt and steps carry request summaries', () {
      const firstDetail = TrajectoryRequestDetail(
        messageCount: 1,
        systemPromptChars: 0,
        toolCount: 1,
        toolNames: ['bash'],
        messages: [
          TrajectoryRequestMessageSummary(
            role: 'user',
            chars: 10,
            preview: 'list files',
          ),
        ],
      );
      const secondDetail = TrajectoryRequestDetail(
        messageCount: 3,
        systemPromptChars: 0,
        toolCount: 1,
        toolNames: ['bash'],
        messages: [
          TrajectoryRequestMessageSummary(
            role: 'user',
            chars: 10,
            preview: 'list files',
          ),
          TrajectoryRequestMessageSummary(
            role: 'assistant',
            chars: 30,
            preview: '',
          ),
          TrajectoryRequestMessageSummary(
            role: 'toolResult',
            chars: 7,
            preview: 'files',
          ),
        ],
      );
      AssistantMessage step({
        required DateTime timestamp,
        List<ContentBlock> content = const [],
        StopReason stopReason = StopReason.stop,
        String? errorMessage,
      }) => AssistantMessage(
        content: content,
        api: 'anthropic-messages',
        provider: 'anthropic',
        model: 'claude-test',
        usage: const Usage(
          input: 10,
          output: 2,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 12,
          cost: UsageCost(),
        ),
        stopReason: stopReason,
        errorMessage: errorMessage,
        timestamp: timestamp,
      );

      // Live tail: a two-step turn whose first step calls a tool.
      final live = TrajectorySnapshotBuilder();
      live.applyEvent(
        MessageEndEvent(UserMessage.text('list files', timestamp: _at(0))),
      );
      live.applyEvent(ModelRequestEvent(detail: firstDetail));
      final step1 = step(
        timestamp: _at(2),
        content: [
          const TextContent(text: 'running'),
          ToolCall(id: 'c1', name: 'bash', arguments: const {'cmd': 'ls'}),
        ],
      );
      live.applyEvent(MessageEndEvent(step1));
      live.applyEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c1',
          toolName: 'bash',
          args: const {},
          timestamp: _at(3),
        ),
      );
      live.applyEvent(
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
      live.applyEvent(ModelRequestEvent(detail: secondDetail));
      live.applyEvent(
        MessageEndEvent(
          step(
            timestamp: _at(8),
            stopReason: StopReason.error,
            errorMessage: 'boom',
          ),
        ),
      );
      final liveSnapshot = live.build();

      final tools = liveSnapshot.records
          .whereType<TrajectoryToolRecord>()
          .toList();
      expect(tools, hasLength(1));
      expect(tools.single.startedAt, _at(3));
      expect(tools.single.result, 'files');
      expect(tools.single.isError, isFalse);
      final assistants = liveSnapshot.records
          .whereType<TrajectoryAssistantRecord>()
          .toList();
      expect(assistants, hasLength(2));
      expect(assistants[0].requestDetail?.toJson(), firstDetail.toJson());
      expect(assistants[1].isError, isTrue);
      expect(assistants[1].errorMessage, 'boom');
      expect(assistants[1].requestDetail?.toJson(), secondDetail.toJson());
      expect(liveSnapshot.runningCalls, isEmpty);
      expect(liveSnapshot.requests.map((request) => request.status).toList(), [
        TrajectoryRequestStatus.completed,
        TrajectoryRequestStatus.failed,
      ]);

      // Durable replay of the same session: the summaries persist as
      // hidden custom records, and every fact matches the live snapshot.
      CustomRecord summary(Object data, String id, String parentId) =>
          CustomRecord(
            id: id,
            parentId: parentId,
            timestamp: _at(0),
            customType: 'model_request_summary',
            data: data,
          );
      final replay = TrajectorySnapshotBuilder();
      replay.append(_userRecord('u1'));
      replay.append(summary(firstDetail.toJson(), 's1', 'u1'));
      replay.append(
        _assistantRecord(
          'a1',
          parentId: 'u1',
          content: [
            const TextContent(text: 'running'),
            _toolCall('c1'),
          ],
        ),
      );
      replay.append(_toolResultRecord('r1', parentId: 'a1', callId: 'c1'));
      replay.append(summary(secondDetail.toJson(), 's2', 'r1'));
      replay.append(
        _assistantRecord(
          'a2',
          parentId: 'r1',
          stopReason: StopReason.error,
          errorMessage: 'boom',
        ),
      );
      final replaySnapshot = replay.build();
      final replayTools = replaySnapshot.records
          .whereType<TrajectoryToolRecord>()
          .toList();
      expect(
        replayTools.single.startedAt,
        _at(1),
        reason: 'replay stamps startedAt from the assistant record',
      );
      final replayAssistants = replaySnapshot.records
          .whereType<TrajectoryAssistantRecord>()
          .toList();
      expect(
        replayAssistants[0].requestDetail?.toJson(),
        assistants[0].requestDetail?.toJson(),
        reason: 'replayed request detail equals the live one',
      );
      expect(
        replayAssistants[1].requestDetail?.toJson(),
        assistants[1].requestDetail?.toJson(),
      );
    });
  });
}
