// The narrow shell's unified header bar system: chats, Apps, trajectory,
// and the opened-app view all render the SAME bar height on a phone.
//
// The chat floating glass header is the reference
// (`FaFloatingHeaderBar`: 6 + 91 + 6 = 103pt below the status bar, 162pt
// extent on the seeded iPhone frame). PR #2112 review feedback: the Apps
// section header, the trajectory pane header, and the opened-app toolbar
// each showed a DIFFERENT height than the chats bar (the trajectory block
// stacked stats + search + filters into a 210pt header; the app toolbar
// kept Material's 56pt band). These frames seed iPhone 15-like metrics
// (390x844, FakeViewPadding top 59 / bottom 34, platform iOS, TZ=UTC) and
// prove — with widget-rect asserts, one golden per header — that all four
// strips share the canonical extent and the same control rows (36pt
// circle at 76, 40pt band/pill on the 94 centerline).
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
        FaFloatingHeaderBar,
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
    tester.view.physicalSize = goldenSizePhone;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(
      top: _iPhoneTopInset,
      bottom: 34,
    );
    addTearDown(tester.view.reset);
    // The binding's invariant check runs BEFORE test tearDowns: every test
    // body clears the platform override inline before returning (same
    // pattern as narrow_ios_top_golden_test).
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

  /// The canonical bar rows every header strip must render: the strip
  /// starts at the status-bar line and spans [FaFloatingHeaderBar.barExtent];
  /// the leading circle sits at 59 + 6 + 11 = 76.
  void expectCanonicalBar(Rect bar, String label) {
    expect(bar.top, _iPhoneTopInset, reason: '$label starts at the status bar');
    expect(
      bar.height,
      FaFloatingHeaderBar.barExtent,
      reason: '$label uses the canonical bar extent (chats reference)',
    );
  }

  testWidgets('narrow_header_heights_chat: the reference glass header', (
    tester,
  ) async {
    await seedIphone(tester);
    final env = MemoryExecutionEnv(cwd: '/work/fa_network');
    final service = _fakeService(env);
    service.messages.add(
      FahChatMessage(role: 'user', content: 'Hello from the bar golden.'),
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

    final chatBar = _globalRect(
      find.byKey(const ValueKey('faChatFloatingHeader')),
    );
    expectCanonicalBar(chatBar, 'chat header');
    final avatar = _globalRect(find.byKey(const ValueKey('faChatHeaderAvatar')));
    expect(avatar.top, 76, reason: '59 status bar + 6 header + 11 icon inset');
    final pill = _globalRect(
      find.byKey(const ValueKey('faChatHeaderTitlePill')),
    );
    expect(pill.bottom, chatBar.bottom - FaFloatingHeaderBar.padVertical);
    await expectGolden(tester, 'narrow_header_heights_chat');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow_header_heights_apps: Apps strip matches the chat bar', (
    tester,
  ) async {
    await seedIphone(tester);
    final manager = await pumpShell(tester);
    await manager.env.writeFile(
      'apps/demo/manifest.json',
      '{"name":"Demo","description":"A mock installed app for the bar golden."}',
    );
    await manager.env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"Demo"});})();',
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.byType(AppLauncherScreen), findsOneWidget);

    final appsBar = _globalRect(
      find.byKey(const ValueKey('appsOverviewHeader')),
    );
    expectCanonicalBar(appsBar, 'Apps header');
    final icon = _globalRect(find.byKey(const ValueKey('messengerPageIcon')));
    expect(icon.top, 76, reason: 'same leading-circle row as the chat avatar');
    final pill = _globalRect(
      find.byKey(const ValueKey('messengerPageTitlePill')),
    );
    expect(pill.bottom, appsBar.bottom - FaFloatingHeaderBar.padVertical);
    // The grid keeps its own lane below the header instead of overlapping.
    final firstTile = _globalRect(find.text('Demo'));
    expect(firstTile.top, greaterThanOrEqualTo(appsBar.bottom));
    await expectGolden(tester, 'narrow_header_heights_apps');
    await disposeGoldenShell(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'narrow_header_heights_trajectory: pane bar equals the chat bar LIVE',
    (tester) async {
      await seedIphone(tester);
      final env = MemoryExecutionEnv(cwd: '/work/fa_network');
      final service = _fakeService(env);
      service.messages.add(
        FahChatMessage(role: 'user', content: 'Hello from the bar golden.'),
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

      final chatBar = _globalRect(
        find.byKey(const ValueKey('faChatFloatingHeader')),
      );
      await tester.tap(find.byIcon(Icons.timeline));
      await tester.pumpAndSettle();

      final trajectoryBar = _globalRect(find.byType(TrajectoryHeader));
      expect(
        trajectoryBar.top,
        chatBar.bottom,
        reason: 'the pane bar is flush with the chat header above it',
      );
      expect(
        trajectoryBar.height,
        chatBar.height,
        reason: 'the trajectory bar shares the chat bar height, live',
      );
      final pill = _globalRect(
        find.byKey(const ValueKey('trajectoryBarTitlePill')),
      );
      expect(
        pill.bottom,
        trajectoryBar.bottom - FaFloatingHeaderBar.padVertical,
      );
      expect(find.byIcon(Icons.close), findsWidgets);
      // The re-homed ledger deck (stats/search/filters) starts BELOW the
      // bar instead of inflating it (the old 210pt header block).
      final deck = _globalRect(find.text('Messages'));
      expect(deck.top, greaterThanOrEqualTo(trajectoryBar.bottom));
      await expectGolden(tester, 'narrow_header_heights_trajectory');
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'narrow_header_heights_app_view: toolbar band matches the chat bar',
    (tester) async {
      await seedIphone(tester);
      final manager = await pumpShell(tester);
      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
      await tester.pumpAndSettle();
      await manager.env.writeFile(
        'apps/demo/manifest.json',
        '{"name":"Demo","description":"A mock installed app for the bar golden."}',
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

      final band = _globalRect(
        find.byKey(const ValueKey('appPanelChromeBand')),
      );
      expectCanonicalBar(band, 'app view toolbar band');
      // The canvas starts EXACTLY at the band's bottom edge — the same
      // line the chat header extent reserves on this frame.
      final canvas = tester.widget<Padding>(
        find.byKey(const ValueKey('appCanvasHeaderInset')),
      );
      expect(
        canvas.padding.resolve(TextDirection.ltr).top,
        _iPhoneTopInset + FaFloatingHeaderBar.barExtent,
        reason: 'canvas inset = status bar + canonical bar, applied once',
      );
      final action = _globalRect(find.byKey(const ValueKey('appFull')));
      expect(
        action.center.dy,
        closeTo(band.top + 6 + 9 + 20, .5),
        reason: 'actions ride the same 94 centerline as the chat header',
      );
      final canvasContent = _globalRect(find.text('Demo'));
      expect(canvasContent.top, band.bottom);
      await expectGolden(tester, 'narrow_header_heights_app_view');
      await disposeGoldenShell(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
