// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// End-to-end render check: boots the REAL calculator demo app
/// (assets/apps/calculator/widget.js) through the real JavaScriptCore
/// backend and renders the resulting UI tree into actual Flutter widgets
/// with the same JsonWidgetRenderer the JsAppView uses.
///
/// The engine is booted inside `tester.runAsync` (the JS backend needs the
/// real event loop); the renderer itself is synchronous.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('calculator demo app renders real widgets', (tester) async {
    final env = MemoryExecutionEnv();
    late final JsAppEngine engine;
    Map<String, dynamic>? tree;
    await tester.runAsync(() async {
      // Real async IO only progresses inside runAsync under flutter_test.
      final source = await File(
        'assets/apps/calculator/widget.js',
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
}
