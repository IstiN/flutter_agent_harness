// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_chat_service.dart';

Future<void> _pumpPanelHarness(WidgetTester tester, FakeChatService service) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => openTrajectoryPanel(context, service: service),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Taps [trigger] and settles the open animation with explicit pumps
/// (pumpAndSettle never settles while the loading spinner animates).
Future<void> _tapAndOpen(WidgetTester tester, Finder trigger) async {
  await tester.tap(trigger);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  final at = DateTime.utc(2026, 1, 1, 12);

  TrajectorySnapshot buildSnapshot() => TrajectorySnapshotBuilder().append(
    MessageRecord(
      id: 'u1',
      parentId: null,
      timestamp: at,
      message: UserMessage.text('hello'),
    ),
  );

  testWidgets('shows the loading state until the first snapshot lands', (
    tester,
  ) async {
    final events = StreamController<TrajectorySnapshot>.broadcast();
    addTearDown(events.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaTrajectoryPanel(trajectory: events.stream)),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading trajectory…'), findsOneWidget);

    events.add(buildSnapshot());
    await tester.pump(); // deliver the event
    await tester.pump(const Duration(milliseconds: 100)); // snapshot debounce
    await tester.pump(); // rebuild frame

    expect(find.byType(TrajectoryView), findsOneWidget);
    expect(find.text('Loading trajectory…'), findsNothing);
    // Flush the search-index throttle timer before teardown.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a pre-populated feed renders without the loading state', (
    tester,
  ) async {
    final feed = TrajectoryServiceFeed();
    feed.append(
      MessageRecord(
        id: 'u1',
        parentId: null,
        timestamp: at,
        message: UserMessage.text('hello'),
      ),
    );
    addTearDown(feed.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaTrajectoryPanel(trajectory: feed.stream)),
      ),
    );
    await tester.pump(); // deliver the replayed latest snapshot
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.byType(TrajectoryView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('opens a full-height bottom sheet on narrow canvases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = FakeChatService();
    await _pumpPanelHarness(tester, service);

    await _tapAndOpen(tester, find.text('OPEN'));

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(FaTrajectoryPanel), findsOneWidget);
    // Flush the panel controller's debounce + search-index timers.
    await tester.pump(const Duration(seconds: 4));
    service.feed.dispose();
  });

  testWidgets('opens a dialog page on wide canvases', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = FakeChatService();
    await _pumpPanelHarness(tester, service);

    await _tapAndOpen(tester, find.text('OPEN'));

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(FaTrajectoryPanel), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    service.feed.dispose();
  });

  testWidgets('swapping the stream rebinds the panel', (tester) async {
    final first = TrajectoryServiceFeed();
    final second = TrajectoryServiceFeed();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    second.append(
      MessageRecord(
        id: 'u9',
        parentId: null,
        timestamp: at,
        message: UserMessage.text('from the second feed'),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaTrajectoryPanel(trajectory: first.stream)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaTrajectoryPanel(trajectory: second.stream)),
      ),
    );
    await tester.pump(); // deliver the replayed latest snapshot
    await tester.pumpAndSettle();

    expect(find.text('from the second feed'), findsOneWidget);
  });
}
