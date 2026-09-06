import 'dart:convert';
import 'dart:collection';

import 'package:flutter_agent_harness/src/trajectory/trajectory_export.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

TrajectorySnapshot _snapshot() {
  const requestDetail = TrajectoryRequestDetail(
    messageCount: 2,
    systemPromptChars: 40,
    toolCount: 1,
    toolNames: ['bash'],
    messages: [
      TrajectoryRequestMessageSummary(
        role: 'user',
        chars: 10,
        preview: 'list files',
      ),
      TrajectoryRequestMessageSummary(
        role: 'toolResult',
        chars: 21,
        preview: 'files listing result',
      ),
    ],
  );
  final records = <TrajectoryRecord>[
    TrajectoryUserRecord(
      index: 1,
      recordId: 'u1',
      text: 'list files',
      previewMarkdown: 'list files',
      opensTurn: true,
      startedAt: _base,
    ),
    TrajectoryAssistantRecord(
      index: 2,
      recordId: 'a1',
      messageId: 'm1',
      turn: 1,
      step: 1,
      provider: 'anthropic',
      model: 'claude-test',
      usage: const Usage(
        input: 100,
        output: 20,
        cacheRead: 30,
        cacheWrite: 5,
        reasoning: 8,
        totalTokens: 163,
        cost: UsageCost(),
      ),
      inputTokens: 100,
      cacheReadTokens: 30,
      cacheWriteTokens: 5,
      outputTokens: 20,
      reasoningTokens: 8,
      completedTime: _base.add(const Duration(seconds: 1)),
      outputBlocks: const [
        TrajectorySourceBlock(type: 'text', content: 'The answer'),
      ],
      outputDetail: 'The answer',
      isError: false,
      requestDetail: requestDetail,
    ),
    TrajectoryToolRecord(
      index: 3,
      recordId: 'tool\u0000call\u0000c1',
      callId: 'c1',
      parentCallId: null,
      name: 'bash',
      argsRaw: '{"cmd":"ls"}',
      result: 'files listing result',
      isError: false,
      timeSeconds: const Duration(seconds: 4),
      startedAt: _base.add(const Duration(seconds: 2)),
    ),
    TrajectoryContextRecord(
      index: 4,
      recordId: 'ctx1',
      text: 'project instructions',
      previewMarkdown: 'project instructions',
      startedAt: _base,
    ),
    TrajectoryCompactedRecord(
      index: 5,
      recordId: 'cp1',
      text: 'summary',
      summary: 'summary of everything before',
      timeSeconds: const Duration(seconds: 5),
      startedAt: _base.add(const Duration(seconds: 6)),
    ),
    TrajectorySystemRecord(
      index: 6,
      recordId: 'sys1',
      text: 'anthropic/claude-test',
      change: TrajectorySystemChange.modelChange,
      detail: 'anthropic/claude-test',
      time: _base,
    ),
    TrajectoryAssistantRecord(
      index: 7,
      recordId: 'a2',
      messageId: 'm2',
      turn: 2,
      step: 1,
      provider: 'anthropic',
      model: 'claude-test',
      usage: const Usage(
        input: 1,
        output: 1,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 2,
        cost: UsageCost(),
      ),
      completedTime: _base.add(const Duration(seconds: 9)),
      isError: true,
      errorCode: null,
      errorMessage: 'boom',
    ),
  ];
  return TrajectorySnapshot(
    records: UnmodifiableListView(records),
    requests: UnmodifiableListView(const []),
    callSchemas: const {},
    partial: null,
    runningCalls: UnmodifiableListView(const []),
    recordLocations: const {},
    revision: 7,
  );
}

void main() {
  group('exportTrajectoryJson', () {
    test('round-trips every record field-equal to the snapshot', () {
      final snapshot = _snapshot();
      final exported =
          jsonDecode(exportTrajectoryJson(snapshot)) as Map<String, dynamic>;
      final records = exported['records'] as List;
      expect(records, hasLength(snapshot.records.length));

      final user = records[0] as Map<String, dynamic>;
      expect(user['kind'], 'user');
      expect(user['recordId'], 'u1');
      expect(user['text'], 'list files');
      expect(user['opensTurn'], isTrue);
      expect(user['startedAt'], _base.toIso8601String());

      final assistant = records[1] as Map<String, dynamic>;
      expect(assistant['kind'], 'message');
      expect(assistant['turn'], 1);
      expect(assistant['step'], 1);
      expect(assistant['provider'], 'anthropic');
      expect(
        assistant['completedTime'],
        _base.add(const Duration(seconds: 1)).toIso8601String(),
      );
      expect(
        (assistant['usage'] as Map)['input'],
        (snapshot.records[1] as TrajectoryAssistantRecord).usage!
            .toJson()['input'],
      );
      expect(
        assistant['requestDetail'],
        (snapshot.records[1] as TrajectoryAssistantRecord).requestDetail!
            .toJson(),
      );
      expect(assistant['outputDetail'], 'The answer');

      final tool = records[2] as Map<String, dynamic>;
      expect(tool['kind'], 'tool');
      expect(tool['callId'], 'c1');
      expect(tool['name'], 'bash');
      expect(tool['argsRaw'], '{"cmd":"ls"}');
      expect(tool['result'], 'files listing result');
      expect(tool['timeSeconds'], 4.0);
      expect(
        tool['startedAt'],
        _base.add(const Duration(seconds: 2)).toIso8601String(),
      );

      final context = records[3] as Map<String, dynamic>;
      expect(context['kind'], 'context');
      expect(context['text'], 'project instructions');
      expect(context['startedAt'], _base.toIso8601String());

      final compacted = records[4] as Map<String, dynamic>;
      expect(compacted['kind'], 'compacted');
      expect(compacted['summary'], 'summary of everything before');
      expect(compacted['timeSeconds'], 5.0);

      final system = records[5] as Map<String, dynamic>;
      expect(system['kind'], 'system');
      expect(system['change'], 'modelChange');
      expect(system['time'], _base.toIso8601String());

      final failed = records[6] as Map<String, dynamic>;
      expect(failed['kind'], 'message');
      expect(failed['turn'], 2);
      expect(failed['isError'], isTrue);
      expect(failed['errorMessage'], 'boom');
    });
  });

  group('exportTrajectoryMarkdown', () {
    test('renders turns as sections with full content in fences', () {
      final markdown = exportTrajectoryMarkdown(_snapshot());
      expect(markdown, contains('# Trajectory export'));
      expect(markdown, contains('## Turn 1'));
      expect(markdown, contains('## Turn 2'));
      // Full tool arguments and result survive verbatim in fenced blocks.
      expect(markdown, contains('{"cmd":"ls"}'));
      expect(markdown, contains('files listing result'));
      // Full assistant output and the error flag survive.
      expect(markdown, contains('The answer'));
      expect(markdown, contains('ERROR: boom'));
      // Labeled rows.
      expect(markdown, contains('### #1 user'));
      expect(
        markdown,
        contains('### #2 assistant · step 1 · anthropic/claude'),
      );
      expect(markdown, contains('#### #3 tool `bash` `c1`'));
      // Request summaries render with bounded previews.
      expect(markdown, contains('_request_ 2 messages'));
      expect(markdown, contains('`toolResult` 21 chars: files listing result'));
      // The system and compacted rows are labeled.
      expect(markdown, contains('### #5 compacted'));
      expect(markdown, contains('summary of everything before'));
      expect(markdown, contains('### #6 system · modelChange'));
    });

    test('four-backtick fences survive embedded triple backticks', () {
      final snapshot = _snapshot();
      final embedded = TrajectoryAssistantRecord(
        index: 8,
        recordId: 'a3',
        messageId: 'm3',
        turn: 2,
        step: 2,
        outputDetail: 'text with ```code``` inside',
      );
      final withCode = TrajectorySnapshot(
        records: UnmodifiableListView([...snapshot.records, embedded]),
        requests: snapshot.requests,
        callSchemas: snapshot.callSchemas,
        partial: null,
        runningCalls: snapshot.runningCalls,
        recordLocations: snapshot.recordLocations,
        revision: snapshot.revision,
      );
      final markdown = exportTrajectoryMarkdown(withCode);
      expect(markdown, contains('text with ```code``` inside'));
      // No unbalanced fence: every opening 4-fence has its 4-fence closer.
      expect('````'.allMatches(markdown).length.isEven, isTrue);
    });
  });
}
