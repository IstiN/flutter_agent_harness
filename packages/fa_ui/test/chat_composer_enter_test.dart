// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// FakeChatService that records [FakeChatService.sendText] calls; everything
/// else keeps the shared no-op surface.
final class _RecordingChatService extends FakeChatService {
  final List<String> sentTexts = [];
  @override
  Future<void> sendText(String text) async {
    sentTexts.add(text);
  }
}

/// Issue #973: plain Enter must send the draft, Shift+Enter must insert a
/// newline — not the other way around.
void main() {
  TextField field(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  Future<_RecordingChatService> pump(WidgetTester tester) async {
    final service = _RecordingChatService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatComposer(service: service)),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('desktop: plain Enter sends, Shift+Enter inserts a newline',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final service = await pump(tester);
      await tester.enterText(find.byType(TextField), 'hello');

      // Shift+Enter: nothing is sent, the key falls through unhandled (the
      // native IME layer — untestable here — turns that into the break).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final shiftHandled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(shiftHandled, isFalse);
      expect(service.sentTexts, isEmpty);
      expect(field(tester).focusNode!.hasFocus, isTrue);

      // Plain Enter: the draft is sent and the field cleared.
      final enterHandled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(enterHandled, isTrue);
      expect(service.sentTexts, ['hello']);
      expect(field(tester).controller!.text, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop: Cmd/Ctrl+Enter still sends', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final service = await pump(tester);
      await tester.enterText(find.byType(TextField), 'draft');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(service.sentTexts, ['draft']);
      expect(field(tester).controller!.text, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Mobile soft keyboards deliver the return key through the IME as a
  // text delta under TextInputAction.newline — no hardware key event, so
  // _handleComposerKey never sees it. The newline action is kept (see the
  // TextField), so that path is untouched by the Enter-sends fix.
}
