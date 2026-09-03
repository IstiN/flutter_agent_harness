// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math' as math;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'fixture_timeline.dart';

/// Pump surface: the timeline sits at the origin, 44px gutter + 600px
/// track (100px per sequence slot).
Future<void> _pump(WidgetTester tester, TrajectoryController controller) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: trajectoryTimelineLabelGutter + 600,
              height: 50,
              child: TrajectoryTimeline(controller: controller),
            ),
          ),
        ),
      ),
    );

TrajectoryTimelinePainter _painterOf(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((painter) => painter.painter)
    .whereType<TrajectoryTimelinePainter>()
    .single;

void main() {
  // -- Geometry helpers ---------------------------------------------------

  group('geometry', () {
    const viewport = TrajectoryTimelineViewport(start: 0, duration: 6);

    test('sequence span rects follow lane, gutter, and slot width', () {
      final model = TrajectoryTimelineModel(
        start: 0,
        end: 6,
        spans: [
          const TrajectoryTimelineSpan(
            start: 0,
            end: 1,
            index: 1,
            isError: false,
            kind: TrajectoryCellKind.user,
            label: 'u',
            lane: 0,
          ),
          const TrajectoryTimelineSpan(
            start: 2,
            end: 3,
            index: 3,
            isError: false,
            kind: TrajectoryCellKind.tool,
            label: 't',
            lane: 2,
          ),
        ],
        turnBoundaries: const [],
      );
      final user = trajectoryTimelineSpanRect(
        model.spans[0],
        viewport: viewport,
        mode: TrajectoryTimelineMode.sequence,
        trackWidth: 600,
      );
      expect(user, const Rect.fromLTWH(44, 0, 100, 8));
      final tool = trajectoryTimelineSpanRect(
        model.spans[1],
        viewport: viewport,
        mode: TrajectoryTimelineMode.sequence,
        trackWidth: 600,
      );
      expect(tool, const Rect.fromLTWH(244, 28, 100, 8));
    });

    test('narrow and zero-width spans clamp to minimum widths', () {
      const span = TrajectoryTimelineSpan(
        start: 1,
        end: 1.01,
        index: 2,
        isError: false,
        kind: TrajectoryCellKind.message,
        label: 'm',
        lane: 1,
      );
      const zero = TrajectoryTimelineSpan(
        start: 1,
        end: 1,
        index: 2,
        isError: false,
        kind: TrajectoryCellKind.message,
        label: 'm',
        lane: 1,
      );
      // 1 domain unit = 50px, so 0.01 units = 0.5px → clamped to 2px.
      expect(
        trajectoryTimelineSpanRect(
          span,
          viewport: viewport,
          mode: TrajectoryTimelineMode.duration,
          trackWidth: 600,
        ).width,
        trajectoryTimelineMinimumSpanPx,
      );
      expect(
        trajectoryTimelineSpanRect(
          zero,
          viewport: viewport,
          mode: TrajectoryTimelineMode.duration,
          trackWidth: 600,
        ).width,
        trajectoryTimelineMinimumSpanPx,
      );
      // `time` mode renders zero-width spans at the fixed 8px marker width.
      expect(
        trajectoryTimelineSpanRect(
          zero,
          viewport: viewport,
          mode: TrajectoryTimelineMode.time,
          trackWidth: 600,
        ).width,
        trajectoryTimelineTimeSpanPx,
      );
    });

    test('viewport round-trips px and domain', () {
      expect(viewport.toPx(3, 600), 300);
      expect(viewport.toDomain(300, 600), 3);
      expect(viewport.toPx(9, 600), 900);
    });

    test('zoom anchors at the cursor and clamps to the minimum', () {
      final model = TrajectoryTimelineModel(
        start: 0,
        end: 6,
        spans: const [],
        turnBoundaries: const [],
      );
      final zoomed = trajectoryTimelineZoomed(
        viewport: viewport,
        anchorPx: 300,
        deltaY: -120,
        trackWidth: 600,
        model: model,
        mode: TrajectoryTimelineMode.sequence,
      )!;
      expect(zoomed.duration, closeTo(6 * math.exp(-0.18), 0.001));
      expect(zoomed.toDomain(300, 600), closeTo(3, 0.001));
      // Huge zoom-in clamps to the 4-slot minimum.
      final minimum = trajectoryTimelineZoomed(
        viewport: viewport,
        anchorPx: 300,
        deltaY: -1000000,
        trackWidth: 600,
        model: model,
        mode: TrajectoryTimelineMode.sequence,
      )!;
      expect(minimum.duration, 4);
      expect(minimum.start, 1);
      // Zooming out past 99.9% of the full domain resets to full (null).
      expect(
        trajectoryTimelineZoomed(
          viewport: viewport,
          anchorPx: 300,
          deltaY: 10,
          trackWidth: 600,
          model: model,
          mode: TrajectoryTimelineMode.sequence,
        ),
        isNull,
      );
    });

    test('pan shifts the window and clamps to the domain', () {
      final model = TrajectoryTimelineModel(
        start: 0,
        end: 6,
        spans: const [],
        turnBoundaries: const [],
      );
      const zoomed = TrajectoryTimelineViewport(start: 1, duration: 4);
      // -50px pans right by a third of the 4-unit window.
      expect(
        trajectoryTimelinePanned(
          viewport: zoomed,
          dxPx: -50,
          trackWidth: 600,
          model: model,
          mode: TrajectoryTimelineMode.sequence,
        ).start,
        closeTo(1 + 1 / 3, 0.001),
      );
      // Panning past either edge clamps at the domain.
      expect(
        trajectoryTimelinePanned(
          viewport: zoomed,
          dxPx: 100000,
          trackWidth: 600,
          model: model,
          mode: TrajectoryTimelineMode.sequence,
        ).start,
        0,
      );
      expect(
        trajectoryTimelinePanned(
          viewport: zoomed,
          dxPx: -100000,
          trackWidth: 600,
          model: model,
          mode: TrajectoryTimelineMode.sequence,
        ).start,
        2,
      );
    });

    test('degenerate zero-width domains stay finite', () {
      final model = TrajectoryTimelineModel(
        start: 1767268800000,
        end: 1767268800000,
        spans: const [
          TrajectoryTimelineSpan(
            start: 1767268800000,
            end: 1767268800000,
            index: 1,
            isError: false,
            kind: TrajectoryCellKind.user,
            label: 'u',
            lane: 0,
          ),
        ],
        turnBoundaries: const [],
      );
      final viewport = TrajectoryTimelineViewport.full(model);
      expect(viewport.duration, greaterThan(0));
      final rect = trajectoryTimelineSpanRect(
        model.spans.single,
        viewport: viewport,
        mode: TrajectoryTimelineMode.duration,
        trackWidth: 600,
      );
      expect(rect.width, trajectoryTimelineMinimumSpanPx);
      expect(rect.left.isFinite, isTrue);
    });
  });

  group('assistant TTFT fraction', () {
    final base = DateTime.utc(2026, 1, 1, 12);

    TrajectoryAssistantRecord assistant({
      DateTime? start,
      DateTime? first,
      DateTime? completed,
    }) => TrajectoryAssistantRecord(
      index: 1,
      recordId: 'a',
      messageId: 'm',
      turn: 1,
      step: 1,
      stepStartTime: start,
      firstTokenTime: first,
      completedTime: completed,
    );

    test('valid timing yields ttft / (ttft + decoding)', () {
      expect(
        trajectoryTimelineTtftFraction(
          assistant(
            start: base,
            first: base.add(const Duration(milliseconds: 250)),
            completed: base.add(const Duration(milliseconds: 1250)),
          ),
        ),
        closeTo(0.2, 0.0001),
      );
    });

    test('missing or inconsistent timing is invalid', () {
      expect(trajectoryTimelineTtftFraction(assistant()), isNull);
      expect(
        trajectoryTimelineTtftFraction(
          assistant(
            start: base,
            first: base.subtract(const Duration(milliseconds: 1)),
            completed: base,
          ),
        ),
        isNull,
      );
      expect(
        trajectoryTimelineTtftFraction(
          assistant(
            start: base,
            first: base,
            completed: base.subtract(const Duration(milliseconds: 1)),
          ),
        ),
        isNull,
      );
    });

    test('non-assistant records never split', () {
      expect(
        trajectoryTimelineTtftFraction(
          const TrajectoryUserRecord(
            index: 1,
            recordId: 'u',
            text: 'hi',
            opensTurn: true,
          ),
        ),
        isNull,
      );
    });
  });

  group('painter shouldRepaint', () {
    final model = TrajectoryTimelineModel(
      start: 0,
      end: 3,
      spans: [
        const TrajectoryTimelineSpan(
          start: 0,
          end: 1,
          index: 1,
          isError: false,
          kind: TrajectoryCellKind.user,
          label: 'u',
          lane: 0,
        ),
      ],
      turnBoundaries: const [],
    );
    const labels = ['Input', 'Model', 'Tools'];

    TrajectoryTimelinePainter painter({
      int? hoverIndex,
      TrajectoryTimelineViewport? viewport,
      TrajectoryTimeRange? selection,
      Set<int>? searchMatches,
      TrajectoryTimelineModel? withModel,
    }) => TrajectoryTimelinePainter(
      model: withModel ?? model,
      records: const [],
      mode: TrajectoryTimelineMode.sequence,
      colors: FahColors.dark,
      laneLabels: labels,
      hoverIndex: hoverIndex,
      viewport: viewport,
      selection: selection,
      searchMatches: searchMatches,
    );

    test('identical state does not repaint', () {
      expect(painter().shouldRepaint(painter()), isFalse);
    });

    test('every keyed state change repaints', () {
      final base = painter();
      expect(base.shouldRepaint(painter(hoverIndex: 1)), isTrue);
      expect(
        base.shouldRepaint(
          painter(
            viewport: const TrajectoryTimelineViewport(start: 0, duration: 2),
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          painter(selection: const TrajectoryTimeRange(start: 0, end: 1)),
        ),
        isTrue,
      );
      expect(base.shouldRepaint(painter(searchMatches: const {1})), isTrue);
      expect(
        base.shouldRepaint(
          painter(
            withModel: TrajectoryTimelineModel(
              start: 0,
              end: 3,
              spans: model.spans,
              turnBoundaries: model.turnBoundaries,
            ),
          ),
        ),
        isTrue,
      );
    });
  });

  // -- Widget behavior ----------------------------------------------------

  testWidgets('renders a placeholder without a timeline model', (tester) async {
    final controller = TrajectoryController();
    await _pump(tester, controller);
    expect(find.text('No timing data'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('renders every record span and lane labels', (tester) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);
    final painter = _painterOf(tester);
    expect(painter.model.spans, hasLength(6));
    expect(painter.model.turnBoundaries.map((boundary) => boundary.time), [
      0,
      4,
    ]);
    expect(painter.laneLabels, ['Input', 'Model', 'Tools']);
    expect(painter.viewport, isNull);
    expect(painter.selection, isNull);
    controller.dispose();
  });

  testWidgets('drag-select commits the drafted range', (tester) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);

    final gesture = await tester.startGesture(const Offset(144, 20));
    await gesture.moveBy(const Offset(150, 0));
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);

    final selection = controller.timelineSelection!;
    expect(selection.start, closeTo(1, 0.001));
    expect(selection.end, closeTo(2.5, 0.001));
    // Inclusive overlap: slot [0, 1] touches the selection at 1.
    expect(controller.timelineFocusIndexes, {1, 2, 3});
    controller.dispose();
  });

  testWidgets('a drag narrower than one slot centers on its midpoint', (
    tester,
  ) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);

    final gesture = await tester.startGesture(const Offset(144, 20));
    await gesture.moveBy(const Offset(10, 0)); // 0.1 slots < 1 slot minimum
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);

    final selection = controller.timelineSelection!;
    expect(selection.end - selection.start, closeTo(1, 0.001));
    expect((selection.start + selection.end) / 2, closeTo(1.05, 0.001));
    controller.dispose();
  });

  testWidgets('clicking a span selects its record and clears the range', (
    tester,
  ) async {
    final controller = timelineFixtureController();
    controller.setTimelineSelection(
      const TrajectoryTimeRange(start: 0, end: 6),
    );
    await _pump(tester, controller);

    // x=194 → domain 1.5 → span slot [1, 2) = record index 2.
    final gesture = await tester.startGesture(const Offset(194, 20));
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);

    expect(controller.selectedRecordId, controller.records[1].recordId);
    expect(controller.timelineSelection, isNull);
    expect(controller.takeRecordFocus(), 2);
    expect(controller.takeRecordFocus(), isNull);
    controller.dispose();
  });

  testWidgets('clicking whitespace commits the minimum selection and '
      'focuses the nearest span', (tester) async {
    final controller = timelineFixtureController()
      ..actualDuration = true
      ..actualTime = true;
    await _pump(tester, controller);
    // Core anchors only user rows from plain message records, so the
    // timed model holds two zero-width spans at 0s and 10s; the gap
    // between them is span-free. x=344 → 5s.
    expect(_painterOf(tester).model.spans, hasLength(2));

    // Hovering the gap first paints the guide line.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(344, 20));
    await mouse.moveTo(const Offset(344.5, 20));
    await tester.pump();
    expect(_painterOf(tester).guideX, isNotNull);
    expect(_painterOf(tester).hoverIndex, isNull);
    await mouse.removePointer();

    final gesture = await tester.startGesture(const Offset(344, 20));
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);

    final selection = controller.timelineSelection!;
    // Minimum selection = full domain / span count = 10s / 2.
    const minimum = 5000.0;
    final model = controller.timelineModel!;
    expect(selection.end - selection.start, closeTo(minimum, 0.01));
    expect(selection.start - model.start, closeTo(5000 - minimum / 2, 0.01));
    // 5s is equidistant from both spans; the earlier span wins.
    expect(controller.takeRecordFocus(), 1);
    controller.dispose();
  });

  testWidgets('wheel zoom anchors at the cursor, clamps, and resets', (
    tester,
  ) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);

    Future<void> scroll(double dy) => tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(344, 20),
        scrollDelta: Offset(0, dy),
      ),
    );

    await scroll(-120);
    await tester.pump();
    var viewport = _painterOf(tester).viewport!;
    expect(viewport.duration, closeTo(6 * math.exp(-0.18), 0.001));
    expect(viewport.toDomain(300, 600), closeTo(3, 0.001));

    await scroll(-1000000);
    await tester.pump();
    viewport = _painterOf(tester).viewport!;
    expect(viewport.duration, 4);
    expect(viewport.start, 1);

    await scroll(1000000);
    await tester.pump();
    expect(_painterOf(tester).viewport, isNull);
    controller.dispose();
  });

  testWidgets('right-click without a pan clears the selection', (tester) async {
    final controller = timelineFixtureController()
      ..setTimelineSelection(const TrajectoryTimeRange(start: 1, end: 3));
    await _pump(tester, controller);

    final gesture = await tester.startGesture(
      const Offset(300, 20),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);
    expect(controller.timelineSelection, isNull);
    controller.dispose();
  });

  testWidgets('right-drag pans while zoomed', (tester) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(344, 20),
        scrollDelta: const Offset(0, -1000000),
      ),
    );
    await tester.pump();
    expect(_painterOf(tester).viewport!.start, 1);

    final gesture = await tester.startGesture(
      const Offset(300, 20),
      buttons: kSecondaryButton,
    );
    // -300px pans right by half the 4-unit window.
    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pump();
    // -300px pans right past the domain edge; clamps at start 2.
    expect(_painterOf(tester).viewport!.start, closeTo(2, 0.001));
    expect(controller.timelineSelection, isNull);
    controller.dispose();
  });

  testWidgets('double-click clears the selection', (tester) async {
    final controller = timelineFixtureController()
      ..setTimelineSelection(const TrajectoryTimeRange(start: 1, end: 3));
    await _pump(tester, controller);

    await tester.tap(find.byType(TrajectoryTimeline));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byType(TrajectoryTimeline));
    await tester.pump(kDoubleTapTimeout);
    expect(controller.timelineSelection, isNull);
    controller.dispose();
  });

  testWidgets('escape clears the selection', (tester) async {
    final controller = timelineFixtureController()
      ..setTimelineSelection(const TrajectoryTimeRange(start: 1, end: 3));
    await _pump(tester, controller);

    final state = tester.state(find.byType(TrajectoryTimeline));
    (state as dynamic).focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(controller.timelineSelection, isNull);
    controller.dispose();
  });

  testWidgets('search dims non-matching spans', (tester) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);
    expect(_painterOf(tester).searchMatches, isNull);

    controller.searchQuery = 'deploy';
    await tester.pump();
    final matches = _painterOf(tester).searchMatches!;
    expect(matches, containsAll(const <int>[1, 2, 3, 4]));
    expect(matches, isNot(contains(5)));
    expect(matches, isNot(contains(6)));
    controller.dispose();
  });

  testWidgets('hovering a span shows its tooltip after the delay', (
    tester,
  ) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(194, 18));
    await mouse.moveTo(const Offset(194.5, 18));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ASSISTANT'), findsNothing);

    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('ASSISTANT'), findsOneWidget);
    expect(find.textContaining('Started'), findsOneWidget);

    await mouse.moveTo(const Offset(194.5, 49)); // below the lanes area
    await tester.pump();
    expect(find.text('ASSISTANT'), findsNothing);
    await mouse.removePointer();
    controller.dispose();
  });

  testWidgets('edge auto-pan advances the zoomed viewport during a drag', (
    tester,
  ) async {
    final controller = timelineFixtureController();
    await _pump(tester, controller);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(344, 20),
        scrollDelta: const Offset(0, -1000000),
      ),
    );
    await tester.pump();
    expect(_painterOf(tester).viewport!.start, 1);

    // Drag in the right edge-pan zone (last 32px of the track).
    final gesture = await tester.startGesture(const Offset(639, 20));
    await gesture.moveBy(const Offset(1, 0));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_painterOf(tester).viewport!.start, greaterThan(1.05));
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);
    controller.dispose();
  });
}
