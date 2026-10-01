// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// A [FakeChatService] scripted for the issue #1159 streaming scenarios:
/// settable streaming/below state plus an [onLoadNewer] hook the test uses
/// to play the service side of a page-down (the real AgentService lands
/// the tail window, clears the below-count, and notifies).
class _StreamingPagingService extends FakeChatService {
  int? above = 0;
  int? below;
  bool streaming = false;
  bool loading = false;
  List<FaChatMessage> msgs = const [];

  /// Plays the service side of [loadNewerHistory].
  Future<void> Function()? onLoadNewer;

  @override
  bool get isStreaming => streaming;
  @override
  List<FaChatMessage> get messages => msgs;
  @override
  int? get historyAboveCount => above;
  @override
  int? get historyBelowCount => below;
  @override
  bool get historyLoading => loading;

  @override
  Future<void> loadNewerHistory() async {
    loadNewerHistoryCalls++;
    await onLoadNewer?.call();
  }
}

/// A transcript window of [n] fake records.
List<FaChatMessage> _msgs(int n) => [
  for (var i = 0; i < n; i++)
    FaChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
];

Future<void> _pump(WidgetTester tester, _StreamingPagingService service) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  // flutter_chat_ui's empty chat list schedules a 50ms timer; the
  // reveal-on-top gate settles one frame after the first layout.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('AC1: the banner taps through an active run and clears at '
      'the tail', (tester) async {
    final service = _StreamingPagingService()
      ..streaming = true
      ..msgs = _msgs(30)
      ..hasNewer = true
      ..below = 55;
    service.onLoadNewer = () async {
      service
        ..hasNewer = false
        ..below = 0
        ..notifyListeners();
    };
    await _pump(tester, service);

    // Visible and live-labeled mid-run.
    expect(find.text('Load newer (55 more)'), findsOneWidget);

    await tester.tap(find.text('Load newer (55 more)'));
    await tester.pump();
    await tester.pump();

    expect(service.loadNewerHistoryCalls, 1);
    expect(find.textContaining('Load newer'), findsNothing);
  });

  testWidgets('AC2: pinned to the bottom the view follows the tail — no '
      'banner, no accumulating count', (tester) async {
    final service = _StreamingPagingService()
      ..msgs = _msgs(30)
      ..above = 0;
    service.onLoadNewer = () async {
      service
        ..hasNewer = false
        ..below = 0
        ..notifyListeners();
    };
    await _pump(tester, service);
    expect(find.textContaining('Load newer'), findsNothing);

    // Mid-run the loaded window is stale (records landed below it) while
    // the user is parked at the bottom: the screen rejoins the tail on
    // its own — the below-count never becomes a banner.
    service
      ..streaming = true
      ..hasNewer = true
      ..below = 3
      ..notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(service.loadNewerHistoryCalls, 1);
    expect(find.textContaining('Load newer'), findsNothing);
  });

  testWidgets('AC3: scrolled up during a run the banner counts live; one '
      'tap returns to the tail', (tester) async {
    final service = _StreamingPagingService()
      ..msgs = _msgs(60)
      ..above = 0;
    service.onLoadNewer = () async {
      service
        ..hasNewer = false
        ..below = 0
        ..streaming = false
        ..notifyListeners();
    };
    await _pump(tester, service);

    // Drag to the oldest edge — a reversed list puts it at
    // maxScrollExtent, reached by a downward drag.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();

    // Mid-run the below-count grows; the banner stays and counts live,
    // and a deliberately scrolled-away user is never auto-paged.
    service
      ..streaming = true
      ..hasNewer = true
      ..below = 55
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Load newer (55 more)'), findsOneWidget);
    expect(service.loadNewerHistoryCalls, 0);

    service
      ..below = 56
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Load newer (56 more)'), findsOneWidget);
    expect(service.loadNewerHistoryCalls, 0);

    // One tap: live tail, banner gone.
    await tester.tap(find.text('Load newer (56 more)'));
    await tester.pump();
    await tester.pump();
    expect(service.loadNewerHistoryCalls, 1);
    expect(find.textContaining('Load newer'), findsNothing);
  });

  testWidgets('AC4: after the run the banner clears by itself once the '
      'window rejoins the tail', (tester) async {
    final service = _StreamingPagingService()
      ..msgs = _msgs(60)
      ..above = 0
      ..streaming = true;
    service.onLoadNewer = () async {
      service
        ..hasNewer = false
        ..below = 0
        ..notifyListeners();
    };
    await _pump(tester, service);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    // The streaming status row animates — pumpAndSettle would never
    // settle; fixed pumps park the drag.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    service
      ..hasNewer = true
      ..below = 55
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Load newer (55 more)'), findsOneWidget);
    expect(service.loadNewerHistoryCalls, 0);

    // The run ends while the user stays scrolled away: the plate stays
    // (it is the only "you are in history" signal).
    service
      ..streaming = false
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Load newer (55 more)'), findsOneWidget);

    // Returning to the bottom rejoins the live tail — the banner clears
    // without a tap. No stuck plate post-run.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(service.loadNewerHistoryCalls, 1);
    expect(find.textContaining('Load newer'), findsNothing);
  });
}
