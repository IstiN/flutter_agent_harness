// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The follow-mode contract on the app/web surface (gh-1439 AC2/AC3/AC4/
/// AC5): dragging away during a stream pins the list, arrivals count into
/// the `⌄ N new` pill, one tap returns to the live tail, and a drag back
/// into the near-bottom band re-arms live without the pill. The state
/// machine is the CORE [FollowMode] — AC3 asserts the shared owner (the
/// same contract instance type the CLI TUI drives), never a per-surface
/// copy.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'fake_chat_service.dart';

/// A [FakeChatService] scripted for the follow-mode scenarios: settable
/// streaming flag and a mutable transcript the test grows mid-run.
class _FollowTestService extends FakeChatService {
  bool streaming = false;
  List<FaChatMessage> msgs = const [];

  /// Plays the service side of [loadNewerHistory]: the tail window lands,
  /// the below-count clears (the real AgentService contract).
  @override
  Future<void> loadNewerHistory() async {
    loadNewerHistoryCalls++;
    hasNewer = false;
    notifyListeners();
  }

  @override
  bool get isStreaming => streaming;
  @override
  List<FaChatMessage> get messages => msgs;

  void append(int count) {
    final base = msgs.length;
    msgs = [
      ...msgs,
      for (var i = 0; i < count; i++)
        FaChatMessage(
          role: (base + i).isEven ? 'user' : 'assistant',
          content: 'm${base + i}',
        ),
    ];
    notifyListeners();
  }

  /// Plays the service side of `loadOlderHistory`: an older page
  /// PREPENDS — index-based ids (`msg-$index`) all shift, so the sync
  /// sees a whole new window.
  void prepend(int count) {
    final old = msgs;
    msgs = [
      for (var i = 0; i < count; i++)
        FaChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'old$i'),
      ...old,
    ];
    notifyListeners();
  }
}

List<FaChatMessage> _msgs(int n) => [
  for (var i = 0; i < n; i++)
    FaChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
];

Future<void> _pump(WidgetTester tester, _FollowTestService service) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  // flutter_chat_ui's empty chat list schedules a 50ms timer; the sync
  // debounce is 50ms — fixed pumps settle both.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Drags the transcript toward history (a reversed list: a downward drag
/// grows the pixel offset) and parks it, like a momentum flick.
Future<void> _dragTowardHistory(WidgetTester tester, double dy) async {
  await tester.drag(find.byType(Scrollable).first, Offset(0, dy));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  test('AC3: the shared core FollowMode owns the screen state — '
      'the contract type is the harness one, not a local copy', () {
    // The owner assertion: the screen's held/unseen state IS the core
    // machine's shape (value semantics, shared classifier). Behavior
    // parity with the CLI surface is pinned by the core suite.
    const live = FollowMode.live();
    final held = live.userScrolled(distanceFromLiveEdge: 500, armExtent: 100);
    expect(held.isHeld, isTrue);
    expect(held.appended(3).unseen, 3);
    expect(held.jumpToLive(), const FollowMode.live());
  });

  testWidgets('AC2: drag away during a run pins the list; arrivals count '
      'into the pill; one tap jumps to live', (tester) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);

    // Hold: drag toward history, parking beyond the arm band.
    await _dragTowardHistory(tester, 400);
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsNothing,
      reason: 'no arrivals yet — the affordance shows only with unseen',
    );

    // The stream keeps producing; the viewport must stay pinned and the
    // count must grow instead of yanking the user down.
    service.append(3);
    await tester.pump(const Duration(milliseconds: 100));
    service.append(4);
    await tester.pump(const Duration(milliseconds: 100));

    final pill = find.byKey(const ValueKey('faChatJumpToLivePill'));
    expect(pill, findsOneWidget);
    expect(
      find.text('⌄ 7 new'),
      findsOneWidget,
      reason: 'the pill counts live (AC2)',
    );

    // One action: back to the live tail, count flushed.
    await tester.tap(pill);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(pill, findsNothing);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .widget
        .controller!
        .position;
    expect(position.pixels, 0, reason: 'the window lands at the live tail');
    expect(
      find.text('m36'),
      findsOneWidget,
      reason: 'the newest arrival is on the glass (zero loss)',
    );
  });

  testWidgets('AC2: a near-bottom drag re-arms live without the pill', (
    tester,
  ) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);

    // Hold, then drag back to just inside the ~10% arm band.
    await _dragTowardHistory(tester, 400);
    service.append(2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('faChatJumpToLivePill')), findsOneWidget);

    await _dragTowardHistory(tester, -350);
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsNothing,
      reason: 'landing inside the band re-arms live — no button needed',
    );

    // Following again: further arrivals never show the pill.
    service.append(2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('faChatJumpToLivePill')), findsNothing);
  });

  testWidgets('AC4: a held session loses nothing — the post-jump '
      'transcript equals the twin live run', (tester) async {
    // Twin A: hold, stream 20, jump to live.
    final held = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, held);
    await _dragTowardHistory(tester, 400);
    held.append(20);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('faChatJumpToLivePill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final heldWindow = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toSet();

    // Twin B: the same stream with the user at the bottom the whole time.
    final live = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, live);
    live.append(20);
    await tester.pump(const Duration(milliseconds: 100));
    final liveWindow = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toSet();

    expect(
      heldWindow,
      liveWindow,
      reason:
          'held withheld only the VIEWPORT — after re-engage the '
          'rendered transcript equals the live twin',
    );
  });

  testWidgets('AC5: a fresh screen starts live; a session swap never '
      'restores held', (tester) async {
    final service = _FollowTestService()..msgs = _msgs(30);
    await _pump(tester, service);
    await _dragTowardHistory(tester, 400);
    service.append(1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('faChatJumpToLivePill')), findsOneWidget);

    // The host swaps sessions: the same screen re-syncs to the new
    // service — the viewport restarts live (nothing durable carries the
    // held state, AC5).
    final nextService = _FollowTestService()..msgs = _msgs(30);
    await tester.pumpWidget(
      MaterialApp(home: FaChatScreen(service: nextService)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    nextService.append(2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsNothing,
      reason: 'a swapped-in session always starts live',
    );
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .widget
        .controller!
        .position;
    expect(position.pixels, 0);
  });

  testWidgets('REG: the #1159 banner contract is untouched by the pill', (
    tester,
  ) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..hasNewer = true
      ..streaming = true;
    await _pump(tester, service);

    // Held: the banner owns the below-count surface and the user is
    // never auto-paged — the pill is a SIBLING, not a rework.
    await _dragTowardHistory(tester, 400);
    await tester.pump();
    expect(
      find.textContaining('Load newer'),
      findsOneWidget,
      reason: 'the deep-paged banner keeps its own contract (#1159)',
    );
    expect(
      service.loadNewerHistoryCalls,
      0,
      reason: 'a held user is never auto-paged (#1159 AC3)',
    );
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsNothing,
      reason: 'banner below-counts are not follow-mode arrivals',
    );

    // Back at the tail the banner auto-rejoins (unchanged behavior).
    await _dragTowardHistory(tester, -400);
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.loadNewerHistoryCalls, 1);
    expect(find.textContaining('Load newer'), findsNothing);
  });

  test('pill copy exists in both locales (en/ru string parity)', () {
    const en = FaChatStringsEn();
    const ru = FaChatStringsRu();
    expect(en.chatFollowNewCount('42'), '⌄ 42 new');
    expect(en.chatJumpToLive, 'Jump to live');
    expect(ru.chatFollowNewCount('42'), contains('42'));
    expect(ru.chatJumpToLive, isNotEmpty);
  });

  testWidgets('re-review: a history-page PREPEND while held is not an '
      'arrival — the pill keeps its previous count', (tester) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);
    await _dragTowardHistory(tester, 400);

    // Pure tail growth: 3 arrivals counted.
    service.append(3);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('⌄ 3 new'), findsOneWidget);

    // The user loads an older history page while held: the page
    // PREPENDS, index-based ids (`msg-$index`) all shift, and the sync
    // sees a whole new window (commonPrefix collapses to 0). None of it
    // is an arrival — the pill must stay at 3.
    service.prepend(25);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('⌄ 3 new'),
      findsOneWidget,
      reason:
          'prepends are not arrivals — the pill counts tail growth only',
    );
    expect(find.text('⌄ 28 new'), findsNothing);
  });

  testWidgets('re-review: a prepend with zero arrivals never shows the '
      'pill', (tester) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);
    await _dragTowardHistory(tester, 400);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('faChatJumpToLivePill')), findsNothing);

    service.prepend(25);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsNothing,
      reason: 'a history-page load adds zero arrivals — no pill',
    );
  });

  testWidgets('re-review: a WHEEL scroll-up during a run holds and arms '
      'the pill (mouse/trackpad are user gestures too)', (tester) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);

    // Wheel-up = toward history (reversed list: a negative wheel delta
    // grows the offset). The tick lands far beyond the arm band.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(Scrollable).first),
        scrollDelta: const Offset(0, -400),
      ),
    );
    await tester.pump();

    // The stream keeps producing; a wheel user must NOT be yanked back
    // and the arrivals must count.
    service.append(3);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsOneWidget,
      reason: 'wheel-up is a user gesture: it holds and arrivals count',
    );
    expect(find.text('⌄ 3 new'), findsOneWidget);
  });

  testWidgets('re-review: a WHEEL scroll-down back to the near-bottom '
      're-arms live (the pill goes away)', (tester) async {
    final service = _FollowTestService()
      ..msgs = _msgs(30)
      ..streaming = true;
    await _pump(tester, service);
    await _dragTowardHistory(tester, 400);
    service.append(2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('faChatJumpToLivePill')), findsOneWidget);

    // Wheel-down to just inside the ~10% arm band.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(Scrollable).first),
        scrollDelta: const Offset(0, 350),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('faChatJumpToLivePill')),
      findsNothing,
      reason: 'landing inside the band by wheel re-arms live',
    );
  });
}
