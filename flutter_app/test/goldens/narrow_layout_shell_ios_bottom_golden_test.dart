// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// iOS bottom-layout contract for the narrow (phone) Duo shell.
///
/// The phone shell floats its navigation dock OVER the section lists
/// (`extendBody`), and the iOS keyboard must lift the chat composer above
/// the message input. These goldens seed iPhone-typical metrics — home
/// indicator (padding.bottom 34) and keyboard viewInsets (36) — and pin
/// the corrected behavior:
///
/// - section lists reserve the dock's occupied height as scroll padding,
///   so the final rows are reachable above the pill (chats, activity);
/// - with the keyboard up, the chat composer sits fully above it;
/// - a pointer-down on the transcript drops the composer focus (the
///   platform then hides the keyboard) and the frame returns.
///
/// Desktop never runs the narrow scaffold, and the keyboard gate reads
/// ambient view insets (always 0 on desktop), so desktop frames are
/// byte-identical — the existing suites cover that.
library;

import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/screens/settings_navigation.dart'
    show SettingsCategoryPanel;
import 'package:fa/ui/widgets/messenger_navigation_controls.dart'
    show MessengerBottomNavigation;
import 'package:fa/ui/widgets/messenger_section_header.dart'
    show MessengerFloatingDockInsets;
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride, TargetPlatform;
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

ChatListEntry _conversation(String id, String title, DateTime activity) {
  return ChatListEntry(
    id: ChatEntryId.local(id),
    kind: ChatListEntryKind.localAgent,
    title: title,
    preview: 'A conversation row scrolling under the glass dock.',
    folderName: 'fa',
    folderPath: '/work/fa',
    createdAt: activity,
    lastActivity: activity,
    localMessageCount: 2,
  );
}

/// iPhone-typical notch/home-indicator profile: top viewPadding 59, home
/// indicator 34. Desktop seeds none of these — the narrow scaffold never
/// builds there.
void _seedIphoneInsets(WidgetTester tester) {
  tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
}

Future<FlutterSessionManager> _pumpNarrowShell(
  WidgetTester tester, {
  required List<ChatListEntry> conversations,
  int activitySessions = 0,
}) async {
  final env = MemoryExecutionEnv(cwd: '/work/fa');
  final service = _fakeService(env);
  service.messages
    ..add(FahChatMessage(role: 'user', content: 'Open the chat on the phone.'))
    ..add(
      FahChatMessage(
        role: 'assistant',
        content:
            'The composer rides above the keyboard and the transcript '
            'keeps every message reachable beneath the glass chrome.',
      ),
    );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession(
      'design-session',
      service,
      createdAt: DateTime.utc(2020, 1, 2, 15, 4),
      lastUpdatedAt: DateTime.utc(2020, 1, 2, 15, 4),
    );
  for (var index = 0; index < activitySessions; index++) {
    manager.addSession(
      'activity-$index',
      _fakeService(env),
      createdAt: DateTime.utc(2020, 2, index + 1),
      lastUpdatedAt: DateTime.utc(2020, 2, index + 1),
    );
  }
  manager.switchTo('design-session');
  _seedIphoneInsets(tester);
  await pumpGolden(
    tester,
    WideLayoutShell(
      manager: manager,
      sessionNamesStore: SessionNamesStore.inMemory({
        'design-session': 'Fa 2.0 redesign',
      }),
      chatPinStore: ChatPinStore.inMemory(accountId: 'local'),
      chatReadCursorStore: ChatReadCursorStore.inMemory(accountId: 'local'),
      localChatAdapterFactory: () => StaticChatListAdapter(conversations),
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

Rect _dockRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('narrowShellNavigation')));

void main() {
  setUpAll(ensureGoldenFonts);
  setUp(() {
    debugFaGlassAlwaysFake = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() => debugFaGlassAlwaysFake = false);

  testWidgets('iOS chats list scrolls its tail above the floating dock', (
    tester,
  ) async {
    final conversations = <ChatListEntry>[
      _conversation('design-session', 'Fa 2.0 redesign', DateTime.utc(2020, 1, 21, 15, 4)),
      for (var index = 0; index < 11; index++)
        _conversation(
          'phone-$index',
          'Phone thread ${index + 1}',
          DateTime.utc(2020, 1, 15 - index, 9),
        ),
    ];
    await _pumpNarrowShell(tester, conversations: conversations);
    final dock = _dockRect(tester);
    expect(dock.top, 746, reason: '34pt home indicator + 8pt gap + 56pt pill');

    // Scroll the conversation list to its very end: the tail rows must
    // land ABOVE the dock instead of being cut behind the pill.
    await tester.drag(
      find.byKey(const ValueKey('chatListScroll')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    final lastRow = find.text('Phone thread 11');
    expect(lastRow, findsOneWidget);
    expect(
      tester.getRect(lastRow).bottom,
      lessThanOrEqualTo(dock.top),
      reason: 'the list tail must clear the floating dock',
    );
    await expectGolden(tester, 'narrow_layout_shell_ios_bottom_chats');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS activity list scrolls its tail above the floating dock', (
    tester,
  ) async {
    final conversations = <ChatListEntry>[
      _conversation('design-session', 'Fa 2.0 redesign', DateTime.utc(2020, 1, 2, 15, 4)),
    ];
    await _pumpNarrowShell(
      tester,
      conversations: conversations,
      activitySessions: 12,
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-activity')));
    await tester.pumpAndSettle();
    final dock = _dockRect(tester);

    await tester.drag(
      find.byKey(const ValueKey('activityList')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    final lastRow = find.byKey(const ValueKey('activitySession-activity-11'));
    expect(lastRow, findsOneWidget);
    expect(
      tester.getRect(lastRow).bottom,
      lessThanOrEqualTo(dock.top),
      reason: 'the activity tail must clear the floating dock',
    );
    await expectGolden(tester, 'narrow_layout_shell_ios_bottom_activity');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS settings category list clears the home indicator', (
    tester,
  ) async {
    // Review blocker (PR #2112): the dock reserve used to be read from the
    // shell State context — ABOVE the Scaffold's extendBody MediaQuery
    // injection — so the ≥64pt gate saw the raw 34pt home indicator and the
    // reserve silently degraded to 0. On narrow the More sheet pushes the
    // SettingsScreen route (its own SafeArea, no dock); the reserve is now
    // resolved inside SettingsCategoryPanel.build, where the shell context
    // actually lives, and the route list must clear the gesture area.
    final conversations = <ChatListEntry>[
      _conversation('design-session', 'Fa 2.0 redesign', DateTime.utc(2020, 1, 2, 15, 4)),
    ];
    await _pumpNarrowShell(tester, conversations: conversations);
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-more')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('narrowShellMore-messengerPrimaryNav-settings'),
      ),
    );
    await tester.pumpAndSettle();

    // The pushed route replaces the shell chrome — no dock on this page.
    expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
    expect(find.byType(SettingsCategoryPanel), findsOneWidget);

    // The category list tail ('Others') stays above the 34pt gesture area.
    final lastCategory = find.byKey(
      const ValueKey('settingsCategory-others'),
    );
    expect(lastCategory, findsOneWidget);
    expect(
      tester.getRect(lastCategory).bottom,
      lessThanOrEqualTo(844 - 34),
      reason: 'the settings tail must clear the home-indicator gesture area',
    );
    await expectGolden(tester, 'narrow_layout_shell_ios_bottom_settings');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS keyboard lifts the chat composer above it', (tester) async {
    final conversations = <ChatListEntry>[
      _conversation('design-session', 'Fa 2.0 redesign', DateTime.utc(2020, 1, 2, 15, 4)),
    ];
    await _pumpNarrowShell(tester, conversations: conversations);
    await tester.tap(find.text('Fa 2.0 redesign').hitTestable());
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('faChatComposerTextField'));
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();
    // Simulate the iOS keyboard sliding in (36pt test frame).
    tester.view.viewInsets = const FakeViewPadding(bottom: 36);
    await tester.pumpAndSettle();

    final fieldRect = tester.getRect(field);
    expect(
      fieldRect.bottom,
      lessThanOrEqualTo(goldenSizePhone.height - 36),
      reason: 'the composer must sit fully above the keyboard',
    );
    await expectGolden(tester, 'narrow_layout_shell_ios_bottom_chat_keyboard_open');

    // The tap-to-dismiss contract: a pointer-down on the message area
    // drops the composer focus (the platform hides the keyboard), and the
    // frame returns to the keyboard-free layout.
    await tester.tap(
      find.byKey(const ValueKey('faChatTranscriptList')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final focusBefore = FocusManager.instance.primaryFocus;
    await tester.tap(
      find.byKey(const ValueKey('faChatTranscriptList')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus,
      isNot(same(focusBefore)),
      reason: 'tapping the transcript must drop the composer focus',
    );
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(
      tester.getRect(field).bottom,
      greaterThan(780),
      reason: 'the composer returns to the keyboard-free bottom lane',
    );
    await expectGolden(
      tester,
      'narrow_layout_shell_ios_bottom_chat_keyboard_dismissed',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  test('dock gate stays pinned to the dock geometry (review digest)', () {
    // The ≥64pt gate duplicates MessengerBottomNavigation.height + 8pt
    // bottomGap as a literal (an import cycle forbids sharing it in
    // production); this test is the pin so the two can never drift.
    expect(
      MessengerFloatingDockInsets.minInflatedBottom,
      MessengerBottomNavigation.height + MessengerBottomNavigation.bottomGap,
    );
  });
}
