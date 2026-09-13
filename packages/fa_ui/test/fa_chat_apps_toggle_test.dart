// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

void main() {
  testWidgets('the chat bar renders no Apps toggle without a host builder '
      '(issue #224 AC5)', (tester) async {
    final service = FakeChatService();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
    // flutter_chat_ui's empty chat list schedules a 50ms timer.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byIcon(Icons.apps), findsNothing);
  });

  testWidgets('the host appsToggleButtonBuilder renders the Apps button '
      '(issue #224)', (tester) async {
    var taps = 0;
    FaChatHost.appsToggleButtonBuilder = (context, service) =>
        FaChatHeaderAction(
          // The host-styled inline button (issue #224 contract, now riding
          // the adaptive header's demotable action list — issue #225).
          widget: IconButton(
            key: const ValueKey('testAppsToggle'),
            icon: const Icon(Icons.apps),
            onPressed: () => taps++,
          ),
          label: 'Apps',
          onPressed: () => taps++,
        );
    addTearDown(() => FaChatHost.appsToggleButtonBuilder = null);

    final service = FakeChatService();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
    // flutter_chat_ui's empty chat list schedules a 50ms timer.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('testAppsToggle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('testAppsToggle')));
    expect(taps, 1);
  });
}
