@TestOn('vm')
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/material.dart' show Size;
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

void main() {
  setUpAll(ensureGoldenFonts);

  Future<FlutterSessionManager> pumpShell(
    WidgetTester tester, {
    Size size = goldenSizeDesktop,
    bool populateChats = false,
  }) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    service.messages
      ..add(
        FahChatMessage(
          role: 'user',
          content: 'Can you make the desktop shell feel like a messenger?',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'Done — Chats, Activity, and Apps now share one compact '
              'navigation row, with the conversation front and center.',
        ),
      )
      ..add(
        FahChatMessage(role: 'user', content: 'What can I see in Activity?'),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'Running work and recent conversations, with live status '
              'updates and a direct path back to each chat.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'user',
          content: 'And Apps no longer takes a permanent third pane?',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'Exactly. Selecting Apps gives the launcher the whole '
              'center surface at every wide size.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'user',
          content: 'Keep the conversation list familiar, please.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'It stays in place with search, chat names, session '
              'actions, and the active conversation preserved.',
        ),
      );
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession(
        'design-session',
        service,
        createdAt: DateTime.utc(2020, 1, 2, 15, 4),
        lastUpdatedAt: DateTime.utc(2020, 1, 2, 15, 4),
      );
    final titles = <String, String>{'design-session': 'Fa 2.0 redesign'};
    if (populateChats) {
      final conversations = [
        ('release-planning', 'Release planning', DateTime.utc(2020, 1, 5, 9)),
        ('research-notes', 'Research notes', DateTime.utc(2020, 1, 4, 14)),
        ('website-copy', 'Website copy review', DateTime.utc(2020, 1, 3, 11)),
        ('weekly-plan', 'Weekly planning', DateTime.utc(2020, 1, 1, 16)),
      ];
      for (final (id, title, createdAt) in conversations) {
        manager.addSession(
          id,
          _fakeService(env),
          createdAt: createdAt,
          lastUpdatedAt: createdAt,
        );
        titles[id] = title;
      }
      manager.switchTo('design-session');
    }
    final names = SessionNamesStore.inMemory(titles);
    await pumpGolden(
      tester,
      WideLayoutShell(manager: manager, sessionNamesStore: names),
      size: size,
      wrap: (child) => child,
    );
    return manager;
  }

  testWidgets('desktop Chats shell', (tester) async {
    await pumpShell(tester);
    await expectGolden(tester, 'wide_layout_shell_chats');
  });

  testWidgets('desktop Activity shell', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.widgetWithText(SidebarNavItem, 'Activity'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_activity');
  });

  testWidgets('mobile Chats shell with populated conversations', (
    tester,
  ) async {
    await pumpShell(tester, size: goldenSizePhone, populateChats: true);
    await expectGolden(tester, 'narrow_layout_shell_chats');
  });
}
