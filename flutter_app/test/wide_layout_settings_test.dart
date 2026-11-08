// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

@TestOn('vm')
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
}

void main() {
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  Future<void> pumpShell(
    WidgetTester tester,
    FlutterSessionManager manager, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.graphite,
          brightness: Brightness.dark,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WideLayoutShell(manager: manager),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Settings owns the sidebar and replaces the transcript with '
      'the selected category', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    service.messages.add(
      FahChatMessage(role: 'user', content: 'Transcript must be replaced'),
    );
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('settings-session', service);
    await pumpShell(tester, manager);
    expect(find.byType(ChatScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('railSettingsRow')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byKey(const ValueKey('settingsCategoryPanel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settingsCategoryContent')),
      findsOneWidget,
    );
    for (final label in [
      'Providers & Models',
      'UI Theme',
      'Accounts & Secrets',
      'Skills & Tools',
      'Agent Config',
      'Others',
    ]) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.byType(ProvidersSection), findsOneWidget);
    expect(find.byType(VisualDirectionSection), findsNothing);

    await tester.tap(find.text('UI Theme').first);
    await tester.pumpAndSettle();

    expect(find.byType(VisualDirectionSection), findsOneWidget);
    expect(find.byType(ProvidersSection), findsNothing);
    expect(find.byType(ChatScreen), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settingsBackButton')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('settingsCategoryPanel')), findsNothing);
  });

  testWidgets('phone More exposes Settings at 320 and 390 and keeps category '
      'drill-down navigation', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('settings-session', _fakeService(env));

    for (final size in const [Size(320, 700), Size(390, 844)]) {
      // Replace the whole tree so the previous iteration's pushed Settings
      // route cannot cover the next iteration's shell dock.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpShell(tester, manager, size: size);
      expect(
        find.byKey(const ValueKey('narrowSettingsButton')),
        findsNothing,
        reason: '$size',
      );
      final directSettings = find.descendant(
        of: find.byKey(const ValueKey('narrowShellNavigation')),
        matching: find.byKey(const ValueKey('messengerPrimaryNav-settings')),
      );
      expect(directSettings, findsNothing, reason: '$size');
      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-more')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('narrowShellMore-messengerPrimaryNav-settings'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing, reason: '$size');
      expect(
        find.byKey(const ValueKey('settingsCategoryPanel')),
        findsOneWidget,
        reason: '$size',
      );
      expect(find.text('Providers & Models'), findsWidgets, reason: '$size');
      expect(find.text('Others'), findsWidgets, reason: '$size');

      await tester.tap(find.byKey(const ValueKey('settingsCategory-uiTheme')));
      await tester.pumpAndSettle();
      expect(find.byType(VisualDirectionSection), findsOneWidget);
      expect(find.text('UI Theme'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('settingsBackButton')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settingsCategoryPanel')),
        findsOneWidget,
      );
      expect(find.byType(VisualDirectionSection), findsNothing);
    }
  });

  testWidgets('the Apps Settings tile uses the same categorized shell', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('settings-session', _fakeService(env));
    await pumpShell(tester, manager);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('launcherCell:${LauncherLayoutStore.settingsKey}')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('settingsCategoryPanel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settingsCategoryContent')),
      findsOneWidget,
    );
    expect(find.byType(ProvidersSection), findsOneWidget);
  });
}
