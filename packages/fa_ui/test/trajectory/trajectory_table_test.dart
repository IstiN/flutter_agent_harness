// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

// ponytail: direct src imports — the fa_ui barrel still carries sibling
// phase 7/8 WIP that fails to compile; switch to the barrel once it lands.
import 'package:fa_ui/src/trajectory/trajectory_controller.dart';
import 'package:fa_ui/src/trajectory/trajectory_table.dart';
import 'package:fa_ui/src/trajectory/trajectory_turn.dart';

import 'fixture_table.dart';

Widget _host(TrajectoryController controller, {List<TrajectoryRecord>? taps}) =>
    MaterialApp(
      home: Scaffold(
        body: TrajectoryTable(controller: controller, onRecordTap: taps?.add),
      ),
    );

/// Plain text of every [Text] on screen (rich spans flattened).
List<String> _texts(WidgetTester tester) => [
  for (final widget in tester.widgetList<Text>(find.byType(Text)))
    widget.data ??
        (widget.textSpan != null ? widget.textSpan!.toPlainText() : ''),
];

void main() {
  group('structure', () {
    testWidgets('renders turn, group, and cell rows in section order', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final texts = _texts(tester);
      int at(String needle) => texts.indexWhere((t) => t.contains(needle));
      // Sections and their content, in display order.
      expect(at('Turn 1'), greaterThanOrEqualTo(0));
      expect(at('Between turns'), greaterThan(at('Deploy finished')));
      expect(at('Turn 2'), greaterThan(at('Between turns')));
      expect(at('Run the deployment'), greaterThan(at('Turn 1')));
      expect(at('Step 1'), greaterThan(at('Run the deployment')));
      expect(at('Deploying now'), greaterThan(at('Step 1')));
      expect(at('Step 2'), greaterThan(at('deployed')));
      expect(at('Deploy finished'), greaterThan(at('Step 2')));
      expect(
        at('Compacted the deployment work'),
        greaterThan(at('Between turns')),
      );
      expect(at('anthropic/claude-x'), greaterThan(at('Turn 2')));
      // Index is never shown.
      expect(at('#1'), -1);
      controller.dispose();
    });
  });

  group('per-kind cells', () {
    testWidgets('renders every kind pill for its row', (tester) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final texts = _texts(tester);
      for (final pill in ['USER', 'ASSISTANT', 'TOOL', 'COMPACTED', 'SYSTEM']) {
        expect(
          texts.where((t) => t == pill),
          isNotEmpty,
          reason: 'missing pill $pill',
        );
      }
      controller.dispose();
    });

    testWidgets('tool rows split name, args, and inline result', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final texts = _texts(tester).join('\n');
      expect(texts, contains('bash'));
      expect(texts, contains('→ deployed'));
      expect(texts, contains('→ boom'));
      controller.dispose();
    });

    testWidgets('failed tool rows show the failed state', (tester) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      expect(_texts(tester), contains('Failed'));
      controller.dispose();
    });

    testWidgets('unsettled tool rows show the pending state', (tester) async {
      final controller = runningToolController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      expect(_texts(tester), contains('Pending'));
      controller.dispose();
    });
  });

  group('search', () {
    testWidgets('filters to matches and recomputes separators', (tester) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.searchQuery = 'deployed';
      await tester.pumpAndSettle();

      final texts = _texts(tester).join('\n');
      expect(texts, contains('→ deployed'));
      expect(texts, contains('Turn 1'));
      // Non-matching records and now-empty sections disappear.
      expect(texts, isNot(contains('Run the deployment')));
      expect(texts, isNot(contains('Deploy finished')));
      expect(texts, isNot(contains('Turn 2')));
      expect(texts, isNot(contains('Between turns')));
      controller.dispose();
    });

    testWidgets('an empty result shows the no-matches state', (tester) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.searchQuery = 'zzznothing';
      await tester.pumpAndSettle();

      expect(_texts(tester), contains('No matches'));
      controller.dispose();
    });
  });

  group('collapse', () {
    testWidgets('a collapsed turn keeps its first row plus a summary', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.toggleTurn(1);
      await tester.pumpAndSettle();

      final texts = _texts(tester).join('\n');
      expect(texts, contains('2 steps · 2 tool calls'));
      expect(texts, contains('Run the deployment'));
      expect(texts, isNot(contains('Deploying now')));
      expect(texts, isNot(contains('Deploy finished')));
      expect(texts, isNot(contains('→ deployed')));
      controller.dispose();
    });

    testWidgets('a collapsed assistant replaces its tool run', (tester) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final assistantId = recordIds(
        controller,
        TrajectoryCellKind.message,
      ).first;
      controller.toggleAssistant(assistantId);
      await tester.pumpAndSettle();

      final texts = _texts(tester).join('\n');
      expect(texts, contains('2 tool calls · bash, read'));
      expect(texts, contains('Deploying now'));
      expect(texts, isNot(contains('→ deployed')));
      expect(texts, isNot(contains('→ boom')));
      controller.dispose();
    });

    testWidgets('tapping a summary row toggles the fold back open', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.toggleTurn(1);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('2 steps · 2 tool calls'));
      await tester.pumpAndSettle();

      expect(_texts(tester).join('\n'), contains('Deploy finished'));
      controller.dispose();
    });
  });

  group('selection', () {
    testWidgets('tapping a cell selects it and reports the record', (
      tester,
    ) async {
      final controller = tableFixtureController();
      final taps = <TrajectoryRecord>[];
      await tester.pumpWidget(_host(controller, taps: taps));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Deploy finished'));
      await tester.pumpAndSettle();

      final messageId = recordIds(controller, TrajectoryCellKind.message).last;
      expect(controller.selectedRecordId, messageId);
      expect(taps, hasLength(1));
      expect(taps.single.kind, TrajectoryCellKind.message);
      controller.dispose();
    });
  });

  group('virtualisation and tail-follow', () {
    testWidgets('a 120-record session builds lazily and scrolls to the end', (
      tester,
    ) async {
      final controller = TrajectoryController(
        initial: buildLargeFixtureSnapshot(turns: 40),
      );
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      // Only a window around the tail is built; the oldest turns are not
      // in the tree at all.
      expect(_texts(tester).join('\n'), isNot(contains('Turn 1 prompt')));
      expect(_texts(tester).join('\n'), contains('Turn 40 prompt'));

      await tester.drag(find.byType(TrajectoryTable), const Offset(0, 10000));
      await tester.pumpAndSettle();

      expect(_texts(tester).join('\n'), contains('Turn 1 prompt'));
      controller.dispose();
    });

    testWidgets('follows the tail while at the bottom', (tester) async {
      final controller = TrajectoryController(
        initial: buildLargeFixtureSnapshot(turns: 40),
      );
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.updateSnapshot(buildLargeFixtureSnapshot(turns: 45));
      await tester.pumpAndSettle();

      expect(
        controller.records.length,
        45 * 3,
        reason: 'fixture sanity: 3 records per turn',
      );
      expect(_texts(tester).join('\n'), contains('Turn 45 prompt'));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(position.pixels, position.maxScrollExtent);
      controller.dispose();
    });

    testWidgets('stops following once the user scrolls up', (tester) async {
      final controller = TrajectoryController(
        initial: buildLargeFixtureSnapshot(turns: 40),
      );
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(TrajectoryTable), const Offset(0, 300));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final detached = position.pixels;

      controller.updateSnapshot(buildLargeFixtureSnapshot(turns: 45));
      await tester.pumpAndSettle();

      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        detached,
      );
      controller.dispose();
    });
  });

  group('projection', () {
    test('projects headers, cells, and summaries without building widgets', () {
      final controller = tableFixtureController();
      controller.toggleAssistant(
        recordIds(controller, TrajectoryCellKind.message).first,
      );

      final rows = projectTrajectoryRows(controller);
      final kinds = [
        for (final row in rows)
          switch (row) {
            TrajectoryTurnHeaderRow() => 'turn',
            TrajectoryGroupHeaderRow() => 'group',
            TrajectoryCellRow() => 'cell',
            TrajectoryAssistantSummaryRow() => 'assistantSummary',
            TrajectoryTurnSummaryRow() => 'turnSummary',
          },
      ];
      expect(
        kinds,
        containsAllInOrder(['turn', 'group', 'cell', 'assistantSummary']),
      );
      expect(kinds.where((kind) => kind == 'assistantSummary'), hasLength(1));
      controller.dispose();
    });
  });
}
