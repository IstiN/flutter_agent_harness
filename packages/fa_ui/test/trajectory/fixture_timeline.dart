// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:collection';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Timeline fixture: two turns with known wall-clock timings, built through
/// the core [TrajectorySnapshotBuilder] so record ids and indexes match
/// real projection.
///
/// Layout: turn 1 = [user, message, tool, message] at t=0s/1s/1..2s/3s;
/// turn 2 = [user, message] at t=10s/11s. Six ledger records, indexes
/// 1..6. The 3s..10s idle gap gives timed modes a span-free zone.
///
/// Only the first turn mentions "deploy", so a `deploy` search matches
/// indexes 1-4 and misses 5-6.

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

AssistantMessage _assistant(
  String text,
  StopReason stopReason,
  DateTime timestamp,
) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'anthropic-messages',
  provider: 'anthropic',
  model: 'claude-test',
  usage: const Usage(
    input: 100,
    output: 20,
    cacheRead: 0,
    cacheWrite: 0,
    reasoning: 0,
    totalTokens: 120,
    cost: UsageCost(),
  ),
  stopReason: stopReason,
  timestamp: timestamp,
);

/// Builds the two-turn timed fixture snapshot.
TrajectorySnapshot buildTimelineFixtureSnapshot() {
  final builder = TrajectorySnapshotBuilder();
  TrajectorySnapshot snapshot = TrajectorySnapshot.empty;
  final records = <SessionRecord>[
    MessageRecord(
      id: 'u1',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('First prompt: run the deployment'),
    ),
    MessageRecord(
      id: 'a1',
      parentId: 'u1',
      timestamp: _at(1),
      message: AssistantMessage(
        content: [
          const TextContent(text: 'Deploying now'),
          const ToolCall(
            id: 'call1',
            name: 'bash',
            arguments: {'cmd': 'deploy'},
          ),
        ],
        api: 'anthropic-messages',
        provider: 'anthropic',
        model: 'claude-test',
        usage: const Usage(
          input: 100,
          output: 20,
          cacheRead: 0,
          cacheWrite: 0,
          reasoning: 0,
          totalTokens: 120,
          cost: UsageCost(),
        ),
        stopReason: StopReason.toolUse,
        timestamp: _at(1),
      ),
    ),
    MessageRecord(
      id: 'r1',
      parentId: 'a1',
      timestamp: _at(2),
      message: ToolResultMessage(
        toolCallId: 'call1',
        toolName: 'bash',
        content: [const TextContent(text: 'deployed')],
        isError: false,
        timestamp: _at(2),
      ),
    ),
    MessageRecord(
      id: 'a2',
      parentId: 'r1',
      timestamp: _at(3),
      message: _assistant('Deploy finished', StopReason.stop, _at(3)),
    ),
    MessageRecord(
      id: 'u2',
      parentId: 'a2',
      timestamp: _at(10),
      message: UserMessage.text('Second prompt'),
    ),
    MessageRecord(
      id: 'a3',
      parentId: 'u2',
      timestamp: _at(11),
      message: _assistant('All done', StopReason.stop, _at(11)),
    ),
  ];
  for (final record in records) {
    snapshot = builder.append(record);
  }
  return snapshot;
}

/// A controller seeded with the timeline fixture.
TrajectoryController timelineFixtureController() =>
    TrajectoryController(initial: buildTimelineFixtureSnapshot());

/// Gantt fixture: an hour-long turn against a millisecond turn, built as
/// a raw [TrajectorySnapshot] for exact anchors. Exercises extreme
/// duration ratios (overflow clamping, min bar width) and the tools lane:
/// turn 1 = user + 60min assistant with a 29min tool and a 10min subtool;
/// turn 2 (after 1min idle) = user + 5ms assistant. Six records.
TrajectorySnapshot buildTimelineGanttSnapshot() {
  DateTime at(int ms) => _base.add(Duration(milliseconds: ms));
  return TrajectorySnapshot(
    records: UnmodifiableListView([
      TrajectoryUserRecord(
        index: 1,
        recordId: 'gantt-u1',
        text: 'Hour task',
        opensTurn: true,
        startedAt: at(0),
      ),
      TrajectoryAssistantRecord(
        index: 2,
        recordId: 'gantt-a1',
        messageId: 'gantt-m1',
        turn: 1,
        step: 1,
        stepStartTime: at(0),
        firstTokenTime: at(30000),
        completedTime: at(3600000),
        timeSeconds: const Duration(minutes: 60),
        displayText: 'Working',
      ),
      TrajectoryToolRecord(
        index: 3,
        recordId: 'gantt-t1',
        callId: 'gantt-call1',
        parentCallId: null,
        name: 'bash',
        argsRaw: '{}',
        result: 'ok',
        startedAt: at(60000),
        timeSeconds: const Duration(minutes: 29),
      ),
      TrajectoryToolRecord(
        index: 4,
        recordId: 'gantt-t2',
        callId: 'gantt-call2',
        parentCallId: 'gantt-call1',
        name: 'grep',
        argsRaw: '{}',
        result: 'ok',
        startedAt: at(600000),
        timeSeconds: const Duration(minutes: 10),
      ),
      TrajectoryUserRecord(
        index: 5,
        recordId: 'gantt-u2',
        text: 'Follow-up',
        opensTurn: true,
        startedAt: at(3660000),
      ),
      TrajectoryAssistantRecord(
        index: 6,
        recordId: 'gantt-a2',
        messageId: 'gantt-m2',
        turn: 2,
        step: 1,
        stepStartTime: at(3660000),
        completedTime: at(3660005),
        timeSeconds: const Duration(milliseconds: 5),
        displayText: 'Done',
      ),
    ]),
    requests: UnmodifiableListView(const []),
    callSchemas: const {},
    partial: null,
    runningCalls: UnmodifiableListView(const []),
    recordLocations: const {},
    revision: 6,
  );
}

/// A controller seeded with the gantt fixture.
TrajectoryController timelineGanttController() =>
    TrajectoryController(initial: buildTimelineGanttSnapshot());

/// Live-tail fixture: a settled turn, one still-running tool call, and a
/// streaming assistant partial. The running call projects a synthetic
/// lane-2 row and the partial pulses on the model lane.
TrajectorySnapshot buildTimelineLiveSnapshot() {
  DateTime at(int ms) => _base.add(Duration(milliseconds: ms));
  return TrajectorySnapshot(
    records: UnmodifiableListView([
      TrajectoryUserRecord(
        index: 1,
        recordId: 'live-u1',
        text: 'go',
        opensTurn: true,
        startedAt: _base,
      ),
      TrajectoryAssistantRecord(
        index: 2,
        recordId: 'live-a1',
        messageId: 'live-m1',
        turn: 1,
        step: 1,
        stepStartTime: _base,
        completedTime: at(1000),
        timeSeconds: const Duration(seconds: 1),
        displayText: 'Thinking',
      ),
    ]),
    requests: UnmodifiableListView(const []),
    callSchemas: const {},
    partial: TrajectoryPartialAssistant(
      messageId: 'live-partial',
      turn: 1,
      step: 2,
      blocks: const [],
      startedAt: at(1500),
    ),
    runningCalls: UnmodifiableListView([
      TrajectoryRunningToolCall(
        callId: 'live-call',
        name: 'bash',
        turn: 1,
        step: 2,
        startedAt: at(2000),
      ),
    ]),
    recordLocations: const {},
    revision: 3,
  );
}

/// A controller seeded with the live fixture.
TrajectoryController timelineLiveController() =>
    TrajectoryController(initial: buildTimelineLiveSnapshot());

/// Context-only fixture: one context injection with no wall-clock anchor
/// anywhere, so timed projections derive an empty (null) model.
TrajectorySnapshot buildTimelineContextOnlySnapshot() => TrajectorySnapshot(
  records: UnmodifiableListView([
    const TrajectoryContextRecord(index: 1, recordId: 'ctx-1', text: 'ctx'),
  ]),
  requests: UnmodifiableListView(const []),
  callSchemas: const {},
  partial: null,
  runningCalls: UnmodifiableListView(const []),
  recordLocations: const {},
  revision: 1,
);

/// A controller seeded with the context-only fixture.
TrajectoryController timelineContextOnlyController() =>
    TrajectoryController(initial: buildTimelineContextOnlySnapshot());
