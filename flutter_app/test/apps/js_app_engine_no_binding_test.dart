// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1266 regression guard: [JsAppEngine] lifecycle must be safe in plain
/// `test()`s that never initialize the widget binding.
///
/// Do NOT add `TestWidgetsFlutterBinding.ensureInitialized()` to this file:
/// the regression it guards is `_inWidgetTest` probing
/// `WidgetsBinding.instance` unguarded, which THROWS
/// "Binding has not yet been initialized" in this exact state (seen on the
/// macOS nightly when the app-launcher smoke gate booted a real engine from
/// a binding-less plain test).
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JsAppEngine.dispose is safe without a widget binding', () async {
    final engine = JsAppEngine(
      app: JsAppInfo.fromManifest(
        const {'id': 'demo', 'name': 'Demo'},
        bundled: false,
        fallbackId: 'demo',
      ),
      env: MemoryExecutionEnv(),
      permissions: const AppPermissions(),
    );
    await engine.dispose();
  });
}
