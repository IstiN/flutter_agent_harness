// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  group('snapshot pipeline', () {
    testWidgets('updateSnapshot applies after the debounce window', (
      tester,
    ) async {
      final controller = TrajectoryController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      final next = buildFixtureSnapshot();
      controller.updateSnapshot(next);
      expect(controller.snapshot, same(TrajectorySnapshot.empty));
      expect(notifications, 0);

      await tester.pump(controller.snapshotDebounce);
      expect(controller.snapshot, same(next));
      expect(controller.revision, next.revision);
      expect(notifications, 1);
      controller.dispose();
    });

    testWidgets('bursts coalesce into the latest snapshot', (tester) async {
      final controller = TrajectoryController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.updateSnapshot(buildFixtureSnapshot());
      final latest = buildFixtureSnapshot();
      controller.updateSnapshot(latest);
      await tester.pump(controller.snapshotDebounce);
      expect(controller.snapshot, same(latest));
      expect(notifications, 1);
      controller.dispose();
    });

    test('derives turns, records, and the timeline model', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      expect(controller.turns, hasLength(1));
      expect(controller.turns.single.turn, 1);
      expect(controller.records.map((record) => record.kind).toList(), [
        TrajectoryCellKind.user,
        TrajectoryCellKind.message,
        TrajectoryCellKind.tool,
        TrajectoryCellKind.message,
      ]);
      expect(controller.timelineModel, isNotNull);
      expect(controller.timelineModel!.spans, hasLength(4));
      expect(controller.timelineMode, TrajectoryTimelineMode.sequence);
    });
  });

  group('fold state', () {
    test('collapse-all targets the collapsible turns and assistants', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);
      final assistants = recordIds(controller, TrajectoryCellKind.message);
      expect(assistants, hasLength(2));

      controller.collapseAllTurns();
      expect(controller.collapsedTurns, {1});

      controller.collapseAllAssistants();
      // Only the assistant followed by its tool run folds; the trailing
      // message has no tool after it.
      expect(controller.collapsedAssistants, {assistants.first});

      controller.expandAllTurns();
      controller.expandAllAssistants();
      expect(controller.collapsedTurns, isEmpty);
      expect(controller.collapsedAssistants, isEmpty);
    });

    test('toggleTurn flips a single turn', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      controller.toggleTurn(1);
      expect(controller.collapsedTurns, {1});
      controller.toggleTurn(1);
      expect(controller.collapsedTurns, isEmpty);
    });

    test('toggleAssistant flips a single assistant run', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);
      final assistant = recordIds(controller, TrajectoryCellKind.message).first;

      controller.toggleAssistant(assistant);
      expect(controller.collapsedAssistants, {assistant});
      controller.toggleAssistant(assistant);
      expect(controller.collapsedAssistants, isEmpty);
    });
  });

  group('timeline mode and selection', () {
    test('the mode matrix follows the duration and time toggles', () {
      final controller = TrajectoryController();
      addTearDown(controller.dispose);

      expect(controller.timelineMode, TrajectoryTimelineMode.sequence);
      controller.actualDuration = true;
      expect(controller.timelineMode, TrajectoryTimelineMode.duration);
      controller.actualTime = true;
      expect(controller.timelineMode, TrajectoryTimelineMode.actual);
      controller.actualDuration = false;
      expect(controller.timelineMode, TrajectoryTimelineMode.time);
      controller.actualTime = false;
      expect(controller.timelineMode, TrajectoryTimelineMode.sequence);
      // Empty snapshot: no visible record, so no model.
      expect(controller.timelineModel, isNull);
    });

    test('toggling duration or time clears the timeline selection', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      controller.setTimelineSelection(
        const TrajectoryTimeRange(start: 0, end: 2),
      );
      controller.actualDuration = true;
      expect(controller.timelineSelection, isNull);

      controller.setTimelineSelection(
        const TrajectoryTimeRange(start: 0, end: 2),
      );
      controller.actualTime = true;
      expect(controller.timelineSelection, isNull);
    });

    test('focus indexes follow the selection in the active mode', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      expect(controller.timelineFocusIndexes, isEmpty);
      // Select a point at the first span's own start so exactly one span
      // (the first record's) can overlap it.
      final span = controller.timelineModel!.spans.first;
      controller.setTimelineSelection(
        TrajectoryTimeRange(start: span.start, end: span.start),
      );
      expect(controller.timelineFocusIndexes, {span.index});
      controller.setTimelineSelection(null);
      expect(controller.timelineFocusIndexes, isEmpty);
    });
  });

  group('record selection', () {
    test('selecting outside the focus set clears the timeline selection', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);
      final span = controller.timelineModel!.spans.first;
      final inside = controller.records[span.index - 1].recordId;
      final outside = controller.records.last.recordId;

      controller.setTimelineSelection(
        TrajectoryTimeRange(start: span.start, end: span.start),
      );
      controller.selectRecord(outside);
      expect(controller.selectedRecordId, outside);
      expect(controller.timelineSelection, isNull);

      controller.setTimelineSelection(
        TrajectoryTimeRange(start: span.start, end: span.start),
      );
      controller.selectRecord(inside);
      expect(controller.selectedRecordId, inside);
      expect(controller.timelineSelection, isNotNull);
    });

    test('selectRecord(null) only clears the record selection', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      controller.selectRecord(controller.records.first.recordId);
      controller.selectRecord(null);
      expect(controller.selectedRecordId, isNull);
    });
  });

  group('search and focus', () {
    test('matching, blank, and empty queries', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);
      final message = recordIds(controller, TrajectoryCellKind.message).first;

      controller.searchQuery = 'deploy';
      final matches = controller.searchMatchRecordIds;
      expect(matches, isNotNull);
      expect(matches, contains(message));
      expect(controller.searchMatchIndexes, isNotEmpty);

      controller.searchQuery = '';
      expect(controller.searchMatchRecordIds, isNull);
      expect(controller.searchMatchIndexes, isEmpty);

      controller.searchQuery = 'no-such-term';
      expect(controller.searchMatchRecordIds, isEmpty);
      expect(controller.searchMatchIndexes, isEmpty);
    });

    test('focusRecord hands its index to exactly one takeRecordFocus', () {
      final controller = TrajectoryController();
      addTearDown(controller.dispose);

      expect(controller.takeRecordFocus(), isNull);
      controller.focusRecord(3);
      expect(controller.takeRecordFocus(), 3);
      expect(controller.takeRecordFocus(), isNull);
    });
  });

  group('ledger filters', () {
    test('every chip on returns the layout unchanged', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);
      expect(controller.filters.length, TrajectoryLedgerFilter.values.length);
      final layout = [
        for (final turn in deriveTrajectoryLayout(buildFixtureSnapshot()))
          for (final group in turn.groups) ...group.cells,
      ];
      final display = [
        for (final turn in controller.turns)
          for (final group in turn.groups) ...group.cells,
      ];
      expect(
        [for (final cell in display) cell.recordId],
        [for (final cell in layout) cell.recordId],
      );
    });

    test('toggling a chip filters the display turns, not the records', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      controller.toggleFilter(TrajectoryLedgerFilter.messages);
      final cells = [
        for (final turn in controller.turns)
          for (final group in turn.groups) ...group.cells,
      ];
      expect(cells, hasLength(1));
      expect(cells.single.kind, TrajectoryCellKind.tool);
      // The underlying layout and record list stay complete.
      expect(controller.records, hasLength(4));
      expect(deriveTrajectoryLayout(buildFixtureSnapshot()).length,
          controller.turns.length);

      controller.toggleFilter(TrajectoryLedgerFilter.messages);
      expect(controller.filters.length, TrajectoryLedgerFilter.values.length);
    });

    test('the errors chip keeps failed rows visible across categories', () {
      final at = DateTime.utc(2026, 1, 1, 12);
      final builder = TrajectorySnapshotBuilder();
      builder
        ..append(
          MessageRecord(
            id: 'u1',
            parentId: null,
            timestamp: at,
            message: UserMessage.text('go'),
          ),
        )
        ..append(
          MessageRecord(
            id: 'a1',
            parentId: 'u1',
            timestamp: at,
            message: AssistantMessage(
              content: [
                const ToolCall(id: 'c1', name: 'bash', arguments: {}),
              ],
              api: 'anthropic-messages',
              provider: 'anthropic',
              model: 'claude-test',
              usage: const Usage(
                input: 10,
                output: 5,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 15,
                cost: UsageCost(),
              ),
              stopReason: StopReason.toolUse,
              timestamp: at,
            ),
          ),
        )
        ..append(
          MessageRecord(
            id: 'r1',
            parentId: 'a1',
            timestamp: at,
            message: ToolResultMessage(
              toolCallId: 'c1',
              toolName: 'bash',
              content: const [TextContent(text: 'boom')],
              isError: true,
              timestamp: at,
            ),
          ),
        );
      final controller = TrajectoryController(initial: builder.build());
      addTearDown(controller.dispose);
      expect(controller.records, hasLength(3));

      controller.toggleFilter(TrajectoryLedgerFilter.messages);
      controller.toggleFilter(TrajectoryLedgerFilter.tools);
      final cells = [
        for (final turn in controller.turns)
          for (final group in turn.groups) ...group.cells,
      ];
      // The failed tool result survives even with its category off.
      expect(cells, hasLength(1));
      expect(cells.single.kind, TrajectoryCellKind.tool);
    });
  });

  group('search match navigation', () {
    test('order, current index, and wrap-around stepping', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      expect(controller.currentMatchIndex, isNull);
      controller.searchQuery = 'deploy';
      final order = controller.searchMatchOrder;
      expect(order.length, greaterThanOrEqualTo(2));
      expect(controller.currentMatchIndex, 0);

      controller.nextSearchMatch();
      expect(controller.currentMatchIndex, 1);
      expect(controller.selectedRecordId, order[1]);

      controller.previousSearchMatch();
      expect(controller.currentMatchIndex, 0);
      expect(controller.selectedRecordId, order[0]);

      // Wraps both ways.
      controller.previousSearchMatch();
      expect(controller.currentMatchIndex, order.length - 1);
      controller.nextSearchMatch();
      expect(controller.currentMatchIndex, 0);
    });

    testWidgets('a snapshot change clamps the position into the new matches', (
      tester,
    ) async {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      controller.searchQuery = 'deploy';
      final count = controller.searchMatchOrder.length;
      for (var i = 0; i < count - 1; i++) {
        controller.nextSearchMatch();
      }
      expect(controller.currentMatchIndex, count - 1);

      // Re-applying the same snapshot keeps the index in range.
      controller.updateSnapshot(buildFixtureSnapshot());
      await tester.pump(const Duration(milliseconds: 100)); // debounce
      expect(controller.currentMatchIndex, isNotNull);
      expect(
        controller.currentMatchIndex,
        lessThan(controller.searchMatchOrder.length),
      );
      // Two throttled-index cycles re-arm the 3s window timer; pump past it.
      await tester.pump(const Duration(seconds: 7));
    });
  });

  group('session stats', () {
    test('rolls up turns, tokens, and start time from the snapshot', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);

      final stats = controller.stats;
      expect(stats.turnCount, 1);
      // Two assistant steps at 100 in / 20 out.
      expect(stats.inputTokens, 200);
      expect(stats.outputTokens, 40);
      // History-replayed records carry no request timing; the label only
      // appears for live event-captured requests.
      expect(stats.startedAt, isNull);
      // The fixture's spaced timestamps project real step durations.
      expect(stats.totalDuration, greaterThan(Duration.zero));
    });

    test('empty snapshots produce the zero stats', () {
      final controller = TrajectoryController();
      addTearDown(controller.dispose);
      expect(controller.stats.turnCount, 0);
      expect(controller.stats.totalDuration, Duration.zero);
      expect(controller.stats.inputTokens, 0);
      expect(controller.stats.outputTokens, 0);
      expect(controller.stats.startedAt, isNull);
    });
  });

  group('expanded rows', () {
    test('toggling flips exactly one id', () {
      final controller = fixtureController();
      addTearDown(controller.dispose);
      final id = controller.records.first.recordId;

      expect(controller.expandedRecordIds, isEmpty);
      controller.toggleExpandedRow(id);
      expect(controller.expandedRecordIds, {id});
      controller.toggleExpandedRow(id);
      expect(controller.expandedRecordIds, isEmpty);
    });
  });
}
