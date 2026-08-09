// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

/// Pumps the chat over [env] and lets the sandbox image loads (real async
/// I/O in [MemoryExecutionEnv]) land before returning.
Future<void> _pumpChat(
  WidgetTester tester,
  ExecutionEnv env,
  AgentService service,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', service);
  // The env read and the image codec both resolve on the real event loop,
  // and each resolved image needs another layout pass — iterate
  // delay+pump until everything settles (same dance as the golden
  // image-attachment test, looped for the inline markdown images).
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  });
}

/// Images decoded from bytes (sandbox files and data: URIs) — file-backed
/// attachment thumbnails use [FileImage] and don't match.
Finder _memoryImages() => find.byWidgetPredicate(
  (widget) => widget is Image && widget.image is MemoryImage,
);

void main() {
  testWidgets('markdown images with sandbox paths render from the env; '
      'tap opens the fullscreen preview', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('generated/x.png', _tinyPngBytes);
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'assistant',
        content:
            'Here you go:\n\n![teal pixel](generated/x.png)\n\n'
            'Leading slash works too: ![again](/generated/x.png)',
      ),
    );
    await _pumpChat(tester, env, service);

    expect(_memoryImages(), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.tap(_memoryImages().first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    Navigator.of(tester.element(find.byType(InteractiveViewer))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('a missing sandbox file degrades to a dim placeholder — '
      'no throw, no red box', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'assistant',
        content: '![gone](generated/missing.png)',
      ),
    );
    await _pumpChat(tester, env, service);

    expect(_memoryImages(), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.text('gone'), findsOneWidget); // alt text as the label
    expect(tester.takeException(), isNull);
  });

  testWidgets('generate_image tool result renders the image inline under '
      'the tile; errors render nothing', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('generated/image-1.png', _tinyPngBytes);
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'generate_image',
          content:
              'Generated image saved to generated/image-1.png '
              '(67 bytes, 1024x1024). Reference it as '
              '![image](generated/image-1.png) to display it inline in the '
              'chat.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'generate_image',
          isError: true,
          content: 'Error: quota exceeded',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'read',
          content:
              'Generated image saved to generated/image-1.png '
              '(67 bytes, 1024x1024).',
        ),
      );
    await _pumpChat(tester, env, service);

    // Only the successful generate_image tile gets an inline image — the
    // error tile has no path and other tools are never sniffed.
    expect(_memoryImages(), findsOneWidget);
    expect(find.text('[ generate_image ]'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.tap(_memoryImages());
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    Navigator.of(tester.element(find.byType(InteractiveViewer))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('a generate_image result pointing at a deleted file shows '
      'the placeholder instead of crashing', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'tool',
        toolName: 'generate_image',
        content: 'Generated image saved to generated/gone.png (0 bytes).',
      ),
    );
    await _pumpChat(tester, env, service);

    expect(_memoryImages(), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
