// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Coverage for the JsAppView display chrome: `chrome: 'header'` (default)
/// keeps the AppBar with the permissions/reload actions; `chrome: 'full'`
/// drops the AppBar and moves both actions into a floating overlay menu.
///
/// The view starts from the deterministic start-error state (manifest.json
/// exists, widget.js is missing — the engine fails while reading the source,
/// before ever touching the JS backend); the reload test then fixes the app
/// and boots the REAL JavaScriptCore backend via the menu's Reload action.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const widgetJs =
      '(function(){ jsr.render({type:"text",data:"reloaded"}); })();';

  Future<MemoryExecutionEnv> brokenAppEnv() async {
    final env = MemoryExecutionEnv();
    // Only the manifest — no widget.js: a deterministic start error.
    await env.writeFile('apps/demo/manifest.json', '{}');
    return env;
  }

  Future<void> pumpView(
    WidgetTester tester,
    MemoryExecutionEnv env, {
    Map<String, Object?> manifest = const {'id': 'demo', 'name': 'Demo'},
  }) async {
    final permissions = await AppPermissionsStore.load(env);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: JsAppView(
          app: JsAppInfo.fromManifest(
            manifest,
            bundled: false,
            fallbackId: 'demo',
          ),
          env: env,
          permissionsStore: permissions,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openChromeMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  testWidgets('header chrome keeps the AppBar with permissions and reload', (
    tester,
  ) async {
    final env = await brokenAppEnv();
    await pumpView(tester, env);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    // No floating overlay menu in header mode.
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('full chrome hides the AppBar and floats a controls menu', (
    tester,
  ) async {
    final env = await brokenAppEnv();
    await pumpView(
      tester,
      env,
      manifest: const {'id': 'demo', 'name': 'Demo', 'chrome': 'full'},
    );

    expect(find.byType(AppBar), findsNothing);
    expect(find.byIcon(Icons.shield_outlined), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    await openChromeMenu(tester);
    expect(find.text('App permissions'), findsOneWidget);
    expect(find.text('Reload app'), findsOneWidget);
  });

  testWidgets('full chrome menu opens the permissions dialog', (tester) async {
    final env = await brokenAppEnv();
    await pumpView(
      tester,
      env,
      manifest: const {'id': 'demo', 'name': 'Demo', 'chrome': 'full'},
    );

    await openChromeMenu(tester);
    await tester.tap(find.text('App permissions'));
    await tester.pumpAndSettle();

    expect(find.byType(AppPermissionsDialog), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(8));

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(AppPermissionsDialog), findsNothing);
  });

  testWidgets('full chrome menu reload restarts the app', (tester) async {
    final env = await brokenAppEnv();
    await pumpView(
      tester,
      env,
      manifest: const {'id': 'demo', 'name': 'Demo', 'chrome': 'full'},
    );
    expect(find.textContaining('Failed to start Demo'), findsOneWidget);

    // Fix the app, then reload through the overlay menu. The real JS backend
    // boots on the real event loop, so this runs inside runAsync with manual
    // pumps (the fake-zone settle would hang on the engine's periodic timer).
    await tester.runAsync(() async {
      await env.writeFile('apps/demo/widget.js', widgetJs);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Reload app'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.text('reloaded').evaluate().isNotEmpty) break;
      }
    });
    expect(find.text('reloaded'), findsOneWidget);
    expect(find.textContaining('Failed to start Demo'), findsNothing);

    // Unmount so the engine is disposed before teardown.
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  });
}
