// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// FakeChatService that records sends and aborts; everything else keeps the
/// shared no-op surface.
final class _RecordingChatService extends FakeChatService {
  final List<String> sentTexts = [];
  int abortCalls = 0;
  bool streaming = false;
  @override
  bool get isStreaming => streaming;
  @override
  Future<void> sendText(String text) async {
    sentTexts.add(text);
  }

  @override
  void abort() {
    abortCalls++;
  }
}

/// Scripted [FaChatVoiceInput]: available, records nothing — enough to
/// light up the mic slot.
final class _AvailableVoiceInput implements FaChatVoiceInput {
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<bool> start() async => true;
  @override
  Future<String?> stopAndTranscribe() async => null;
  @override
  Future<void> cancel() async {}
}

/// The composer's pick paths (`_attachFiles`: pick-cancel / pick-failure /
/// add-to-state) and the iMessage-style one-action trailing slot
/// (mic ↔ send/stop swap, `hideMicWhenNotEmpty`) — issue #1848 coverage.
void main() {
  FaChatUploadFile upload(String name, [List<int> bytes = const [1, 2, 3]]) =>
      (name: name, bytes: Uint8List.fromList(bytes), mimeType: 'text/plain');

  Future<_RecordingChatService> pumpComposer(
    WidgetTester tester, {
    FaChatUploadPicker? uploadPicker,
    bool hideMicWhenNotEmpty = false,
    FaChatVoiceInput? voiceInput,
    VoidCallback? onSent,
  }) async {
    final service = _RecordingChatService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            service: service,
            uploadPicker: uploadPicker,
            hideMicWhenNotEmpty: hideMicWhenNotEmpty,
            voiceInput: voiceInput,
            onSent: onSent,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  group('attach file picking', () {
    testWidgets('a cancelled pick (empty selection) stages nothing', (
      tester,
    ) async {
      final service = await pumpComposer(tester, uploadPicker: () async => []);

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();

      expect(service.stagedCalls, isEmpty);
      // The attach button itself is still the only content — no chips.
      expect(find.byType(FaAttachGlyph), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('a throwing picker surfaces the failure snack and stages '
        'nothing', (tester) async {
      final service = await pumpComposer(
        tester,
        uploadPicker: () async => throw StateError('nope'),
      );

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Upload failed'), findsOneWidget);
      expect(service.stagedCalls, isEmpty);
    });

    testWidgets('picked files stage immediately as pending chips', (
      tester,
    ) async {
      final service = await pumpComposer(
        tester,
        uploadPicker: () async => [upload('notes.txt'), upload('pic.bin')],
      );

      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();

      expect(service.stagedCalls.map((c) => c.name), ['notes.txt', 'pic.bin']);
      // One remove affordance per chip.
      expect(find.byIcon(Icons.close), findsNWidgets(2));
      expect(find.textContaining('notes.txt'), findsOneWidget);
      expect(find.textContaining('pic.bin'), findsOneWidget);
    });
  });

  group('one-action trailing slot', () {
    Future<_RecordingChatService> pumpSlot(
      WidgetTester tester, {
      VoidCallback? onSent,
    }) async {
      return pumpComposer(
        tester,
        hideMicWhenNotEmpty: true,
        voiceInput: _AvailableVoiceInput(),
        onSent: onSent,
      );
    }

    testWidgets('an idle empty field shows the mic, never send', (
      tester,
    ) async {
      await pumpSlot(tester);

      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.stop), findsNothing);
    });

    testWidgets('typing swaps the mic for send; sending clears the field and '
        'fires onSent', (tester) async {
      var sentCount = 0;
      final service = await pumpSlot(tester, onSent: () => sentCount++);

      await tester.enterText(find.byType(TextField), 'slot send');
      // The mic → send swap runs a 180ms scale+fade; let it finish.
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.mic_none), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(service.sentTexts, ['slot send']);
      expect(sentCount, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      // The empty field swaps back to the mic.
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });

    testWidgets('streaming with an empty field shows stop; tapping it '
        'aborts without sending', (tester) async {
      final service = await pumpComposer(
        tester,
        hideMicWhenNotEmpty: true,
        voiceInput: _AvailableVoiceInput(),
      );
      // Flip the streaming flag after mount, the way the service listener
      // would pick it up.
      service.streaming = true;
      // ignore: invalid_use_of_protected_member
      service.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pumpAndSettle();

      expect(service.abortCalls, 1);
      expect(service.sentTexts, isEmpty);
    });
  });
}
