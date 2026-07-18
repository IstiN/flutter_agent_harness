import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/file_browser.dart';
import 'package:flutter_agent_example/session_sidebar.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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
  );
}

void _useWideSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
}

Finder _sidebarListTiles() => find.descendant(
  of: find.byType(SessionSidebar),
  matching: find.byType(ListTile),
);

void main() {
  group('ChatScreen side panels', () {
    testWidgets('wide: left sidebar and right files panel toggle '
        'independently', (tester) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(service: _fakeService(env))),
      );
      await tester.pumpAndSettle();

      // The session sidebar is open by default, docked on the left edge;
      // the files panel starts closed.
      expect(find.byType(SessionSidebar), findsOneWidget);
      expect(tester.getTopLeft(find.byType(SessionSidebar)).dx, 0);
      expect(find.byType(FileBrowser), findsNothing);

      // Opening the files panel keeps the sidebar open.
      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsOneWidget);
      expect(find.byType(SessionSidebar), findsOneWidget);
      expect(tester.getTopLeft(find.byType(FileBrowser)).dx, greaterThan(1000));

      // Closing the sidebar keeps the files panel open.
      await tester.tap(find.byTooltip('Sessions & model'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionSidebar), findsNothing);
      expect(find.byType(FileBrowser), findsOneWidget);

      // And back: the files panel survives the sidebar round-trip.
      await tester.tap(find.byTooltip('Sessions & model'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionSidebar), findsOneWidget);
      expect(find.byType(FileBrowser), findsOneWidget);
    });

    testWidgets('wide: model card opens settings mid-chat; applying switches '
        'the backend and keeps the transcript', (tester) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      final service = _fakeService(env);
      await service.initialize();
      // The agent loop consumes its event stream on the real event loop,
      // which the widget test's fake zone only drives inside runAsync.
      await tester.runAsync(() async {
        await service.sendText('hello');
        await service.waitForIdle();
      });

      await tester.pumpWidget(MaterialApp(home: ChatScreen(service: service)));
      await tester.pumpAndSettle();

      // The model card shows the current backend.
      expect(find.text('test-model'), findsWidgets);

      // Tapping it opens the connection settings mid-chat.
      await tester.tap(
        find.descendant(
          of: find.byType(SessionSidebar),
          matching: find.byType(Card),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'new-model-2',
      );
      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // The backend switched…
      expect(service.providerKind, 'openai-completions');
      expect(service.modelId, 'new-model-2');
      expect(find.text('Settings'), findsNothing);
      // …and the visible transcript survived.
      expect(service.messages, hasLength(2));
      expect(service.messages[0].content, 'hello');
    });

    testWidgets('wide: sessions list renders; new session clears the chat; '
        'tapping a session loads it back', (tester) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      final service = _fakeService(env);
      await service.initialize();
      // The agent loop consumes its event stream on the real event loop,
      // which the widget test's fake zone only drives inside runAsync.
      await tester.runAsync(() async {
        await service.sendText('first question');
        await service.waitForIdle();
      });
      final firstSession = (await service.listSessions()).single;

      await tester.pumpWidget(MaterialApp(home: ChatScreen(service: service)));
      await tester.pumpAndSettle();
      expect(_sidebarListTiles(), findsOneWidget);
      expect(service.messages, hasLength(2));

      // "New session" clears the chat and persists a fresh session.
      await tester.tap(
        find.descendant(
          of: find.byType(SessionSidebar),
          matching: find.byTooltip('New session'),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.messages, isEmpty);
      expect(_sidebarListTiles(), findsNWidgets(2));

      // Tapping the previous session (list is newest-first) loads it back.
      await tester.tap(_sidebarListTiles().at(1));
      await tester.pumpAndSettle();
      expect(service.currentSessionId, firstSession.id);
      expect(service.messages, hasLength(2));
      expect(service.messages[0].role, 'user');
      expect(service.messages[0].content, 'first question');
      expect(service.messages[1].role, 'assistant');
      expect(service.messages[1].content, 'ok');
    });

    testWidgets('narrow: menu icon opens the sessions drawer', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(500, 900);
      addTearDown(tester.view.reset);

      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(service: _fakeService(env))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionSidebar), findsNothing);

      await tester.tap(find.byTooltip('Sessions & model'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byType(SessionSidebar), findsOneWidget);
      // The files end drawer stays closed.
      expect(find.byType(FileBrowser), findsNothing);
    });
  });
}
