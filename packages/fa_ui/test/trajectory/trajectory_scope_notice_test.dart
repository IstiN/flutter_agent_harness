// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

Future<void> _pump(
  WidgetTester tester,
  TrajectoryController controller, {
  TrajectoryProjectionScope? scope,
  ValueChanged<TrajectoryRecord>? onRecordActivate,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: TrajectoryScreen(
        controller: controller,
        onClose: () {},
        loaded: true,
        scope: scope,
        onRecordActivate: onRecordActivate,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('AC11: a partial window renders the scope notice with counts', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(
      tester,
      controller,
      scope: const TrajectoryProjectionScope(
        above: 1200,
        below: 40,
        total: 2000,
      ),
    );

    expect(find.textContaining('Windowed projection'), findsOneWidget);
    // "760 of 2000 shown" — never a partial window presented as complete.
    expect(find.textContaining('760 of 2000'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('AC11: a complete window renders no scope notice', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(
      tester,
      controller,
      scope: const TrajectoryProjectionScope(above: 0, below: 0, total: 2000),
    );

    expect(find.textContaining('Windowed projection'), findsNothing);
    controller.dispose();
  });

  testWidgets('AC11: a null scope (full-open session) renders no notice', (
    tester,
  ) async {
    final controller = fixtureController();
    await _pump(tester, controller);

    expect(find.textContaining('Windowed projection'), findsNothing);
    controller.dispose();
  });

  testWidgets('AC6: the wide details pane jumps in chat by record id', (
    tester,
  ) async {
    final controller = fixtureController();
    final target = recordIds(controller, TrajectoryCellKind.tool).first;
    String? jumped;
    TrajectoryRecord? jumpedRecord;
    await _pump(
      tester,
      controller,
      onRecordActivate: (record) {
        jumpedRecord = record;
        jumped = record.recordId;
      },
    );

    controller.selectRecord(target);
    await tester.pump();
    await tester.tap(find.text('Jump in chat'));
    await tester.pump();

    expect(jumped, target);
    expect(jumpedRecord, isNotNull);
    controller.dispose();
  });
}
