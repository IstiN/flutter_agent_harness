// ATIF (Agent Trajectory Interchange Format) export — gh-1681 Gap 2.
//
// Harbor's leaderboard static analysis requires every rewarded trial to
// carry an ATIF trajectory at <trial>/agent/trajectory.json; the harbor
// `upload` packager uploads it as the trial's trajectory_path. The schema
// contract below is pinned against harbor 0.23.0
// (harbor/models/trajectories/*.py) and cross-validated from the Python
// side by bench/harbor_fa/test_atif_contract.py against the SAME checked-in
// golden fixture (bench/harbor_fa/fixtures/atif_sample.json).
import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

/// user → assistant (text + reasoning + usage) → tool (ok) → tool (raw
/// args, no result yet) → context → compacted → system.
TrajectorySnapshot _snapshot() {
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
        cost: UsageCost(total: 0.5),
      ),
      inputTokens: 100,
      cacheReadTokens: 30,
      cacheWriteTokens: 5,
      outputTokens: 20,
      reasoningTokens: 8,
      stepStartTime: _base.add(const Duration(milliseconds: 500)),
      completedTime: _base.add(const Duration(seconds: 1)),
      outputBlocks: const [
        TrajectorySourceBlock(type: 'text', content: 'The answer'),
      ],
      thinkingDetail: 'let me think',
      isError: false,
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
    TrajectoryToolRecord(
      index: 4,
      recordId: 'tool\u0000call\u0000c2',
      callId: 'c2',
      parentCallId: null,
      name: 'read',
      argsRaw: 'not json',
      result: '',
      isError: false,
      startedAt: _base.add(const Duration(seconds: 3)),
    ),
    TrajectoryContextRecord(
      index: 5,
      recordId: 'ctx1',
      text: 'project instructions',
      previewMarkdown: 'project instructions',
      startedAt: _base.add(const Duration(seconds: 5)),
    ),
    TrajectoryCompactedRecord(
      index: 6,
      recordId: 'cp1',
      text: 'summary',
      summary: 'summary of everything before',
      timeSeconds: const Duration(seconds: 5),
      startedAt: _base.add(const Duration(seconds: 6)),
    ),
    TrajectorySystemRecord(
      index: 7,
      recordId: 'sys1',
      text: 'anthropic/claude-test',
      change: TrajectorySystemChange.modelChange,
      detail: 'anthropic/claude-test',
      time: _base.add(const Duration(seconds: 7)),
    ),
  ];
  return TrajectorySnapshot(
    records: UnmodifiableListView(records),
    requests: UnmodifiableListView(const []),
    callSchemas: const {},
    partial: null,
    runningCalls: UnmodifiableListView(const []),
    recordLocations: const {},
    revision: records.length,
  );
}

Map<String, dynamic> _export(TrajectorySnapshot snapshot) =>
    jsonDecode(
          exportAtifJson(
            snapshot,
            agentName: 'fa',
            agentVersion: '1.2.3',
            sessionId: 'sess-1',
          )!,
        )
        as Map<String, dynamic>;

void main() {
  group('exportAtifJson', () {
    test('emits an ATIF-v1.7 document with agent identity', () {
      final doc = _export(_snapshot());
      expect(doc['schema_version'], 'ATIF-v1.7');
      expect(doc['session_id'], 'sess-1');
      expect(doc['agent'], {
        'name': 'fa',
        'version': '1.2.3',
        'model_name': 'claude-test',
      });
    });

    test('derives model_name from the first assistant record when not given',
        () {
      final doc = _export(_snapshot());
      expect(doc['agent']['model_name'], 'claude-test');
    });

    test('steps are sequential from 1 with ledger-order sources', () {
      final doc = _export(_snapshot());
      final steps = (doc['steps'] as List).cast<Map<String, dynamic>>();
      expect(steps, hasLength(7));
      for (var i = 0; i < steps.length; i++) {
        expect(steps[i]['step_id'], i + 1);
      }
      expect(
        steps.map((s) => s['source']).toList(),
        ['user', 'agent', 'agent', 'agent', 'system', 'system', 'system'],
      );
    });

    test('non-agent steps carry no agent-only fields', () {
      final doc = _export(_snapshot());
      final steps = (doc['steps'] as List).cast<Map<String, dynamic>>();
      for (final step in steps.where((s) => s['source'] != 'agent')) {
        for (final key in [
          'model_name',
          'metrics',
          'tool_calls',
          'reasoning_content',
          'llm_call_count',
        ]) {
          expect(step.containsKey(key), isFalse, reason: 'step $key');
        }
      }
    });

    test('assistant step carries message, reasoning, and token metrics', () {
      final doc = _export(_snapshot());
      final steps = (doc['steps'] as List).cast<Map<String, dynamic>>();
      final assistant = steps[1];
      expect(assistant['message'], 'The answer');
      expect(assistant['reasoning_content'], 'let me think');
      expect(assistant['model_name'], 'claude-test');
      expect(
        assistant['timestamp'],
        _base.add(const Duration(milliseconds: 500)).toIso8601String(),
      );
      expect(assistant['metrics'], {
        'prompt_tokens': 100,
        'completion_tokens': 20,
        'cached_tokens': 30,
        'cost_usd': 0.5,
      });
    });

    test('tool step carries the call, parsed arguments, and observation', () {
      final doc = _export(_snapshot());
      final steps = (doc['steps'] as List).cast<Map<String, dynamic>>();
      final tool = steps[2];
      expect(tool['llm_call_count'], 0);
      expect(tool['tool_calls'], [
        {
          'tool_call_id': 'c1',
          'function_name': 'bash',
          'arguments': {'cmd': 'ls'},
        },
      ]);
      expect(tool['observation'], {
        'results': [
          {'source_call_id': 'c1', 'content': 'files listing result'},
        ],
      });
    });

    test('unparseable arguments fall back to empty args plus raw extra', () {
      final doc = _export(_snapshot());
      final steps = (doc['steps'] as List).cast<Map<String, dynamic>>();
      final tool = steps[3];
      expect(tool['tool_calls'].single['arguments'], isEmpty);
      expect(tool['tool_calls'].single['extra'], {'raw_arguments': 'not json'});
      // A call whose result never arrived exports no observation.
      expect(tool.containsKey('observation'), isFalse);
    });

    test('final_metrics totals the agent-step metrics', () {
      final doc = _export(_snapshot());
      expect(doc['final_metrics'], {
        'total_prompt_tokens': 100,
        'total_completion_tokens': 20,
        'total_cached_tokens': 30,
        'total_cost_usd': 0.5,
        'total_steps': 7,
      });
    });

    test('empty snapshot exports null (ATIF requires at least one step)', () {
      expect(
        exportAtifJson(
          TrajectorySnapshot.empty,
          agentName: 'fa',
          agentVersion: '1.2.3',
        ),
        isNull,
      );
    });

    test('matches the cross-validated golden fixture the Python gate reads', () {
      // The SAME bytes the harbor-side contract test
      // (bench/harbor_fa/test_atif_contract.py) validates against harbor
      // 0.23.0's pydantic Trajectory model — one artifact, both sides.
      final fixture = File('bench/harbor_fa/fixtures/atif_sample.json');
      final golden = jsonDecode(fixture.readAsStringSync());
      expect(_export(_snapshot()), golden);
    });
  });
}
