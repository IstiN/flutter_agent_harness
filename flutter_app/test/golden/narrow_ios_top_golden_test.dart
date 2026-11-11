// iPhone top-clearance goldens for the three narrow-shell surfaces that
// compute their own top inset: the Apps section, a presented app view, and
// the trajectory pane inside a narrow chat.
//
// The bugs this pins (iOS batch "top"): each surface double-counted the
// phone status bar against desktop-only chrome — the shell's shared narrow
// inset vs the launcher's own SafeArea (Apps), Scaffold's primary app-bar
// slot padding vs the panel chrome's manual titlebarTop (presented app),
// and the floating glass header's safe area vs TrajectoryScreen's own
// SafeArea (trajectory). Every frame below seeds iPhone 15-like metrics
// (status bar 59, home indicator 34) on the iOS platform, so the baseline
// PNGs prove the insets apply EXACTLY ONCE: the header lands at y=59, the
// app canvas at the title band's bottom edge, the trajectory header flush
// with the chat header above it.
@TestOn('vm')
library;

import 'package:fa/apps/apps_store.dart' show JsAppInfo;
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaVisualDirection,
        TrajectoryHeader,
        buildFaTheme,
        debugFaGlassAlwaysFake;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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
      timestamp: DateTime.utc(2026, 1, 2, 3, 4),
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

/// iPhone status bar (notch) height the frames are pinned against.
const _iPhoneTopInset = 59.0;

Rect _globalRect(Finder finder) {
  final element = finder.evaluate().first;
  final renderObject = element.renderObject!;
  final box = renderObject is RenderBox
      ? renderObject
      : renderObject.parent! as RenderBox;
  final transform = box.getTransformTo(null);
  return MatrixUtils.transformPoint(transform, Offset.zero) & box.size;
}

void main() {
  setUpAll(ensureGoldenFonts);
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  /// iPhone 15-class frame: portrait 390×844, notch status bar 59, home
  /// indicator 34, NO Duo rail (plain right edge), iOS platform.
  Future<void> seedIphone(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = goldenSizePhone;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(
      top: _iPhoneTopInset,
      bottom: 34,
    );
    addTearDown(tester.view.reset);
  }

  Future<FlutterSessionManager> pumpShell(
    WidgetTester tester, {
    bool populateChats = false,
  }) async {
    final env = MemoryExecutionEnv(cwd: '/work/fa_network');
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession(
        'design-session',
        service,
        createdAt: DateTime.utc(2020, 1, 2, 15, 4),
        lastUpdatedAt: DateTime.utc(2020, 1, 2, 15, 4),
      );
    await pumpGolden(
      tester,
      WideLayoutShell(
        manager: manager,
        layoutStore: null,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        chatPinStore: ChatPinStore.inMemory(accountId: 'local'),
        chatReadCursorStore: ChatReadCursorStore.inMemory(accountId: 'local'),
        localChatAdapterFactory: populateChats
            ? () => StaticChatListAdapter([
                ChatListEntry(
                  id: ChatEntryId.local('design-session'),
                  kind: ChatListEntryKind.localAgent,
                  title: 'Fa 2.0 redesign',
                  preview: 'It stays in place with search and a calm list.',
                  createdAt: DateTime.utc(2020, 1, 2, 15, 4),
                  lastActivity: DateTime.utc(2020, 1, 2, 15, 4),
                  localMessageCount: 2,
                ),
              ])
            : null,
      ),
      size: goldenSizePhone,
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      wrap: (child) => child,
    );
    return manager;
  }

  /// QuickJS keeps a null-tree watchdog armed; let it observe disposal so
  /// the fake-async zone ends without a pending timer.
  Future<void> disposeGoldenShell(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  testWidgets('narrow_ios_top_apps: Apps header sits at the status bar', (
    tester,
  ) async {
    await seedIphone(tester);
    final manager = await pumpShell(tester);
    await manager.env.writeFile(
      'apps/demo/manifest.json',
      '{"name":"Demo","description":"A mock installed app for the top golden."}',
    );
    await manager.env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"Demo"});})();',
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.byType(AppLauncherScreen), findsOneWidget);

    // The floating header starts exactly at the status-bar line — NOT at
    // status bar + shell inset (the old 118pt double count).
    final header = _globalRect(
      find.byKey(const ValueKey('appsOverviewHeader')),
    );
    expect(header.top, _iPhoneTopInset,
        reason: 'Apps top clearance is the status bar, applied once');
    final icon = _globalRect(find.byKey(const ValueKey('messengerPageIcon')));
    expect(icon.top, 76, reason: '59 status bar + 6 header + 11 icon inset');
    // The grid keeps its own lane below the header instead of overlapping.
    final pill = _globalRect(
      find.byKey(const ValueKey('messengerPageTitlePill')),
    );
    expect(pill.bottom, lessThanOrEqualTo(header.bottom));
    final firstTile = _globalRect(find.text('Demo'));
    expect(firstTile.top, greaterThanOrEqualTo(header.bottom));
    await expectGolden(tester, 'narrow_ios_top_apps');
    await disposeGoldenShell(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'narrow_ios_top_app_view: presented canvas starts at the title band',
    (tester) async {
      await seedIphone(tester);
      final manager = await pumpShell(tester);
      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
      await tester.pumpAndSettle();
      await manager.env.writeFile(
        'apps/demo/manifest.json',
        '{"name":"Demo","description":"A mock installed app for the top golden."}',
      );
      await manager.env.writeFile(
        'apps/demo/widget.js',
        '(function(){jsr.render({type:"text",data:"Demo"});})();',
      );
      await tester.pumpAndSettle();
      await pushJsApp(
        tester.element(find.byType(AppLauncherScreen)),
        manager: manager,
        app: JsAppInfo.fromManifest(
          {'id': 'demo', 'name': 'Fa Craft'},
          bundled: false,
          fallbackId: 'demo',
        ),
        source: 'golden',
      );
      await tester.pumpAndSettle();

      // The chrome band = status-bar remainder + toolbar, and the JS canvas
      // starts EXACTLY there — not another status bar lower (the old 166pt
      // inset with a dead glass band under the toolbar).
      final canvas = tester.widget<Padding>(
        find.byKey(const ValueKey('appCanvasHeaderInset')),
      );
      expect(
        canvas.padding.resolve(TextDirection.ltr).top,
        107,
        reason: 'status-bar remainder (51) + toolbar (56), applied once',
      );
      final toolbarAction = _globalRect(
        find.byKey(const ValueKey('appFull')),
      );
      expect(toolbarAction.top, greaterThanOrEqualTo(_iPhoneTopInset - 8));
      expect(toolbarAction.bottom, lessThanOrEqualTo(107));
      final canvasContent = _globalRect(find.text('Demo'));
      expect(canvasContent.top, 107);
      await expectGolden(tester, 'narrow_ios_top_app_view');
      await disposeGoldenShell(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'narrow_ios_top_trajectory: trajectory header flush with chat header',
    (tester) async {
      await seedIphone(tester);
      final env = MemoryExecutionEnv(cwd: '/work/fa_network');
      final service = _fakeService(env);
      service.messages.add(
        FahChatMessage(role: 'user', content: 'Hello from the top golden.'),
      );
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      )..addSession(
        'design-session',
        service,
        createdAt: DateTime.utc(2020, 1, 2, 15, 4),
        lastUpdatedAt: DateTime.utc(2020, 1, 2, 15, 4),
      );
      manager.switchTo('design-session');
      // The narrow shell pushes ChatScreen as a route and adds NO iOS inset
      // of its own (_chatAreaTopInset is macOS-only), so this direct pump is
      // the exact chat-pane stack the shell presents on a phone.
      await pumpGolden(
        tester,
        Scaffold(
          backgroundColor: const Color(0xFF10141A),
          body: ChatScreen(manager: manager, sessionTitle: 'Fa 2.0 redesign'),
        ),
        size: goldenSizePhone,
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
        ),
        wrap: (child) => child,
      );

      final chatHeader = _globalRect(
        find.byKey(const ValueKey('faChatFloatingHeader')),
      );
      expect(
        chatHeader.top,
        _iPhoneTopInset,
        reason: 'the floating glass header clears the status bar once',
      );
      await tester.tap(find.byIcon(Icons.timeline));
      await tester.pumpAndSettle();

      // The trajectory page starts at the chat header's bottom edge — not
      // another status bar lower (the old double SafeArea, 162 + 59).
      final trajectoryHeader = _globalRect(find.byType(TrajectoryHeader));
      expect(
        trajectoryHeader.top,
        chatHeader.bottom,
        reason: 'no second top inset between the chat chrome and trajectory',
      );
      expect(find.byIcon(Icons.close), findsWidgets);
      await expectGolden(tester, 'narrow_ios_top_trajectory');
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
