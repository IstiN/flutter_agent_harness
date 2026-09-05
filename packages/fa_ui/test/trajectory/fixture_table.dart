// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/trajectory/trajectory_controller.dart';

/// Fixtures for the ledger table tests, built through the core
/// [TrajectorySnapshotBuilder] so record ids and indexes match real
/// projection.
///
/// [buildTableFixtureSnapshot] lays out one multi-tool turn, a standalone
/// compaction section, and a trailing system row:
/// turn 1 = [user, message, tool ok, tool error, message],
/// "between turns" = [compacted], turn 2 = [system].

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

AssistantMessage _assistant(
  List<ContentBlock> content,
  StopReason stopReason,
  int seconds,
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
  timestamp: _at(seconds),
);

final List<SessionRecord> _tableRecords = [
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
    message: _assistant(
      [
        TextContent(text: 'Deploying now'),
        ToolCall(id: 'call1', name: 'bash', arguments: const {'cmd': 'deploy'}),
        ToolCall(id: 'call2', name: 'read', arguments: const {'path': 'a.txt'}),
      ],
      StopReason.toolUse,
      1,
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
    id: 'r2',
    parentId: 'r1',
    timestamp: _at(3),
    message: ToolResultMessage(
      toolCallId: 'call2',
      toolName: 'read',
      content: [TextContent(text: 'boom')],
      isError: true,
      timestamp: _at(3),
    ),
  ),
  MessageRecord(
    id: 'a2',
    parentId: 'r2',
    timestamp: _at(4),
    message: _assistant(
      [TextContent(text: 'Deploy finished')],
      StopReason.stop,
      4,
    ),
  ),
  CompactionRecord(
    id: 'cp1',
    parentId: 'a2',
    timestamp: _at(5),
    summary: 'Compacted the deployment work so far',
    firstKeptEntryId: 'u1',
    tokensBefore: 900,
  ),
  ModelChangeRecord(
    id: 'm1',
    parentId: 'cp1',
    timestamp: _at(6),
    provider: 'anthropic',
    modelId: 'claude-x',
  ),
];

/// The small table fixture snapshot (7 ledger records over 3 sections).
TrajectorySnapshot buildTableFixtureSnapshot() {
  final builder = TrajectorySnapshotBuilder();
  TrajectorySnapshot snapshot = TrajectorySnapshot.empty;
  for (final record in _tableRecords) {
    snapshot = builder.append(record);
  }
  return snapshot;
}

/// A controller seeded with [buildTableFixtureSnapshot].
TrajectoryController tableFixtureController() =>
    TrajectoryController(initial: buildTableFixtureSnapshot());

/// Record ids of one kind, in fixture display order.
List<String> recordIds(
  TrajectoryController controller,
  TrajectoryCellKind kind,
) => [
  for (final record in controller.records)
    if (record.kind == kind) record.recordId,
];

/// A controller whose last tool call never settles: the row must render
/// the running state.
TrajectoryController runningToolController() {
  final builder = TrajectorySnapshotBuilder();
  TrajectorySnapshot snapshot = TrajectorySnapshot.empty;
  final records = [
    MessageRecord(
      id: 'u1',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('Probe the service'),
    ),
    MessageRecord(
      id: 'a1',
      parentId: 'u1',
      timestamp: _at(1),
      message: _assistant(
        [
          TextContent(text: 'Probing'),
          ToolCall(id: 'call1', name: 'sleep', arguments: const {'ms': 5}),
        ],
        StopReason.toolUse,
        1,
      ),
    ),
  ];
  for (final record in records) {
    snapshot = builder.append(record);
  }
  return TrajectoryController(initial: snapshot);
}

/// A session of [turns] single-tool turns — 3 ledger records per turn
/// (user, message, tool) for virtualisation-threshold coverage.
TrajectorySnapshot buildLargeFixtureSnapshot({int turns = 40}) {
  final builder = TrajectorySnapshotBuilder();
  TrajectorySnapshot snapshot = TrajectorySnapshot.empty;
  String? previousId;
  for (var i = 1; i <= turns; i++) {
    final userId = 'lu$i';
    final assistantId = 'la$i';
    final resultId = 'lr$i';
    snapshot = builder.append(
      MessageRecord(
        id: userId,
        parentId: previousId,
        timestamp: _at(i * 10),
        message: UserMessage.text('Turn $i prompt'),
      ),
    );
    snapshot = builder.append(
      MessageRecord(
        id: assistantId,
        parentId: userId,
        timestamp: _at(i * 10 + 1),
        message: _assistant(
          [
            TextContent(text: 'Turn $i reply'),
            ToolCall(id: 'lc$i', name: 'bash', arguments: const {'i': 0}),
          ],
          StopReason.toolUse,
          i * 10 + 1,
        ),
      ),
    );
    snapshot = builder.append(
      MessageRecord(
        id: resultId,
        parentId: assistantId,
        timestamp: _at(i * 10 + 2),
        message: ToolResultMessage(
          toolCallId: 'lc$i',
          toolName: 'bash',
          content: [TextContent(text: 'ok $i')],
          isError: false,
          timestamp: _at(i * 10 + 2),
        ),
      ),
    );
    previousId = resultId;
  }
  return snapshot;
}

TrajectorySnapshot _appendAll(
  TrajectorySnapshotBuilder builder,
  List<SessionRecord> records,
) {
  var snapshot = TrajectorySnapshot.empty;
  for (final record in records) {
    snapshot = builder.append(record);
  }
  return snapshot;
}

/// A controller whose assistant step produced nothing at all: the row
/// must render the explicit empty-response state.
TrajectoryController emptyAssistantController() {
  final snapshot = _appendAll(TrajectorySnapshotBuilder(), [
    MessageRecord(
      id: 'eu1',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('Say something'),
    ),
    MessageRecord(
      id: 'ea1',
      parentId: 'eu1',
      timestamp: _at(1),
      message: AssistantMessage(
        content: const [],
        api: 'anthropic-messages',
        provider: 'anthropic',
        model: 'claude-test',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: _at(1),
      ),
    ),
  ]);
  return TrajectoryController(initial: snapshot);
}

/// A controller with a nested tool call (`call1-1` under `call1`): the
/// child row must indent under its parent.
TrajectoryController subtoolController() {
  final snapshot = _appendAll(TrajectorySnapshotBuilder(), [
    MessageRecord(
      id: 'su1',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('Search the sources'),
    ),
    MessageRecord(
      id: 'sa1',
      parentId: 'su1',
      timestamp: _at(1),
      message: _assistant(
        const [
          ToolCall(id: 'call1', name: 'bash', arguments: {'cmd': 'ls src'}),
        ],
        StopReason.toolUse,
        1,
      ),
    ),
    MessageRecord(
      id: 'sr1',
      parentId: 'sa1',
      timestamp: _at(2),
      message: ToolResultMessage(
        toolCallId: 'call1',
        toolName: 'bash',
        content: [const TextContent(text: 'main.ts api.ts')],
        isError: false,
        timestamp: _at(2),
      ),
    ),
    MessageRecord(
      id: 'sa2',
      parentId: 'sr1',
      timestamp: _at(3),
      message: _assistant(
        const [
          ToolCall(
            id: 'call1-1',
            parentCallId: 'call1',
            name: 'grep',
            arguments: {'pattern': 'deploy'},
          ),
        ],
        StopReason.toolUse,
        3,
      ),
    ),
    MessageRecord(
      id: 'sr2',
      parentId: 'sa2',
      timestamp: _at(4),
      message: ToolResultMessage(
        toolCallId: 'call1-1',
        toolName: 'grep',
        content: [const TextContent(text: 'main.ts:1: deploy')],
        isError: false,
        timestamp: _at(4),
      ),
    ),
  ]);
  return TrajectoryController(initial: snapshot);
}

/// A controller whose tool result is ~1.5 MiB: the expanded body must
/// stay bounded and offer the `show content` expander.
TrajectoryController bigResultController() {
  final snapshot = _appendAll(TrajectorySnapshotBuilder(), [
    MessageRecord(
      id: 'bu1',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('Dump the log'),
    ),
    MessageRecord(
      id: 'ba1',
      parentId: 'bu1',
      timestamp: _at(1),
      message: _assistant(
        const [
          ToolCall(id: 'call1', name: 'read', arguments: {'path': 'big.log'}),
        ],
        StopReason.toolUse,
        1,
      ),
    ),
    MessageRecord(
      id: 'br1',
      parentId: 'ba1',
      timestamp: _at(2),
      message: ToolResultMessage(
        toolCallId: 'call1',
        toolName: 'read',
        content: [TextContent(text: '${'x' * (1536 * 1024)}\nEND_OF_RESULT')],
        isError: false,
        timestamp: _at(2),
      ),
    ),
  ]);
  return TrajectoryController(initial: snapshot);
}

/// A controller whose rows carry an RTL string, a huge unbroken token,
/// and emoji: row layout must soft-wrap and never overflow horizontally
/// (E9), including the expanded body.
TrajectoryController overflowProbeController() {
  final unbroken = 'A' * 2000;
  final snapshot = _appendAll(TrajectorySnapshotBuilder(), [
    MessageRecord(
      id: 'ou1',
      parentId: null,
      timestamp: _at(0),
      message: UserMessage.text('🔍🚀🛠️ $unbroken مرحبا بالعالم'),
    ),
    MessageRecord(
      id: 'oa1',
      parentId: 'ou1',
      timestamp: _at(1),
      message: _assistant(
        const [
          ToolCall(id: 'ocall1', name: 'bash', arguments: {'cmd': 'probe'}),
        ],
        StopReason.toolUse,
        1,
      ),
    ),
    MessageRecord(
      id: 'or1',
      parentId: 'oa1',
      timestamp: _at(2),
      message: ToolResultMessage(
        toolCallId: 'ocall1',
        toolName: 'bash',
        content: [TextContent(text: '💥🎉 $unbroken ok')],
        isError: false,
        timestamp: _at(2),
      ),
    ),
  ]);
  return TrajectoryController(initial: snapshot);
}
