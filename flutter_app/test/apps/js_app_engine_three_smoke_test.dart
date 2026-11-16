// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/app_storage.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// The minimal upstream-THREE smoke widget, derived from the runtime's
/// v0.4.191 `example/lib/three_example.dart` contract. The same source is
/// syntax-checked and stub-run with Node as required by the fa-widgets skill.
const threeCubeWidgetJs = r'''
(() => {
  const render = jsr.render;
  jsr.render = (tree) => render.call(jsr, jsr.three._prepareTree(tree));
  const canvas = jsr.three.createCanvas('main');
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(75, 1, 0.1, 100);
  camera.position.z = 3;
  const cube = new THREE.Mesh(
    new THREE.BoxGeometry(1, 1, 1),
    new THREE.MeshBasicMaterial({color: 0x4f8cff})
  );
  scene.add(cube);
  const renderer = new THREE.WebGLRenderer({canvas, antialias: false});
  renderer.setSize(64, 64);
  renderer.render(scene, camera);
  jsr.render({type: 'three', canvasId: 'main'});
  jsr.exportState({revision: THREE.REVISION, meshCount: scene.children.length});
})();
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real QuickJS loads bundled THREE and renders a cube tree', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/three-cube/widget.js', threeCubeWidgetJs);
      final engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {'id': 'three-cube', 'name': 'THREE cube'},
          bundled: false,
          fallbackId: 'three-cube',
        ),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        await engine.start();
        for (var attempt = 0; attempt < 100; attempt++) {
          if (engine.exportedState != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(engine.bootError.value, isNull);
        expect(engine.tree.value?['type'], 'three');
        expect(engine.tree.value?['canvasId'], 'main');
        expect(engine.exportedState?['revision'], '186');
        expect(engine.exportedState?['meshCount'], 1);
      } finally {
        await engine.dispose();
      }
    });
  });
}
