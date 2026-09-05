@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/trajectory_tui.dart';
import 'package:test/test.dart';

import 'mock_session.dart';

void main() {
  late Directory sessionsRoot;

  setUp(() {
    sessionsRoot = Directory.systemTemp.createTempSync('fa_traj_snap_');
  });

  tearDown(() {
    sessionsRoot.deleteSync(recursive: true);
  });

  /// Persists [script] and replays the disk round trip through a real
  /// [TrajectorySnapshotBuilder].
  Future<(MockSessionFixture, TrajectorySnapshot)> buildAndReplay(
    MockSessionScript script,
  ) async {
    final fixture = await MockSessionFixture.build(
      script,
      sessionsRoot: sessionsRoot,
    );
    final records = await fixture.readBack();
    final builder = TrajectorySnapshotBuilder();
    var snapshot = TrajectorySnapshot.empty;
    for (final record in records) {
      snapshot = builder.append(record);
    }
    return (fixture, snapshot);
  }

  Usage usage(int input, int output, {double cost = 0.01}) => Usage(
    input: input,
    output: output,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: input + output,
    cost: UsageCost(total: cost),
  );

  group('snapshot builder over the real JSONL round trip', () {
    test(
      'full ledger: every row kind lands with turns, steps, and marks',
      () async {
        final script = MockSessionScript()
          ..contextInject('repo context: flutter_agent_harness')
          ..modelChange(provider: 'openai', modelId: 'gpt-mock')
          ..turn(
            'fix the bug',
            toolCalls: [
              const MockToolCallSpec(
                'call-1',
                name: 'read',
                args: {'path': 'lib/x.dart'},
              ),
            ],
          )
          ..assistantText('patched and verified')
          ..checkpoint(messageCount: 6, goal: 'investigate flaky test');
        script.compaction(
          summary: 'compacted summary',
          firstKeptEntryId: script.stepId(6),
        );
        script
          ..user('continue')
          ..assistantText('finished');
        final (fixture, snapshot) = await buildAndReplay(script);

        // The JSONL round trip preserved every scripted record.
        final records = await fixture.readBack();
        expect(
          records.map((record) => record.id),
          fixture.records.map((record) => record.id),
        );
        expect(
          records.map((record) => record.toJson()),
          fixture.records.map((record) => record.toJson()),
        );

        final kinds = [for (final record in snapshot.records) record.kind.name];
        expect(kinds, [
          'context',
          'system',
          'user',
          'message',
          'tool',
          'message',
          'system',
          'compacted',
          'user',
          'message',
        ]);

        final rows = snapshot.records;
        final context = rows[0] as TrajectoryContextRecord;
        expect(context.text, 'repo context: flutter_agent_harness');

        final modelChange = rows[1] as TrajectorySystemRecord;
        expect(modelChange.change, TrajectorySystemChange.modelChange);
        expect(modelChange.text, 'openai/gpt-mock');

        final firstPrompt = rows[2] as TrajectoryUserRecord;
        expect(firstPrompt.text, 'fix the bug');
        expect(firstPrompt.opensTurn, isTrue);
        final followUp = rows[8] as TrajectoryUserRecord;
        expect(followUp.text, 'continue');
        expect(followUp.opensTurn, isTrue);

        final toolCallStep = rows[3] as TrajectoryAssistantRecord;
        expect((toolCallStep.turn, toolCallStep.step), (1, 1));
        final tool = rows[4] as TrajectoryToolRecord;
        expect(tool.callId, 'call-1');
        expect(tool.name, 'read');
        expect(tool.result, 'ok');
        expect(tool.isError, isFalse);
        final finalStep = rows[5] as TrajectoryAssistantRecord;
        expect((finalStep.turn, finalStep.step), (1, 2));
        expect(finalStep.outputDetail, contains('patched and verified'));

        final checkpointRow = rows[6] as TrajectorySystemRecord;
        expect(checkpointRow.change, TrajectorySystemChange.checkpoint);
        expect(checkpointRow.text, 'investigate flaky test');

        final compacted = rows[7] as TrajectoryCompactedRecord;
        expect(compacted.summary, 'compacted summary');
        expect(compacted.firstKeptEntryId, script.stepId(6));

        final lastStep = rows[9] as TrajectoryAssistantRecord;
        expect((lastStep.turn, lastStep.step), (2, 1));
      },
    );

    test(
      'nested tool call replays as a subtool row bound to its parent',
      () async {
        final script = MockSessionScript()
          ..turn(
            'explore nested',
            toolCalls: [
              const MockToolCallSpec('call-1', name: 'bash'),
              const MockToolCallSpec(
                'call-1-1',
                name: 'grep',
                args: {'pattern': 'deploy'},
                parentCallId: 'call-1',
              ),
            ],
          )
          ..assistantText('all settled');
        final (_, snapshot) = await buildAndReplay(script);

        final kinds = [for (final record in snapshot.records) record.kind.name];
        expect(kinds, ['user', 'message', 'tool', 'subtool', 'message']);

        final rows = snapshot.records;
        final parent = rows[2] as TrajectoryToolRecord;
        expect(parent.callId, 'call-1');
        expect(parent.parentCallId, isNull);
        final nested = rows[3] as TrajectoryToolRecord;
        expect(nested.callId, 'call-1-1');
        expect(nested.kind, TrajectoryCellKind.subtool);
        expect(nested.parentCallId, 'call-1');
        expect(nested.result, 'ok');
      },
    );

    test(
      'requests: sequential numbering, compaction rows, cumulative usage',
      () async {
        final script = MockSessionScript()
          ..user('one')
          ..assistantText('a1', usage: usage(100, 20))
          ..user('two')
          ..assistantText('a2', usage: usage(150, 30));
        script.compaction(
          summary: 'mid summary',
          firstKeptEntryId: script.stepId(2),
        );
        script
          ..user('three')
          ..assistantText('a3', usage: usage(200, 40, cost: 0.03));
        final (_, snapshot) = await buildAndReplay(script);

        final requests = snapshot.requests;
        expect(requests, hasLength(4));
        expect(requests.map((request) => request.seq), [1, 2, 3, 4]);
        expect(requests.map((request) => request.purpose), [
          TrajectoryRequestPurpose.assistant,
          TrajectoryRequestPurpose.assistant,
          TrajectoryRequestPurpose.compaction,
          TrajectoryRequestPurpose.assistant,
        ]);
        expect(requests.map((request) => (request.turn, request.step)), [
          (1, 1),
          (2, 1),
          (2, 0),
          (3, 1),
        ]);
        expect(requests.map((request) => request.usage?.input), [
          100,
          150,
          null,
          200,
        ]);
        expect(requests.map((request) => request.usage?.totalTokens), [
          120,
          180,
          null,
          240,
        ]);
        // Compaction carries no usage; the fold passes straight through it.
        expect(
          requests.map((request) => request.cumulativeUsage?.totalTokens),
          [120, 300, 300, 540],
        );
        expect(requests.map((request) => request.cumulativeUsage?.input), [
          100,
          250,
          250,
          450,
        ]);
        expect(requests.map((request) => request.cumulativeUsage?.cost.total), [
          0.01,
          0.02,
          0.02,
          0.05,
        ]);
        expect(requests[0].model, 'mock-model');
        expect(requests[2].model, '');
        expect(requests.map((request) => request.status), [
          TrajectoryRequestStatus.completed,
          TrajectoryRequestStatus.completed,
          TrajectoryRequestStatus.completed,
          TrajectoryRequestStatus.completed,
        ]);
      },
    );

    test('durations derive from record timestamps', () async {
      final script = MockSessionScript()
        ..turn(
          'look at the file',
          toolCalls: [const MockToolCallSpec('call-1', name: 'read')],
          perToolLatency: const Duration(milliseconds: 1500),
        )
        ..assistantText('done');
      final (_, snapshot) = await buildAndReplay(script);

      final tool = snapshot.records[2] as TrajectoryToolRecord;
      expect(tool.timeSeconds, const Duration(milliseconds: 1500));
      // The tool result settles its row without producing a new one, so
      // the final assistant runs from the tool-call step's stamp (+2s) to
      // its own (+4.5s).
      final finalStep = snapshot.records[3] as TrajectoryAssistantRecord;
      expect(finalStep.timeSeconds, const Duration(milliseconds: 2500));
      expect(finalStep.usage?.totalTokens, 120);
    });

    test(
      'live tail: applyEvent stream then real records == pure append replay',
      () async {
        final script = MockSessionScript()
          ..turn(
            'explore',
            toolCalls: [
              const MockToolCallSpec('call-1', name: 'bash'),
              const MockToolCallSpec('call-2', name: 'read'),
            ],
          )
          ..assistantText('all settled');
        final fixture = await MockSessionFixture.build(
          script,
          sessionsRoot: sessionsRoot,
        );
        final records = await fixture.readBack();

        final replayBuilder = TrajectorySnapshotBuilder();
        var replayed = TrajectorySnapshot.empty;
        for (final record in records) {
          replayed = replayBuilder.append(record);
        }

        // The host mirrors the live tail: message-end events stream rows in,
        // tool-execution starts mark running calls, and the finalized record
        // lands right after and replaces the streamed rows.
        final liveBuilder = TrajectorySnapshotBuilder();
        for (final record in records) {
          if (record is MessageRecord) {
            final message = record.message;
            if (message is AssistantMessage) {
              for (final block in message.content) {
                if (block is ToolCall) {
                  liveBuilder.applyEvent(
                    ToolExecutionStartEvent(
                      toolCallId: block.id,
                      toolName: block.name,
                      args: block.arguments,
                      timestamp: DateTime.now(),
                    ),
                  );
                }
              }
            }
            liveBuilder.applyEvent(MessageEndEvent(message));
          }
          liveBuilder.append(record);
        }
        final live = liveBuilder.build();

        expect(live.records, hasLength(replayed.records.length));
        for (var i = 0; i < live.records.length; i++) {
          final liveRow = live.records[i];
          final replayRow = replayed.records[i];
          expect(liveRow.runtimeType, replayRow.runtimeType, reason: 'row $i');
          expect(liveRow.index, replayRow.index, reason: 'row $i');
          expect(liveRow.recordId, replayRow.recordId, reason: 'row $i');
          Map<String, dynamic> shape(TrajectoryRecord row) =>
              jsonDecode(trajectoryJsonLine(row)) as Map<String, dynamic>;
          expect(shape(liveRow), shape(replayRow), reason: 'row $i');
        }
        // Finalized durations come from the real records in both paths.
        expect(
          live.records.whereType<TrajectoryAssistantRecord>().map(
            (row) => row.timeSeconds,
          ),
          replayed.records.whereType<TrajectoryAssistantRecord>().map(
            (row) => row.timeSeconds,
          ),
        );
        expect(live.partial, isNull);
        expect(live.runningCalls, isEmpty);

        expect(live.requests, hasLength(replayed.requests.length));
        for (var i = 0; i < live.requests.length; i++) {
          final liveRequest = live.requests[i];
          final replayRequest = replayed.requests[i];
          expect(liveRequest.seq, replayRequest.seq);
          expect(
            (liveRequest.turn, liveRequest.step),
            (replayRequest.turn, replayRequest.step),
          );
          expect(liveRequest.purpose, replayRequest.purpose);
          expect(liveRequest.status, replayRequest.status);
          expect(liveRequest.model, replayRequest.model);
          expect(
            liveRequest.usage?.totalTokens,
            replayRequest.usage?.totalTokens,
          );
          expect(
            liveRequest.cumulativeUsage?.totalTokens,
            replayRequest.cumulativeUsage?.totalTokens,
          );
        }
      },
    );

    test('branch navigation: moveTo keeps shared-prefix rows stable', () async {
      final script = MockSessionScript()
        ..user('one')
        ..assistantText('first answer')
        ..user('two')
        ..assistantText('second answer');
      final fixture = await MockSessionFixture.build(
        script,
        sessionsRoot: sessionsRoot,
      );
      final records = await fixture.readBack();
      TrajectorySnapshot replayOf(List<SessionRecord> source) {
        final builder = TrajectorySnapshotBuilder();
        var snapshot = TrajectorySnapshot.empty;
        for (final record in source) {
          snapshot = builder.append(record);
        }
        return snapshot;
      }

      final before = replayOf(records);
      expect(before.records, hasLength(4));

      // Navigate back to the second prompt ('rec003') and branch anew.
      final branchSummaryId = await fixture.session.moveTo(
        'rec003',
        summary: 'kept: explored turn two',
      );
      final userRow = await fixture.append(
        MessageRecord(
          id: 'brx001',
          parentId: branchSummaryId,
          timestamp: DateTime.utc(2026, 3, 1, 13),
          message: UserMessage.text(
            'three',
            timestamp: DateTime.utc(2026, 3, 1, 13),
          ),
        ),
      );
      await fixture.append(
        MessageRecord(
          id: 'brx002',
          parentId: userRow.id,
          timestamp: DateTime.utc(2026, 3, 1, 13, 0, 1),
          message: AssistantMessage(
            content: const [TextContent(text: 'branch answer')],
            api: 'mock-api',
            provider: 'mock',
            model: 'mock-model',
            usage: usage(10, 5),
            stopReason: StopReason.stop,
            timestamp: DateTime.utc(2026, 3, 1, 13, 0, 1),
          ),
        ),
      );

      final after = replayOf(await fixture.readBack());
      final kinds = [for (final record in after.records) record.kind.name];
      // The abandoned second answer is gone; the branch summary renders as
      // a COMPACTED row on the new branch.
      expect(kinds, [
        'user',
        'message',
        'user',
        'compacted',
        'user',
        'message',
      ]);

      // Shared-prefix rows keep recordId, kind, and index — the identity
      // the ledger prepends/rewrites against.
      for (var i = 0; i < 3; i++) {
        expect(
          after.records[i].recordId,
          before.records[i].recordId,
          reason: 'row $i',
        );
        expect(after.records[i].kind, before.records[i].kind, reason: 'row $i');
        expect(
          after.records[i].index,
          before.records[i].index,
          reason: 'row $i',
        );
      }

      final branchSummary = after.records[3] as TrajectoryCompactedRecord;
      expect(branchSummary.summary, 'kept: explored turn two');
      expect(branchSummary.firstKeptEntryId, isNull);

      // A user landing on another user merges into its turn (queued-prompt
      // semantics), so the branch answer is turn 2, step 1.
      final branchAnswer = after.records[5] as TrajectoryAssistantRecord;
      expect((branchAnswer.turn, branchAnswer.step), (2, 1));
      expect(branchAnswer.outputDetail, contains('branch answer'));
    });
  });
}
