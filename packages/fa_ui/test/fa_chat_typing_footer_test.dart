// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// The in-list typing indicator footer (issue #459, AC3): while the agent
/// streams, the indicator is a child of the scrollable message list (the
/// visually-bottom entry, scrolling with the content) — the composer area
/// renders no typing UI at all. The #464 docked dedupe keeps FaWorkBar as
/// the only other owner (covered app-side in session_chat_sheet_test).
class _StreamingService extends FakeChatService {
  bool streaming = true;
  @override
  bool get isStreaming => streaming;
  @override
  List<FaChatMessage> get messages => const [];
}

class _StreamingWithHistory extends _StreamingService {
  @override
  List<FaChatMessage> get messages => [
    FaChatMessage(role: 'user', content: 'hello'),
  ];
}

Future<void> _pump(WidgetTester tester, FaChatService service) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  // flutter_chat_ui's empty chat list schedules a 50ms timer.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  const footerKey = ValueKey('faChatTypingFooter');

  testWidgets('AC3: streaming renders the indicator inside the scrollable '
      'list — not in the composer area', (tester) async {
    final service = _StreamingWithHistory();
    await _pump(tester, service);

    // The footer exists and is a child of the list's scrollable.
    final footer = find.byKey(footerKey);
    expect(footer, findsOneWidget);
    expect(
      find.descendant(of: find.byType(Scrollable), matching: footer),
      findsOneWidget,
    );
    // Exactly one typing surface: the «Fa is typing...» text renders ONLY
    // in the footer — the composer subtree carries none.
    expect(find.text('Fa is typing...'), findsOneWidget);
    expect(find.byKey(const ValueKey('faChatTypingRow')), findsNothing);
  });

  testWidgets('AC3: ending the stream drops the footer', (tester) async {
    final service = _StreamingWithHistory();
    await _pump(tester, service);
    expect(find.byKey(footerKey), findsOneWidget);

    // Flip the service flag; the screen mirrors it on notify.
    service
      ..streaming = false
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(footerKey), findsNothing);
    expect(find.text('Fa is typing...'), findsNothing);
  });

  testWidgets('AC3 E1: empty history + typing — the footer is the only '
      'item (the package "No messages yet" overlay is suppressed)', (
    tester,
  ) async {
    final service = _StreamingService();
    await _pump(tester, service);

    expect(find.byKey(footerKey), findsOneWidget);
    expect(find.text('No messages yet'), findsNothing);
  });
}
