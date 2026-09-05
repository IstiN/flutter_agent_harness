// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_chat_service.dart';

/// Appends a tall transcript so the trajectory ledger overflows its
/// viewport (drives the AC2 scroll-preservation assertions).
void _populate(TrajectoryServiceFeed feed) {
  final at = DateTime.utc(2026, 1, 1, 12);
  AssistantMessage assistant(String text, DateTime at) => AssistantMessage(
    content: [TextContent(text: text)],
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
    stopReason: StopReason.stop,
    timestamp: at,
  );
  for (var i = 0; i < 24; i++) {
    final base = at.add(Duration(seconds: i * 2));
    feed
      ..append(
        MessageRecord(
          id: 'u$i',
          parentId: i == 0 ? null : 'a${i - 1}',
          timestamp: base,
          message: UserMessage.text(
            i == 0 ? 'deploy the service now' : 'message $i',
          ),
        ),
      )
      ..append(
        MessageRecord(
          id: 'a$i',
          parentId: 'u$i',
          timestamp: base.add(const Duration(seconds: 1)),
          message: assistant('reply $i', base.add(const Duration(seconds: 1))),
        ),
      );
  }
}

Future<void> _pumpScreen(
  WidgetTester tester,
  FakeChatService service, {
  FaChatFeatures features = const FaChatFeatures(),
  Size size = const Size(600, 1000),
  void Function(TrajectoryServiceFeed)? populate,
}) async {
  populate?.call(service.feed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: FaChatScreen(service: service, features: features),
    ),
  );
}

void main() {
  // flutter_chat_ui's empty chat list schedules a 50ms timer and the
  // trajectory controller leaves a throttled search-index timer behind —
  // flush both before teardown. Explicit pumps instead of
  // pumpAndSettle: the loading spinner animates until the first
  // snapshot lands.
  Future<void> flushTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  /// Opens the narrow trajectory page via the switcher and settles.
  Future<void> openTrajectory(WidgetTester tester) async {
    await tester.tap(find.text('Trajectory'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4)); // debounce + throttle
  }

  testWidgets('wide shows the timeline icon, narrow the switcher', (
    tester,
  ) async {
    final service = FakeChatService();
    await _pumpScreen(tester, service, size: const Size(1400, 1000));
    expect(find.byIcon(Icons.timeline), findsOneWidget);
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    await flushTimers(tester);
    service.feed.dispose();

    await _pumpScreen(tester, service, size: const Size(600, 1000));
    expect(find.byIcon(Icons.timeline), findsNothing);
    expect(find.byType(SegmentedButton<bool>), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Trajectory'), findsOneWidget);
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('trajectory affordances follow the feature flag', (tester) async {
    final service = FakeChatService();
    await _pumpScreen(
      tester,
      service,
      features: const FaChatFeatures.minimal(),
    );
    expect(find.byIcon(Icons.timeline), findsNothing);
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('narrow switch swaps chat body with the trajectory page', (
    tester,
  ) async {
    final service = FakeChatService();
    await _pumpScreen(tester, service);

    await openTrajectory(tester);

    expect(find.byType(TrajectoryScreen), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    // Back to chat: the page goes away, the transcript stays.
    await tester.tap(find.text('Chat'));
    await tester.pump();
    expect(find.byType(TrajectoryScreen), findsNothing);
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('wide tap opens a full-screen route, not a dialog', (
    tester,
  ) async {
    final service = FakeChatService();
    await _pumpScreen(tester, service, size: const Size(1400, 1000));

    await tester.tap(find.byIcon(Icons.timeline));
    await tester.pump(); // start the route animation
    await tester.pump(const Duration(milliseconds: 400)); // finish it
    await tester.pump(const Duration(seconds: 4)); // flush timers

    expect(find.byType(TrajectoryScreen), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    // AC1: the route carries the persistent details pane next to the feed.
    expect(find.byType(TrajectoryDetailsPane), findsOneWidget);
    await flushTimers(tester);
    service.feed.dispose();
  });

  testWidgets('switching back and forth keeps scroll, query, selection (AC2)', (
    tester,
  ) async {
    final service = FakeChatService();
    await _pumpScreen(tester, service, populate: _populate);

    await openTrajectory(tester);

    final pageFind = find.descendant(
      of: find.byType(TrajectoryScreen),
      matching: find.byType(TextField),
    );
    // Select a record via the search match navigation.
    await tester.enterText(pageFind, 'deploy');
    await tester.pump();
    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.text('1 of 1'), findsOneWidget);

    // Clear the query so the full ledger (48+ rows) overflows again, then
    // scroll it away from the tail-follow position.
    await tester.enterText(pageFind, '');
    await tester.pump();
    final ledgerScrollable = find
        .descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        // The header's search TextField owns an internal vertical
        // Scrollable too; the ledger's is the last one in tree order.
        .last;
    await tester.drag(ledgerScrollable, const Offset(0, -300));
    await tester.pump();
    final offsetBefore = tester
        .state<ScrollableState>(ledgerScrollable)
        .position
        .pixels;
    expect(offsetBefore, greaterThan(0));

    // Chat and back: everything survives the swap.
    await tester.tap(find.text('Chat'));
    await tester.pump();
    await tester.tap(find.text('Trajectory'));
    await tester.pump();

    expect(
      tester.state<ScrollableState>(ledgerScrollable).position.pixels,
      offsetBefore,
    );
    // The selection made through match navigation survives the swap: the
    // selected row keeps its highlight border. Scroll back up first so the
    // lazily-built first row materializes.
    await tester.drag(ledgerScrollable, const Offset(0, 10000));
    await tester.pump();
    final decorated = tester.widgetList<Container>(
      find.ancestor(
        of: find.text('deploy the service now'),
        matching: find.byType(Container),
      ),
    );
    expect(
      decorated.where((c) => (c.decoration as BoxDecoration?)?.border != null),
      isNotEmpty,
    );
    await flushTimers(tester);
    service.feed.dispose();
  });
}
