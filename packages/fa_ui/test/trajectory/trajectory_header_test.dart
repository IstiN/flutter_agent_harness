// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

Future<void> _pump(
  WidgetTester tester,
  TrajectoryController controller, {
  VoidCallback? onClose,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: TrajectoryHeader(controller: controller, onClose: onClose),
    ),
  ),
);

void main() {
  testWidgets('renders title, stats cluster, search, and filter chips', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    expect(find.text('Trajectory'), findsOneWidget);
    // The fixture has no recorded durations: turns + token pills only.
    expect(find.text('1 turn'), findsOneWidget);
    expect(find.text('In 200'), findsOneWidget);
    expect(find.text('Out 40'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    for (final chip in ['Messages', 'Tools', 'Errors', 'System']) {
      expect(find.text(chip), findsOneWidget);
    }
    // No close affordance without an onClose callback.
    expect(find.byTooltip('Close trajectory'), findsNothing);
    controller.dispose();
  });

  testWidgets('close affordance appears and fires with onClose', (tester) async {
    final controller = fixtureController();
    var closed = false;
    await _pump(tester, controller, onClose: () => closed = true);

    await tester.tap(find.byTooltip('Close trajectory'));
    expect(closed, isTrue);
    controller.dispose();
  });

  testWidgets('search shows the match count and navigates prev/next', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    await tester.enterText(find.byType(TextField), 'deploy');
    await tester.pump();

    final count = controller.searchMatchOrder.length;
    expect(count, greaterThan(1));
    expect(find.text('1 of $count'), findsOneWidget);

    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.text('2 of $count'), findsOneWidget);
    expect(controller.selectedRecordId, controller.searchMatchOrder[1]);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pump();
    expect(find.text('1 of $count'), findsOneWidget);

    // Wraps forward from the last match.
    for (var i = 0; i < count - 1; i++) {
      controller.nextSearchMatch();
    }
    await tester.pump();
    expect(find.text('$count of $count'), findsOneWidget);
    controller.nextSearchMatch();
    await tester.pump();
    expect(find.text('1 of $count'), findsOneWidget);

    // Clearing the query hides the navigation.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('1 of $count'), findsNothing);
    controller.dispose();
  });

  testWidgets('filter chips toggle controller filters and hide rows', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    // System off: no fixture rows are system rows, nothing hides.
    await tester.tap(find.text('System'));
    await tester.pump();
    expect(
      controller.filters,
      isNot(contains(TrajectoryLedgerFilter.system)),
    );
    List<TrajectoryRecord> visibleCells() => [
      for (final turn in controller.turns)
        for (final group in turn.groups) ...group.cells,
    ];

    expect(visibleCells(), hasLength(4));

    // Messages off: only the tool call row remains visible.
    await tester.tap(find.text('Messages'));
    await tester.pump();
    expect(
      controller.filters,
      isNot(contains(TrajectoryLedgerFilter.messages)),
    );
    expect(visibleCells(), hasLength(1));
    expect(visibleCells().single.kind, TrajectoryCellKind.tool);

    // Back on: every row returns.
    await tester.tap(find.text('Messages'));
    await tester.pump();
    expect(visibleCells(), hasLength(4));
    controller.dispose();
  });

  testWidgets('disables the search field on an empty snapshot', (tester) async {
    final controller = TrajectoryController();
    await _pump(tester, controller);

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    controller.dispose();
  });
}
