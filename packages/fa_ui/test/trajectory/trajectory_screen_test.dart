// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

Future<void> _pump(
  WidgetTester tester,
  TrajectoryController controller, {
  Size size = const Size(1280, 800),
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: TrajectoryScreen(controller: controller, onClose: onClose ?? () {}),
    ),
  );
  await tester.pump(); // let the autofocus/focus pass settle
}

void main() {
  testWidgets('wide renders the master-detail split with the details pane', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    expect(find.byType(TrajectoryDetailsPane), findsOneWidget);
    expect(find.text('Select a record to inspect'), findsOneWidget);

    // Selecting a record binds the pane to its real tab content.
    controller.selectRecord(
      recordIds(controller, TrajectoryCellKind.tool).first,
    );
    await tester.pump();
    expect(find.text('Select a record to inspect'), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(TabBarView), findsOneWidget);
    controller.dispose();
  });

  testWidgets('narrow renders the feed only (details stay a sheet)', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller, size: const Size(600, 1000));

    expect(find.byType(TrajectoryDetailsPane), findsNothing);
    expect(find.byType(TrajectoryView), findsOneWidget);
    controller.dispose();
  });

  testWidgets('the header close button invokes onClose', (tester) async {
    final controller = fixtureController();
    var closed = false;
    await _pump(tester, controller, onClose: () => closed = true);

    await tester.tap(find.byTooltip('Close trajectory'));
    expect(closed, isTrue);
    controller.dispose();
  });

  testWidgets('Escape invokes onClose', (tester) async {
    final controller = fixtureController();
    var closed = false;
    await _pump(tester, controller, onClose: () => closed = true);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, isTrue);
    controller.dispose();
  });

  testWidgets('pushed as a route it pops via onClose', (tester) async {
    final controller = fixtureController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => TrajectoryScreen(
                      controller: controller,
                      onClose: () {
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TrajectoryScreen), findsOneWidget);
    // No dimmed dialog backdrop: the route IS the page.
    expect(find.byType(Dialog), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(); // start the pop transition
    await tester.pump(const Duration(milliseconds: 600)); // finish it
    expect(find.byType(TrajectoryScreen), findsNothing);
    // Flush the fixture controller's throttled search-index timer.
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('resizing wide <-> narrow keeps the controller state (E6)', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller, size: const Size(600, 1000));

    // Mutate every owned slice of state on the narrow layout.
    controller
      ..selectRecord(recordIds(controller, TrajectoryCellKind.tool).first)
      ..searchQuery = 'deploy'
      ..toggleExpandedRow(recordIds(controller, TrajectoryCellKind.tool).first)
      ..toggleFilter(TrajectoryLedgerFilter.system);
    await tester.pump();

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    expect(find.byType(TrajectoryDetailsPane), findsOneWidget);

    // Selection survives the morph and still drives the pane.
    expect(find.text('Select a record to inspect'), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);

    tester.view.physicalSize = const Size(600, 1000);
    await tester.pump();
    expect(find.byType(TrajectoryDetailsPane), findsNothing);
    expect(controller.selectedRecordId, isNotNull);
    expect(controller.searchQuery, 'deploy');
    expect(controller.expandedRecordIds, isNotEmpty);
    expect(controller.filters, isNot(contains(TrajectoryLedgerFilter.system)));
    controller.dispose();
  });
}
