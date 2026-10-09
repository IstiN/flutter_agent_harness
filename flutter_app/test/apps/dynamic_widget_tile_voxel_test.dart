// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1441 IT-2 — the live-tile surface (DynamicWidgetCanvas) must build a
// JsVoxelNode — NOT the "Voxel world" placeholder — when a tile tree
// carries a `{type:'voxel'}` node (AC2).
//
// Boots a REAL engine against a MemoryExecutionEnv voxel fixture (issue
// #184 guard) and injects it through the existing tile test harness
// (`DynamicMessagesService.debugAdd`), so the canvas renders the live
// engine tree exactly as a chat tile does.
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import '../native_test_guard.dart';

/// Skip value stamped on this file's engine-dependent tests: every one
/// boots a real JS engine (issue #184). Resolved once per isolate.
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

/// Probe → one chunk upload → camera → first render (same contract as the
/// fullscreen IT-1 fixture).
const voxelTileSource = '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  var ID = 'sandbox';
  jsr.hostCall('voxel.attach', {id: ID}).then(function() {
    return jsr.hostCall('voxel.mesh', {
      id: ID,
      key: 'chunk-0',
      origin: [0, 0, 0],
      positions: [0,0,0, 1,0,0, 1,1,0, 0,1,0],
      colors: [0,0,1, 0,0,1, 0,0,1, 0,0,1],
      indices: [0,1,2, 0,2,3]
    });
  }).then(function() {
    return jsr.hostCall('voxel.camera', {
      id: ID, position: [3, 3, 5], yaw: 0, pitch: 0, skyColor: '#87CEEB'
    });
  }).then(function() {
    jsr.render({type: 'column', children: [
      {type: 'text', data: 'TILE-VOXEL-READY'},
      {type: 'voxel', id: ID, width: 200, height: 200}
    ]});
  });
})();
''';

void main() {
  group('DynamicWidgetTile voxel node (gh-1441 IT-2)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    DynamicMessageDefinition definition(String id) =>
        DynamicMessageDefinition(
          id: id,
          title: 'Voxel sandbox',
          jsSource: voxelTileSource,
          createdAt: DateTime(2026, 10, 9, 12, 30),
        );

    DynamicMessagesService service() => DynamicMessagesService(
      env: MemoryExecutionEnv(),
      sendText: (_) async {},
      sessionIdOf: () => 's1',
      sessionFileOf: () => 'sessions/s1.json',
      mediaGatewayOf: () => null,
      videoReaderOf: () => null,
      hostSecretsOf: () => const {},
      llmHandlerOf: () => null,
      asrTranscriberOf: () async => null,
    );

    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('a tile tree with a voxel node renders JsVoxelNode, not the '
        'placeholder (AC2)', skip: _engineSkip, (tester) async {
      final dm = service();
      final def = definition('dm-voxel');
      final env = MemoryExecutionEnv();
      final engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          {'id': def.id, 'name': def.title, 'version': '1.0.0'},
          bundled: false,
          fallbackId: def.id,
        ),
        env: env,
        permissions: const AppPermissions(),
      );
      await tester.runAsync(() async {
        await env.writeFile('apps/${def.id}/widget.js', voxelTileSource);
        await engine.start();
        for (var i = 0; i < 20 && engine.tree.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      addTearDown(() async {
        await tester.runAsync(engine.dispose);
      });
      expect(engine.tree.value, isNotNull);
      dm.debugAdd(def, engine: engine);

      await tester.pumpWidget(
        host(
          DynamicWidgetTile(
            service: dm,
            message: FaChatMessage(role: 'widget', content: '', data: def.id),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('TILE-VOXEL-READY'), findsOneWidget);
      // The canvas wired the engine's bridge world: the real node paints.
      expect(find.byType(JsVoxelNode), findsOneWidget);
      expect(find.byIcon(Icons.landscape), findsNothing);
      expect(find.text('Voxel world'), findsNothing);
    });
  });
}
