// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// A [FakeChatService] with a controllable above-count and tap recording.
class _PagingService extends FakeChatService {
  int? above;
  int? below;
  int? total;
  bool loading = false;
  int loadCalls = 0;
  List<FaChatMessage> msgs = const [];

  @override
  List<FaChatMessage> get messages => msgs;
  @override
  int? get historyAboveCount => above;
  @override
  int? get historyBelowCount => below;
  @override
  int? get historyTotalCount => total;
  @override
  bool get historyLoading => loading;

  @override
  Future<void> loadOlderHistory() async {
    loadCalls++;
  }
}

/// A transcript window of [n] fake records.
List<FaChatMessage> _msgs(int n) => [
  for (var i = 0; i < n; i++)
    FaChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
];

Future<void> _pumpScreen(WidgetTester tester, _PagingService service) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  // flutter_chat_ui's empty chat list schedules a 50ms timer.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('banner shows "Load earlier" while the count is running', (
    tester,
  ) async {
    // A non-empty window: a big session whose background count has not
    // landed yet keeps the in-flight banner (issue #135). An EMPTY window
    // with a null count shows no banner (issue #223, see below).
    final service = _PagingService()
      ..above = null
      ..msgs = _msgs(3);
    await _pumpScreen(tester, service);

    expect(find.text('Load earlier'), findsOneWidget);
  });

  testWidgets('banner shows the record count above the window', (tester) async {
    final service = _PagingService()..above = 42;
    await _pumpScreen(tester, service);

    expect(find.text('Load earlier (42 more)'), findsOneWidget);
    expect(find.text('Load earlier'), findsNothing);
  });

  testWidgets('tapping the banner pages older history in', (tester) async {
    final service = _PagingService()..above = 42;
    await _pumpScreen(tester, service);

    await tester.tap(find.text('Load earlier (42 more)'));
    await tester.pump();

    expect(service.loadCalls, 1);
  });

  testWidgets('E6: the terminal banner at the file top', (tester) async {
    final service = _PagingService()
      ..above = 0
      ..total = 5000
      ..msgs = _msgs(3);
    await _pumpScreen(tester, service);

    expect(find.text('Beginning of session (1 of 5000)'), findsOneWidget);
    // The terminal state is not a tap target.
    await tester.tap(find.text('Beginning of session (1 of 5000)'));
    await tester.pump();
    expect(service.loadCalls, 0);
  });

  testWidgets('the spinner replaces the label while a page is in flight', (
    tester,
  ) async {
    final service = _PagingService()
      ..above = 42
      ..loading = true;
    await _pumpScreen(tester, service);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Load earlier (42 more)'), findsNothing);
  });

  testWidgets('the bottom "Load newer" banner pages back down', (tester) async {
    final service = _PagingService()
      ..above = 0
      ..hasNewer = true;
    await _pumpScreen(tester, service);

    expect(find.text('Load newer'), findsOneWidget);
    await tester.tap(find.text('Load newer'));
    await tester.pump();
    expect(service.loadNewerHistoryCalls, 1);

    // Once the tail is back, the banner disappears.
    service
      ..hasNewer = false
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Load newer'), findsNothing);
  });

  testWidgets('a known below-count labels the "Load newer" banner', (
    tester,
  ) async {
    final service = _PagingService()
      ..above = 0
      ..hasNewer = true
      ..below = 2400;
    await _pumpScreen(tester, service);

    expect(find.text('Load newer (2400 more)'), findsOneWidget);
  });

  testWidgets('banner is absent once everything is loaded', (tester) async {
    final service = _PagingService()..above = 0;
    await _pumpScreen(tester, service);

    expect(find.text('Load earlier'), findsNothing);
    expect(find.text('Load earlier (0 more)'), findsNothing);
  });

  testWidgets('a landing count (null -> N) flips the banner without a '
      'service swap', (tester) async {
    final service = _PagingService()
      ..above = null
      ..msgs = _msgs(3);
    await _pumpScreen(tester, service);
    expect(find.text('Load earlier'), findsOneWidget);

    service
      ..above = 7
      ..notifyListeners();
    await tester.pump();

    expect(find.text('Load earlier (7 more)'), findsOneWidget);
  });

  testWidgets('a failed page load surfaces the retry banner', (tester) async {
    final service = _PagingService()
      ..above = 42
      ..historyLoadError = 'disk full';
    await _pumpScreen(tester, service);

    expect(
      find.text("Couldn't load earlier messages - tap to retry"),
      findsOneWidget,
    );
    expect(find.text('Load earlier (42 more)'), findsNothing);
  });

  testWidgets('tapping the retry banner pages history again', (tester) async {
    final service = _PagingService()
      ..above = 42
      ..historyLoadError = 'disk full';
    await _pumpScreen(tester, service);

    await tester.tap(
      find.text("Couldn't load earlier messages - tap to retry"),
    );
    await tester.pump();

    expect(service.loadCalls, 1);
  });

  testWidgets('retry banner clears when the error does', (tester) async {
    final service = _PagingService()
      ..above = 42
      ..historyLoadError = 'disk full';
    await _pumpScreen(tester, service);
    expect(
      find.text("Couldn't load earlier messages - tap to retry"),
      findsOneWidget,
    );

    service
      ..historyLoadError = null
      ..notifyListeners();
    await tester.pump();

    expect(find.text('Load earlier (42 more)'), findsOneWidget);
    expect(
      find.text("Couldn't load earlier messages - tap to retry"),
      findsNothing,
    );
  });

  // --- Issue #223: no top banner on an empty session. ---

  /// No top banner of any kind renders.
  void expectNoTopBanner() {
    expect(find.textContaining('Load earlier'), findsNothing);
    expect(find.textContaining('Beginning of session'), findsNothing);
    expect(
      find.text("Couldn't load earlier messages - tap to retry"),
      findsNothing,
    );
  }

  testWidgets('UT-empty: an empty session shows no banner once the count '
      'lands', (tester) async {
    // Header-only session: nothing in the window, nothing above, the
    // background count landed at zero.
    final service = _PagingService()
      ..above = 0
      ..total = 0;
    await _pumpScreen(tester, service);

    expectNoTopBanner();
  });

  testWidgets('UT-empty-inflight: an empty session shows no banner while '
      'the count is still running', (tester) async {
    final service = _PagingService()..above = null;
    await _pumpScreen(tester, service);

    expectNoTopBanner();

    // A count landing at 0 keeps it hidden.
    service
      ..above = 0
      ..total = 0
      ..notifyListeners();
    await tester.pump();
    expectNoTopBanner();
  });

  testWidgets('UT-one-msg: a single-record session shows no terminal '
      'banner', (tester) async {
    final service = _PagingService()
      ..above = 0
      ..total = 1
      ..msgs = _msgs(1);
    await _pumpScreen(tester, service);

    expectNoTopBanner();
  });

  testWidgets('UT-count-fail: a failed count over an empty transcript '
      'hides; over a non-empty one the retry banner stays', (tester) async {
    final service = _PagingService()
      ..above = null
      ..historyLoadError = 'scan failed';
    await _pumpScreen(tester, service);
    expectNoTopBanner();

    // Same failure with a non-empty window keeps the retry surface.
    service
      ..msgs = _msgs(3)
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text("Couldn't load earlier messages - tap to retry"),
      findsOneWidget,
    );
  });

  testWidgets('E2E-golden: the wide layout renders no banner on an empty '
      'session either', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _PagingService()
      ..above = null
      ..total = 0;
    await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
    await tester.pump(const Duration(seconds: 1));

    expectNoTopBanner();
  });
}
