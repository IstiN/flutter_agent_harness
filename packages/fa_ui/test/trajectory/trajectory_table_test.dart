// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

// ponytail: direct src imports — the fa_ui barrel still carries sibling
// phase 7/8 WIP that fails to compile; switch to the barrel once it lands.
import 'package:fa_ui/src/theme/app_theme.dart';
import 'package:fa_ui/src/trajectory/trajectory_controller.dart';
import 'package:fa_ui/src/trajectory/trajectory_table.dart';
import 'package:fa_ui/src/trajectory/trajectory_cell.dart';
import 'package:fa_ui/src/trajectory/trajectory_cell_assistant.dart';
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
  group('expand', () {
    testWidgets('chevron toggles the row expanded with full content', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final toolId = recordIds(controller, TrajectoryCellKind.tool).first;
      // Collapsed by default: pretty-printed args are not rendered.
      expect(find.textContaining('"cmd": "deploy"'), findsNothing);
      await tester.tap(find.byIcon(Icons.expand_more).at(2));
      await tester.pumpAndSettle();

      expect(controller.expandedRecordIds, contains(toolId));
      expect(find.textContaining('"cmd": "deploy"'), findsOneWidget);
      expect(find.textContaining('deployed'), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.expand_more).at(2));
      await tester.pumpAndSettle();
      expect(controller.expandedRecordIds, isNot(contains(toolId)));
      expect(find.textContaining('"cmd": "deploy"'), findsNothing);
      controller.dispose();
    });

    testWidgets('an expanded assistant shows thinking and output', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.toggleExpandedRow(
        recordIds(controller, TrajectoryCellKind.message).first,
      );
      await tester.pumpAndSettle();

      final texts = _texts(tester).join('\n');
      expect(texts, contains('Deploying now'));
      controller.dispose();
    });
  });

  group('copy', () {
    testWidgets('the copy button puts the record JSON on the clipboard', (
      tester,
    ) async {
      final clipboard = <String>[];
      _mockClipboard(tester, clipboard);
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy).first);
      await tester.pump();

      expect(clipboard, hasLength(1));
      final json = jsonDecode(clipboard.single) as Map<String, dynamic>;
      expect(json['kind'], 'user');
      expect(json['text'], 'Run the deployment');
      controller.dispose();
    });

    testWidgets('on touch platforms the copy button is always visible', (
      tester,
    ) async {
      final clipboard = <String>[];
      _mockClipboard(tester, clipboard);
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      // Default test platform (android) — no hover needed.
      await tester.tap(find.byIcon(Icons.copy).at(1));
      await tester.pump();

      expect(clipboard, hasLength(1));
      final json = jsonDecode(clipboard.single) as Map<String, dynamic>;
      expect(json['kind'], 'message');
      controller.dispose();
    });
  });

  group('keyboard navigation', () {
    testWidgets('arrow keys move the selection while the feed has focus', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Run the deployment'));
      await tester.pumpAndSettle();
      final order = [
        for (final row in projectTrajectoryRows(controller))
          if (row is TrajectoryCellRow) row.record.recordId,
      ];
      expect(
        controller.selectedRecordId,
        recordIds(controller, TrajectoryCellKind.user).first,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.selectedRecordId, order[1]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(controller.selectedRecordId, order[0]);
      controller.dispose();
    });
  });

  group('search highlight', () {
    testWidgets('matches get a tint and the current match a stronger one', (
      tester,
    ) async {
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.searchQuery = 'de';
      await tester.pumpAndSettle();
      expect(controller.searchMatchOrder, isNotEmpty);
      expect(controller.currentMatchIndex, 0);

      final context = tester.element(find.textContaining('de').first);
      final teal = FahColors.of(context).teal;
      final current =
          (_rowBox(
                    tester,
                    find.textContaining('Run the deployment'),
                  ).decoration!
                  as BoxDecoration)
              .color!;
      expect(current, teal.withValues(alpha: 0.16));

      final other =
          (_rowBox(tester, find.textContaining('Deploying now')).decoration!
                  as BoxDecoration)
              .color!;
      expect(other, teal.withValues(alpha: 0.08));
      controller.dispose();
    });
  });

  group('subtool indent', () {
    testWidgets('a subtool row indents under its parent tool row', (
      tester,
    ) async {
      final controller = subtoolController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();
      final parent =
          _rowBox(tester, find.textContaining('bash')).padding as EdgeInsets;
      final child =
          _rowBox(tester, find.textContaining('grep')).padding as EdgeInsets;
      expect(child.left, parent.left + 24);
      controller.dispose();
    });
  });

  group('empty response', () {
    testWidgets('an empty assistant step says so instead of an em dash', (
      tester,
    ) async {
      final controller = emptyAssistantController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      expect(find.textContaining('Empty response'), findsOneWidget);
      expect(find.textContaining('—'), findsNothing);
      expect(find.textContaining('step 1'), findsOneWidget);
      controller.dispose();
    });
  });

  group('oversized result', () {
    testWidgets('a 1.5 MiB result stays collapsed with a byte label', (
      tester,
    ) async {
      final controller = bigResultController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.toggleExpandedRow(
        recordIds(controller, TrajectoryCellKind.tool).single,
      );
      await tester.pumpAndSettle();

      // The body is bounded: preview + byte-size expander, not the full
      // 1.5 MiB text.
      expect(find.textContaining('Show content ('), findsOneWidget);
      expect(find.textContaining('MiB'), findsOneWidget);
      expect(find.textContaining('END_OF_RESULT'), findsNothing);

      controller.dispose();
    });
  });

  group('selection copy', () {
    testWidgets('copying a selection across rows preserves newlines', (
      tester,
    ) async {
      final clipboard = <String>[];
      _mockClipboard(tester, clipboard);
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll(SelectionChangedCause.toolbar);
      await tester.pump();
      region.copySelection(SelectionChangedCause.toolbar);
      await tester.pump();

      final copied = clipboard.single;
      expect(copied, contains('\n'));
      expect(copied, contains('Run the deployment'));
      expect(copied, contains('Deploying now'));
      controller.dispose();
    });
  });

  group('keyboard copy (AC4)', () {
    testWidgets('ctrl+C sends the selection to the clipboard', (tester) async {
      final clipboard = <String>[];
      _mockClipboard(tester, clipboard);
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final regionFocus = tester
          .widgetList<Focus>(
            find.descendant(
              of: find.byType(SelectableRegion),
              matching: find.byWidgetPredicate(
                (widget) => widget is Focus && widget.focusNode != null,
              ),
            ),
          )
          .first;
      regionFocus.focusNode!.requestFocus();
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.toolbar);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(clipboard, hasLength(1));
      expect(clipboard.single, contains('Run the deployment'));
      controller.dispose();
    });

    // Runs only on the macOS platform variant (meta-style shortcut).
    testWidgets('cmd+C sends the selection to the clipboard on macOS', (
      tester,
    ) async {
      final clipboard = <String>[];
      _mockClipboard(tester, clipboard);
      final controller = tableFixtureController();
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final regionFocus = tester
          .widgetList<Focus>(
            find.descendant(
              of: find.byType(SelectableRegion),
              matching: find.byWidgetPredicate(
                (widget) => widget is Focus && widget.focusNode != null,
              ),
            ),
          )
          .first;
      regionFocus.focusNode!.requestFocus();
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.toolbar);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(clipboard, hasLength(1));
      expect(clipboard.single, contains('Run the deployment'));
      controller.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('timeline focus reveal (P2-1)', () {
    testWidgets('focusRecord scrolls the record row into view', (tester) async {
      final controller = TrajectoryController(
        initial: buildLargeFixtureSnapshot(turns: 40),
      );
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      // Near the tail (the exact offset lags the growing extent).
      expect(position.pixels, greaterThan(position.maxScrollExtent - 1000));
      // The timeline tap handler marks record 1 the same way.
      controller.selectRecord(
        recordIds(controller, TrajectoryCellKind.user).first,
      );
      controller.focusRecord(1);
      await tester.pumpAndSettle();

      expect(find.textContaining('Turn 1 prompt'), findsOneWidget);
      final viewport = tester.getRect(find.byType(TrajectoryTable));
      final row = tester.getRect(find.textContaining('Turn 1 prompt'));
      expect(row.top, greaterThanOrEqualTo(viewport.top));
      expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
      final revealed = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(revealed.pixels, lessThan(revealed.maxScrollExtent));
      controller.dispose();
    });
  });

  group('layout robustness (E9)', () {
    testWidgets('RTL rows with unbroken strings and emoji pump clean', (
      tester,
    ) async {
      final controller = overflowProbeController();
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: SizedBox(
                width: 600,
                child: TrajectoryTable(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The expanded unbroken body stays soft-wrapped too.
      controller.toggleExpandedRow(
        recordIds(controller, TrajectoryCellKind.tool).single,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      controller.dispose();
    });
  });

  group('long-session virtualisation (E5)', () {
    testWidgets(
      'a 2400-record long session stays virtualised while scrolling',
      (tester) async {
        // Issue #283: was 3500 turns (10.5k records, ~220s locally / ~8.5 min
        // in CI — 85% of the whole fa_ui suite, unshardable below file
        // granularity). 800 turns = 2400 records still dwarfs the <400-row
        // window asserted below, so the virtualisation guarantee (bounded
        // window, no exceptions, correct content at the extremes) is fully
        // preserved while the scroll simulation costs ~4x less.
        final controller = TrajectoryController(
          initial: buildLargeFixtureSnapshot(turns: 800),
        );
        await tester.pumpWidget(_host(controller));
        await tester.pumpAndSettle();

        int builtRowTexts() => tester
            .widgetList<TrajectoryRowText>(find.byType(TrajectoryRowText))
            .length;
        final table = find.byType(TrajectoryTable);

        // At the tail: a bounded window, not 2400 rows.
        expect(builtRowTexts(), lessThan(400));
        expect(tester.takeException(), isNull);

        // Scroll to the middle and back to the very top. The 45k px drag
        // lands mid-list for a 2400-record session: neither the last turn's
        // nor the first turn's prompt may be on screen there.
        await tester.drag(table, const Offset(0, 45000));
        await tester.pumpAndSettle();
        expect(builtRowTexts(), lessThan(400));
        expect(tester.takeException(), isNull);
        expect(_texts(tester).join('\n'), isNot(contains('Turn 800 prompt')));
        expect(_texts(tester).join('\n'), isNot(contains('Turn 1 prompt')));

        await tester.drag(table, const Offset(0, 1000000));
        await tester.pumpAndSettle();
        expect(builtRowTexts(), lessThan(400));
        expect(tester.takeException(), isNull);
        expect(_texts(tester).join('\n'), contains('Turn 1 prompt'));
        controller.dispose();
      },
    );
  });

  group('expanded text (trajectoryExpandedText)', () {
    test('user and context rows expand to their full text', () {
      const user = TrajectoryUserRecord(
        index: 1,
        recordId: 'u1',
        text: 'full prompt',
        opensTurn: true,
      );
      const context = TrajectoryContextRecord(
        index: 2,
        recordId: 'c1',
        text: 'injected context',
      );
      expect(trajectoryExpandedText(user), 'full prompt');
      expect(trajectoryExpandedText(context), 'injected context');
    });

    test('assistant rows join the non-empty thinking and output sections', () {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        thinkingDetail: 'pondering',
        outputDetail: 'the answer',
        displayText: 'fallback',
      );
      expect(trajectoryExpandedText(record), 'pondering\n\nthe answer');
    });

    test('assistant rows fall back to the display text without sections', () {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        displayText: 'plain display',
      );
      expect(trajectoryExpandedText(record), 'plain display');
    });

    test('tool rows pretty-print the args and append the result', () {
      const record = TrajectoryToolRecord(
        index: 1,
        recordId: 't1',
        callId: 'call1',
        parentCallId: null,
        name: 'read',
        argsRaw: '{"path":"a.md"}',
        result: 'file body',
      );
      expect(
        trajectoryExpandedText(record),
        'read({\n  "path": "a.md"\n})\n\n'
        'file body',
      );
    });

    test('tool rows keep unparsable args verbatim and skip empty parts', () {
      const unparsable = TrajectoryToolRecord(
        index: 1,
        recordId: 't1',
        callId: 'call1',
        parentCallId: null,
        name: 'bash',
        argsRaw: 'not json at all',
        result: 'exit 0',
      );
      expect(
        trajectoryExpandedText(unparsable),
        'bash(not json at all)\n\nexit 0',
      );

      const emptyArgs = TrajectoryToolRecord(
        index: 2,
        recordId: 't2',
        callId: 'call2',
        parentCallId: null,
        name: 'list',
        argsRaw: '',
        result: 'nothing here',
      );
      expect(trajectoryExpandedText(emptyArgs), 'nothing here');

      const emptyResult = TrajectoryToolRecord(
        index: 3,
        recordId: 't3',
        callId: 'call3',
        parentCallId: null,
        name: 'write',
        argsRaw: '[]',
      );
      expect(trajectoryExpandedText(emptyResult), 'write([])');
    });

    test('compacted rows prefer the summary and fall back to the text', () {
      const withSummary = TrajectoryCompactedRecord(
        index: 1,
        recordId: 'k1',
        text: 'preview',
        summary: 'full summary',
      );
      const withoutSummary = TrajectoryCompactedRecord(
        index: 2,
        recordId: 'k2',
        text: 'only text',
        summary: '',
      );
      expect(trajectoryExpandedText(withSummary), 'full summary');
      expect(trajectoryExpandedText(withoutSummary), 'only text');
    });

    test('system rows prefer a non-empty detail and fall back to the text', () {
      const withDetail = TrajectorySystemRecord(
        index: 1,
        recordId: 's1',
        text: 'model changed',
        change: TrajectorySystemChange.modelChange,
        detail: 'claude-test → gpt-test',
      );
      const emptyDetail = TrajectorySystemRecord(
        index: 2,
        recordId: 's2',
        text: 'turn ended',
        change: TrajectorySystemChange.turnEnd,
      );
      const blankDetail = TrajectorySystemRecord(
        index: 3,
        recordId: 's3',
        text: 'turn ended',
        change: TrajectorySystemChange.turnEnd,
        detail: '',
      );
      expect(trajectoryExpandedText(withDetail), 'claude-test → gpt-test');
      expect(trajectoryExpandedText(emptyDetail), 'turn ended');
      expect(trajectoryExpandedText(blankDetail), 'turn ended');
    });
  });

  group('record json (trajectoryRecordJson)', () {
    test('every kind carries the shared identity plus per-kind fields', () {
      final started = DateTime.utc(2026, 1, 1, 12);
      final json = trajectoryRecordJson(
        const TrajectoryAssistantRecord(
          index: 4,
          recordId: 'm1',
          messageId: 'msg1',
          turn: 2,
          step: 1,
          provider: 'anthropic',
          model: 'claude-test',
          thinkingDetail: 'pondering',
          outputDetail: 'the answer',
          timeSeconds: Duration(seconds: 3),
          isError: false,
          requestOnly: false,
          displayText: 'the answer',
        ),
      );
      expect(json['kind'], 'message');
      expect(json['index'], 4);
      expect(json['recordId'], 'm1');
      // identityJson() entries ride along.
      expect(json['messageId'], 'msg1');
      expect(json['turn'], 2);
      expect(json['step'], 1);
      expect(json['provider'], 'anthropic');
      expect(json['model'], 'claude-test');
      expect(json['usage'], isNull);
      expect(json['thinkingDetail'], 'pondering');
      expect(json['outputDetail'], 'the answer');
      expect(json['timeSeconds'], 3000);
      expect(json['isError'], false);
      expect(json['errorCode'], isNull);
      expect(json['errorMessage'], isNull);
      expect(json['requestOnly'], false);
      expect(json['displayText'], 'the answer');
      expect(json['requestDetail'], isNull);

      final tool = trajectoryRecordJson(
        TrajectoryToolRecord(
          index: 5,
          recordId: 't1',
          callId: 'call1',
          parentCallId: null,
          name: 'read',
          argsRaw: '{"path":"a.md"}',
          result: 'file body',
          isError: false,
          timeSeconds: const Duration(milliseconds: 1500),
          startedAt: started,
        ),
      );
      expect(tool['kind'], 'tool');
      expect(tool['callId'], 'call1');
      expect(tool['parentCallId'], isNull);
      expect(tool['name'], 'read');
      expect(tool['argsRaw'], '{"path":"a.md"}');
      expect(tool['result'], 'file body');
      expect(tool['isError'], false);
      expect(tool['timeSeconds'], 1500);
      expect(tool['startedAt'], '2026-01-01T12:00:00.000Z');

      final user = trajectoryRecordJson(
        const TrajectoryUserRecord(
          index: 1,
          recordId: 'u1',
          text: 'full prompt',
          previewMarkdown: 'full prompt',
          opensTurn: true,
          inputDetail: 'req markdown',
          startedAt: null,
        ),
      );
      expect(user['kind'], 'user');
      expect(user['text'], 'full prompt');
      expect(user['previewMarkdown'], 'full prompt');
      expect(user['opensTurn'], true);
      expect(user['inputDetail'], 'req markdown');
      expect(user['startedAt'], isNull);

      final context = trajectoryRecordJson(
        const TrajectoryContextRecord(
          index: 2,
          recordId: 'c1',
          text: 'injected context',
          previewMarkdown: 'injected',
        ),
      );
      expect(context['kind'], 'context');
      expect(context['text'], 'injected context');
      expect(context['previewMarkdown'], 'injected');
      expect(context['startedAt'], isNull);

      final compacted = trajectoryRecordJson(
        const TrajectoryCompactedRecord(
          index: 3,
          recordId: 'k1',
          text: 'preview',
          summary: 'full summary',
          firstKeptEntryId: 'm9',
          timeSeconds: Duration(seconds: 12),
          interrupted: true,
        ),
      );
      expect(compacted['kind'], 'compacted');
      expect(compacted['summary'], 'full summary');
      expect(compacted['firstKeptEntryId'], 'm9');
      expect(compacted['timeSeconds'], 12000);
      expect(compacted['interrupted'], true);

      final system = trajectoryRecordJson(
        TrajectorySystemRecord(
          index: 6,
          recordId: 's1',
          text: 'model changed',
          change: TrajectorySystemChange.modelChange,
          detail: 'claude-test → gpt-test',
          time: started,
          errorCode: 'E1',
          errorMessage: 'boom',
        ),
      );
      expect(system['kind'], 'system');
      expect(system['change'], 'modelChange');
      expect(system['detail'], 'claude-test → gpt-test');
      expect(system['time'], '2026-01-01T12:00:00.000Z');
      expect(system['errorCode'], 'E1');
      expect(system['errorMessage'], 'boom');
    });
  });

  group('assistant cell (TrajectoryCellAssistant)', () {
    Widget host(TrajectoryAssistantRecord record) => MaterialApp(
      home: Scaffold(body: TrajectoryCellAssistant(record: record)),
    );

    testWidgets('a failed step shows the error message as title and meta', (
      tester,
    ) async {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        isError: true,
        errorMessage: 'rate limited',
        timeSeconds: Duration(milliseconds: 2500),
      );
      await tester.pumpWidget(host(record));

      // Title segment and the trailing meta segment both render it
      // (row texts carry a trailing selectable-terminating newline).
      expect(find.textContaining('rate limited'), findsNWidgets(2));
      expect(find.textContaining('step 1 · 2.5s'), findsOneWidget);
    });

    testWidgets('an error message equal to the display stays title-only', (
      tester,
    ) async {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        isError: true,
        errorMessage: 'rate limited',
        outputDetail: 'rate limited',
      );
      await tester.pumpWidget(host(record));

      expect(find.textContaining('rate limited'), findsOneWidget);
    });

    testWidgets('a request-only step renders the no-content placeholder', (
      tester,
    ) async {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        requestOnly: true,
      );
      await tester.pumpWidget(host(record));

      expect(find.textContaining('No content'), findsOneWidget);
      expect(find.text('step 1\n'), findsOneWidget);
    });

    testWidgets('meta sums input and output tokens without a total', (
      tester,
    ) async {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        outputDetail: 'answer',
        inputTokens: 100,
        outputTokens: 20,
      );
      await tester.pumpWidget(host(record));

      expect(find.textContaining('120 tok'), findsOneWidget);
    });

    testWidgets('meta omits the token segment when nothing was reported', (
      tester,
    ) async {
      const record = TrajectoryAssistantRecord(
        index: 1,
        recordId: 'm1',
        messageId: 'msg1',
        turn: 1,
        step: 1,
        outputDetail: 'answer',
      );
      await tester.pumpWidget(host(record));

      expect(find.text('step 1\n'), findsOneWidget);
      expect(find.textContaining('tok'), findsNothing);
    });
  });
}

/// Installs a clipboard mock capturing `Clipboard.setData` payloads.
void _mockClipboard(WidgetTester tester, List<String> sink) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (message) async {
      if (message.method == 'Clipboard.setData') {
        sink.add((message.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

/// The feed-row Container nearest [text] (first ancestor Container).
Container _rowBox(WidgetTester tester, Finder text) => tester.widget<Container>(
  find.ancestor(of: text, matching: find.byType(Container)).first,
);
