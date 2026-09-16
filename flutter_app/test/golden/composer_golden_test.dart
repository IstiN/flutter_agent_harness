// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
//
/// Golden (screenshot) tests for the chat composer's multiline states
/// (`lib/ui/widgets/chat_composer.dart`, issue #463): the field at 1, 3
/// and the 6-line capped height, light + dark, mobile width.
///
/// The composer is snapshotted inside the full [ChatScreen] frame (the
/// marketing-grade pattern of `chat_golden_test.dart`): text is injected
/// through the IME channel, then the field is unfocused so the cursor's
/// wall-clock-dependent blink phase never leaks into the snapshot.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/upload.dart' show UploadPicker;
import 'package:fa_ui/fa_ui.dart' show FaChatHost;
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart' as app;
import 'package:fa_ui/fa_ui.dart' show UploadFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FontLoader, LogicalKeyboardKey, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

AgentService _fakeService(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream()
          ..end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    ),
    watchExternalSessions: false,
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

/// The adapter's uploadPicker slot wants the app [UploadPicker] interface;
/// it hands back the same bytes the paste path stages.
class _FixedPicker implements UploadPicker {
  _FixedPicker(this.png);

  final Uint8List png;

  @override
  Future<List<UploadFile>> pick() async => [(name: 'dropped.png', bytes: png)];
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    // Icon fonts are not registered from the test asset bundle — without
    // this every Icon renders as a placeholder square.
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<void> pumpComposerState(
    WidgetTester tester, {
    required int lines,
    required bool light,
  }) async {
    final manager = FlutterSessionManager(
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    )..addSession('fake-session', _fakeService(MemoryExecutionEnv()));
    await pumpGolden(
      tester,
      ChatScreen(manager: manager),
      size: goldenSizePhone,
      theme: light ? buildFahThemeLight() : null,
      wrap: (child) => child,
    );
    final text = List.generate(lines, (i) => 'composer line ${i + 1}').join(
      '\n',
    );
    await tester.enterText(find.byType(TextField), text);
    // The mic↔send swap runs through an AnimatedSwitcher; settle it.
    await tester.pumpAndSettle();
    // Determinism: unfocus so the snapshot never catches a random cursor
    // blink phase, then wait out the cursor's fade-out animation (the
    // chat_generated_image pattern).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  testWidgets('composer 1-line — dark', (tester) async {
    await pumpComposerState(tester, lines: 1, light: false);
    await expectGolden(tester, 'composer_multiline_1line');
  });

  testWidgets('composer 3-line — dark', (tester) async {
    await pumpComposerState(tester, lines: 3, light: false);
    await expectGolden(tester, 'composer_multiline_3line');
  });

  testWidgets('composer 6-line-capped — dark', (tester) async {
    // 8 lines: the field is visibly capped at the 6-line budget and
    // scrolls internally.
    await pumpComposerState(tester, lines: 8, light: false);
    await expectGolden(tester, 'composer_multiline_6line');
  });

  testWidgets('composer 6-line-capped — dark', (tester) async {
    // 8 lines: the field is visibly capped at the 6-line budget and
    // scrolls internally.
    await pumpComposerState(tester, lines: 8, light: false);
    await expectGolden(tester, 'composer_multiline_6line');
  });

  testWidgets('composer 1-line — light', (tester) async {
    await pumpComposerState(tester, lines: 1, light: true);
    await expectGolden(tester, 'composer_multiline_1line_light');
  });

  testWidgets('composer 3-line — light', (tester) async {
    await pumpComposerState(tester, lines: 3, light: true);
    await expectGolden(tester, 'composer_multiline_3line_light');
  });

  testWidgets('composer 6-line-capped — light', (tester) async {
    await pumpComposerState(tester, lines: 8, light: true);
    await expectGolden(tester, 'composer_multiline_6line_light');
  });

  group('composer staged chip — paste vs picker parity', () {
    // The multiline tests above pump the full ChatScreen, which wires the
    // FaChatHost static gallery/camera pickers for the whole process —
    // with them present the attach entry opens a bottom sheet instead of
    // going straight to the injected picker. Null them for this group.
    setUpAll(() {
      FaChatHost.galleryPicker = null;
      FaChatHost.cameraPicker = null;
    });

    // A deterministic 1x1 red PNG (valid IHDR/IDAT, decodes to fixed
    // pixels, no host/network involved).
    final png = Uint8List.fromList(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4'
      'z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
    ));
    // AC5 contract: paste-staged and picker-staged chips are the same
    // widget fed by the same pending-attachment state.
    Future<void> pumpChipState(
      WidgetTester tester, {
      required bool viaPaste,
      required bool light,
    }) async {
      await pumpGolden(
        tester,
        Scaffold(
          body: app.ChatComposer(
            service: _fakeService(MemoryExecutionEnv()),
            uploadPicker: viaPaste ? null : _FixedPicker(png),
            clipboardImageReader: viaPaste
                ? () async => (
                    name: 'pasted.png',
                    bytes: Uint8List.fromList(png),
                    mimeType: 'image/png',
                  )
                : null,
          ),
        ),
        size: goldenSizePhone,
        theme: light ? buildFahThemeLight() : null,
        wrap: (child) => child,
      );
      await tester.pumpAndSettle();
      if (viaPaste) {
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      } else {
        await tester.tap(find.byTooltip('Attach'));
        await tester.pumpAndSettle();
        // The attach entry opens a picker sheet when more than one source
        // is wired (host statics from the ChatScreen tests above) — pick
        // the file entry; with a single source it goes straight through.
        final fileEntry = find.text('Attach file');
        if (fileEntry.evaluate().isNotEmpty) {
          await tester.tap(fileEntry);
        }
      }
      // The staging chain rides real IO (clipboard probe / picker future).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      // Decode the chip thumbnail on the real event loop, then re-pump:
      // the snapshot must never catch the image mid-load.
      final composerContext = tester.element(find.byType(app.ChatComposer));
      await tester.runAsync(
        () => precacheImage(MemoryImage(png), composerContext),
      );
      await tester.pumpAndSettle();
      // Determinism: no cursor blink phase in the snapshot.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
    }

    testWidgets('via paste — dark', (tester) async {
      await pumpChipState(tester, viaPaste: true, light: false);
      await expectGolden(tester, 'composer_staged_chip');
    });

    testWidgets('via picker — dark', (tester) async {
      await pumpChipState(tester, viaPaste: false, light: false);
      await expectGolden(tester, 'composer_staged_chip_picker');
    });

    testWidgets('via paste — light', (tester) async {
      await pumpChipState(tester, viaPaste: true, light: true);
      await expectGolden(tester, 'composer_staged_chip_light');
    });

    testWidgets('via picker — light', (tester) async {
      await pumpChipState(tester, viaPaste: false, light: true);
      await expectGolden(tester, 'composer_staged_chip_picker_light');
    });
  });
}
