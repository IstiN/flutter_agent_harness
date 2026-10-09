// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1441 — JsAppEngine must expose the bridge-owned voxel world so the
// Fa surfaces can wire it into JsonWidgetRenderer (UT-1/AC5 + AC3).
//
// - `voxelWorld` delegates to the CURRENT engine: null before start and
//   after dispose/restart-gap, a NEW world after a restart — a re-render
//   after reload re-wires the live world, never a stale one from a
//   disposed engine (AC5, E4).
// - `noteUnwiredVoxelWorld` emits the ONE-SHOT diagnostic that tells
//   "host did not wire voxelWorld" from "broken widget" on minimal custom
//   backends whose world is null (AC3); a null-world renderer still draws
//   its placeholder without crashing.
//
// The bridge-gated legs boot a real engine (issue #184 guard); the
// getter/diagnostic asserts run everywhere. The diagnostic's silence
// contract is checked on the states this runner can construct: the boot
// gap (null `_engine` — never started / disposed) and a LIVE shipped
// backend whose world is always wired. The one-shot's spent-flag path
// (live minimal backend, world null) has no constructible backend here —
// same documented gap as REG-2's web-worker leg; the flag's re-arm and
// live-engine gate are pinned statically by
// test/jsr_voxel_world_pin_guard_test.dart.
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/app_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import '../native_test_guard.dart';

/// Skip value stamped on this file's engine-dependent tests: every one
/// boots a real JS engine (issue #184). Resolved once per isolate.
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

JsAppEngine engine(MemoryExecutionEnv env, String id) => JsAppEngine(
  app: JsAppInfo.fromManifest(
    {'id': id, 'name': id},
    bundled: false,
    fallbackId: id,
  ),
  env: env,
  permissions: const AppPermissions(),
);

/// The voxel fixture: probe → one chunk upload → camera → render. The
/// single-quad chunk satisfies the bridge's mesh payload contract (flat
/// xyz / rgb / triangle indices).
const voxelAppSource = '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  var ID = 'world';
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
    jsr.render({type: 'text', data: 'VOXEL-READY'});
  });
})();
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JsAppEngine.voxelWorld (gh-1441 UT-1/AC5) — world-less states', () {
    test('null before start', () {
      final env = MemoryExecutionEnv();
      expect(engine(env, 'voxel-null-pre').voxelWorld, isNull);
    });

    test('null after dispose without a start (never-started engine)', () async {
      final env = MemoryExecutionEnv();
      final e = engine(env, 'voxel-null-disposed');
      await e.dispose();
      expect(e.voxelWorld, isNull);
    });
  });

  group('JsAppEngine.voxelWorld (gh-1441 UT-1/AC5) — live engine', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    testWidgets('live world after start, a NEW world after restart, null '
        'after dispose (no stale world repaints)', (tester) async {
      final env = MemoryExecutionEnv();
      final e = engine(env, 'voxel-live');
      await tester.runAsync(() async {
        await env.writeFile('apps/voxel-live/widget.js', voxelAppSource);
        await e.start();
      });
      final first = e.voxelWorld;
      expect(first, isNotNull);

      // Restart (reload) disposes the old engine and creates a new one —
      // the getter must hand out the NEW world, never the disposed one.
      await tester.runAsync(e.start);
      final second = e.voxelWorld;
      expect(second, isNotNull);
      expect(
        identical(first, second),
        isFalse,
        reason:
            'a reload must re-wire the CURRENT world — a stale world '
            'from the disposed engine would repaint dead state (gh-1441 '
            'AC5/E4)',
      );

      await tester.runAsync(e.dispose);
      expect(e.voxelWorld, isNull);
    });
  }, skip: _engineSkip);

  group('JsAppEngine.noteUnwiredVoxelWorld (gh-1441 AC3 + review)', () {
    test('the boot gap stays silent: a never-started engine is not the AC3 '
        'subject', () {
      AppLog.reset();
      addTearDown(AppLog.reset);
      final env = MemoryExecutionEnv();
      final e = engine(env, 'voxel-boot-gap');
      expect(e.voxelWorld, isNull); // null _engine — nothing wired yet

      e.noteUnwiredVoxelWorld({
        'type': 'column',
        'children': [
          {'type': 'text', 'data': 'hi'},
          {'type': 'voxel', 'id': 'world'},
        ],
      });
      // gh-1441 review: `_start()` nulls `_engine` BEFORE the async
      // dispose/boot while `tree.value` still publishes the old tree — a
      // rebuild in that gap renders the placeholder transiently and must
      // NOT fire the one-shot WARNING (it would fire on shipped backends,
      // contradicting the diagnostic's own contract, and permanently spend
      // the one-shot for the instance). AC3's subject is a LIVE engine
      // whose backend ships no world.
      expect(AppLog.dump(), isEmpty);
    });

    test('a disposed engine (null _engine) stays silent too', () async {
      AppLog.reset();
      addTearDown(AppLog.reset);
      final env = MemoryExecutionEnv();
      final e = engine(env, 'voxel-disposed-gap');
      await e.dispose();
      e.noteUnwiredVoxelWorld({'type': 'voxel', 'id': 'world'});
      expect(AppLog.dump(), isEmpty);
    });

    testWidgets('a null-world renderer still draws the placeholder without '
        'crashing (degradation contract)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => JsonWidgetRenderer(
              onEvent: (_, _) {},
              // The AC3 minimal backend: no world wired.
              voxelWorld: null,
            ).build(const {'type': 'voxel', 'id': 'world'}, context),
          ),
        ),
      );
      expect(find.byIcon(Icons.landscape), findsOneWidget);
      expect(find.text('Voxel world'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('JsAppEngine.noteUnwiredVoxelWorld — live shipped backend', () {
    testWidgets('a LIVE shipped-backend engine with a wired world never '
        'fires the diagnostic — re-armed across restarts', (tester) async {
      AppLog.reset();
      addTearDown(AppLog.reset);
      final env = MemoryExecutionEnv();
      final e = engine(env, 'voxel-wired');
      await tester.runAsync(() async {
        await env.writeFile('apps/voxel-wired/widget.js', voxelAppSource);
        await e.start();
      });
      expect(e.voxelWorld, isNotNull);
      final voxelTree = {'type': 'voxel', 'id': 'world'};
      e.noteUnwiredVoxelWorld(voxelTree);
      // Restart: the diagnostic flag re-arms (a fresh boot), and the new
      // engine's world is wired again — still silent on shipped backends.
      await tester.runAsync(e.start);
      expect(e.voxelWorld, isNotNull);
      e.noteUnwiredVoxelWorld(voxelTree);
      await tester.runAsync(e.dispose);
      expect(
        AppLog.dump(),
        isEmpty,
        reason:
            'shipped backends always own a bridge world — the '
            '"no voxelWorld is wired" WARNING must never fire on them '
            '(gh-1441 AC3 contract)',
      );
    });
  }, skip: _engineSkip);
}
