// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

// gh-1842 smoke — fa-craft 0.2.32 on the js_widget_runtime 0.4.189 DEFAULT
// world-space BSP voxel renderer.
//
// This is the host-side smoke the ticket's acceptance asks for, encoded so
// it is repeatable: the real fa-craft 0.2.32 sources (fa_widgets release
// fa-craft-0.2.32.zip, source commit 48ec2af4dc4b04ae357b842da098e01bd8812cb0
// per the widget's .jsr-pin.json) boot on the REAL QuickJS/JavaScriptCore
// backend (issue #184 guard) inside the Fa host, render through
// JsonWidgetRenderer wired with the bridge-owned voxel world — NO
// `?voxelBsp=0` override anywhere: acceptance covers the default path.
//
// Deliberately a plain `test()` (not `testWidgets`): the rAF tick's JS
// round trip drains on the REAL event loop, so the fake-async pump
// deadlock does not exist here; frames are driven by calling the binding's
// begin/draw-frame handlers directly (the same entry points tester.pump
// uses) on a monotonically advancing clock.
//
// Phases (ticket Scope 3):
//  1. boot + native binary lane (`voxel.blocks.bin`) chunk streaming;
//  2. wide-landscape camera rotation sweep — records per-frame paint ms
//     and a sky-hole pixel proxy (terrain→sky→terrain in one row is the
//     signature of the reported blue triangular holes);
//  3. continuous forward movement across chunk boundaries (joystick held)
//     — records per-frame ms to catch movement/streaming spikes and the
//     resident-chunk growth;
//  4. block break/place edits + debug overlay toggle as a regression
//     sanity check.
//
// Stats are printed as `SMOKE gh-1842 ...` lines so a runner log IS the
// recorded paint/fps evidence for the PR description.
//
// Skip contract: skips (never fails) when the native JS bridge is absent
// (issue #184 pattern) or when FA_CRAFT_SRC does not point at an unpacked
// fa-craft source tree — the widget sources are a catalog artifact, not
// vendored into this repo.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

import '../native_test_guard.dart';

/// File-based progress for smoke debugging: `flutter test` only surfaces
/// print output at the end, so long stalls are otherwise opaque.
void _progress(String msg) {
  File('/tmp/facraft_progress.log').writeAsStringSync(
    '${DateTime.now().toIso8601String()} $msg\n',
    mode: FileMode.append,
  );
}

/// Skip value stamped on this file's tests: a real JS engine (issue #184)
/// AND an unpacked fa-craft source tree are both required.
Object? get _skip {
  if (!quickJsBridgeAvailable) return kQuickJsBridgeUnavailable;
  if (_faCraftSrc == null) return _kSrcSkip;
  return false;
}

/// Unpacked fa-craft source tree (the directory holding widget.js).
final String? _faCraftSrc = Platform.environment['FA_CRAFT_SRC'];

const String _kSrcSkip =
    'set FA_CRAFT_SRC to an unpacked fa-craft source '
    'tree (fa_widgets release fa-craft-0.2.32.zip) to run the gh-1842 '
    'BSP smoke';

/// fa-craft manifest — mirrors the released 0.2.32 manifest.json (the
/// smoke deliberately does not depend on catalog download mechanics).
const _manifest = <String, dynamic>{
  'id': 'fa-craft',
  'name': 'Fa Craft',
  'version': '0.2.32',
};

JsAppEngine _engine(MemoryExecutionEnv env) => JsAppEngine(
  app: JsAppInfo.fromManifest(
    _manifest,
    bundled: false,
    fallbackId: 'fa-craft',
  ),
  env: env,
  permissions: const AppPermissions(),
);

/// Writes every `.js` file under [src] into the env at
/// `apps/fa-craft/…`, preserving the directory layout the loader's
/// relative-import inliner expects.
Future<void> _installSources(MemoryExecutionEnv env, String src) async {
  final root = Directory(src);
  await for (final entity in root.list(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.js')) continue;
    final rel = entity.path.substring(root.path.length + 1);
    await env.writeFile('apps/fa-craft/$rel', await entity.readAsString());
  }
}

/// Whether [node] (a JSON widget tree) contains a `voxel` node — walks
/// both `children` lists and singular `child` slots (fa-craft's HUD tree
/// nests container → center → column via `child`).
bool _containsVoxelNode(Map<String, dynamic> node) {
  if (node['type'] == 'voxel') return true;
  final child = node['child'];
  if (child is Map<String, dynamic> && _containsVoxelNode(child)) {
    return true;
  }
  final children = node['children'];
  if (children is List) {
    for (final childEntry in children) {
      if (childEntry is Map<String, dynamic> &&
          _containsVoxelNode(childEntry)) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('gh-1842 fa-craft 0.2.32 smoke — default jsr 0.4.189 BSP', () async {
    _progress('test-start');
    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    final env = MemoryExecutionEnv();
    final engine = _engine(env);

    // Capture framework errors (paint/build exceptions surface here in a
    // plain test instead of failing asynchronously).
    final frameworkErrors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      frameworkErrors.add(details);
      prevOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    await _installSources(env, _faCraftSrc!);
    await engine.start();
    _progress('engine-started');

    // The acceptance path is the DEFAULT renderer — no ?voxelBsp=0
    // anywhere in this harness.
    expect(
      VoxelDiagnostics.bsp,
      isTrue,
      reason:
          'js_widget_runtime 0.4.189 must default to the '
          'world-space BSP depth orderer (the ?voxelBsp=0 legacy '
          'fallback must NOT be in effect)',
    );

    final boundaryKey = GlobalKey();
    final builtWidgets = <Widget>[];
    binding.attachRootWidget(
      View(
        view: binding.platformDispatcher.views.first,
        child: MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: ValueListenableBuilder<Map<String, dynamic>?>(
                valueListenable: engine.tree,
                builder: (context, tree, _) {
                  if (tree == null) return const SizedBox.shrink();
                  final renderer = JsonWidgetRenderer(
                    theme: JsonWidgetTheme.fromAccent(
                      Colors.teal,
                      brightness: Brightness.light,
                    ),
                    voxelWorld: engine.voxelWorld,
                    onEvent: (actionId, payload) =>
                        unawaited(engine.callEvent(actionId, payload)),
                  );
                  final built = renderer.build(tree, context);
                  builtWidgets.add(built);
                  return built;
                },
              ),
            ),
          ),
        ),
      ),
    );

    // Monotonic frame counter; the binding owns the clock (pump advances
    // it), the rAF scheduler folds ticker restarts into epochs.
    final frameMs = <int>[];

    /// Drives one frame through the binding's begin/draw-frame handlers
    /// (the same entry points tester.pump uses), then takes a real-loop
    /// breath for the JS engine's pending deliveries.
    Future<void> pump([int count = 1]) async {
      for (var i = 0; i < count; i++) {
        final sw = Stopwatch()..start();
        binding.handleBeginFrame(null);
        binding.handleDrawFrame();
        sw.stop();
        frameMs.add(sw.elapsedMilliseconds);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    // Repaints once WITHOUT the trailing real-loop breath: the breath
    // lets the JS tick deliver a camera/sync update that re-dirts the
    // voxel painter, and RenderRepaintBoundary.toImage refuses a dirty
    // boundary. Marks made during the frame are painted within the same
    // handleDrawFrame, so the boundary is clean on return.
    void repaintClean() {
      binding.handleBeginFrame(null);
      binding.handleDrawFrame();
    }

    // ── Phase 1: boot + native binary lane ────────────────────────────
    // fa-craft probes the runtime, then streams terrain through
    // voxel.blocks.bin. Wait for the voxel node + resident chunks.
    var booted = false;
    for (var i = 0; i < 600 && !booted; i++) {
      await pump();
      final tree = engine.tree.value;
      booted =
          tree != null &&
          engine.voxelWorld != null &&
          engine.voxelWorld!.chunksOf('fa-craft').isNotEmpty &&
          _containsVoxelNode(tree);
    }
    expect(engine.bootError.value, isNull);
    expect(
      booted,
      isTrue,
      reason:
          'fa-craft 0.2.32 must boot, attach the voxel world and '
          'stream at least one terrain chunk through the native '
          'binary lane',
    );
    expect(
      builtWidgets,
      isNotEmpty,
      reason:
          'the renderer must have built the app tree at least once; '
          'framework errors so far: $frameworkErrors',
    );
    final chunksAfterBoot = engine.voxelWorld!.chunksOf('fa-craft').length;
    expect(chunksAfterBoot, greaterThan(0));
    frameMs.clear();
    debugPrint(
      'SMOKE gh-1842 boot: chunks=$chunksAfterBoot '
      'bsp=${VoxelDiagnostics.bsp}',
    );

    // ── Phase 2: wide-landscape rotation sweep ──────────────────────
    // 16 × ~23° look steps = full yaw circle.
    final rotationMs = <int>[];
    final skyHolesPerAngle = <int>[];
    for (var step = 0; step < 16; step++) {
      // fire-and-forget: production wiring (js_app_view) never awaits
      // callEvent — the render ack round trip can outlive the frame.
      unawaited(engine.callEvent('look', const {'dx': 100, 'dy': 0}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = frameMs.length;
      await pump();
      rotationMs.add(frameMs.sublist(before).reduce((a, b) => a + b));
      repaintClean();
      skyHolesPerAngle.add(
        await _countEnclosedSkyPixels(
          boundaryKey,
          engine.voxelWorld!.cameraOf('fa-craft').skyColor,
        ),
      );
    }
    debugPrint(
      'SMOKE gh-1842 rotation: frames=${rotationMs.length} '
      'avg=${_avg(rotationMs).toStringAsFixed(1)}ms '
      'max=${rotationMs.reduce((a, b) => a > b ? a : b)}ms '
      'skyHoles=$skyHolesPerAngle',
    );
    expect(
      engine.voxelWorld!.chunksOf('fa-craft'),
      isNotEmpty,
      reason: 'the world must survive a full camera rotation',
    );

    // ── Phase 3: continuous forward movement (streaming) ────────────
    Map<String, dynamic>? posMap(Object? state) =>
        state is Map<String, dynamic> ? state : null;
    final posBefore = posMap(engine.exportedState?['pos']);
    final chunksBeforeMove = engine.voxelWorld!.chunksOf('fa-craft').length;
    unawaited(engine.callEvent('joyMove', const {'x': 48, 'y': 0}));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final moveMs = <int>[];
    for (var frame = 0; frame < 300; frame++) {
      if (frame % 50 == 0) _progress('move-frame-$frame');
      final before = frameMs.length;
      await pump();
      moveMs.add(frameMs.sublist(before).reduce((a, b) => a + b));
    }
    unawaited(engine.callEvent('joyEnd'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final posAfter = posMap(engine.exportedState?['pos']);
    final chunksAfterMove = engine.voxelWorld!.chunksOf('fa-craft').length;
    final maxMoveMs = moveMs.reduce((a, b) => a > b ? a : b);
    debugPrint(
      'SMOKE gh-1842 streaming: frames=${moveMs.length} '
      'avg=${_avg(moveMs).toStringAsFixed(1)}ms max=$maxMoveMs '
      'p95=${_p95(moveMs)}ms '
      'chunks:$chunksBeforeMove→$chunksAfterMove '
      'pos:$posBefore→$posAfter',
    );
    expect(posAfter, isNotNull);
    final movedX = (posAfter!['x'] as num) - (posBefore?['x'] as num? ?? 0);
    final movedZ = (posAfter['z'] as num) - (posBefore?['z'] as num? ?? 0);
    expect(
      movedX.abs() + movedZ.abs(),
      greaterThan(1.0),
      reason:
          'holding the joystick forward must move the player '
          '(tick loop alive across 300 frames)',
    );
    expect(chunksAfterMove, greaterThanOrEqualTo(chunksBeforeMove));
    // Anti-wedge sanity: a software-rasterized headless frame that takes
    // longer than this is a hang, not a spike.
    expect(maxMoveMs, lessThan(2000));

    // ── Phase 4: block edits + overlay regression sanity ────────────
    unawaited(engine.callEvent('break'));
    unawaited(engine.callEvent('place'));
    unawaited(engine.callEvent('debug')); // F3-style debug overlay
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await pump(2);
    expect(engine.bootError.value, isNull);
    expect(
      frameworkErrors.where(
        (d) =>
            d.exception is! NetworkImageLoadException &&
            !d.toString().contains('was not laid out'),
      ),
      isEmpty,
      reason: 'no framework/paint errors across the whole smoke',
    );
    // The tree still renders the voxel viewport plus the HUD overlay
    // (the overlay carries hotbar/notice/debug text around the viewport).
    final finalTree = engine.tree.value;
    expect(finalTree, isNotNull);
    expect(_containsVoxelNode(finalTree!), isTrue);
    debugPrint('SMOKE gh-1842 edits: break+place+debug overlay OK');

    // ── Teardown (inside the body: a live engine past the test end
    // wedges the runner; dispose cancels rAF/intervals first) ─────────
    await engine.dispose();
    binding.attachRootWidget(
      View(
        view: binding.platformDispatcher.views.first,
        child: const SizedBox.shrink(),
      ),
    );
    binding.handleBeginFrame(null);
    binding.handleDrawFrame();
    _progress('test-body-done');
  }, skip: _skip);
}

double _avg(List<int> xs) =>
    xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

int _p95(List<int> xs) {
  final sorted = List<int>.of(xs)..sort();
  return sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
}

/// Sky-hole proxy for the reported blue triangular holes: counts
/// sky-colored pixels that have NON-sky pixels on both sides along the
/// same row — a fully enclosed sky pocket inside terrain. Samples every
/// other pixel to stay cheap; the heuristic can neither prove absence
/// nor catch brown slivers (thin terrain strips), it only flags
/// enclosed-sky regressions. The numbers are recorded for the PR either
/// way.
Future<int> _countEnclosedSkyPixels(
  GlobalKey boundaryKey,
  Color skyColor,
) async {
  final boundary =
      boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return -1;
  // Layer-level capture (the SDK's own alternative to
  // RenderRepaintBoundary.toImage): the needsPaint assert on the
  // render-object API races with the voxel painter's breath-time
  // re-marks; the OffsetLayer holds the last committed picture. A null
  // layer means the boundary was never composited — recorded as -2,
  // never fatal: the scan is an artifact PROXY, not the acceptance core.
  final layer = boundary.layer;
  if (layer == null) return -2;
  final offsetLayer = layer as OffsetLayer;
  final image = await offsetLayer.toImage(
    Offset.zero & boundary.size,
    pixelRatio: 0.5,
  );
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = image.width;
  final h = image.height;
  image.dispose();
  final bytes = byteData!.buffer.asUint8List();

  bool isSky(int x, int y) {
    final o = (y * w + x) * 4;
    // Tolerant match: fa-craft's day-night cycle shifts the sky color.
    return (bytes[o] - skyColor.r * 255).abs() < 20 &&
        (bytes[o + 1] - skyColor.g * 255).abs() < 20 &&
        (bytes[o + 2] - skyColor.b * 255).abs() < 20;
  }

  var holes = 0;
  for (var y = 1; y < h - 1; y += 2) {
    for (var x = 4; x < w - 4; x += 2) {
      if (!isSky(x, y)) continue;
      var leftTerrain = false;
      var rightTerrain = false;
      for (var d = 1; d <= 6 && !(leftTerrain && rightTerrain); d++) {
        if (!isSky(x - d, y)) leftTerrain = true;
        if (!isSky(x + d, y)) rightTerrain = true;
      }
      if (leftTerrain && rightTerrain) holes++;
    }
  }
  return holes;
}
