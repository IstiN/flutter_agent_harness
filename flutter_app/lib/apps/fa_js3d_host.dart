
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// Builds the runtime 3D host with the Fa sandbox GLB loader wired.
///
/// Installed widgets keep their model files in the sandbox tree
/// (`apps/<id>/…` under the session Documents root), which the Flutter
/// asset bundle cannot see — the stock GLB parser fails with
/// "Unable to load asset". The `fileBytesLoader` contract (runtime
/// 0.4.103+) resolves those paths through [env]; every other source
/// (remote URLs, `file://`, bundle assets) falls through to the
/// runtime's own resolution, unchanged.
Js3dHost createFaJs3dHost(ExecutionEnv env) =>
    createJs3dHost(fileBytesLoader: sandboxGlbBytes(env));

/// Resolves sandbox-rooted model sources (`apps/…`) to bytes via
/// [env]; returns null for anything else so the runtime falls through
/// to its own local-file/asset resolution.
Js3dFileBytesLoader sandboxGlbBytes(ExecutionEnv env) => (src) async {
  if (!src.startsWith('apps/')) return null;
  final result = await env.readBinaryFile(src);
  return result.valueOrNull;
};
