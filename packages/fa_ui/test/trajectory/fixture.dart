// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Shared trajectory fixture: one user prompt, an assistant step with a
/// tool call plus result, and a plain follow-up step — built through the
/// core [TrajectorySnapshotBuilder] so record ids and indexes match real
/// projection.
///
/// Layout: turn 1 = [user, message, tool, message] — a collapsible turn
/// whose first assistant (followed by its tool) is the one collapsible
/// assistant run. Record indexes run 1..4 in that order.

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

AssistantMessage _assistantMessage(
  List<ContentBlock> content,
  StopReason stopReason,
  DateTime timestamp,
) => AssistantMessage(
  content: content,
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

/// Builds the fixture snapshot with one turn of four records.
TrajectorySnapshot buildFixtureSnapshot() {
  final builder = TrajectorySnapshotBuilder();
  TrajectorySnapshot snapshot = TrajectorySnapshot.empty;
  for (final record in _records) {
    snapshot = builder.append(record);
  }
  return snapshot;
}

/// A controller seeded with [buildFixtureSnapshot].
TrajectoryController fixtureController() =>
    TrajectoryController(initial: buildFixtureSnapshot());

/// Record ids of one kind, in fixture display order.
List<String> recordIds(
  TrajectoryController controller,
  TrajectoryCellKind kind,
) => [
  for (final record in controller.records)
    if (record.kind == kind) record.recordId,
];

final List<SessionRecord> _records = [
  MessageRecord(
    id: 'u1',
    parentId: null,
    timestamp: _at(0),
    message: UserMessage.text('Run the deployment'),
  ),
  MessageRecord(
    id: 'a1',
    parentId: 'u1',
    timestamp: _at(1),
    message: _assistantMessage(
      [
        TextContent(text: 'Deploying now'),
        ToolCall(id: 'call1', name: 'bash', arguments: const {'cmd': 'deploy'}),
      ],
      StopReason.toolUse,
      _at(1),
    ),
  ),
  MessageRecord(
    id: 'r1',
    parentId: 'a1',
    timestamp: _at(2),
    message: ToolResultMessage(
      toolCallId: 'call1',
      toolName: 'bash',
      content: [TextContent(text: 'deployed')],
      isError: false,
      timestamp: _at(2),
    ),
  ),
  MessageRecord(
    id: 'a2',
    parentId: 'r1',
    timestamp: _at(3),
    message: _assistantMessage(
      [TextContent(text: 'Deploy finished')],
      StopReason.stop,
      _at(3),
    ),
  ),
];
