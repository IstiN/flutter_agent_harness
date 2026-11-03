import 'dart:async';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/material.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/services/flutter_session_manager.dart';
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
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
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

StreamFunction _hungResponse() {
  return (model, context, {cancelToken}) => AssistantMessageEventStream();
}

void main() {
  group('ChatScreen side panels', () {
    testWidgets('wide: the files panel toggles; no sessions sidebar anywhere', (
      tester,
    ) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
      );
      await tester.pumpAndSettle();

      // The legacy left sessions sidebar is gone for good (sessions are
      // managed by the launcher's chat sheet); the files panel starts closed.
      expect(find.byType(FileBrowser), findsNothing);

      await tester.tap(find.byTooltip('Open files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsOneWidget);
      expect(tester.getTopLeft(find.byType(FileBrowser)).dx, greaterThan(1000));

      // Toggle-as-part-of-panel: the header entry hides while open; the
      // band's X is the close toggle.
      expect(find.byTooltip('Open files'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('filesAppClose')));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);
      expect(find.byTooltip('Open files'), findsOneWidget);
    });

    testWidgets('wide: the Files icon is the RIGHTMOST chat-header action', (
      tester,
    ) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
      );
      await tester.pumpAndSettle();

      final files = find.byTooltip('Open files');
      final copy = find.byTooltip('Copy session');
      expect(files, findsOneWidget);
      expect(copy, findsOneWidget);
      // The header folder icon sits at the tail of the action row: right
      // of copy (and any host widgets between them).
      expect(
        tester.getTopRight(files).dx,
        greaterThan(tester.getTopRight(copy).dx),
      );
      // And the panel's own X — not the header icon — closes it. It
      // leads the band's search capsule, and the header entry is gone
      // while the panel is open.
      await tester.tap(files);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Open files'), findsNothing);
      expect(find.byKey(const ValueKey('filesAppClose')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('filesAppClose'))).right,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('filesAppSearch'))).left,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('filesAppClose')));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);
    });

    testWidgets('wide: no settings gear in the chat bar (sidebar owns it)', (
      tester,
    ) async {
      _useWideSurface(tester);
      final env = MemoryExecutionEnv();
      final service = _fakeService(env);
      await service.initialize();
      await tester.runAsync(() async {
        await service.sendText('hello');
        await service.waitForIdle();
      });

      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', service);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
      await tester.pumpAndSettle();

      // The chat-bar gear is gone by design: settings open from the
      // sidebar nav / apps panel. Files and copy remain app-bar actions.
      expect(find.byTooltip('Connection settings'), findsNothing);
      expect(find.byTooltip('Open files'), findsOneWidget);
      expect(service.messages, hasLength(2));
      expect(service.messages[0].content, 'hello');
      // The chat list's initial scroll-to-end timer fires post-asserts;
      // pump it out so no FakeTimer stays pending at teardown.
      await tester.pumpAndSettle();
    });

    testWidgets(
      'narrow: no settings gear; the chat bar fits a phone without overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);

        final env = MemoryExecutionEnv();
        await tester.pumpWidget(
          MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
        );
        await tester.pumpAndSettle();

        expect(find.byTooltip('Connection settings'), findsNothing);
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
      // The runtime's deferred native release is a zero-delay Timer: unmount
      // the tree and elapse fake time so it fires instead of tripping the
      // timers-pending invariant.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
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
          systemPrompt: 'You are Fa.',
          streamFunction: _hungResponse(),
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

  group('ChatScreen floating glass chrome', () {
    testWidgets(
      'transcript extends beneath chrome and both ends stay reachable in every direction',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1100, 700);
        addTearDown(tester.view.reset);
        fa_ui.debugFaGlassAlwaysFake = true;
        addTearDown(() => fa_ui.debugFaGlassAlwaysFake = false);

        for (final direction in fa_ui.FaVisualDirection.values) {
          final env = MemoryExecutionEnv();
          final service = _fakeService(env);
          for (var index = 0; index < 16; index++) {
            service.messages.add(
              FahChatMessage(
                role: index.isEven ? 'user' : 'assistant',
                content: index == 0
                    ? 'message 0 oldest'
                    : index == 15
                    ? 'message 15 newest'
                    : 'Transcript message $index with enough content to scroll.',
              ),
            );
          }
          final manager = FlutterSessionManager(
            env: env,
            sessionsRoot: '/sessions',
          )..addSession('glass-session', service);
          await tester.pumpWidget(
            MaterialApp(
              theme: fa_ui.buildFaTheme(
                direction: direction,
                brightness: Brightness.dark,
              ),
              home: ChatScreen(
                manager: manager,
                projectLabel: 'Personal',
                onProjectTap: () {},
                modelChip: const Text('test-model'),
                chipMenuLabel: 'test-model',
              ),
            ),
          );
          await tester.pumpAndSettle();

          final header = find.byKey(const ValueKey('faChatFloatingHeader'));
          final composer = find.byKey(const ValueKey('faChatFloatingComposer'));
          final transcript = find.byKey(const ValueKey('faChatTranscriptList'));
          expect(header, findsOneWidget);
          expect(composer, findsOneWidget);
          final headerRect = tester.getRect(header);
          final avatar = find.byKey(const ValueKey('faChatHeaderAvatar'));
          final titlePill = find.byKey(const ValueKey('faChatHeaderTitlePill'));
          expect(
            tester.getCenter(avatar).dx,
            closeTo(headerRect.center.dx, .5),
          );
          expect(
            tester.getCenter(titlePill).dx,
            closeTo(headerRect.center.dx, .5),
          );
          expect(
            tester.getRect(titlePill).top,
            greaterThanOrEqualTo(tester.getRect(avatar).bottom),
          );
          expect(
            tester.getRect(titlePill).width,
            lessThan(headerRect.width * .6),
          );
          expect(find.text('test-model'), findsOneWidget);
          expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
          expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
          final copySurface = find
              .ancestor(
                of: find.byIcon(Icons.copy_outlined),
                matching: find.byType(fa_ui.FaHeaderCircularAction),
              )
              .first;
          expect(tester.getRect(copySurface).width, 40);
          expect(tester.getRect(copySurface).height, 40);
          expect(
            tester.getRect(copySurface).left,
            greaterThan(headerRect.center.dx),
          );
          expect(tester.getRect(transcript).top, closeTo(headerRect.top, .5));
          expect(tester.getRect(transcript).bottom, closeTo(700, .5));
          expect(tester.getRect(composer).bottom, closeTo(692, .5));
          expect(
            tester
                .getRect(
                  find.byKey(const ValueKey('faChatBottomEnvironmentFade')),
                )
                .bottom,
            closeTo(700, .5),
          );
          expect(
            tester.getRect(find.textContaining('message 15 newest')).bottom,
            lessThanOrEqualTo(tester.getRect(composer).top),
          );

          final scrollable = tester.widget<Scrollable>(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
          );
          expect(
            scrollable.controller!.position.maxScrollExtent,
            greaterThan(0),
          );
          scrollable.controller!.jumpTo(
            scrollable.controller!.position.maxScrollExtent,
          );
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.textContaining('message 0 oldest')).top,
            greaterThanOrEqualTo(tester.getRect(header).bottom),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  });

  group('ChatScreen composer drafts', () {
    testWidgets('session switching and narrow-route remount restore only the '
        'owning session\'s text and staged attachment', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      final a = _fakeService(env);
      final b = _fakeService(env);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      manager
        ..addSession('session-a', a)
        ..addSession('session-b', b)
        ..switchTo('session-a');
      final drafts = fa_ui.ChatComposerDraftStore();

      Future<void> pumpChat() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ChatScreen(manager: manager, draftStore: drafts),
          ),
        );
        await tester.pumpAndSettle();
      }

      String fieldText() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;

      await pumpChat();
      await tester.enterText(find.byType(TextField), 'A unsent draft');
      await tester
          .state<fa_ui.ChatComposerState>(find.byType(fa_ui.ChatComposer))
          .stageDroppedFiles([
            (
              name: 'a-draft.txt',
              bytes: Uint8List.fromList([1, 3, 3, 7]),
              mimeType: 'text/plain',
            ),
          ]);
      await tester.pump();
      expect(find.textContaining('a-draft.txt'), findsOneWidget);

      manager.switchTo('session-b');
      await tester.pumpAndSettle();
      expect(fieldText(), isEmpty);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(drafts.draftFor('session-b').isEmpty, isTrue);

      await tester.enterText(find.byType(TextField), 'B unsent draft');
      manager.switchTo('session-a');
      await tester.pumpAndSettle();
      expect(fieldText(), 'A unsent draft');
      expect(find.textContaining('a-draft.txt'), findsOneWidget);

      // Narrow Chat/Apps presentation replaces the route's subtree. Rebuild
      // the ChatScreen with the same manager/store, as the shell does.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Apps'))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(fa_ui.ChatComposer), findsNothing);
      await pumpChat();
      expect(fieldText(), 'A unsent draft');
      expect(find.textContaining('a-draft.txt'), findsOneWidget);
      expect(drafts.draftFor('session-b').text, 'B unsent draft');
      expect(drafts.draftFor('session-a').attachments.single.bytes, [
        1,
        3,
        3,
        7,
      ]);

      manager.switchTo('session-b');
      await tester.pumpAndSettle();
      expect(fieldText(), 'B unsent draft');
      expect(find.byIcon(Icons.close), findsNothing);
      await tester.pumpWidget(const SizedBox());
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

      // Collapsed: the newest reasoning (lines 12-14) is visible, the
      // preamble is not; the hint names the hidden remainder (issue #458).
      expect(find.textContaining('reasoning line 14'), findsOneWidget);
      expect(find.textContaining('reasoning line 12'), findsOneWidget);
      expect(find.textContaining('reasoning line 11'), findsNothing);
      expect(find.text('+11 lines'), findsOneWidget);

      // Expand shows everything.
      await tester.tap(find.text('+11 lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('reasoning line 1\n'), findsOneWidget);
    });
  });
}
