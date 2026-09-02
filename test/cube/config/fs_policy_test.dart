/// Tests for `CubeFsPolicy`: longest-prefix mounts, the workspace default,
/// lexical `..` traversal denial, `~` expansion rules and strict parsing.
library;

import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

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
