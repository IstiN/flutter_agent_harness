// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatHost;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import '../native_test_guard.dart';

/// Skip value stamped on this file's engine-dependent tests: every one
/// boots a real JS engine (issue #184). Resolved once per isolate.
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

/// A provider that starts a run immediately and stays open until Stop.
AgentService _hungService() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026, 1, 1),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(ErrorEvent(reason: StopReason.aborted, error: partial));
      stream.end();
    });
    return stream;
  }

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
      streamFunction: fn,
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

/// Hosts the view in a wide shell's nested Apps navigator. A missing
/// widget.js gives a deterministic engine-free start error; Fa chrome is
/// independent of the JS renderer and remains fully testable.
Future<void> _pumpEmbeddedView(
  WidgetTester tester, {
  AgentService? agentService,
  Future<AgentService?> Function(FaAppMessage message)? onSendToAgent,
  bool fullChrome = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final env = MemoryExecutionEnv();
  await env.writeFile('apps/demo/manifest.json', '{}');
  final permissions = await AppPermissionsStore.load(env);
  final app = JsAppInfo.fromManifest(
    {'id': 'demo', 'name': 'Demo', if (fullChrome) 'chrome': 'full'},
    bundled: false,
    fallbackId: 'demo',
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Row(
          children: [
            const Expanded(child: Text('Main chat')),
            SizedBox(
              width: 520,
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => JsAppView(
                    app: app,
                    env: env,
                    permissionsStore: permissions,
                    agentService: agentService,
                    onSendToAgent: onSendToAgent,
                    embeddedInPanel: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _stopRun(WidgetTester tester, AgentService service) async {
  service.abort();
  for (var i = 0; i < 30 && service.isStreaming; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  await tester.pump();
}

/// End-to-end render check: boots the REAL calculator demo app
/// (test/apps/fixtures/calculator_widget.js) through the real JavaScriptCore
/// backend and renders the resulting UI tree into actual Flutter widgets
/// with the same JsonWidgetRenderer the JsAppView uses.
///
/// The engine is booted inside `tester.runAsync` (the JS backend needs the
/// real event loop); the renderer itself is synchronous.
void main() {
  group('embedded Fa chrome (engine-free)', () {
    testWidgets('wide panel Ask Fa sends app context to the bound service', (
      tester,
    ) async {
      final activeService = _hungService();
      final boundService = _hungService();
      addTearDown(activeService.dispose);
      addTearDown(boundService.dispose);
      FaAppMessage? received;

      await _pumpEmbeddedView(
        tester,
        agentService: activeService,
        onSendToAgent: (message) async {
          received = message;
          await boundService.sendText(message.text);
          return boundService;
        },
      );

      final askFab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(askFab.onPressed, isNotNull);
      expect(askFab.tooltip, isNotEmpty);

      await tester.runAsync(() async {
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.byType(TextField).last, 'make it teal');
        await tester.tap(find.byType(FilledButton));
        // Headless screenshot capture can take its full best-effort timeout;
        // the message must still arrive with the rest of the app context.
        for (var i = 0; i < 70 && received == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
      await tester.pump();

      final message = received;
      expect(message, isNotNull);
      expect(message!.text, 'make it teal');
      expect(message.appId, 'demo');
      expect(message.themeLine, isNotEmpty);
      // 520px is the Apps panel, not the 1440px shell beside it.
      expect(message.viewportLine, startsWith('Viewport: 520x'));
      expect(
        boundService.messages.any(
          (entry) => entry.role == 'user' && entry.content == 'make it teal',
        ),
        isTrue,
      );
      expect(
        activeService.messages.any((entry) => entry.content == 'make it teal'),
        isFalse,
      );
      expect(
        tester.widget<FaWorkBar>(find.byType(FaWorkBar)).service,
        same(boundService),
      );

      await _stopRun(tester, boundService);
    });

    testWidgets('wide panel streaming status and Stop are reachable', (
      tester,
    ) async {
      final service = _hungService();
      addTearDown(service.dispose);
      await _pumpEmbeddedView(
        tester,
        agentService: service,
        onSendToAgent: (_) async => service,
      );

      await tester.runAsync(() async {
        await service.sendText('work');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(service.isStreaming, isTrue);
      expect(find.byType(FaWorkBar), findsOneWidget);
      expect(find.text('Fa is working…'), findsOneWidget);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop_circle_outlined));
      for (var i = 0; i < 30 && service.isStreaming; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pump();

      expect(service.isStreaming, isFalse);
      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    });

    testWidgets('wide panel work bar expands the in-app chat overlay', (
      tester,
    ) async {
      final service = _hungService();
      addTearDown(service.dispose);
      await _pumpEmbeddedView(
        tester,
        agentService: service,
        onSendToAgent: (_) async => service,
      );
      await tester.runAsync(() async {
        await service.sendText('work');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(JsAppView), findsOneWidget);
      expect(find.byType(FaChatOverlay), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      final appBounds = tester.getRect(find.byType(JsAppView));
      final overlayBounds = tester.getRect(find.byType(FaChatOverlay));
      expect(overlayBounds.left, greaterThanOrEqualTo(appBounds.left));
      expect(overlayBounds.right, lessThanOrEqualTo(appBounds.right));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(FaChatOverlay), findsNothing);
      await _stopRun(tester, service);
    });

    testWidgets('overlay Open full chat delegates navigation to the shell', (
      tester,
    ) async {
      final service = _hungService();
      addTearDown(service.dispose);
      var revealCalls = 0;
      FaChatHost.revealActiveChat = () async => revealCalls++;
      addTearDown(() => FaChatHost.revealActiveChat = null);
      await _pumpEmbeddedView(
        tester,
        agentService: service,
        onSendToAgent: (_) async => service,
      );
      await tester.runAsync(() async {
        await service.sendText('work');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byTooltip('Open full chat'));
      await tester.pump();

      expect(revealCalls, 1);
      expect(find.byType(JsAppView), findsOneWidget);
      await _stopRun(tester, service);
    });

    testWidgets('wide full-chrome panel keeps its app menu and Ask Fa', (
      tester,
    ) async {
      await _pumpEmbeddedView(
        tester,
        fullChrome: true,
        onSendToAgent: (_) async => null,
      );

      expect(find.byType(AppBar), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('App permissions'), findsOneWidget);
      expect(find.text('Reload app'), findsOneWidget);
      expect(find.text('Close app'), findsOneWidget);
    });
  });

  group('JS engine (native quickjs/JavaScriptCore bridge)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    testWidgets('calculator demo app renders real widgets', (tester) async {
      final env = MemoryExecutionEnv();
      late final JsAppEngine engine;
      Map<String, dynamic>? tree;
      await tester.runAsync(() async {
        // Real async IO only progresses inside runAsync under flutter_test.
        final source = await File(
          'test/apps/fixtures/calculator_widget.js',
        ).readAsString();
        await env.writeFile('apps/calculator/widget.js', source);
        engine = JsAppEngine(
          app: JsAppInfo.fromManifest(
            const {'id': 'calculator', 'name': 'Calculator', 'icon': '🧮'},
            bundled: false,
            fallbackId: 'calculator',
          ),
          env: env,
          permissions: const AppPermissions(),
        );
        await engine.start();
        // Give the bridge a moment to deliver the first render.
        for (var i = 0; i < 20 && engine.tree.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        tree = engine.tree.value;
      });
      addTearDown(() async {
        await tester.runAsync(engine.dispose);
      });

      expect(tree, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final renderer = JsonWidgetRenderer(
                  theme: JsonWidgetTheme.fromAccent(
                    Theme.of(context).colorScheme.primary,
                  ),
                  onEvent: (_, _) {},
                );
                return renderer.build(tree!, context);
              },
            ),
          ),
        ),
      );

      // The calculator keypad from widget.js: digits and the equals key.
      expect(find.text('7'), findsOneWidget);
      expect(find.text('='), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
    });

    /// Pumps a two-route app (home with an "open-app" button → [JsAppView] for
    /// [appId]) and waits until the JS app renders [readyText]. Everything
    /// runs on the real event loop — the JavaScriptCore backend needs it, and
    /// its periodic timer would hang a fake-zone pumpAndSettle.
    Future<void> pumpAppRoute(
      WidgetTester tester,
      MemoryExecutionEnv env,
      String appId,
      String readyText,
    ) async {
      final permissions = await tester.runAsync(
        () => AppPermissionsStore.load(env),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => JsAppView(
                      app: JsAppInfo.fromManifest(
                        {'id': appId, 'name': appId},
                        bundled: false,
                        fallbackId: appId,
                      ),
                      env: env,
                      permissionsStore: permissions!,
                    ),
                  ),
                ),
                child: const Text('open-app'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('open-app'));
        await tester.pump();
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
          if (find.text(readyText).evaluate().isNotEmpty) break;
        }
      });
      expect(find.byType(JsAppView), findsOneWidget);
      expect(find.text(readyText), findsOneWidget);
    }

    /// A system back (what the iOS edge swipe and the Android back button
    /// deliver) plus a settle on the real event loop.
    Future<void> systemBack(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.binding.handlePopRoute();
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
    }

    /// Unmounts the app so the JS engine is disposed before teardown.
    Future<void> unmount(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    testWidgets('system back pops the app route when no jsr.onBack is '
        'registered', (tester) async {
      final env = MemoryExecutionEnv();
      await tester.runAsync(() async {
        await env.writeFile('apps/noback/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {});
    jsr.render({type: 'text', data: 'NOBACK-READY'});
  })();
  ''');
      });
      await pumpAppRoute(tester, env, 'noback', 'NOBACK-READY');

      await systemBack(tester);

      expect(find.byType(JsAppView), findsNothing);
      expect(find.text('open-app'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a consuming jsr.onBack receives the back event and keeps '
        'the route', (tester) async {
      final env = MemoryExecutionEnv();
      await tester.runAsync(() async {
        await env.writeFile('apps/keepback/widget.js', '''
  (function() {
    var backs = 0;
    jsr.onEvent(function(actionId, payload) {});
    jsr.onBack = function() {
      backs++;
      jsr.render({type: 'text', data: 'BACKS:' + backs});
      return true; // always consume — internal navigation
    };
    jsr.render({type: 'text', data: 'KEEPBACK-READY'});
  })();
  ''');
      });
      await pumpAppRoute(tester, env, 'keepback', 'KEEPBACK-READY');
      // The registration push rides the bridge right behind the first render;
      // give it a beat so PopScope flips to canPop: false.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await tester.pump();
      });

      await systemBack(tester);

      // The event reached the JS engine and the app consumed it: the route
      // stays and the app re-rendered from inside jsr.onBack.
      expect(find.byType(JsAppView), findsOneWidget);
      expect(find.text('BACKS:1'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a declining jsr.onBack lets the route pop', (tester) async {
      final env = MemoryExecutionEnv();
      await tester.runAsync(() async {
        await env.writeFile('apps/dropback/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {});
    jsr.onBack = function() { return false; };
    jsr.render({type: 'text', data: 'DROPBACK-READY'});
  })();
  ''');
      });
      await pumpAppRoute(tester, env, 'dropback', 'DROPBACK-READY');
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await tester.pump();
      });

      await systemBack(tester);

      // canPop was false, so the pop came from the back.close bridge — proof
      // the whole forward-then-close path works end to end.
      expect(find.byType(JsAppView), findsNothing);
      expect(find.text('open-app'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
      'JsAppView routes onPanUpdate via dispatchHostEvent(gesture:...) to JS '
      '(gh-1784)',
      (tester) async {
        final env = MemoryExecutionEnv();
        await tester.runAsync(() async {
          await env.writeFile('apps/panapp/widget.js', '''
  (function() {
    var moves = 0;
    jsr.onEvent(function(actionId, payload) {
      if (actionId === 'panMove') {
        moves++;
        jsr.render({
          type: 'gestureDetector',
          onPanUpdate: 'panMove',
          child: {
            type: 'sizedBox',
            width: 200,
            height: 200,
            child: {type: 'text', data: 'MOVED:' + moves}
          }
        });
      }
    });
    jsr.render({
      type: 'gestureDetector',
      onPanUpdate: 'panMove',
      child: {
        type: 'sizedBox',
        width: 200,
        height: 200,
        child: {type: 'text', data: 'PAN-READY'}
      }
    });
  })();
  ''');
        });
        await pumpAppRoute(tester, env, 'panapp', 'PAN-READY');
        await tester.runAsync(() async {
          await tester.drag(find.text('PAN-READY'), const Offset(40, 20));
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (find.textContaining('MOVED:').evaluate().isNotEmpty) break;
          }
        });
        expect(find.textContaining('MOVED:'), findsOneWidget);
        await unmount(tester);
      },
    );

    testWidgets('a widget whose eval never renders shows the boot error '
        'card with the widget id, not an infinite spinner (gh-1336)', (
      tester,
    ) async {
      final previousWarn = JsAppEngine.uiTreeWarnAfter;
      try {
        JsAppEngine.uiTreeWarnAfter = const Duration(milliseconds: 400);
        final env = MemoryExecutionEnv();
        // A SYNTAX error: the wrapper IIFE never parses, so neither the
        // runtime's inner catch nor jsr.showError can run — the exact
        // silent failure from the field report.
        await tester.runAsync(
          () => env.writeFile('apps/broken/widget.js', 'syntax error ;;; {'),
        );
        final permissions = await tester.runAsync(
          () => AppPermissionsStore.load(env),
        );
        // Same route shape as pumpAppRoute: the view (and its engine,
        // and every timer it arms) must come up INSIDE runAsync — a boot
        // in the test's fake zone leaves the runtime's native pollers
        // tracked as fake timers and trips the pending-timer invariant.
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFahTheme(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => JsAppView(
                          app: JsAppInfo.fromManifest(
                            const {'id': 'broken', 'name': 'Broken'},
                            bundled: false,
                            fallbackId: 'broken',
                          ),
                          env: env,
                          permissionsStore: permissions!,
                        ),
                      ),
                    ),
                    child: const Text('open-app'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('open-app'));
          await tester.pump();
          for (var i = 0; i < 40; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            await tester.pump();
            if (find
                .textContaining('produced no UI tree')
                .evaluate()
                .isNotEmpty) {
              break;
            }
          }
        });
        // The error card names the widget and the failure mode; no
        // spinner survives it.
        expect(find.textContaining("'broken'"), findsOneWidget);
        expect(find.textContaining('produced no UI tree'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      } finally {
        JsAppEngine.uiTreeWarnAfter = previousWarn;
        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
      }
    });
  }, skip: _engineSkip);
}
