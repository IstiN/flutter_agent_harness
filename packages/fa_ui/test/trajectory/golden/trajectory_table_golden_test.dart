// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the ledger table: empty, one row, ten rows, and a
/// ~100-row virtualised session (fixed 800×600 viewport — only the
/// visible rows matter, tail-follow lands on the newest rows), each with
/// every turn expanded and every turn collapsed to its summary row. Small
/// fixtures alternate user/assistant turns through the real projection;
/// the large one reuses `fixture_table.dart`'s builder. See
/// `golden_test_setup.dart` for the font and determinism conventions.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixture_table.dart';
import 'golden_test_setup.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

/// A session of [rows] ledger rows: alternating single-message turns
/// (user prompt, assistant reply) built through the real projection.
TrajectorySnapshot _alternatingSnapshot(int rows) {
  final builder = TrajectorySnapshotBuilder();
  var snapshot = TrajectorySnapshot.empty;
  var parentId = 'root';
  for (var i = 0; i < rows; i++) {
    final user = i.isEven;
    final id = 'r$i';
    snapshot = builder.append(
      MessageRecord(
        id: id,
        parentId: user ? null : parentId,
        timestamp: _base.add(Duration(seconds: i)),
        message: user
            ? UserMessage.text('Turn prompt ${i ~/ 2 + 1}')
            : AssistantMessage(
                content: [TextContent(text: 'Reply ${i ~/ 2 + 1}')],
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
                stopReason: StopReason.stop,
                timestamp: _base.add(Duration(seconds: i)),
              ),
      ),
    );
    parentId = id;
  }
  return snapshot;
}

void main() {
  final sessions = <(String, TrajectorySnapshot)>[
    ('rows_0', TrajectorySnapshot.empty),
    ('rows_1', _alternatingSnapshot(1)),
    ('rows_10', _alternatingSnapshot(10)),
    ('rows_100', buildLargeFixtureSnapshot(turns: 34)),
  ];

  for (final (name, snapshot) in sessions) {
    for (final collapsed in [false, true]) {
      final file = 'table/${name}_${collapsed ? 'collapsed' : 'expanded'}.png';
      testWidgets(file, (tester) async {
        final controller = TrajectoryController(initial: snapshot);
        if (collapsed) controller.collapseAllTurns();
        await pumpGolden(
          tester,
          TrajectoryTable(controller: controller),
          size: goldenSizeLedger,
        );
        await expectGolden(tester, file);
        controller.dispose();
      });
    }
  }

  testWidgets('table/row_expanded.png', (tester) async {
    final controller = TrajectoryController(
      initial: buildTableFixtureSnapshot(),
    );
    controller.toggleExpandedRow(
      recordIds(controller, TrajectoryCellKind.tool).first,
    );
    await pumpGolden(
      tester,
      TrajectoryTable(controller: controller),
      size: goldenSizeLedger,
    );
    await expectGolden(tester, 'table/row_expanded.png');
    controller.dispose();
  });
}
