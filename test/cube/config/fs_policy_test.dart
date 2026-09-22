/// Tests for `CubeFsPolicy`: longest-prefix mounts, the workspace default,
/// lexical `..` traversal denial, `~` expansion rules and strict parsing,
/// plus the resolving mode ([CubeFsProbe]) that judges paths by their
/// real-path target.
library;

import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../fake_fs_probe.dart';

void main() {
  CubeFsPolicy parse(String yaml) => CubeFsPolicy.fromYaml(loadYaml(yaml));

  group('CubeFsPolicy.fromYaml', () {
    test('null section defaults to /workspace without mounts', () {
      final policy = CubeFsPolicy.fromYaml(null);
      expect(policy.workspace, '/workspace');
      expect(policy.mounts, isEmpty);
    });

    test('parses workspace and ro/rw/deny mounts', () {
      final policy = parse('''
workspace: /workspace
mounts:
  - {path: /usr/bin, access: ro}
  - {path: /var/tmp, access: rw}
  - {path: ~/.ssh, access: deny}
''');
      expect(policy.workspace, '/workspace');
      expect(policy.mounts, hasLength(3));
      expect(policy.mounts[0].access, CubePathAccess.readOnly);
      expect(policy.mounts[1].access, CubePathAccess.readWrite);
      expect(policy.mounts[2].access, CubePathAccess.deny);
    });

    test('rejects unknown keys at both levels', () {
      expect(
        () => parse('home: /workspace'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.filesystem: unknown key "home"'),
          ),
        ),
      );
      expect(
        () => parse('mounts: [{path: /x, mode: ro}]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('mounts[0]: unknown key "mode"'),
          ),
        ),
      );
    });

    test('rejects unknown access labels and relative workspace', () {
      expect(
        () => parse('mounts: [{path: /x, access: none}]'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parse('workspace: relative/path'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('CubeFsPolicy.accessFor', () {
    test('path under the workspace is read/write', () {
      const policy = CubeFsPolicy();
      expect(policy.accessFor('/workspace/file.txt'), CubePathAccess.readWrite);
      expect(
        policy.accessFor('/workspace/sub/dir/file.txt'),
        CubePathAccess.readWrite,
      );
      expect(policy.accessFor('/workspace'), CubePathAccess.readWrite);
    });

    test('path outside the workspace with no mount is denied', () {
      const policy = CubeFsPolicy();
      expect(policy.accessFor('/etc/passwd'), CubePathAccess.deny);
      expect(policy.accessFor('/workspaced/file'), CubePathAccess.deny);
    });

    test('longest prefix mount wins', () {
      final policy = parse('''
mounts:
  - {path: /workspace, access: ro}
  - {path: /workspace/build, access: rw}
''');
      expect(
        policy.accessFor('/workspace/src/a.dart'),
        CubePathAccess.readOnly,
      );
      expect(
        policy.accessFor('/workspace/build/out.js'),
        CubePathAccess.readWrite,
      );
    });

    test('a root mount grants its access level everywhere', () {
      final ro = parse('mounts: [{path: /, access: ro}]');
      expect(ro.accessFor('/etc/hosts'), CubePathAccess.readOnly);
      expect(ro.accessFor('/work/file.txt'), CubePathAccess.readOnly);
      final rw = parse('mounts: [{path: /, access: rw}]');
      expect(rw.accessFor('/etc/out.txt'), CubePathAccess.readWrite);
      expect(rw.accessFor('/work/file.txt'), CubePathAccess.readWrite);
    });

    test('deny mount inside the workspace beats the workspace default', () {
      final policy = parse(
        'mounts: [{path: /workspace/secrets, access: deny}]',
      );
      expect(policy.accessFor('/workspace/secrets/key'), CubePathAccess.deny);
      expect(policy.accessFor('/workspace/other'), CubePathAccess.readWrite);
    });

    test('dot-segment paths collapse before matching', () {
      const policy = CubeFsPolicy();
      expect(
        policy.accessFor('/workspace/./sub/../file'),
        CubePathAccess.readWrite,
      );
    });

    test('traversal above the workspace is denied', () {
      const policy = CubeFsPolicy();
      expect(policy.accessFor('/workspace/../etc/passwd'), CubePathAccess.deny);
    });

    test('relative traversal escaping the workspace is denied', () {
      const policy = CubeFsPolicy();
      // Relative paths resolve against the workspace; '../../etc' would
      // climb above the root lexically -> denied.
      expect(policy.accessFor('../../etc/passwd'), CubePathAccess.deny);
      expect(policy.accessFor('sub/file.txt'), CubePathAccess.readWrite);
    });

    test('~/.ssh with a known homeDir is denied via the deny mount', () {
      final policy = parse('mounts: [{path: ~/.ssh, access: deny}]');
      expect(
        policy.accessFor('/home/dev/.ssh/id_rsa', homeDir: '/home/dev'),
        CubePathAccess.deny,
      );
      // Same path without homeDir: '~' cannot expand -> denied too.
      expect(policy.accessFor('/home/dev/.ssh/id_rsa'), CubePathAccess.deny);
    });

    test('~ path with unknown homeDir is denied', () {
      const policy = CubeFsPolicy();
      expect(policy.accessFor('~/notes'), CubePathAccess.deny);
      expect(policy.accessFor('~'), CubePathAccess.deny);
    });

    test('~ path with known homeDir lands outside the workspace -> deny', () {
      const policy = CubeFsPolicy();
      expect(
        policy.accessFor('~/notes', homeDir: '/home/dev'),
        CubePathAccess.deny,
      );
    });

    test('mounts on ~ paths resolve with homeDir', () {
      final policy = parse('mounts: [{path: "~", access: ro}]');
      expect(
        policy.accessFor('/home/dev/notes', homeDir: '/home/dev'),
        CubePathAccess.readOnly,
      );
    });

    test('empty path is denied', () {
      const policy = CubeFsPolicy();
      expect(policy.accessFor(''), CubePathAccess.deny);
    });
  });

  group('CubeFsPolicy.accessFor with a probe (resolving mode)', () {
    test('judges the target, not the written form', () {
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(links: {'/workspace/l': '/etc'});
      // Lexically /workspace/l/passwd reads as workspace-internal.
      expect(policy.accessFor('/workspace/l/passwd'), CubePathAccess.readWrite);
      expect(
        policy.accessFor('/workspace/l/passwd', probe: probe),
        CubePathAccess.deny,
      );
    });

    test('denies symlink chains a -> b -> outside', () {
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(links: {
        '/workspace/a': 'b',
        '/workspace/b': '/etc',
      });
      expect(
        policy.accessFor('/workspace/a/passwd', probe: probe),
        CubePathAccess.deny,
      );
    });

    test('allows a link inside the workspace (legitimate use)', () {
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(links: {
        '/workspace/l': 'sub',
        '/workspace/sub/deep': '../other',
      });
      expect(
        policy.accessFor('/workspace/l/file', probe: probe),
        CubePathAccess.readWrite,
      );
      // Both hops stay inside: sub/deep -> ../other = workspace/other.
      expect(
        policy.accessFor('/workspace/sub/deep/f', probe: probe),
        CubePathAccess.readWrite,
      );
    });

    test('denies .. climbing above the root after resolution', () {
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(links: {'/workspace/l': 'sub/deep'});
      // Resolves to /workspace/sub/deep, then four .. climb past the root.
      expect(
        policy.accessFor('/workspace/l/../../../etc/passwd', probe: probe),
        CubePathAccess.deny,
      );
    });

    test('applies .. to the resolved prefix, like the kernel', () {
      // l -> /workspace/sub/deep: l/../.. is /workspace, NOT /workspace/sub.
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(links: {'/workspace/l': '/workspace/sub/deep'});
      expect(
        policy.accessFor('/workspace/l/../../secrets', probe: probe),
        CubePathAccess.readWrite,
      );
      // alt -> /etc/ssh: alt/../config climbs out of the TARGET dir,
      // landing at /etc/config (ro mount) — lexical collapse would have
      // said /workspace/config (workspace rw). The kernel opens the former.
      final ro = parse('mounts: [{path: /etc, access: ro}]');
      final probe2 = FakeFsProbe(links: {'/workspace/alt': '/etc/ssh'});
      expect(
        ro.accessFor('/workspace/alt/../config', probe: probe2),
        CubePathAccess.readOnly,
      );
    });

    test('honors mounts on the resolved target', () {
      final policy = parse('mounts: [{path: /data, access: ro}]');
      final probe = FakeFsProbe(links: {'/workspace/l': '/data/pub'});
      expect(
        policy.accessFor('/workspace/l/f', probe: probe),
        CubePathAccess.readOnly,
      );
      // A longer rw mount under the link's target still wins (no over-block
      // from the walk itself).
      final policy2 = parse(
        'mounts: [{path: /data, access: deny}, {path: /data/pub, access: rw}]',
      );
      final probe2 = FakeFsProbe(links: {'/workspace/l': '/data'});
      expect(
        policy2.accessFor('/workspace/l/pub/f', probe: probe2),
        CubePathAccess.readWrite,
      );
    });

    test('configured roots are trusted heads, not probed', () {
      // macOS firmware symlinks: the workspace itself sits under /var, and
      // /var -> /private/var must not split the verdict from the mounts'
      // spelling (the guard judges the written root, like the mounts do).
      const policy = CubeFsPolicy(workspace: '/var/folders/ws');
      final probe = FakeFsProbe(links: {'/var': '/private/var'});
      expect(
        policy.accessFor('/var/folders/ws/file', probe: probe),
        CubePathAccess.readWrite,
      );
      // A link BELOW the root is still resolved and denied.
      final probe2 = FakeFsProbe(links: {
        '/var': '/private/var',
        '/var/folders/ws/l': '/etc',
      });
      expect(
        policy.accessFor('/var/folders/ws/l/x', probe: probe2),
        CubePathAccess.deny,
      );
    });

    test('unreadable indirection (reparse point) fails closed', () {
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(unreadable: {'/workspace/junction'});
      expect(
        policy.accessFor('/workspace/junction/file', probe: probe),
        CubePathAccess.deny,
      );
    });

    test('relative paths resolve against a custom workspace in both modes', () {
      // The lexical fallback used to hardcode /workspace; both modes must
      // agree on the policy's actual workspace.
      const policy = CubeFsPolicy(workspace: '/data/ws');
      expect(policy.accessFor('sub/f'), CubePathAccess.readWrite);
      expect(policy.accessFor('../../etc/passwd'), CubePathAccess.deny);

      final probe = FakeFsProbe();
      expect(policy.accessFor('sub/f', probe: probe), CubePathAccess.readWrite);
      expect(
        policy.accessFor('../../etc/passwd', probe: probe),
        CubePathAccess.deny,
      );
      final (:access, :resolved) = policy.accessForResolved(
        'sub/f',
        probe: probe,
      );
      expect(access, CubePathAccess.readWrite);
      expect(resolved, '/data/ws/sub/f');
    });

    test('denies chains past the fixed depth', () {
      const policy = CubeFsPolicy();
      final links = <String, String>{
        for (var i = 0; i < 12; i++) '/workspace/l$i': 'l${i + 1}',
      };
      final probe = FakeFsProbe(links: links);
      expect(
        policy.accessFor('/workspace/l0/f', probe: probe),
        CubePathAccess.deny,
      );
    });

    test('resolves ~ heads against the home and probes only below it', () {
      final policy = parse('mounts: [{path: "~", access: ro}]');
      final probe = FakeFsProbe(links: {'/home/dev/l': '/etc'});
      expect(
        policy.accessFor('~/l/passwd', homeDir: '/home/dev', probe: probe),
        CubePathAccess.deny,
      );
      expect(
        policy.accessFor('~/notes', homeDir: '/home/dev', probe: probe),
        CubePathAccess.readOnly,
      );
    });

    test('accessForResolved reports the canonical path to open', () {
      const policy = CubeFsPolicy();
      final probe = FakeFsProbe(links: {'/workspace/l': 'sub'});
      final (:access, :resolved) = policy.accessForResolved(
        '/workspace/l/f',
        probe: probe,
      );
      expect(access, CubePathAccess.readWrite);
      expect(resolved, '/workspace/sub/f');
      // No probe: lexical mode, nothing to open differently.
      final lexical = policy.accessForResolved('/workspace/f');
      expect(lexical.access, CubePathAccess.readWrite);
      expect(lexical.resolved, isNull);
    });
  });

  group('CubePathAccess', () {
    test('parses yaml labels and rejects unknown ones', () {
      expect(CubePathAccess.parse('ro', 'w'), CubePathAccess.readOnly);
      expect(CubePathAccess.parse('rw', 'w'), CubePathAccess.readWrite);
      expect(CubePathAccess.parse('deny', 'w'), CubePathAccess.deny);
      expect(
        () => CubePathAccess.parse('no', 'w'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
