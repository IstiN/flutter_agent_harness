// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'fixture.dart';
import 'fixture_table.dart' as table_fixture;

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
    controller.dispose();
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

    // Scroll the narrow ledger off the tail; the offset must survive the
    // morph to the same live tree at wide size.
    final ledgerScrollable = find
        .descendant(
          of: find.byType(TrajectoryTable),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    await tester.drag(ledgerScrollable, const Offset(0, -200));
    await tester.pump();
    final offsetNarrow = tester
        .state<ScrollableState>(ledgerScrollable)
        .position
        .pixels;

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    expect(find.byType(TrajectoryDetailsPane), findsOneWidget);

    // Selection survives the morph and still drives the pane.
    expect(find.text('Select a record to inspect'), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    expect(
      tester.state<ScrollableState>(ledgerScrollable).position.pixels,
      offsetNarrow,
    );
    tester.view.physicalSize = const Size(600, 1000);
    await tester.pump();
    expect(find.byType(TrajectoryDetailsPane), findsNothing);
    expect(controller.selectedRecordId, isNotNull);
    expect(controller.searchQuery, 'deploy');
    expect(controller.expandedRecordIds, isNotEmpty);
    expect(controller.filters, isNot(contains(TrajectoryLedgerFilter.system)));
    controller.dispose();
  });

  testWidgets('tapping a timeline span scrolls its row into view (P2-1)', (
    tester,
  ) async {
    final controller = TrajectoryController(
      initial: table_fixture.buildLargeFixtureSnapshot(turns: 40),
    );
    await _pump(tester, controller);

    // Tap the first record's span on the real timeline strip.
    final timeline = find.byType(TrajectoryTimeline);
    final model = controller.timelineModel!;
    final trackWidth =
        tester.getSize(timeline).width - trajectoryTimelineLabelGutter;
    final rect = trajectoryTimelineSpanRect(
      model.spans.first,
      viewport: TrajectoryTimelineViewport.full(model),
      mode: controller.timelineMode,
      trackWidth: trackWidth,
    );
    final gesture = await tester.startGesture(
      tester.getTopLeft(timeline) + rect.center,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    // The Turn 1 row is built and inside the ledger viewport. (Row text
    // carries a trailing newline for cross-row copy: match by prefix.)
    expect(find.textContaining('Turn 1 prompt'), findsOneWidget);
    final ledger = find.byType(TrajectoryTable);
    final rowTop = tester.getTopLeft(find.textContaining('Turn 1 prompt')).dy;
    expect(rowTop, greaterThanOrEqualTo(tester.getTopLeft(ledger).dy));
    expect(rowTop, lessThan(tester.getBottomLeft(ledger).dy));
    controller.dispose();
  });

  testWidgets('Tab reaches search field, header buttons, and rows (AC12)', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = fixtureController();
    await _pump(tester, controller);

    expect(find.bySemanticsLabel(RegExp('^Trajectory header')), findsOneWidget);
    expect(find.byTooltip('Close trajectory'), findsOneWidget);

    bool focusHas<T extends Widget>() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<T>() !=
        null;
    bool focusIsCloseButton() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return false;
      return context.findAncestorWidgetOfExactType<IconButton>()?.tooltip ==
          'Close trajectory';
    }

    var sawSearch = false;
    var sawClose = false;
    var sawRows = false;
    for (var i = 0; i < 15 && !(sawSearch && sawClose && sawRows); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      sawSearch = sawSearch || focusHas<TextField>();
      sawClose = sawClose || focusIsCloseButton();
      sawRows = sawRows || focusHas<TrajectoryTable>();
    }
    expect(sawSearch, isTrue, reason: 'Tab should reach the search field');
    expect(sawClose, isTrue, reason: 'Tab should reach the header buttons');
    expect(sawRows, isTrue, reason: 'Tab should reach the ledger rows');
    controller.dispose();
    semantics.dispose();
  });

  testWidgets('SafeArea keeps header and last row inside insets (E11)', (
    tester,
  ) async {
    final controller = TrajectoryController(
      initial: table_fixture.buildLargeFixtureSnapshot(turns: 40),
    );
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.fromLTRB(0, 40, 0, 30),
            viewInsets: EdgeInsets.only(bottom: 25),
          ),
          child: TrajectoryScreen(controller: controller, onClose: () {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    // The header clears the top inset; the tail row sits above the
    // bottom inset plus the keyboard (Scaffold resize + SafeArea).
    expect(tester.getTopLeft(find.text('Trajectory')).dy, greaterThanOrEqualTo(40));
    expect(find.textContaining('Turn 40 prompt'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.textContaining('Turn 40 prompt')).dy,
      lessThanOrEqualTo(800 - 25 - 30),
    );
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
