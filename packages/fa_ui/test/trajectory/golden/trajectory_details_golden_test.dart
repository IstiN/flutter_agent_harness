// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the details bottom sheet: every tab of the rich
/// assistant (Summary, Diff, Preview, Raw, Timing), tool (Summary,
/// Payload, Result, Schema, Timing), user (Summary, Preview, …), system
/// (System Prompt, Tools), and compacted (Summary, Raw Output) fixtures —
/// the full tab set "as applicable" per record kind, driven through the
/// real [showTrajectoryDetails] sheet by tapping each tab. See
/// `golden_test_setup.dart` for the font and determinism conventions.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixture_details.dart';
import 'golden_test_setup.dart';

void main() {
  setUp(resetTrajectoryTabHistory);

  // (golden name, record) — one sheet per test, every tab captured.
  final sheets = [
    ('assistant', richAssistant),
    ('tool', settledTool),
    ('user', userPrompt),
    ('system', systemPrompt),
    ('compacted', compacted),
  ];

  for (final (name, record) in sheets) {
    testWidgets('details sheet tabs for $name', (tester) async {
      await pumpGolden(
        tester,
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showTrajectoryDetails(
                context,
                record: record,
                snapshot: snapshot,
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
        size: goldenSizeSheet,
      );

      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      final tabs = trajectoryDetailTabs(
        record,
        snapshot,
        const TrajectoryStringsEn(),
      );
      for (var i = 0; i < tabs.length; i++) {
        if (i > 0) {
          await tester.tap(find.text(tabs[i].label));
          await tester.pumpAndSettle();
        }
        await expectGolden(tester, 'details/${name}_${tabs[i].id}.png');
      }
    });
  }
}
