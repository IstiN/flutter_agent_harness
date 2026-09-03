// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

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
