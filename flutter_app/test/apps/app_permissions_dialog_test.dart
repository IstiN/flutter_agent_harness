// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// The permissions dialog must show the persisted override after a reload
/// (the "permissions reset after restart" regression).
void main() {
  testWidgets('permissions dialog shows persisted overrides', (tester) async {
    final env = MemoryExecutionEnv();
    final app = JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo', 'icon': '🧪'},
      bundled: false,
      fallbackId: 'demo',
    );

    // Simulate "previous run": the user enabled Network.
    final store = await AppPermissionsStore.load(env);
    await store.setOverride('demo', const AppPermissions(network: true));

    // "New run": a freshly loaded store must expose the override everywhere.
    final reloaded = await AppPermissionsStore.load(env);
    expect(reloaded.forApp(app).network, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppPermissionsDialog(app: app, env: env, store: reloaded),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final networkTile = find.widgetWithText(SwitchListTile, 'Network');
    expect(networkTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(networkTile).value, isTrue);
  });

  testWidgets('permissions dialog shows and toggles the calendar permission', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final app = JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo', 'icon': '🧪'},
      bundled: false,
      fallbackId: 'demo',
    );
    final store = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppPermissionsDialog(app: app, env: env, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final calendarTile = find.widgetWithText(SwitchListTile, 'Calendar');
    expect(calendarTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(calendarTile).value, isFalse);

    await tester.tap(calendarTile);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(calendarTile).value, isTrue);
    expect(store.forApp(app).calendar, isTrue);
  });

  testWidgets('permissions dialog shows and toggles the notifications '
      'permission', (tester) async {
    final env = MemoryExecutionEnv();
    final app = JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo', 'icon': '🧪'},
      bundled: false,
      fallbackId: 'demo',
    );
    final store = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppPermissionsDialog(app: app, env: env, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final notificationsTile = find.widgetWithText(
      SwitchListTile,
      'Notifications',
    );
    expect(notificationsTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(notificationsTile).value, isFalse);

    // The eighth toggle sits below the fold in the default test window.
    await tester.ensureVisible(notificationsTile);
    await tester.pumpAndSettle();
    await tester.tap(notificationsTile);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(notificationsTile).value, isTrue);
    expect(store.forApp(app).notifications, isTrue);
  });

  testWidgets('permissions dialog shows and toggles the host keys permission', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final app = JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo', 'icon': '🧪'},
      bundled: false,
      fallbackId: 'demo',
    );
    final store = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppPermissionsDialog(app: app, env: env, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final keysTile = find.widgetWithText(SwitchListTile, 'Host keys');
    expect(keysTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(keysTile).value, isFalse);

    // The last toggle sits below the fold in the default test window.
    await tester.ensureVisible(keysTile);
    await tester.pumpAndSettle();
    await tester.tap(keysTile);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(keysTile).value, isTrue);
    expect(store.forApp(app).keys, isTrue);
    // The override persisted with the new flag.
    final reloaded = await AppPermissionsStore.load(env);
    expect(reloaded.forApp(app).keys, isTrue);
  });
}
