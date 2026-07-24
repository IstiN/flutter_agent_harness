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
}
