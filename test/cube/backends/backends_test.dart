import 'package:flutter_agent_harness/src/cube/backends/cube_backend.dart';
import 'package:flutter_agent_harness/src/cube/backends/linux_unshare.dart';
import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/backends/no_op_backend.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:test/test.dart';

CubeSpec spec({required bool networkAllowed}) => CubeSpec(
  name: 'test-cube',
  tools: const CubeToolPolicy(allow: {'git'}),
  network: networkAllowed
      ? const CubeNetworkPolicy(allow: [CubeNetworkRule(host: '*')])
      : const CubeNetworkPolicy(),
  filesystem: const CubeFsPolicy(
    workspace: '/workspace',
    mounts: [
      CubeMount(path: '/usr/share', access: CubePathAccess.readOnly),
      CubeMount(path: '/etc', access: CubePathAccess.deny),
    ],
  ),
);

void main() {
  group('MacOsSandboxBackend', () {
    test('the profile contains workspace, mount and network lines', () {
      final backend = MacOsSandboxBackend();
      final profile = backend.buildSandboxProfile(
        spec(networkAllowed: false),
        workspaceRoot: '/real/cwd',
      );

      expect(profile, startsWith('(version 1)'));
      expect(profile, contains('(allow default)'));
      // workspaceRoot override replaces the spec workspace as the rw subpath.
      expect(profile, contains('(allow file-write* (subpath "/real/cwd"))'));
      expect(
        profile,
        isNot(contains('(allow file-write* (subpath "/workspace"))')),
      );
      // ro mount: readable, not writable.
      expect(profile, contains('(allow file-read* (subpath "/usr/share"))'));
      expect(profile, contains('(deny file-write* (subpath "/usr/share"))'));
      // deny mount: invisible.
      expect(profile, contains('(deny file-read* (subpath "/etc"))'));
      expect(profile, contains('(deny file-write* (subpath "/etc"))'));
      // no allow rules => no network.
      expect(profile, contains('(deny network*)'));
    });

    test('an allow-all network policy renders (allow network*)', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        spec(networkAllowed: true),
      );
      expect(profile, contains('(allow network*)'));
      expect(profile, isNot(contains('(deny network*)')));
    });

    test('wrapCommand is a Phase 1 passthrough', () {
      final backend = MacOsSandboxBackend();
      expect(backend.wrapCommand('git status'), 'git status');
      expect(backend.describe(), contains('sandbox-exec'));
      expect(backend.describe(), contains('Phase 2'));
    });
  });

  group('LinuxUnshareBackend', () {
    test('argv has --net exactly when the network is denied', () {
      final backend = LinuxUnshareBackend();
      expect(
        backend.buildUnshareArgv(spec(networkAllowed: false)),
        contains('--net'),
      );
      expect(
        backend.buildUnshareArgv(spec(networkAllowed: true)),
        isNot(contains('--net')),
      );
    });

    test('argv always sets up user, mount and pid namespaces', () {
      final argv = LinuxUnshareBackend().buildUnshareArgv(
        spec(networkAllowed: false),
      );
      expect(argv.first, 'unshare');
      expect(argv, contains('--user'));
      expect(argv, contains('--map-root-user'));
      expect(argv, contains('--mount'));
      expect(argv, contains('--pid'));
      expect(argv, contains('--fork'));
      expect(argv, contains('--mount-proc'));
      // The command lands after the final -- separator.
      expect(argv.last, '--');
      expect(argv[argv.length - 2], '/usr/bin/env');
    });

    test('wrapCommand is a Phase 1 passthrough', () {
      final backend = LinuxUnshareBackend();
      expect(backend.wrapCommand('git status'), 'git status');
      expect(backend.describe(), contains('unshare'));
    });
  });

  group('cubeBackendForPlatform', () {
    test('maps known platforms to their backends', () {
      expect(cubeBackendForPlatform('macos'), isA<MacOsSandboxBackend>());
      expect(cubeBackendForPlatform('linux'), isA<LinuxUnshareBackend>());
    });

    test('an unknown platform falls back to the no-op backend', () {
      expect(cubeBackendForPlatform('windows'), isA<NoOpCubeBackend>());
      expect(cubeBackendForPlatform('web'), isA<NoOpCubeBackend>());
    });
  });

  group('NoOpCubeBackend', () {
    test('passes commands through unchanged', () {
      const backend = NoOpCubeBackend();
      expect(backend.wrapCommand('rm -rf /'), 'rm -rf /');
      expect(backend.describe(), contains('no-op'));
    });
  });
}
