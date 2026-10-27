// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// Composer voice-input (mic button) and smart-paste (Cmd/Ctrl+V) paths:
/// the recording lifecycle around [FaChatVoiceInput], the clipboard
/// smart-paste rules (inline vs staged `.txt` chip), and the
/// `+N lines`-style error surfaces (issue #1848 coverage).
void main() {
  // Canonical 1x1 transparent PNG for the clipboard-image reader fake.
  const k1x1Png = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ];

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<FakeChatService> pumpComposer(
    WidgetTester tester, {
    FaChatVoiceInput? voiceInput,
    FaClipboardImageReader? clipboardImageReader,
  }) async {
    final service = FakeChatService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            service: service,
            voiceInput: voiceInput,
            clipboardImageReader: clipboardImageReader,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  /// Cmd+V through the real focus chain — the exact combo
  /// _handleComposerKey claims (meta down → keyV down/up → meta up).
  Future<void> smartPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  void stubClipboard(WidgetTester tester, {String? text, bool deny = false}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          if (deny) {
            throw PlatformException(code: 'clipboard', message: 'nope');
          }
          return <String, String?>{'text': text};
        }
        return null;
      },
    );
  }

  group('mic button', () {
    testWidgets('tap starts a recording; the second tap transcribes into '
        'the empty field', (tester) async {
      final voice = _FakeVoiceInput(transcript: 'hello world');
      await pumpComposer(tester, voiceInput: voice);

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump(); // pumpAndSettle never settles: the pulse repeats.
      expect(voice.starts, 1);
      expect(find.byTooltip('Stop recording'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      expect(voice.stops, 1);
      expect(fieldText(tester), 'hello world');
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .controller!
            .selection
            .baseOffset,
        'hello world'.length,
        reason: 'the selection lands after the inserted take',
      );
      expect(find.byTooltip('Voice input'), findsOneWidget);
    });

    testWidgets('a take appends to existing text with a single spacer', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(transcript: 'from mic');
      await pumpComposer(tester, voiceInput: voice);
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'draft from mic');
    });

    testWidgets('no double spacer when the draft already ends in a space', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(transcript: 'from mic');
      await pumpComposer(tester, voiceInput: voice);
      await tester.enterText(find.byType(TextField), 'draft ');
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'draft from mic');
    });

    testWidgets('a null take leaves the field untouched and returns to idle', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(transcript: null);
      final service = await pumpComposer(tester, voiceInput: voice);
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();

      expect(voice.stops, 1);
      expect(fieldText(tester), isEmpty);
      expect(service.stagedCalls, isEmpty);
      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('an empty take leaves the field untouched and returns to '
        'idle', (tester) async {
      final voice = _FakeVoiceInput(transcript: '');
      final service = await pumpComposer(tester, voiceInput: voice);
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();

      expect(voice.stops, 1);
      expect(fieldText(tester), isEmpty);
      expect(service.stagedCalls, isEmpty);
      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a StateError from transcription surfaces its message', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(stopError: StateError('no audio'));
      await pumpComposer(tester, voiceInput: voice);
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Voice input failed: no audio'),
        findsOneWidget,
      );
      expect(find.byTooltip('Voice input'), findsOneWidget);
    });

    testWidgets('any other transcription failure surfaces toString', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(stopError: Exception('boom'));
      await pumpComposer(tester, voiceInput: voice);
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Voice input failed: Exception: boom'),
        findsOneWidget,
      );
    });

    testWidgets('start() throwing surfaces the failure and stays idle', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(startError: Exception('mic busy'));
      await pumpComposer(tester, voiceInput: voice);

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(voice.starts, 1);
      expect(voice.stops, 0);
      expect(
        find.textContaining('Voice input failed: Exception: mic busy'),
        findsOneWidget,
      );
      expect(find.byTooltip('Stop recording'), findsNothing);
    });

    testWidgets('start() false with a reason shows the host reason', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(
        startResult: false,
        reason: 'No ASR endpoint configured',
      );
      await pumpComposer(tester, voiceInput: voice);

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No ASR endpoint configured'), findsOneWidget);
      expect(find.byTooltip('Stop recording'), findsNothing);
    });

    testWidgets('start() false without a reason shows the denied copy', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(startResult: false);
      await pumpComposer(tester, voiceInput: voice);

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Microphone access was denied'),
        findsOneWidget,
      );
    });

    testWidgets('disposing mid-recording cancels the native recorder', (
      tester,
    ) async {
      final voice = _FakeVoiceInput(transcript: 'late');
      await pumpComposer(tester, voiceInput: voice);

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      expect(voice.cancels, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(voice.cancels, 1);
    });

    testWidgets('unmounting mid-transcription drops the take without '
        'touching dead state', (tester) async {
      final gate = Completer<String?>();
      final voice = _FakeVoiceInput(stopGate: gate);
      await pumpComposer(tester, voiceInput: voice);

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete('late take');
      await tester.pump();
      // Reaching here is the assertion: the mounted guards dropped the
      // late take instead of touching the disposed controller.
    });
  });

  group('smart paste', () {
    testWidgets('short single-line text inserts inline at the cursor', (
      tester,
    ) async {
      stubClipboard(tester, text: 'hello paste');
      final service = await pumpComposer(tester);
      await smartPaste(tester);

      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), 'hello paste');
    });

    testWidgets('inline paste lands at the cursor, not over the draft', (
      tester,
    ) async {
      stubClipboard(tester, text: 'X');
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'abc');
      await smartPaste(tester);
      expect(fieldText(tester), 'abcX');
    });

    testWidgets('tabs are safe inline characters', (tester) async {
      stubClipboard(tester, text: 'col1\tcol2');
      final service = await pumpComposer(tester);
      await smartPaste(tester);
      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), 'col1\tcol2');
    });

    testWidgets('a URL with trailing whitespace pastes inline, never as a '
        'chip', (tester) async {
      stubClipboard(tester, text: 'https://example.com/page\r');
      final service = await pumpComposer(tester);
      await smartPaste(tester);
      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), 'https://example.com/page\r');
    });

    testWidgets('an empty clipboard is a silent no-op', (tester) async {
      stubClipboard(tester, text: '');
      final service = await pumpComposer(tester);
      await smartPaste(tester);
      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a clipboard with no text is a silent no-op', (tester) async {
      stubClipboard(tester);
      final service = await pumpComposer(tester);
      await smartPaste(tester);
      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), isEmpty);
    });

    testWidgets('a denied clipboard is a silent no-op', (tester) async {
      stubClipboard(tester, deny: true);
      final service = await pumpComposer(tester);
      await smartPaste(tester);
      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('multi-line text stages as a pasted-*.txt chip', (
      tester,
    ) async {
      stubClipboard(tester, text: 'line one\nline two');
      final service = await pumpComposer(tester);
      await smartPaste(tester);

      expect(service.stagedCalls, hasLength(1));
      expect(service.stagedCalls.single.name, startsWith('pasted-'));
      expect(service.stagedCalls.single.name, endsWith('.txt'));
      expect(
        utf8.decode(service.stagedCalls.single.bytes),
        'line one\nline two',
      );
      expect(fieldText(tester), isEmpty);
      expect(find.textContaining(RegExp(r'pasted-\d+\.txt')), findsOneWidget);
    });

    testWidgets('text longer than 1000 chars stages as a chip', (tester) async {
      stubClipboard(tester, text: 'a' * 1001);
      final service = await pumpComposer(tester);
      await smartPaste(tester);

      expect(service.stagedCalls, hasLength(1));
      expect(utf8.decode(service.stagedCalls.single.bytes), 'a' * 1001);
      expect(fieldText(tester), isEmpty);
    });

    testWidgets('control characters stage the text as a chip', (tester) async {
      stubClipboard(tester, text: 'bad\x01char');
      final service = await pumpComposer(tester);
      await smartPaste(tester);

      expect(service.stagedCalls, hasLength(1));
      expect(utf8.decode(service.stagedCalls.single.bytes), 'bad\x01char');
      expect(fieldText(tester), isEmpty);
    });

    testWidgets('a clipboard image stages as a chip and mixed text still '
        'pastes inline', (tester) async {
      stubClipboard(tester, text: 'caption');
      final service = await pumpComposer(
        tester,
        clipboardImageReader: () async => (
          name: 'shot.png',
          bytes: Uint8List.fromList(k1x1Png),
          mimeType: 'image/png',
        ),
      );
      await smartPaste(tester);
      await tester.pumpAndSettle();

      expect(service.stagedCalls.map((c) => c.name), ['shot.png']);
      expect(fieldText(tester), 'caption');
      // Image chips render a 48x48 thumbnail, not a name label.
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('no clipboard image falls through to text', (tester) async {
      stubClipboard(tester, text: 'just text');
      final service = await pumpComposer(
        tester,
        clipboardImageReader: () async => null,
      );
      await smartPaste(tester);

      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), 'just text');
    });

    testWidgets('a broken image reader falls through to text', (tester) async {
      stubClipboard(tester, text: 'still text');
      final service = await pumpComposer(
        tester,
        clipboardImageReader: () async => throw Exception('probe failed'),
      );
      await smartPaste(tester);

      expect(service.stagedCalls, isEmpty);
      expect(fieldText(tester), 'still text');
    });
  });
}

/// Scripted [FaChatVoiceInput]: records call counts and replays the
/// start/transcript outcome the test wants.
final class _FakeVoiceInput implements FaChatVoiceInput {
  _FakeVoiceInput({
    this.startResult = true,
    this.reason,
    Object? startError,
    this.transcript,
    Object? stopError,
    Completer<String?>? stopGate,
  }) : _startError = startError,
       _stopError = stopError,
       _stopGate = stopGate;

  final bool startResult;
  final String? reason;
  final Object? _startError;
  final String? transcript;
  final Object? _stopError;
  final Completer<String?>? _stopGate;

  int starts = 0;
  int stops = 0;
  int cancels = 0;

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => reason;

  @override
  Future<bool> start() async {
    starts++;
    if (_startError != null) throw _startError;
    return startResult;
  }

  @override
  Future<String?> stopAndTranscribe() async {
    stops++;
    if (_stopError != null) throw _stopError;
    final gate = _stopGate;
    if (gate != null) return gate.future;
    return transcript;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}
