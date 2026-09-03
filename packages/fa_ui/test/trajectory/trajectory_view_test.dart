// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

class _CustomStrings extends TrajectoryStringsEn {
  const _CustomStrings();

  @override
  String get viewNoRecords => 'EMPTY';
}

void main() {
  testWidgets('empty snapshot shows the placeholder and disables the toolbar', (
    tester,
  ) async {
    final controller = TrajectoryController();
    var tableBuilt = false;

    await _pump(
      tester,
      TrajectoryView(
        controller: controller,
        tableBuilder: (_, _) {
          tableBuilt = true;
          return const Text('TABLE');
        },
      ),
    );

    expect(find.text('No records yet'), findsOneWidget);
    expect(tableBuilt, isFalse);
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(button.onPressed, isNull);
    }
    controller.dispose();
  });

  testWidgets('renders the table and timeline seams on a populated snapshot', (
    tester,
  ) async {
    final controller = fixtureController();

    await _pump(
      tester,
      TrajectoryView(
        controller: controller,
        tableBuilder: (_, _) => const Text('TABLE'),
        timelineBuilder: (_, _) => const Text('TIMELINE'),
      ),
    );

    expect(find.text('TABLE'), findsOneWidget);
    expect(find.text('TIMELINE'), findsOneWidget);
    expect(find.text('No records yet'), findsNothing);
    controller.dispose();
  });

  testWidgets('swaps the placeholder for the table once a snapshot lands', (
    tester,
  ) async {
    final controller = TrajectoryController();

    await _pump(
      tester,
      TrajectoryView(
        controller: controller,
        tableBuilder: (_, _) => const Text('TABLE'),
      ),
    );
    expect(find.text('TABLE'), findsNothing);

    controller.updateSnapshot(buildFixtureSnapshot());
    await tester.pump(controller.snapshotDebounce);
    expect(find.text('TABLE'), findsOneWidget);
    expect(find.text('No records yet'), findsNothing);
    controller.dispose();
  });

  testWidgets('scope override swaps the strings', (tester) async {
    final controller = TrajectoryController();

    await _pump(
      tester,
      TrajectoryStringsScope(
        strings: const _CustomStrings(),
        child: TrajectoryView(controller: controller),
      ),
    );

    expect(find.text('EMPTY'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('swapping the controller rebinds the view', (tester) async {
    final first = fixtureController();
    final second = fixtureController();

    await _pump(tester, TrajectoryView(controller: first));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TrajectoryView(controller: second)),
      ),
    );
    await tester.pumpAndSettle();

    // The second controller's content renders through the same state.
    expect(find.text('Run the deployment'), findsOneWidget);
    first.dispose();
    second.dispose();
  });

  testWidgets('tapping a row selects it and opens the details sheet', (
    tester,
  ) async {
    final controller = fixtureController();

    await _pump(tester, TrajectoryView(controller: controller));
    await tester.tap(find.text('Deploying now'));
    await tester.pumpAndSettle();

    expect(controller.selectedRecordId, 'a1');
    expect(find.text('Event details'), findsOneWidget);
    controller.dispose();
  });

  test('string resolution falls back by locale', () {
    expect(
      TrajectoryStrings.forLocale(const Locale('en')),
      isA<TrajectoryStringsEn>(),
    );
    expect(
      TrajectoryStrings.forLocale(const Locale('ru')),
      isA<TrajectoryStringsRu>(),
    );
    expect(
      TrajectoryStrings.forLocale(const Locale('ru')).viewNoRecords,
      'Пока нет записей',
    );
  });
}
