// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_chat_service.dart';

Future<void> _pumpScreen(
  WidgetTester tester,
  FakeChatService service, {
  FaChatFeatures features = const FaChatFeatures(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FaChatScreen(service: service, features: features),
    ),
  );
}

void main() {
  // flutter_chat_ui's empty chat list schedules a 50ms timer and the
  // panel's controller leaves a throttled search-index timer behind —
  // flush both before teardown. Explicit pumps instead of
  // pumpAndSettle: the loading spinner animates until the first
  // snapshot lands.
  Future<void> flushTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  /// Taps the trajectory icon and settles the open animation.
  Future<void> tapAndOpen(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.timeline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('trajectory icon shows only when the feature flag is on', (
    tester,
  ) async {
    final service = FakeChatService();
    await _pumpScreen(tester, service);
    expect(find.byIcon(Icons.timeline), findsOneWidget);

    await _pumpScreen(
      tester,
      service,
      features: const FaChatFeatures.minimal(),
    );
    expect(find.byIcon(Icons.timeline), findsNothing);
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('trajectory icon sits to the right of the copy action', (
    tester,
  ) async {
    final service = FakeChatService();
    await _pumpScreen(tester, service);

    final actions = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .toList();
    expect(
      actions.indexWhere((b) => b.tooltip == 'Trajectory'),
      greaterThan(actions.indexWhere((b) => b.tooltip == 'Copy session')),
    );
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('tap opens the panel as a bottom sheet on narrow canvases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = FakeChatService();
    await _pumpScreen(tester, service);

    await tapAndOpen(tester);

    expect(find.byType(FaTrajectoryPanel), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('tap opens the panel as a dialog on wide canvases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = FakeChatService();
    await _pumpScreen(tester, service);

    await tapAndOpen(tester);

    expect(find.byType(FaTrajectoryPanel), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    await flushTimers(tester);
    service.feed.dispose();
  });
}
