/// Golden (screenshot) tests for the chat surface:
/// `lib/ui/screens/chat_screen.dart` (the full `ChatScreen`) and
/// `lib/ui/widgets/fa_mark.dart`.
///
/// Messages are injected straight into `AgentService.messages` (the pattern
/// from `app_theme_test.dart`) so no agent run, network, or clock leaks into
/// the snapshots; the fakes below are copied verbatim from
/// `chat_screen_test.dart`.
///
/// The hero conversation shot is the full chat surface: transcript, tool
/// call, code block and a collapsed thinking section. There is no left
/// sessions panel anymore (legacy) — sessions live in the launcher sheet.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
// Platform-interface fakes for path_provider (transitive deps — kept out of
// pubspec on purpose; the app never imports them directly).
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'golden_test_helper.dart';
import '../fake_media_controllers.dart';

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

/// A 64×64 teal→indigo gradient swatch PNG (618 bytes), generated once
/// offline and embedded so the image-attachment snapshot never touches
/// network or assets.
final Uint8List _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAACMUlEQVR42u3a2TaVcRzG'
  'cbfQWg67ipAhpUmIFCqpZJ7bUZLpJkpzUQgJIZmnsAfbtodsmaU0kCShC/A/6+j5HX'
  'XwPmu9az0X8P2cPx57PPdSz0MH6ID/CNjnGvFyGtW8HUYfh8nHbtpvN/uOm31tFj+b'
  'xX9sVC3Aaj2gNmoNtIwdVDPbDpltQaZxtcNG+5ERNcfRYccxtSHn8SFn8DtX8KDrxO'
  'D7kAG1idD+ibB+d1if+2SvO7x3MrxnMqLnw6lutanIrqnTndNqZzqmozpmotpnottn'
  'Y97OxrTNnW2bO/dmXu1860Js6wIEUNTHtogA7ddfaF6EAIr6OAFAUR/3+iMGMNRfFA'
  'AU9ZealiCAol4EMNRfbvwEART18Q0YQFEf3/BZAmi//sorDKCoTxAAFPUJ9csYwFCf'
  'KAAo6pNefoEAivqkOgHAUJ9c9xUCKOpTajGAoj6l9psE0H59ag0GUNSn1XyHAIr6tB'
  'cSgKA+vRoDKOozqlcggKI+o0oAMNRnVq1CAEV9ViUGUNRnVf7AAIb67OcYQFGf82wN'
  'AijqZQBB/dUKDKCoN1T8hACKekO5AGCov1a+DgEU9blPMYCiPvfJLwxgqM8TABT11x'
  '9vQABFvQwgqL/x6DcEUNTnCwCK+vyHIkD79TcfbEIARX2BAKCoL7j/BwMY6m8JAIr6'
  'wntbEEBRLwIY6ovubkMARX1xGQZQ1BeX7UgA7deX3MEAivpSAUBRX3r7r/7c1QE64N'
  '92ATXq/Gi3ONqSAAAAAElFTkSuQmCC',
);

/// Off the web, `chatImageMessageSource` writes attached-image bytes into
/// path_provider's temp directory. There is no plugin implementation in a
/// widget test (and on macOS path_provider talks pigeon, not a plain
/// MethodChannel), so the platform interface is replaced outright.
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this._tempPath);

  final String _tempPath;

  @override
  Future<String?> getTemporaryPath() async => _tempPath;
}

/// Pumps the full [ChatScreen] as the app home (it is a Scaffold itself) at
/// [size] — no left sessions panel exists anymore (legacy); the snapshot is
/// the chat surface itself.
Future<void> _pumpChatScreen(
  WidgetTester tester,
  AgentService service, {
  Size size = goldenSizeWide,
}) async {
  final manager = FlutterSessionManager(
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  )..addSession('fake-session', service);
  await pumpGolden(
    tester,
    ChatScreen(manager: manager),
    size: size,
    wrap: (child) => child,
  );
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

  group('ChatScreen goldens', () {
    testWidgets('empty chat screen', (tester) async {
      await _pumpChatScreen(tester, _fakeService(MemoryExecutionEnv()));
      await expectGolden(tester, 'chat_empty');
    });

    testWidgets('conversation — light theme', (tester) async {
      final service = _fakeService(MemoryExecutionEnv());
      service.messages
        ..add(
          FahChatMessage(
            role: 'user',
            content:
                'the auth integration test fails after my refactor — can you '
                'take a look?',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'assistant',
            content:
                'Found it — the test still calls the old two-argument '
                '`signIn`:\n'
                '\n'
                '```dart\n'
                'test(\'signs in anonymously\', () async {\n'
                '  final session = await auth.signIn();\n'
                '  expect(session.token, isNotNull);\n'
                '});\n'
                '```\n'
                '\n'
                'Patched `integration_test/auth_test.dart` — the suite is '
                'green again.',
          ),
        );
      final manager = FlutterSessionManager(
        env: MemoryExecutionEnv(),
        sessionsRoot: '/sessions',
      )..addSession('fake-session', service);
      await pumpGolden(
        tester,
        ChatScreen(manager: manager),
        size: goldenSizeDesktop,
        theme: buildFahThemeLight(),
        wrap: (child) => child,
      );
      await expectGolden(tester, 'chat_conversation_light');
    });

    testWidgets('hero: conversation with sidebar, tool call, code block, '
        'collapsed thinking', (tester) async {
      final env = MemoryExecutionEnv();
      final service = _fakeService(env);
      service.messages
        ..add(
          FahChatMessage(
            role: 'user',
            content:
                'the auth integration test fails after my refactor — can you '
                'take a look?',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'thinking',
            content: [
              'Let me trace through the auth flow.',
              'The refactor made the token parameter optional…',
              '…but the test may still pass it positionally.',
              'Checking the call sites first:',
              '  - lib/auth.dart: signIn({token})',
              '  - integration_test/auth_test.dart: old two-arg call',
              'So the expectation is stale, not the implementation.',
              'I will read the test to confirm the exact mismatch,',
              'then update the expectation to the new signature',
              'and re-run the suite to make sure it is green.',
              'Nothing else touches signIn directly —',
              'the provider wrapper goes through the facade.',
              'Risk is low: test-only change, no behavior diff.',
              'Plan: read → patch expectation → verify.',
            ].join('\n'),
          ),
        )
        ..add(
          FahChatMessage(
            role: 'system',
            content: '[read] {"path": "integration_test/auth_test.dart"}',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'tool',
            toolName: 'read',
            content:
                '12  test(\'signs in anonymously\', () async {\n'
                '13    final session = await auth.signIn(\'token\');\n'
                '14    expect(session.token, isNotNull);\n'
                '15  });',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'assistant',
            content:
                'Found it — the test still calls the old two-argument '
                '`signIn`:\n'
                '\n'
                '```dart\n'
                'test(\'signs in anonymously\', () async {\n'
                '  final session = await auth.signIn();\n'
                '  expect(session.token, isNotNull);\n'
                '});\n'
                '```\n'
                '\n'
                'Patched `integration_test/auth_test.dart` — the suite is '
                'green again.',
          ),
        );

      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('7b21e04d-notes-app', _fakeService(env))
        ..addSession('f3a9c1d4-auth-test-fix', service);

      await pumpGolden(
        tester,
        ChatScreen(manager: manager),
        size: goldenSizeDesktop,
        wrap: (child) => child,
      );

      await expectGolden(tester, 'chat_conversation');
    });

    testWidgets('image attachment thumbnail', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('fah_chat_golden');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform(tmp.path);
      addTearDown(() => PathProviderPlatform.instance = previous);

      tester.view.physicalSize = goldenSizeWide;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = _fakeService(MemoryExecutionEnv());
      service.messages
        ..add(
          FahChatMessage(
            role: 'user',
            content: 'what color is this swatch?',
            imageBytes: _tinyPngBytes,
          ),
        )
        ..add(
          FahChatMessage(
            role: 'assistant',
            content: 'A teal-to-indigo gradient.',
          ),
        );
      final manager = FlutterSessionManager(
        env: MemoryExecutionEnv(),
        sessionsRoot: '/sessions',
      )..addSession('fake-session', service);

      // The message sync writes the temp file and decodes the image on the
      // real event loop — runAsync lets both finish between pumps.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatScreen(manager: manager),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        // The image widget only exists after the messages render above; its
        // file decode is another real-async hop before it can paint.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pumpAndSettle();
      });
      await expectGolden(tester, 'chat_image');
    });

    testWidgets('generated image — inline under the tool tile and in the '
        'markdown reply', (tester) async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('generated/image-1.png', _tinyPngBytes);
      final service = _fakeService(env);
      service.messages
        ..add(
          FahChatMessage(
            role: 'user',
            content: 'draw me a teal-to-indigo gradient swatch',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'tool',
            toolName: 'generate_image',
            content:
                'Generated image saved to generated/image-1.png '
                '(618 bytes, 1024x1024). Reference it as '
                '![image](generated/image-1.png) to display it inline in '
                'the chat.',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'assistant',
            content:
                'Here is the swatch:\n\n'
                '![teal-to-indigo gradient swatch](generated/image-1.png)',
          ),
        );
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', service);

      tester.view.physicalSize = goldenSizeWide;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The env read + image codec resolve on the real event loop; each
      // resolved image needs another layout pass before it can paint.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatScreen(manager: manager),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();
        }
        await tester.pumpAndSettle();
      });
      await expectGolden(tester, 'chat_generated_image');
    });

    testWidgets('generated media — audio player under the speak tile and a '
        'video player under a bash tile', (tester) async {
      final env = MemoryExecutionEnv();
      final fakeBytes = Uint8List.fromList(List<int>.filled(64, 7));
      await env.writeBinaryFile('generated/speech-1.mp3', fakeBytes);
      await env.writeBinaryFile('generated/clip-1.mp4', fakeBytes);
      final service = _fakeService(env);
      service.messages
        ..add(
          FahChatMessage(
            role: 'user',
            content: 'say hi out loud, then render a 2s teal clip',
          ),
        )
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
            toolName: 'bash',
            content: 'rendered generated/clip-1.mp4 (64 bytes)',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'assistant',
            content: 'Done — the voice line and the clip are above.',
          ),
        );
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', service);

      tester.view.physicalSize = goldenSizeWide;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The env reads + controller creation resolve on the real event loop
      // (same dance as the generated-image shot); the players themselves are
      // deterministic fakes (paused at 0:00, fixed 0:07 duration).
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatScreen(
              manager: manager,
              audioControllerFactory: (bytes) => FakeAudioController(),
              videoControllerFactory: (path, bytes) => FakeVideoController(),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();
        }
        await tester.pumpAndSettle();
      });
      expect(find.byType(SandboxAudioPlayer), findsOneWidget);
      expect(find.byType(SandboxVideoPlayer), findsOneWidget);
      expect(find.text('0:00 / 0:07'), findsOneWidget);
      await expectGolden(tester, 'chat_generated_media');
    });
  });

  group('FaMark goldens', () {
    testWidgets('standalone brand mark', (tester) async {
      await pumpGolden(tester, const FaMark(size: 64));
      await expectGolden(tester, 'chat_fa_mark');
    });
  });
}
