/// Golden (screenshot) tests for the session sidebar:
/// `lib/ui/widgets/session_sidebar.dart`.
///
/// The populated shots are full desktop app frames ([goldenSizeDesktop]):
/// the real [ChatScreen] docks the sidebar on the left and fills the rest
/// with the chat surface, into which a fixed conversation is injected
/// straight through `AgentService.messages` (the pattern from
/// `chat_golden_test.dart`) so no agent run, network, or clock leaks into
/// the snapshots. The service/manager fakes are copied verbatim from
/// `test/session_sidebar_restore_test.dart`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/session_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

// Fakes copied verbatim from test/session_sidebar_restore_test.dart.

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
/// `build/unit_test_assets/`.
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

/// A manager with two live sessions (fixed ids — the tiles render the first
/// 8 chars) and one persisted session on disk from a "previous run". The
/// active session carries a fixed conversation so the chat panel next to
/// the sidebar looks real.
Future<FlutterSessionManager> _populatedManager(ExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  await repo.create(
    JsonlSessionCreateOptions(
      id: 'c0ffee01-restored-chat',
      cwd: 'openai-completions',
      metadata: const {'agent': 'fa', 'model': 'old-model'},
    ),
  );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('aaa00001-first-chat', _fakeService(env));
  manager.addSession('bbb00002-second-chat', _fakeService(env));
  manager.active!.service.messages
    ..add(FahChatMessage(role: 'user', content: 'what is in README.md?'))
    ..add(
      FahChatMessage(
        role: 'assistant',
        content:
            'The README describes the **Flutter Agent Harness**:\n'
            '- a pure Dart agent core\n'
            '- a Flutter chat example app',
      ),
    );
  return manager;
}

/// The app theme's `FilledButton.styleFrom(textStyle: TextStyle(fontWeight:
/// w600))` carries no `fontFamily`; the button applies it as its internal
/// `DefaultTextStyle`, so the label falls back to the engine default font —
/// the system font on device, placeholder boxes in tests. This override
/// restores the theme's own intent (`buildFahTheme` applies Inter to the
/// whole text theme) so dialog action labels aren't tofu in snapshots.
ThemeData _withInterButtonLabels() {
  final theme = buildFahTheme();
  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style?.copyWith(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}

/// The full app frame at the desktop size: the real [ChatScreen] (a
/// Scaffold) docks the sidebar on the left and shows the injected
/// conversation on the right.
Future<void> _pumpFrame(
  WidgetTester tester,
  FlutterSessionManager manager, {
  Locale locale = const Locale('en'),
  ThemeData? themeOverride,
}) {
  return pumpGolden(
    tester,
    ChatScreen(manager: manager),
    size: goldenSizeDesktop,
    locale: locale,
    wrap: themeOverride == null
        ? (child) => child
        : (child) => Theme(data: themeOverride, child: child),
  );
}

/// Waits until the whole sidebar finished loading.
///
/// `_loadApps` (unawaited from `initState`) seeds the bundled demo apps via
/// `rootBundle` — real async I/O that `pumpAndSettle` does NOT wait for (no
/// frame is scheduled between the last write and the final `setState`), so
/// the apps section would race the snapshot. Alternating `runAsync` delays
/// (the real event loop drives the seeding) with `pump` (rebuilds with
/// whatever state landed) converges deterministically.
Future<void> _settleSidebar(WidgetTester tester) async {
  for (var i = 0; i < 200 && find.text('Calculator').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  // Sanity: every section rendered before the snapshot.
  expect(find.text('test-model'), findsWidgets);
  expect(find.textContaining('aaa00001'), findsOneWidget);
  expect(find.textContaining('bbb00002'), findsOneWidget);
  expect(find.textContaining('c0ffee01'), findsOneWidget);
  expect(find.text('Calculator'), findsOneWidget);
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    // MaterialIcons ships in the test asset bundle (FontManifest) but
    // flutter_test never registers it with the engine — without this every
    // icon renders as a hollow square.
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('populated: model card, sessions, persisted, apps', (
    tester,
  ) async {
    _mockBundledAppAssets();
    final env = MemoryExecutionEnv();
    final manager = await _populatedManager(env);

    await _pumpFrame(tester, manager);
    await _settleSidebar(tester);

    await expectGolden(tester, 'sidebar_populated');
  });

  testWidgets('empty: no sessions at all', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');

    // ChatScreen requires an active session, so the empty state shoots the
    // bare sidebar at its real width.
    await pumpGolden(
      tester,
      SizedBox(
        width: kSessionSidebarWidth,
        child: SessionSidebar(manager: manager),
      ),
    );

    await expectGolden(tester, 'sidebar_empty');
  });

  testWidgets('populated sidebar in Russian', (tester) async {
    _mockBundledAppAssets();
    final env = MemoryExecutionEnv();
    final manager = await _populatedManager(env);

    await _pumpFrame(tester, manager, locale: const Locale('ru'));
    await _settleSidebar(tester);

    await expectGolden(tester, 'sidebar_populated_ru');
  });

  testWidgets('delete session confirmation dialog', (tester) async {
    _mockBundledAppAssets();
    final env = MemoryExecutionEnv();
    final manager = await _populatedManager(env);

    await _pumpFrame(tester, manager, themeOverride: _withInterButtonLabels());
    await _settleSidebar(tester);

    // The trailing delete button of the first (active) session tile.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    await expectGolden(tester, 'sidebar_delete_dialog');
  });
}
