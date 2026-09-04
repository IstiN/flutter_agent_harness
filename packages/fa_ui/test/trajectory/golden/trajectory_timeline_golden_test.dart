// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the trajectory timeline strip: the four
/// projections (sequence, duration, time, actual) with and without an
/// active drag selection — eight shots over the fixed two-turn timed
/// fixture (real wall-clock timings, one span-free idle gap). The
/// selection is a fixed mid-domain window in the active projection's
/// units, so every mode exercises its own geometry. See
/// `golden_test_setup.dart` for the font and determinism conventions.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixture_timeline.dart';
import 'golden_test_setup.dart';

void main() {
  // (name, actualDuration, actualTime) — the controller's mode switches.
  final modes = [
    ('sequence', false, false),
    ('duration', true, false),
    ('time', false, true),
    ('actual', true, true),
  ];

  for (final (name, actualDuration, actualTime) in modes) {
    for (final selected in [false, true]) {
      final file = 'timeline/${name}_${selected ? 'selected' : 'plain'}.png';
      testWidgets(file, (tester) async {
        final controller = timelineFixtureController()
          ..actualDuration = actualDuration
          ..actualTime = actualTime;
        if (selected) {
          final model = controller.timelineModel!;
          final width = model.end - model.start;
          controller.setTimelineSelection(
            TrajectoryTimeRange(
              start: model.start + width * 0.15,
              end: model.start + width * 0.55,
            ),
          );
        }
        await pumpGolden(tester, TrajectoryTimeline(controller: controller));
        await expectGolden(tester, file);
        controller.dispose();
      });
    }
  }
}
