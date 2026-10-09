// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1441 IT-1 — the fullscreen surface (JsAppView `_treeView`) must build
// a JsVoxelNode — NOT the "Voxel world" placeholder — for an engine whose
// tree carries a `{type:'voxel'}` node after a successful voxel.attach +
// voxel.mesh + voxel.camera (AC1), and already on the FIRST tree with zero
// chunks (E1: the bridge world is eager, so the first frame renders the
// node's empty sky, never the placeholder).
//
// Boots the REAL JavaScriptCore/QuickJS backend (issue #184 guard) with a
// MemoryExecutionEnv + voxel fixture, pushes the JsAppView route like the
// calculator suite, and asserts on the live widget tree.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import '../native_test_guard.dart';

/// Skip value stamped on this file's engine-dependent tests: every one
/// boots a real JS engine (issue #184). Resolved once per isolate.
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

/// Probe → one chunk upload → camera → first render. The single-quad chunk
/// satisfies the bridge's mesh payload contract (flat xyz / rgb / triangle
/// indices, in-bounds).
const voxelAppSource = '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  var ID = 'fa-craft';
  jsr.hostCall('voxel.attach', {id: ID}).then(function() {
    return jsr.hostCall('voxel.mesh', {
      id: ID,
      key: 'chunk-0',
      origin: [0, 0, 0],
      positions: [0,0,0, 1,0,0, 1,1,0, 0,1,0],
      colors: [1,0,0, 1,0,0, 1,0,0, 1,0,0],
      indices: [0,1,2, 0,2,3]
    });
  }).then(function() {
    return jsr.hostCall('voxel.camera', {
      id: ID, position: [3, 3, 5], yaw: 0, pitch: 0, skyColor: '#87CEEB'
    });
  }).then(function() {
    jsr.render({type: 'column', children: [
      {type: 'text', data: 'VOXEL-READY'},
      {type: 'voxel', id: ID, width: 240, height: 240}
    ]});
  });
})();
''';

/// E1: a bare voxel node on the FIRST tree — zero `voxel.*` calls. The
/// bridge creates the world eagerly at start, so the node still renders.
const bareVoxelAppSource = '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  jsr.render({type: 'column', children: [
    {type: 'text', data: 'BARE-VOXEL-READY'},
    {type: 'voxel', id: 'bare', width: 120, height: 120}
  ]});
})();
''';

void main() {
  group('JsAppView voxel node (gh-1441 IT-1)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Every leg boots a real JS engine — skip wholesale on hosts without
    // the native bridge (issue #184).

    /// Pumps a two-route app (home with an "open-app" button → [JsAppView])
    /// and waits until the JS app renders [readyText]. Everything runs on
    /// the real event loop — the JS backend needs it, and its periodic
    /// timer would hang a fake-zone pumpAndSettle.
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

    /// Unmounts the app so the JS engine is disposed before teardown.
    Future<void> unmount(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    testWidgets('a voxel node after attach + mesh + camera renders '
        'JsVoxelNode, not the placeholder (AC1)', (tester) async {
      final env = MemoryExecutionEnv();
      await tester.runAsync(() async {
        await env.writeFile('apps/voxelapp/widget.js', voxelAppSource);
      });
      await pumpAppRoute(tester, env, 'voxelapp', 'VOXEL-READY');

      // The renderer built the real voxel node wired to the engine world.
      expect(find.byType(JsVoxelNode), findsOneWidget);
      // …and NOT the null-world fallback that used to swallow it.
      expect(find.byIcon(Icons.landscape), findsNothing);
      expect(find.text('Voxel world'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a bare voxel node on the FIRST tree (zero voxel.* calls) '
        'renders JsVoxelNode — the eager bridge world (E1)', (tester) async {
      final env = MemoryExecutionEnv();
      await tester.runAsync(() async {
        await env.writeFile('apps/voxelbare/widget.js', bareVoxelAppSource);
      });
      await pumpAppRoute(tester, env, 'voxelbare', 'BARE-VOXEL-READY');

      expect(find.byType(JsVoxelNode), findsOneWidget);
      expect(find.byIcon(Icons.landscape), findsNothing);
      expect(find.text('Voxel world'), findsNothing);
      await unmount(tester);
    });
  }, skip: _engineSkip);
}
