// Tests for the Fa 3D host wiring: installed widgets keep their GLB
// files in the sandbox tree (Documents/fah_sandbox/apps/<id>/…),
// outside the Flutter asset bundle — the stock asset parser cannot
// see them. The fileBytesLoader contract (js_widget_runtime 0.4.103+)
// resolves those paths through the ExecutionEnv; every other source
// falls through to the runtime's own local-file/asset resolution.

import 'dart:typed_data';

import 'package:fa/apps/fa_js3d_host.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sandboxGlbBytes', () {
    test('resolves apps/… paths through the env', () async {
      final env = MemoryExecutionEnv();
      final bytes = Uint8List.fromList(const [0x67, 0x6C, 0x54, 0x46]);
      await env.writeBinaryFile('apps/fitness-trainer/models/a.glb', bytes);

      final loader = sandboxGlbBytes(env);
      expect(await loader('apps/fitness-trainer/models/a.glb'), bytes);
    });

    test('falls through for non-sandbox sources', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile(
        'apps/x/a.glb',
        Uint8List.fromList(const [1]),
      );
      final loader = sandboxGlbBytes(env);
      expect(await loader('https://example.com/a.glb'), isNull);
      expect(await loader('assets/bundled.glb'), isNull);
      expect(await loader('/abs/path/a.glb'), isNull);
    });

    test('falls through when the sandbox file is missing', () async {
      final loader = sandboxGlbBytes(MemoryExecutionEnv());
      expect(await loader('apps/nope/missing.glb'), isNull);
    });
  });

  group('createFaJs3dHost', () {
    test('returns the shared dispatcher with the loader installed', () {
      final host = createFaJs3dHost(MemoryExecutionEnv());
      expect(host, isNotNull);
      expect(Js3dUrlGlbParser.fileBytesLoader, isNotNull);
    });
  });
}
