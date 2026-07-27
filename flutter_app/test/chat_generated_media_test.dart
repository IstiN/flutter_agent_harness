// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_media_controllers.dart';

/// Fake bytes standing in for an mp3/mp4 — the fake controllers never read
/// them; they only must be non-null for the player to leave "missing".
final Uint8List _fakeMediaBytes = Uint8List.fromList(List<int>.filled(64, 7));

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
      systemPrompt: 'You are fah.',
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

/// Pumps the chat over [env] with fake media controllers and lets the
/// sandbox reads + controller creation (real async hops) land before
/// returning. Returns the created fakes for assertions.
Future<({FakeAudioController audio, FakeVideoController video})> _pumpChat(
  WidgetTester tester,
  ExecutionEnv env,
  AgentService service,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', service);
  final audio = FakeAudioController();
  final video = FakeVideoController();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(
          manager: manager,
          audioControllerFactory: (bytes) => audio,
          videoControllerFactory: (path, bytes) => video,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  });
  return (audio: audio, video: video);
}

void main() {
  testWidgets('SandboxAudioPlayer renders paused (0:00 / 0:07), play '
      'toggles, seek calls through', (tester) async {
    final controller = FakeAudioController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SandboxAudioPlayer(
            bytes: Future<Uint8List?>.value(_fakeMediaBytes),
            controllerFactory: (bytes) => controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0:00 / 0:07'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(controller.playCalls, 1);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pumpAndSettle();
    expect(controller.pauseCalls, 1);

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(controller.seeks, isNotEmpty);
    expect(controller.seeks.last, greaterThan(Duration.zero));
  });

  testWidgets('SandboxVideoPlayer renders the ready surface; tap toggles '
      'play/pause', (tester) async {
    final controller = FakeVideoController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SandboxVideoPlayer(
            path: 'generated/clip-1.mp4',
            bytes: Future<Uint8List?>.value(_fakeMediaBytes),
            controllerFactory: (path, bytes) => controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pumpAndSettle();
    expect(controller.playCalls, 1);
    // Playing now: the paused overlay icon is gone.
    expect(find.byIcon(Icons.play_circle_outline), findsNothing);

    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    expect(controller.muted, isTrue);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
  });

  testWidgets('speak and generate_music tool results render an inline '
      'audio player; a read result with a lookalike path does NOT', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('generated/speech-1.mp3', _fakeMediaBytes);
    await env.writeBinaryFile('generated/music-1.mp3', _fakeMediaBytes);
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'speak',
          content:
              'Speech saved to generated/speech-1.mp3 '
              '(64 bytes, voice "alloy", ~0s).',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'generate_music',
          content:
              'Music saved to generated/music-1.mp3 '
              '(64 bytes, 30 s requested).',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'read',
          content: 'Speech saved to generated/speech-1.mp3 (64 bytes).',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'tool',
          toolName: 'speak',
          isError: true,
          content: 'Error: quota exceeded for generated/speech-1.mp3',
        ),
      );
    final fakes = await _pumpChat(tester, env, service);

    // Exactly the two successful audio tiles get a player — read is never
    // sniffed, and error tiles are skipped.
    expect(find.byType(SandboxAudioPlayer), findsNWidgets(2));
    expect(find.byType(SandboxVideoPlayer), findsNothing);
    expect(tester.takeException(), isNull);

    // Tapping play on the first player reaches the fake controller.
    await tester.tap(
      find
          .descendant(
            of: find.byType(SandboxAudioPlayer).first,
            matching: find.byIcon(Icons.play_arrow),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(fakes.audio.playCalls, greaterThan(0));
  });

  testWidgets('any (non-read) tool result mentioning a video path renders '
      'the inline video player', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('generated/clip-1.mp4', _fakeMediaBytes);
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'tool',
        toolName: 'bash',
        content: 'rendered generated/clip-1.mp4 (64 bytes)',
      ),
    );
    await _pumpChat(tester, env, service);

    expect(find.byType(SandboxVideoPlayer), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a generate_video tool result renders the inline video '
      'player', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('generated/video-1.mp4', _fakeMediaBytes);
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'tool',
        toolName: 'generate_video',
        content:
            'Video saved to generated/video-1.mp4 '
            '(64 bytes, 8s, 1280x720).',
      ),
    );
    await _pumpChat(tester, env, service);

    expect(find.byType(SandboxVideoPlayer), findsOneWidget);
    expect(find.byType(SandboxAudioPlayer), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a speak result pointing at a deleted file shows the missing '
      'note instead of crashing', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'tool',
        toolName: 'speak',
        content: 'Speech saved to generated/gone.mp3 (0 bytes).',
      ),
    );
    await _pumpChat(tester, env, service);

    expect(find.byType(SandboxAudioPlayer), findsOneWidget);
    expect(find.text('Media file not found'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an audio sandbox link in markdown opens the player dialog', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('generated/speech-1.mp3', _fakeMediaBytes);
    final service = _fakeService(env);
    addTearDown(service.dispose);
    service.messages.add(
      FahChatMessage(
        role: 'assistant',
        content: 'Listen: [the speech](generated/speech-1.mp3)',
      ),
    );
    await _pumpChat(tester, env, service);

    // Markdown links are RichText spans, not Text widgets.
    await tester.tap(find.textContaining('the speech', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SandboxAudioPlayer),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
