// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

    expect(find.byType(TrajectoryBody), findsOneWidget);
    expect(find.text('Loading trajectory…'), findsNothing);
    // Flush the search-index throttle timer before teardown.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a pre-populated feed renders the shell without loading', (
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

    expect(find.byType(TrajectoryBody), findsOneWidget);
    expect(find.byType(TrajectoryHeader), findsOneWidget);
    expect(find.byType(TrajectoryView), findsOneWidget);
    expect(find.text('Trajectory'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 4));
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
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.textContaining('from the second feed'), findsOneWidget);
    // Flush the search-index throttle timer before teardown.
    await tester.pump(const Duration(seconds: 4));
  });
}
