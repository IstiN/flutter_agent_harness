/// Tests for the built-in cube security presets: the catalog shape, id
/// lookup, and the manifest generator — every generated yaml must parse
/// through the strict [CubeSpec.fromYaml] parser (a preset can never drift
/// from the schema) and carry the level/app-axis semantics.
library;

import 'package:flutter_agent_harness/src/cube/config/cube_presets.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('CubePresets.all', () {
    test('exposes the 3 levels x 2 app axes with unique lowercase ids', () {
      final ids = CubePresets.all.map((p) => p.id).toList();
      expect(ids, hasLength(6));
      expect(
        ids,
        containsAll([
          'l1-core',
          'l1-full',
          'l2-core',
          'l2-full',
          'l3-core',
          'l3-full',
        ]),
      );
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids must be unique');
    });

    test('every preset carries level, apps and a non-empty description', () {
      for (final preset in CubePresets.all) {
        expect(preset.level, isIn(CubePresets.levels));
        expect(preset.apps, isIn(CubePresets.appAxes));
        expect(preset.id, '${preset.level.toLowerCase()}-${preset.apps}');
        expect(preset.title, isNotEmpty);
        expect(preset.description, isNotEmpty);
      }
    });
  });

  group('CubePresets.byId', () {
    test('accepts exact ids case-insensitively', () {
      expect(CubePresets.byId('l2-full')?.id, 'l2-full');
      expect(CubePresets.byId('L2-FULL')?.id, 'l2-full');
      expect(CubePresets.byId(' l1-core ')?.id, 'l1-core');
    });

    test('a bare level selects the conservative core axis', () {
      expect(CubePresets.byId('L2')?.id, 'l2-core');
      expect(CubePresets.byId('l3')?.id, 'l3-core');
    });

    test('non-preset ids return null', () {
      expect(CubePresets.byId('l4-core'), isNull);
      expect(CubePresets.byId('l2-fast'), isNull);
      expect(CubePresets.byId(''), isNull);
      expect(CubePresets.byId('my-cube.yaml'), isNull);
    });
  });

  group('CubePresets.manifestYaml', () {
    const cwd = '/tmp/project';

    /// Parses the generated yaml through the STRICT parser — the invariant
    /// that presets can never drift from the schema.
    CubeSpec parse(String id, {String root = cwd}) {
      final preset = CubePresets.byId(id)!;
      return CubeSpec.fromYaml(
        loadYaml(CubePresets.manifestYaml(preset, root)),
        sourcePath: 'builtin:$id',
      );
    }

    test('all 6 presets parse through the strict CubeSpec parser', () {
      for (final preset in CubePresets.all) {
        final spec = parse(preset.id);
        expect(spec.name, preset.id);
        expect(spec.backend, CubeBackendMode.kernel);
        expect(spec.filesystem.workspace, cwd);
      }
    });

    test('L1: no mounts, no network', () {
      final spec = parse('l1-core');
      expect(spec.filesystem.mounts, isEmpty);
      expect(spec.network.allow, isEmpty);
      expect(spec.network.permits('pub.dev', 443), isFalse);
    });

    test('L2: cwd rw + root ro, dev hosts on 443 only', () {
      final spec = parse('l2-full');
      final mounts = {for (final m in spec.filesystem.mounts) m.path: m.access};
      expect(mounts[cwd], CubePathAccess.readWrite);
      expect(mounts['/'], CubePathAccess.readOnly);

      expect(spec.network.permits('pub.dev', 443), isTrue);
      expect(spec.network.permits('api.github.com', 443), isTrue);
      expect(spec.network.permits('evil.example.com', 443), isFalse);
      expect(spec.network.permits('pub.dev', 80), isFalse);
    });

    test('L3: root rw, full network', () {
      final spec = parse('l3-core');
      expect(spec.filesystem.mounts.single.path, '/');
      expect(spec.filesystem.mounts.single.access, CubePathAccess.readWrite);
      expect(spec.network.permits('anything.example.com', 8080), isTrue);
    });

    test('core axis: read commands + read-only git only', () {
      final spec = parse('l2-core');
      expect(spec.tools.allow, containsAll(CubePresets.coreToolAllow));
      expect(spec.tools.allow, isNot(contains('*')));
      expect(spec.tools.permits('cat file.txt'), isTrue);
      expect(spec.tools.permits('git status'), isTrue);
      expect(spec.tools.permits('git log -5'), isTrue);
      // Write paths stay out.
      expect(spec.tools.permits('git push'), isFalse);
      expect(spec.tools.permits('rm -rf /'), isFalse);
      expect(spec.tools.permits('curl http://x'), isFalse);
    });

    test('full axis: any command', () {
      final spec = parse('l3-full');
      expect(spec.tools.allow, contains('*'));
      expect(spec.tools.permits('rm -rf /'), isTrue);
      expect(spec.tools.permits('git push'), isTrue);
    });

    test('a cwd with quotes survives the yaml escaping', () {
      final spec = parse("l1-core", root: "/tmp/it's a test");
      expect(spec.filesystem.workspace, "/tmp/it's a test");
    });
  });

  group('CubePresets.maybeSpec', () {
    test('resolves a preset id to a parsed spec with a builtin source', () {
      final spec = CubePresets.maybeSpec(name: 'L1-FULL', cwd: '/tmp/x');
      expect(spec, isNotNull);
      expect(spec!.name, 'l1-full');
      expect(spec.filesystem.workspace, '/tmp/x');
    });

    test('returns null for names that are not preset ids', () {
      expect(CubePresets.maybeSpec(name: 'my-cube.yaml', cwd: '/tmp'), isNull);
      expect(CubePresets.maybeSpec(name: 'l9', cwd: '/tmp'), isNull);
    });
  });
}
