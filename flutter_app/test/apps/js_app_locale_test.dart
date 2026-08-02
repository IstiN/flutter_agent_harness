// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// `jsr.locale` exposes the host UI locale to JS apps (they branch their
/// strings on it — see the js-apps skill's localization section). One
/// engine boot per file: repeated native boot/dispose cycles inside a
/// single widget-test process can crash the native JS context.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the host locale reaches the JS app as jsr.locale', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeFile(
      'apps/demo/widget.js',
      '(function(){ jsr.exportState({locale: jsr.locale}); })();',
    );
    final engine = JsAppEngine(
      app: JsAppInfo.fromManifest(
        const {'id': 'demo', 'name': 'Demo'},
        bundled: false,
        fallbackId: 'demo',
      ),
      env: env,
      permissions: const AppPermissions(),
      hostLocale: 'ru',
    );
    try {
      await tester.runAsync(() => engine.start());
      for (var i = 0; i < 40 && engine.exportedState == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(engine.exportedState?['locale'], 'ru');
    } finally {
      await tester.runAsync(() => engine.dispose());
    }
  });
}
