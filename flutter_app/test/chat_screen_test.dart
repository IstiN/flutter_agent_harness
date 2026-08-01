import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/widgets/session_sidebar.dart';
import 'package:fa/ui/screens/settings.dart';
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
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

FlutterSessionManager _fakeManager(ExecutionEnv env) {
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('fake-session', _fakeService(env));
  return manager;
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

StreamFunction _hungResponse() {
  return (model, context, {cancelToken}) => AssistantMessageEventStream();
}

void main() {
  group('chatImageMessageSource', () {
    test('web rides a data: URI — no dart:io temp file (regression: '
        'getTemporaryDirectory threw on every chat sync on web)', () async {
      final source = await chatImageMessageSource(
        3,
        Uint8List.fromList([1, 2, 3]),
        isWeb: true,
      );
      expect(source, 'data:image/png;base64,AQID');
    });
  });

  group('ChatScreen side panels', () {
    testWidgets('wide: left sidebar and right files panel toggle '
        'independently', (tester) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
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

      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', service);
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(manager: manager, registry: registry),
        ),
      );
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

      // The default-chat-model flow: pick the provider, enter a model,
      // apply (keyless custom endpoint — no key needed).
      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'new-model-2',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // The backend switched…
      expect(service.providerKind, 'openai-completions');
      expect(service.modelId, 'new-model-2');
      // …the flow returned to the settings screen…
      expect(find.text('Settings'), findsOneWidget);
      // …and back in the chat the visible transcript survived.
      await tester.pageBack();
      await tester.pumpAndSettle();
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

      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', service);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
      await tester.pumpAndSettle();
      expect(_sidebarListTiles(), findsOneWidget);
      expect(service.messages, hasLength(2));

      // "New session" creates a fresh session and makes it active; the old
      // one stays in the manager (that's the multi-session point).
      await tester.tap(
        find.descendant(
          of: find.byType(SessionSidebar),
          matching: find.byTooltip('New session'),
        ),
      );
      await tester.pumpAndSettle();
      // Debug: check what sessions exist after "New session".
      // ignore: avoid_print
      print('Sessions after new session: ${manager.sessions.map((s) => s.id)}');
      // ignore: avoid_print
      print('Active id: ${manager.activeId}');
      expect(manager.active!.service.messages, isEmpty);
      expect(manager.sessions, hasLength(2));

      // Tapping the previous session (list is newest-first) switches back.
      await tester.tap(_sidebarListTiles().at(0));
      await tester.pumpAndSettle();
      expect(manager.activeId, 'fake-session');
      expect(manager.active!.service.messages, hasLength(2));
      expect(manager.active!.service.messages[0].role, 'user');
      expect(manager.active!.service.messages[0].content, 'first question');
      expect(manager.active!.service.messages[1].role, 'assistant');
      expect(manager.active!.service.messages[1].content, 'ok');
    });

    testWidgets('wide: deleting a session from the sidebar asks for '
        'confirmation; deleting the active one resets the chat', (
      tester,
    ) async {
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
      final active = (await service.listSessions()).single;

      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', service);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
      await tester.pumpAndSettle();
      expect(_sidebarListTiles(), findsOneWidget);
      expect(service.messages, hasLength(2));

      // The row's delete affordance asks first; cancelling keeps the row.
      await tester.tap(find.byTooltip('Delete session'));
      await tester.pumpAndSettle();
      expect(find.text('Delete session?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_sidebarListTiles(), findsOneWidget);
      expect((await service.listSessions()), hasLength(1));

      // Confirming deletes the ACTIVE session: the manager switches to the
      // most recent remaining session, or creates a fresh one if none remain.
      await tester.tap(find.byTooltip('Delete session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(manager.active?.service.messages ?? [], isEmpty);
      expect(manager.activeId, isNot(active.id));
      final sessions = await service.listSessions();
      expect(sessions, hasLength(1));
      expect(manager.activeId, isNotNull);
      expect(_sidebarListTiles(), findsOneWidget);
    });

    testWidgets('narrow: menu icon opens the sessions drawer', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(500, 900);
      addTearDown(tester.view.reset);

      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
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

    testWidgets(
      'narrow: settings screen opens from the gear and fits a phone screen '
      'without overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);

        final env = MemoryExecutionEnv();
        await tester.pumpWidget(
          MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Connection settings'));
        await tester.pumpAndSettle();

        expect(find.text('Settings'), findsOneWidget);
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        // A RenderFlex overflow would throw here.
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('open_app: the screen installs the launcher and the tool '
        'navigates to the app', (tester) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/demo/manifest.json',
        '{"id":"demo","name":"Demo App"}',
      );
      await env.writeFile(
        'apps/demo/widget.js',
        '(function(){jsr.render({type:"text",data:"hi"});})();',
      );
      final manager = _fakeManager(env);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
      await tester.pumpAndSettle();

      // The chat screen installed its launcher: the tool is registered.
      final service = manager.active!.service;
      final tool = service.toolsForTest
          .where((t) => t.name == 'open_app')
          .cast<AgentTool>()
          .single;

      // Invoking it (as the agent loop would) pushes the app view — the same
      // navigation a sidebar tap performs. The launcher is fire-and-forget
      // (the push completes only when the user leaves the app), so give the
      // navigation chain real time to reach Navigator.push. The JS engine
      // booting in JsAppView must start inside runAsync: its JavaScriptCore
      // runtime registers periodic timers, which have to be REAL timers —
      // under fake time they never settle.
      await tester.runAsync(() async {
        await tool.execute({'id': 'demo'}, null, null);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      // The route is pushed but its entrance transition runs on the fake
      // clock, frozen inside runAsync — advance it now so the route comes
      // onstage.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JsAppView), findsOneWidget);

      // Tear the route down on the real loop too, so the engine disposes.
      await tester.runAsync(() async {
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
    });

    testWidgets('the composer send button becomes stop while streaming', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      final service = AgentService(
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
          streamFunction: _hungResponse(),
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
      manager.addSession('hung', service);
      addTearDown(service.dispose);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
      await tester.pumpAndSettle();

      unawaited(service.sendText('hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(service.isStreaming, isTrue);
      // App bar stop + composer stop.
      expect(find.byIcon(Icons.stop), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.stop).last);
      await tester.pumpAndSettle();
      expect(service.isStreaming, isFalse);
      // Let the Live Activity end timer (4 s) fire so nothing is pending.
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('ChatScreen thinking bubble', () {
    testWidgets('collapsed thinking shows the TAIL of the reasoning', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = _fakeManager(env);
      manager.active!.service.messages.add(
        FahChatMessage(
          role: 'thinking',
          content: [
            for (var i = 1; i <= 14; i++) 'reasoning line $i',
          ].join('\n'),
        ),
      );
      await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
      await tester.pumpAndSettle();

      // Collapsed: the newest reasoning (lines 7-14) is visible, the
      // preamble is not.
      expect(find.textContaining('reasoning line 14'), findsOneWidget);
      expect(find.textContaining('reasoning line 7'), findsOneWidget);
      expect(find.textContaining('reasoning line 6'), findsNothing);

      // Expand shows everything.
      await tester.tap(find.text('Show all (14)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('reasoning line 1\n'), findsOneWidget);
    });
  });
}
