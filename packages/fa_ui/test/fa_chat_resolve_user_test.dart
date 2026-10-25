// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The chat screen's user resolution (the [Chat.resolveUser] contract the
/// screen wires): the four known author ids map to the fixed screen
/// users ("Me", "Fa", "tool", "system"); anything else falls back to a
/// user named after its id — hosts may push author ids the screen never
/// minted (custom roles, future roles).
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// Pumps the chat screen and returns the [Chat.resolveUser] callback it
/// wired into the transcript.
Future<ResolveUserCallback> _pumpAndResolve(WidgetTester tester) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = FakeChatService();
  await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
  // The sync debounce is 50ms; fixed pumps settle it.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 100));
  return tester.widget<Chat>(find.byType(Chat)).resolveUser;
}

void main() {
  testWidgets('known author ids resolve to the fixed screen users', (
    tester,
  ) async {
    final resolve = await _pumpAndResolve(tester);
    expect(await resolve('user'), const User(id: 'user', name: 'Me'));
    expect(await resolve('assistant'), const User(id: 'assistant', name: 'Fa'));
    expect(await resolve('tool'), const User(id: 'tool', name: 'tool'));
    expect(await resolve('system'), const User(id: 'system', name: 'system'));
  });

  testWidgets('an unknown author id falls back to a user named after it', (
    tester,
  ) async {
    final resolve = await _pumpAndResolve(tester);
    expect(
      await resolve('greeter-7'),
      const User(id: 'greeter-7', name: 'greeter-7'),
    );
  });
}
