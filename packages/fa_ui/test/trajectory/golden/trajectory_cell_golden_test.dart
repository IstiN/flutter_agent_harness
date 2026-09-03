// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the seven trajectory ledger cell kinds, dark and
/// light: one full-frame page per kind with realistic row content
/// (assistant with text + usage, tool with an error-result variant, a
/// multi-block user message, a running compaction, a system model change,
/// a context injection, and a nested subtool child). See
/// `golden_test_setup.dart` for the font and determinism conventions.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../golden/golden_test_setup.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

AssistantMessage _assistant(
  List<ContentBlock> content,
  StopReason stopReason,
  DateTime timestamp,
) => AssistantMessage(
  content: content,
  api: 'anthropic-messages',
  provider: 'anthropic',
  model: 'claude-opus-4-6',
  usage: const Usage(
    input: 1832,
    output: 96,
    cacheRead: 4096,
    cacheWrite: 128,
    reasoning: 0,
    totalTokens: 6152,
    cost: UsageCost(),
  ),
  stopReason: stopReason,
  timestamp: timestamp,
);

/// Ledger records of one kind from a snapshot built through the real
/// projection ([extra] seeds additional finalized records).
List<TrajectoryRecord> _rowsOf(
  TrajectoryCellKind kind,
  List<SessionRecord> extra,
) {
  final builder = TrajectorySnapshotBuilder();
  var snapshot = TrajectorySnapshot.empty;
  for (final record in extra) {
    snapshot = builder.append(record);
  }
  return [
    for (final record in snapshot.records)
      if (record.kind == kind) record,
  ];
}

/// The subtool child row — built directly for a fixed fixture (the core
/// builder only produces one when the session carries a nested call, same
/// shape fixture_details.dart uses).
final _subtoolRow = TrajectoryToolRecord(
  index: 1,
  recordId: 'goldens/subtool',
  callId: 'call1-1',
  parentCallId: 'call1',
  name: 'grep',
  argsRaw: '{"pattern":"deploy","path":"src/"}',
  result: 'src/api.ts:42: deploy retry loop',
  timeSeconds: const Duration(milliseconds: 120),
  startedAt: _at(5),
);

void main() {
  // One realistic row set per ledger kind, in enum order minus message.
  final kinds = <(String, TrajectoryCellKind, List<TrajectoryRecord>)>[
    (
      'message',
      TrajectoryCellKind.message,
      _rowsOf(TrajectoryCellKind.message, [
        MessageRecord(
          id: 'u1',
          parentId: null,
          timestamp: _at(0),
          message: UserMessage.text('Deploy the api service'),
        ),
        MessageRecord(
          id: 'a1',
          parentId: 'u1',
          timestamp: _at(1),
          message: _assistant(
            [const TextContent(text: 'Deploying the api service now')],
            StopReason.toolUse,
            _at(1),
          ),
        ),
      ]),
    ),
    (
      'tool',
      TrajectoryCellKind.tool,
      _rowsOf(TrajectoryCellKind.tool, [
        MessageRecord(
          id: 'u1',
          parentId: null,
          timestamp: _at(0),
          message: UserMessage.text('Deploy'),
        ),
        MessageRecord(
          id: 'a1',
          parentId: 'u1',
          timestamp: _at(1),
          message: _assistant(
            const [
              ToolCall(id: 'call1', name: 'bash', arguments: {'cmd': 'deploy'}),
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
            content: [const TextContent(text: 'deployed in 41s')],
            isError: false,
            timestamp: _at(2),
          ),
        ),
        MessageRecord(
          id: 'u2',
          parentId: 'r1',
          timestamp: _at(3),
          message: UserMessage.text('Check the health endpoint'),
        ),
        MessageRecord(
          id: 'a2',
          parentId: 'u2',
          timestamp: _at(4),
          message: _assistant(
            const [
              ToolCall(
                id: 'call2',
                name: 'bash',
                arguments: {'cmd': 'curl :8080'},
              ),
            ],
            StopReason.toolUse,
            _at(4),
          ),
        ),
        MessageRecord(
          id: 'r2',
          parentId: 'a2',
          timestamp: _at(5),
          message: ToolResultMessage(
            toolCallId: 'call2',
            toolName: 'bash',
            content: [const TextContent(text: 'connection refused')],
            isError: true,
            timestamp: _at(5),
          ),
        ),
      ]),
    ),
    (
      'user',
      TrajectoryCellKind.user,
      _rowsOf(TrajectoryCellKind.user, [
        MessageRecord(
          id: 'u1',
          parentId: null,
          timestamp: _at(0),
          message: UserMessage(
            content: [
              const TextContent(text: 'Check the failing deploy job'),
              const TextContent(text: 'Logs are in the CI output'),
            ],
            timestamp: _at(0),
          ),
        ),
      ]),
    ),
    (
      'compacted',
      TrajectoryCellKind.compacted,
      _rowsOf(TrajectoryCellKind.compacted, [
        // summary '' while the compaction is still running → Pending row.
        CompactionRecord(
          id: 'c1',
          parentId: null,
          timestamp: _at(6),
          summary: '',
          firstKeptEntryId: 'u1',
          tokensBefore: 4200,
        ),
      ]),
    ),
    (
      'system',
      TrajectoryCellKind.system,
      _rowsOf(TrajectoryCellKind.system, [
        ModelChangeRecord(
          id: 's1',
          parentId: null,
          timestamp: _at(8),
          provider: 'anthropic',
          modelId: 'claude-opus-4-6',
        ),
      ]),
    ),
    (
      'context',
      TrajectoryCellKind.context,
      _rowsOf(TrajectoryCellKind.context, [
        CustomMessageRecord(
          id: 'x1',
          parentId: null,
          timestamp: _at(7),
          customType: 'context',
          content: 'Working directory: ~/work/api-server (git, branch main)',
          display: true,
        ),
      ]),
    ),
    ('subtool', TrajectoryCellKind.subtool, [_subtoolRow]),
  ];

  for (final (name, kind, rows) in kinds) {
    testWidgets('$kind cells render dark and light', (tester) async {
      expect(rows, isNotEmpty, reason: 'fixture must produce $kind rows');
      await pumpGolden(tester, goldenCellPage(rows));
      await expectGolden(tester, 'cells/${name}_dark.png');
      await pumpGolden(
        tester,
        goldenCellPage(rows),
        theme: buildFahThemeLight(),
      );
      await expectGolden(tester, 'cells/${name}_light.png');
    });
  }
}
