// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A service whose scripted provider answers each run with the next reply
/// text (same pattern as test/apps/fa_reply_sheet_test.dart).
AgentService _scriptedService(List<String> replies) {
  var call = 0;
  fn(Model model, dynamic context, {cancelToken}) {
    final text = replies[call < replies.length ? call : replies.length - 1];
    call++;
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026, 1, 1),
    );
    stream.push(StartEvent(partial: message));
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  }

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
      streamFunction: fn,
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

/// Pumps the overlay standalone inside a MaterialApp.
Future<void> _pumpOverlay(
  WidgetTester tester,
  AgentService service, {
  Future<void> Function(String text)? onSend,
  VoidCallback? onCollapse,
  VoidCallback? onOpenFullChat,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: FaChatOverlay(
                service: service,
                onSend: onSend,
                onCollapse: onCollapse,
                onOpenFullChat: onOpenFullChat,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('empty transcript shows the hint', (tester) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    await _pumpOverlay(tester, service);
    expect(find.textContaining('Nothing here yet'), findsOneWidget);
  });

  testWidgets('transcript renders user, assistant and tool messages', (
    tester,
  ) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    service.messages.addAll([
      FahChatMessage(role: 'user', content: 'make it purple'),
      FahChatMessage(role: 'thinking', content: 'weighing purples…'),
      FahChatMessage(
        role: 'tool',
        content: 'patched widget.js',
        toolName: 'edit',
      ),
      FahChatMessage(role: 'system', content: '[edit] widget.js'),
      FahChatMessage(role: 'assistant', content: 'Done — now **purple**.'),
    ]);
    await _pumpOverlay(tester, service);

    // The overlay renders through the shared ChatMessageTile: user/assistant
    // as Markdown bubbles, thinking as an italic note, tools as styled
    // `[ name ]` tiles, system rows as `$ …` shell lines.
    expect(find.textContaining('make it purple'), findsOneWidget);
    expect(find.textContaining('weighing purples'), findsOneWidget);
    expect(find.text('[ edit ]'), findsOneWidget);
    expect(find.text('patched widget.js'), findsOneWidget);
    expect(
      find.textContaining('[edit] widget.js', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Done — now'), findsOneWidget);
  });

  testWidgets('composer sends through the callback and clears itself', (
    tester,
  ) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    final sent = <String>[];
    await _pumpOverlay(tester, service, onSend: (text) async => sent.add(text));

    await tester.enterText(find.byType(TextField), 'make it teal');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(sent, ['make it teal']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('send is disabled while a send is in flight', (tester) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    final sent = <String>[];
    await _pumpOverlay(
      tester,
      service,
      onSend: (text) {
        sent.add(text);
        // Never completes within the test — the button must stay disabled.
        // (A Completer, not Future.delayed: no pending timer at teardown.)
        return Completer<void>().future;
      },
    );

    await tester.enterText(find.byType(TextField), 'one');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, ['one']);

    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(button.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'two');
    await tester.pump();
    expect(sent, ['one']);
  });

  testWidgets('collapse button fires onCollapse', (tester) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    var collapsed = 0;
    await _pumpOverlay(tester, service, onCollapse: () => collapsed++);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();
    expect(collapsed, 1);
  });

  testWidgets('open-full-chat button fires onOpenFullChat', (tester) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    var opened = 0;
    await _pumpOverlay(tester, service, onOpenFullChat: () => opened++);

    await tester.tap(find.byIcon(Icons.open_in_new));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('pull-down on the header collapses', (tester) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    var collapsed = 0;
    await _pumpOverlay(tester, service, onCollapse: () => collapsed++);

    // Below the threshold: no collapse.
    await tester.drag(
      find.byKey(const ValueKey('faChatOverlayHandle')),
      const Offset(0, 30),
    );
    await tester.pump();
    expect(collapsed, 0);

    // Past the 48px threshold: collapses.
    await tester.drag(
      find.byKey(const ValueKey('faChatOverlayHandle')),
      const Offset(0, 100),
    );
    await tester.pump();
    expect(collapsed, 1);
  });

  testWidgets('new messages keep the transcript scrolled to the bottom', (
    tester,
  ) async {
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    for (var i = 0; i < 40; i++) {
      service.messages.add(FahChatMessage(role: 'user', content: 'q$i'));
    }
    await _pumpOverlay(tester, service);

    service.messages.add(
      FahChatMessage(role: 'assistant', content: 'latest answer'),
    );
    service.setApprovalMode(ApprovalMode.yolo); // any notifyListeners trigger
    await tester.pump();
    await tester.pump();

    expect(find.text('latest answer'), findsOneWidget);
  });

  testWidgets('assistant markdown renders sandbox images from the env', (
    tester,
  ) async {
    // A 2×2 teal/indigo PNG (76 bytes), generated once offline.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAE0lEQVR4nGPQvbIfiBga'
      'e34AEQAw3weL9bEH6gAAAABJRU5ErkJggg==',
    );
    final service = _scriptedService(const []);
    addTearDown(service.dispose);
    await service.env.writeBinaryFile(
      'generated/x.png',
      Uint8List.fromList(png),
    );
    service.messages.add(
      FahChatMessage(
        role: 'assistant',
        content: 'Here it is:\n\n![teal pixel](generated/x.png)',
      ),
    );
    await _pumpOverlay(tester, service);

    // The env read + image codec resolve on the real event loop; each
    // resolved image needs another layout pass.
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      }
    });
    await tester.pump();

    final image = find.byWidgetPredicate(
      (widget) => widget is Image && widget.image is MemoryImage,
    );
    expect(image, findsOneWidget);

    // Tap opens the fullscreen preview.
    await tester.tap(image);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    Navigator.of(tester.element(find.byType(InteractiveViewer))).pop();
    await tester.pumpAndSettle();
  });
}
