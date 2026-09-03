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
}
