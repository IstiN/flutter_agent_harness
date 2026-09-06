// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the trajectory controls' eight states: duration
/// projection on/off × fold state (everything expanded vs every turn and
/// assistant run collapsed) × search field empty vs filled. The search
/// field lives in [TrajectoryHeader] (full-screen shell), the duration and
/// fold buttons in [TrajectoryToolbar] (the ledger strip above it) — the
/// golden pumps both in shell order. State is set through the controller
/// (folds, duration) and the field itself (`enterText`), never by poking
/// private internals. See `golden_test_setup.dart` for the font and
/// determinism conventions.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixture.dart';
import 'golden_test_setup.dart';

void main() {
  for (final duration in [false, true]) {
    for (final collapsed in [false, true]) {
      for (final search in [false, true]) {
        final name =
            'toolbar/duration_${duration ? 'on' : 'off'}'
            '_folds_${collapsed ? 'collapsed' : 'open'}'
            '_search_${search ? 'filled' : 'empty'}';
        testWidgets(name, (tester) async {
          final controller = fixtureController();
          if (duration) controller.actualDuration = true;
          if (collapsed) {
            controller
              ..collapseAllTurns()
              ..collapseAllAssistants();
          }
          await pumpGolden(
            tester,
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TrajectoryHeader(controller: controller),
                TrajectoryToolbar(controller: controller),
              ],
            ),
          );
          if (search) {
            await tester.enterText(find.byType(TextField), 'deploy');
            await tester.pumpAndSettle();
          }
          await expectGolden(tester, '$name.png');
          controller.dispose();
        });
      }
    }
  }
}
