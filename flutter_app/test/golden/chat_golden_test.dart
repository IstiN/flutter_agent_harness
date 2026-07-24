/// Golden (screenshot) tests for the chat surface: `lib/chat_screen.dart`
/// (the full `ChatScreen` on the wide layout) and `lib/fa_mark.dart`.
///
/// Messages are injected straight into `AgentService.messages` (the pattern
/// from `app_theme_test.dart`) so no agent run, network, or clock leaks into
/// the snapshots; the fakes below are copied verbatim from
/// `chat_screen_test.dart`.
///
/// The left session sidebar is collapsed before every snapshot: its apps
/// section seeds bundled demos from assets on the real event loop, which is
/// inherently racy in widget tests — and the sidebar has its own golden file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/agent_service.dart';
import 'package:fa/app_theme.dart';
import 'package:fa/chat_screen.dart';
import 'package:fa/fa_mark.dart';
import 'package:fa/flutter_session_manager.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
// Platform-interface fakes for path_provider (transitive deps — kept out of
// pubspec on purpose; the app never imports them directly).
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'golden_test_helper.dart';

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
/// the wide surface, then collapses the left sidebar (see the file doc).
Future<void> _pumpChatScreen(WidgetTester tester, AgentService service) async {
  final manager = FlutterSessionManager(
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  )..addSession('fake-session', service);
  await pumpGolden(
    tester,
    ChatScreen(manager: manager),
    size: goldenSizeWide,
    wrap: (child) => child,
  );
  await _collapseSidebar(tester);
}

Future<void> _collapseSidebar(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Sessions & model'));
  await tester.pumpAndSettle();
}

void main() {
  group('ChatScreen goldens', () {
    testWidgets('empty chat screen', (tester) async {
      await _pumpChatScreen(tester, _fakeService(MemoryExecutionEnv()));
      await expectGolden(tester, 'chat_empty');
    });

    testWidgets('conversation: user + assistant + tool messages', (
      tester,
    ) async {
      final service = _fakeService(MemoryExecutionEnv());
      service.messages
        ..add(FahChatMessage(role: 'user', content: 'what is in README.md?'))
        ..add(
          FahChatMessage(
            role: 'system',
            content: '[read] {"path": "README.md"}',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'tool',
            toolName: 'read',
            content: '# Flutter Agent Harness\n\nA Dart agent core.',
          ),
        )
        ..add(
          FahChatMessage(
            role: 'assistant',
            content:
                'The README describes the **Flutter Agent Harness** project:\n'
                '- a pure Dart agent core\n'
                '- a Flutter chat example app',
          ),
        );
      await _pumpChatScreen(tester, service);
      await expectGolden(tester, 'chat_conversation');
    });

    testWidgets('collapsed thinking block', (tester) async {
      final thinking = [
        for (var i = 1; i <= 20; i++) 'reasoning step $i: checking the code',
      ].join('\n');
      final service = _fakeService(MemoryExecutionEnv());
      service.messages
        ..add(FahChatMessage(role: 'user', content: 'fix the failing test'))
        ..add(FahChatMessage(role: 'thinking', content: thinking))
        ..add(
          FahChatMessage(
            role: 'assistant',
            content: 'I found the issue in the parser.',
          ),
        );
      await _pumpChatScreen(tester, service);
      await expectGolden(tester, 'chat_thinking_collapsed');
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
        await _collapseSidebar(tester);
      });
      await expectGolden(tester, 'chat_image');
    });
  });

  group('FaMark goldens', () {
    testWidgets('standalone brand mark', (tester) async {
      await pumpGolden(tester, const FaMark(size: 64));
      await expectGolden(tester, 'chat_fa_mark');
    });
  });
}
