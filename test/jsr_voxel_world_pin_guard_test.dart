// gh-1441 — the Fa app must wire the bridge-owned voxel world into every
// JsonWidgetRenderer it builds.
//
// js_widget_runtime 0.4.156 renders a `voxel` node as the "Voxel world"
// placeholder (Icons.landscape) exactly when the renderer's `voxelWorld`
// is null (json_widget_renderer.dart `_voxel`). The runtime engine exposes
// its bridge-owned world (`JsWidgetEngine.voxelWorld`, js_widget_engine_
// wrapper.dart:77 — the JsWidgetBridge creates the world eagerly at start,
// js_widget_bridge.dart:134), but the Fa app constructed the renderer
// without `voxelWorld` at BOTH of its construction sites, so fa-craft /
// voxel-sandbox resolved their voxel probes, uploaded chunk meshes — and
// the screen showed the placeholder.
//
// Deliberately static asserts over the committed sources (the
// jsr_host_call_pin_guard_test.dart / nightly_desktop_leg_guard_test.dart
// pattern) so the guard runs without the native JS bridge and blocks merge
// even when all widget/E2E suites are green (ticket REG-1).
import 'dart:io';

import 'package:test/test.dart';

/// The two Fa-app surfaces that render JS widget trees.
const rendererSites = <String, String>{
  'fullscreen app view': 'flutter_app/lib/apps/js_app_view.dart',
  'live widget tile': 'flutter_app/lib/apps/dynamic_widget_tile.dart',
};

const engineSource = 'flutter_app/lib/apps/js_app_engine.dart';

/// Strips `//` line comments so paren balancing below never counts a paren
/// inside a wiring comment (both construction sites carry prose comments).
String withoutLineComments(String source) => source
    .split('\n')
    .map((line) {
      final inString = "'";
      var quote = false;
      for (var i = 0; i < line.length - 1; i++) {
        final ch = line[i];
        if (ch == r'\' && quote) {
          i++;
          continue;
        }
        if (ch == inString) quote = !quote;
        if (!quote && ch == '/' && line[i + 1] == '/') {
          return line.substring(0, i);
        }
      }
      return line;
    })
    .join('\n');

/// The balanced text of the call whose arguments open at [openParen] —
/// from `(` through its matching `)` — or null when unbalanced.
String? balancedArgs(String source, int openParen) {
  var depth = 0;
  for (var i = openParen; i < source.length; i++) {
    final ch = source[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return source.substring(openParen, i + 1);
    }
  }
  return null;
}

/// Every `JsonWidgetRenderer(` construction site as (lineNo, args).
List<(int, String)> rendererConstructions(String commentedSource) {
  final source = withoutLineComments(commentedSource);
  final sites = <(int, String)>[];
  var from = 0;
  while (true) {
    final at = source.indexOf('JsonWidgetRenderer(', from);
    if (at < 0) break;
    final line = source.substring(0, at).split('\n').length;
    sites.add((line, balancedArgs(source, at + 'JsonWidgetRenderer'.length)!));
    from = at + 'JsonWidgetRenderer('.length;
  }
  return sites;
}

void main() {
  group('gh-1441 voxelWorld wiring guard', () {
    test('every Fa-app JsonWidgetRenderer construction passes voxelWorld:',
        () {
      rendererSites.forEach((surface, path) {
        final source = File(path).readAsStringSync();
        final sites = rendererConstructions(source);
        expect(
          sites,
          isNotEmpty,
          reason: '$surface: the guard found no JsonWidgetRenderer( '
              'construction — the scan is stale (file renamed/moved?), fix '
              'the guard before trusting a green run',
        );
        for (final (line, args) in sites) {
          expect(
            args,
            contains('voxelWorld:'),
            reason:
                '$surface builds JsonWidgetRenderer at $path:$line without '
                '`voxelWorld:` — every `voxel` node in the tree degrades to '
                'the "Voxel world" placeholder (gh-1441). Wire the engine '
                "bridge world: `voxelWorld: engine.voxelWorld` (mirrors the "
                'webViewHost/js3dHost wiring).',
          );
        }
      });
    });

    test('JsAppEngine exposes the runtime engine voxelWorld', () {
      final source = withoutLineComments(File(engineSource).readAsStringSync());
      expect(
        source,
        contains('JsVoxelWorld? get voxelWorld'),
        reason: 'JsAppEngine keeps the JsWidgetEngine private — without a '
            'voxelWorld accessor the surfaces have nothing to pass to '
            'JsonWidgetRenderer (gh-1441)',
      );
      // Delegation to the live engine (null before start / after dispose —
      // reload then re-wires the CURRENT world, never a stale one).
      expect(
        source,
        contains('get voxelWorld => _engine?.voxelWorld'),
        reason: 'voxelWorld must delegate to the CURRENT _engine: a cached '
            'world survives dispose/reload and repaints a disposed world '
            '(gh-1441 AC5)',
      );
    });
  });
}
