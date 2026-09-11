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
  int loadCalls = 0;

  @override
  int? get historyAboveCount => above;

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
}
