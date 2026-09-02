// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

Future<void> _pump(WidgetTester tester, TrajectoryController controller) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TrajectoryToolbar(controller: controller)),
    ),
  );
}

void main() {
  testWidgets('renders every control with its tooltip', (tester) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    expect(find.byType(IconButton), findsNWidgets(3));
    expect(find.byTooltip('Use actual duration'), findsOneWidget);
    expect(find.byTooltip('Collapse turns'), findsOneWidget);
    expect(find.byTooltip('Collapse calls'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    controller.dispose();
  });

  testWidgets('disables every control on an empty snapshot', (tester) async {
    final controller = TrajectoryController();
    await _pump(tester, controller);

    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(button.onPressed, isNull);
    }
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    controller.dispose();
  });

  testWidgets('duration toggle flips the projection and its tooltip', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    await tester.tap(find.byTooltip('Use actual duration'));
    await tester.pump();
    expect(controller.actualDuration, isTrue);
    expect(find.byTooltip('Use equal-width operations'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('turn fold button collapses and expands all turns', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    await tester.tap(find.byTooltip('Collapse turns'));
    expect(controller.collapsedTurns, {1});
    await tester.pump();
    await tester.tap(find.byTooltip('Expand turns'));
    expect(controller.collapsedTurns, isEmpty);
    controller.dispose();
  });

  testWidgets('calls fold button collapses and expands assistant runs', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    await tester.tap(find.byTooltip('Collapse calls'));
    expect(controller.collapsedAssistants, isNotEmpty);
    await tester.pump();
    await tester.tap(find.byTooltip('Expand calls'));
    expect(controller.collapsedAssistants, isEmpty);
    controller.dispose();
  });

  testWidgets('search field feeds the controller query immediately', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    await tester.enterText(find.byType(TextField), 'deploy');
    expect(controller.searchQuery, 'deploy');
    expect(controller.searchMatchRecordIds, isNotNull);
    controller.dispose();
  });
}
