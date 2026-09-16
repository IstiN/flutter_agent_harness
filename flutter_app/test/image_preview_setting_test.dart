// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Widget tests for the "High-quality image previews" setting (issue
/// #207): the attached-image thumbnail decode is hardcoded at
/// `cacheWidth: 600` unless the setting flips it to full resolution.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/image_preview_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatAttachment;
import 'package:flutter_test/flutter_test.dart';

/// A 2×2 teal/indigo PNG (76 bytes), generated once offline and embedded
/// so the tests never touch network or assets.
final Uint8List _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAE0lEQVR4nGPQvbIfiBga'
  'e34AEQAw3weL9bEH6gAAAABJRU5ErkJggg==',
);

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

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
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
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

/// The attached-image thumbnail — the user bubble renders it straight
/// from the record's bytes (`Image.memory(cacheWidth: …)` wraps the
/// provider in a [ResizeImage]; full-resolution previews keep the bare
/// [MemoryImage]).
Finder _attachmentImage() => find.byWidgetPredicate((widget) {
  if (widget is! Image) return false;
  final provider = widget.image;
  return provider is MemoryImage ||
      (provider is ResizeImage && provider.imageProvider is MemoryImage);
});

/// The decode constraint of the matched thumbnail: the [ResizeImage.width]
/// when downscaled, `null` at full resolution.
int? _previewCacheWidth(WidgetTester tester) {
  final provider = tester.widget<Image>(_attachmentImage()).image;
  return switch (provider) {
    ResizeImage resize => resize.width,
    _ => null,
  };
}

/// Pumps the chat with one image-attachment message inside
/// [ImagePreviewScope] and lets the thumbnail decode (real async I/O)
/// land before returning.
Future<void> _pumpChat(
  WidgetTester tester,
  AgentService service,
  ImagePreviewStore store,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final manager = FlutterSessionManager(
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  )..addSession('fake-session', service);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ImagePreviewScope(
          store: store,
          child: ChatScreen(manager: manager),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  });
}

void main() {
  AgentService serviceWithAttachment(ExecutionEnv env) {
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'user',
        content: 'what is this?',
        attachments: <FaChatAttachment>[
          (bytes: _tinyPngBytes, path: 'uploads/what-is-this.png'),
        ],
      ),
    );
    return service;
  }

  testWidgets('default (setting off): the preview decodes downscaled at '
      'cacheWidth 600', (tester) async {
    final store = ImagePreviewStore(MemoryExecutionEnv());
    await _pumpChat(
      tester,
      serviceWithAttachment(MemoryExecutionEnv()),
      store,
    );

    expect(_attachmentImage(), findsOneWidget);
    expect(_previewCacheWidth(tester), 600);
    expect(tester.takeException(), isNull);
  });

  testWidgets('setting on: the preview decodes at full resolution (no '
      'cacheWidth constraint), and the flip applies live', (tester) async {
    final store = ImagePreviewStore(MemoryExecutionEnv())
      ..setHighQuality(true);
    await _pumpChat(
      tester,
      serviceWithAttachment(MemoryExecutionEnv()),
      store,
    );

    expect(_attachmentImage(), findsOneWidget);
    expect(_previewCacheWidth(tester), isNull);

    // Flipping the store live re-renders the open transcript with the
    // downscale back on — no restart needed.
    store.setHighQuality(false);
    await tester.pump();
    expect(_previewCacheWidth(tester), 600);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings section toggles the store', (tester) async {
    final store = ImagePreviewStore(MemoryExecutionEnv());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ImagePreviewScope(
            store: store,
            child: const SingleChildScrollView(
              child: ImagePreviewsSection(),
            ),
          ),
        ),
      ),
    );

    final toggle = find.byType(Switch);
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(store.highQuality, isTrue);
    expect(tester.widget<Switch>(toggle).value, isTrue);
  });
}
