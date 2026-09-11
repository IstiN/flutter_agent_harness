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
    final service = _PagingService()..above = null;
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
      ..total = 5000;
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
    final service = _PagingService()..above = null;
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
}
