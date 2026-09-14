// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

final _sheetKey = GlobalKey<SessionChatSheetState>();

/// The launcher chat surfaces (issue #336): the iOS app's home transcript
/// is [SessionChatSheet]'s panel and [FaChatOverlay] — neither mounts the
/// full [ChatScreen] that used to own the widget-tile builder, so a
/// `widget`-role message degraded to the generic tool card there. These
/// tests pin the tile rendering on every transcript surface.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AgentService fakeService(ExecutionEnv env) {
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
          final message = AssistantMessage(
            content: const [TextContent(text: 'ok')],
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
        },
        toolRegistry: ToolRegistry(const []),
      ),
      watchExternalSessions: false,
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

  /// Seeds the replayed-transcript shape (issue #336 AC2): the tool call
  /// card that emitted the widget, the widget marker right under it, and
  /// the following assistant reply — the order `adoptBranch` splices.
  (AgentService, DynamicMessageDefinition) serviceWithWidget(
    MemoryExecutionEnv env, {
    String? bootError,
  }) {
    final service = fakeService(env);
    final definition = DynamicMessageDefinition(
      id: 'dm-hm9kguds14',
      title: 'Демо динамического сообщения',
      jsSource: 'jsr.render({type:"text",data:"hello"});',
      initialState: const {},
      heightHint: 120,
      createdAt: DateTime.now(),
    );
    service.dynamicMessages.debugAdd(definition, bootError: bootError);
    service.messages.addAll([
      FahChatMessage(
        role: 'user',
        content: 'а ты умеешь динамические сообщения делать?',
      ),
      FahChatMessage(
        role: 'tool',
        content:
            "Dynamic message 'Демо динамического сообщения' presented to the "
            'user (widget dm-hm9kguds14)',
      ),
      FahChatMessage(
        role: 'widget',
        content: 'Демо динамического сообщения',
        data: 'dm-hm9kguds14',
      ),
      FahChatMessage(role: 'assistant', content: 'Готово.'),
    ]);
    return (service, definition);
  }

  Future<void> pumpSheet(WidgetTester tester, AgentService service) async {
    final manager = FlutterSessionManager(
      env: service.env,
      sessionsRoot: '/sessions',
    )..addSession('sess-a', service);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SessionChatSheet(key: _sheetKey, manager: manager),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The launcher panel starts collapsed in tests (no persisted mode):
    // expand it so the transcript actually builds.
    _sheetKey.currentState!.expand();
    await tester.pumpAndSettle();
  }

  group('launcher sheet transcript (the iOS home chat surface)', () {
    testWidgets('mounts the interactive widget tile next to the tool card', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final (service, _) = serviceWithWidget(env);
      addTearDown(service.dispose);
      await pumpSheet(tester, service);

      expect(find.byType(DynamicWidgetTile), findsOneWidget);
      // The tile title bar shows the widget title...
      expect(find.text('Демо динамического сообщения'), findsOneWidget);
      // ...and the emitting tool card stays (audit trail, AC E3).
      expect(find.textContaining('presented to the user'), findsOneWidget);
      // AC4 (issue #378): the surface exposes the tile's ⋮ menu.
      expect(find.byTooltip('More actions'), findsOneWidget);
    });

    testWidgets('a boot failure renders the expandable error tile, never '
        'the plain card (AC3)', (tester) async {
      final env = MemoryExecutionEnv();
      final (service, _) = serviceWithWidget(env, bootError: 'engine dead');
      addTearDown(service.dispose);
      await pumpSheet(tester, service);

      expect(find.byType(DynamicWidgetTile), findsOneWidget);
      expect(find.text('Widget error'), findsOneWidget);
      // The retry affordance rides the same error tile (AC9).
      expect(find.byTooltip('Retry'), findsOneWidget);
    });
  });

  group('app-view chat overlay', () {
    // Issue #336 AC6: the same mount on every platform family.
    Future<void> mountAndExpect(
      WidgetTester tester,
      TargetPlatform platform,
    ) async {
      final env = MemoryExecutionEnv();
      final (service, _) = serviceWithWidget(env);
      addTearDown(service.dispose);
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: FaChatOverlay(service: service, onSend: (_) async {}),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // AC4 (issue #378): the overlay surface exposes the ⋮ menu too.
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(find.byType(DynamicWidgetTile), findsOneWidget);
      expect(find.text('Демо динамического сообщения'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    }

    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      testWidgets('mounts the interactive widget tile on $platform', (
        tester,
      ) async {
        await mountAndExpect(tester, platform);
      });
    }
  });
}
