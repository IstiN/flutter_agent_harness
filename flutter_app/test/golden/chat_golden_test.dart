/// Golden (screenshot) tests for the chat surface:
/// `lib/ui/screens/chat_screen.dart` (the full `ChatScreen`) and
/// `lib/ui/widgets/fa_mark.dart`.
///
/// Messages are injected straight into `AgentService.messages` (the pattern
/// from `app_theme_test.dart`) so no agent run, network, or clock leaks into
/// the snapshots; the fakes below are copied verbatim from
/// `chat_screen_test.dart`.
///
/// The hero conversation shot keeps the session sidebar OPEN: its apps
/// section seeds the bundled demo apps through `rootBundle`, which is
/// unreliable in widget tests without the `_mockBundledAppAssets` +
/// `_settleSidebar` dance (borrowed from `sidebar_golden_test.dart`). The
/// smaller states collapse the sidebar so they stay focused on the chat
/// surface itself.
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

/// Serves `rootBundle` from the asset tree `flutter test` builds into
/// `build/unit_test_assets/` (same helper as `sidebar_golden_test.dart`).
///
/// The sidebar's `_loadApps` seeds the bundled demo apps through
/// `AppsStore` → `rootBundle.loadString` (not injectable — see
/// `SessionSidebar._loadApps`). Two framework quirks make this unreliable
/// without help:
///  1. the real `flutter/assets` channel answers only in the FIRST test of
///     a process (later sends hang forever), so every test registers this
///     mock handler — the framework resets handlers per test;
///  2. `rootBundle` is a process-global `CachingAssetBundle`: a test that
///     ends with asset loads in flight leaves PENDING cached futures whose
///     continuations belonged to the dead test zone — every later
///     `loadString` of those keys hangs on the poisoned cache entry.
///     `rootBundle.clear()` drops them so each test re-reads via the mock.
void _mockBundledAppAssets() {
  rootBundle.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        if (message == null) return null;
        final key = utf8.decode(message.buffer.asUint8List());
        final file = File('build/unit_test_assets/$key');
        if (!file.existsSync()) return null;
        return ByteData.sublistView(await file.readAsBytes());
      });
}

/// Waits until the sidebar's apps section finished seeding + loading.
///
/// `_loadApps` (unawaited from `initState`) is real async I/O that
/// `pumpAndSettle` does NOT wait for (no frame is scheduled between the last
/// write and the final `setState`), so it would race the snapshot.
/// Alternating `runAsync` delays (the real event loop drives the seeding)
/// with `pump` (rebuilds with whatever state landed) converges
/// deterministically.
Future<void> _settleSidebar(WidgetTester tester) async {
  for (var i = 0; i < 200 && find.text('Calculator').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  // Sanity: the seeded apps rendered before the snapshot.
  expect(find.text('Calculator'), findsOneWidget);
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
/// [size], then collapses the left sidebar so the snapshot focuses on the
/// chat surface (the sidebar has its own golden file).
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
  await tester.tap(find.byTooltip('Sessions & model'));
  await tester.pumpAndSettle();
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

    testWidgets('hero: conversation with sidebar, tool call, code block, '
        'collapsed thinking', (tester) async {
      _mockBundledAppAssets();
      final env = MemoryExecutionEnv();
      // One persisted session from a "previous run" so the sidebar shows its
      // on-disk section next to the two live ones.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await repo.create(
        JsonlSessionCreateOptions(
          id: 'c0ffee01-weekend-plan',
          cwd: 'openai-completions',
          metadata: const {'agent': 'fa', 'model': 'old-model'},
        ),
      );

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
      await _settleSidebar(tester);
      expect(find.textContaining('f3a9c1d4'), findsOneWidget);

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
        await tester.tap(find.byTooltip('Sessions & model'));
        await tester.pumpAndSettle();
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
