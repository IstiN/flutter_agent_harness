import 'package:flutter_agent_harness/src/cube/backends/cube_backend.dart';
import 'package:flutter_agent_harness/src/cube/backends/linux_unshare.dart';
import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/backends/no_op_backend.dart';
import 'package:flutter_agent_harness/src/cube/backends/windows_job.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/env_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/resource_limits.dart';
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
  group('shellQuote', () {
    test('wraps a plain word and a word with spaces', () {
      expect(shellQuote('git'), "'git'");
      expect(shellQuote('git status'), "'git status'");
    });

    test('escapes embedded single quotes', () {
      expect(shellQuote("git commit -m 'hi'"), "'git commit -m '\\''hi'\\'''");
    });

    test('quotes the empty string', () {
      expect(shellQuote(''), "''");
    });
  });

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

    test('wrapCommand builds the standalone sandbox-exec line', () {
      const backend = MacOsSandboxBackend(
        workspaceRoot: '/real/cwd',
        tmpdir: '/real/cwd/.fah/tmp',
        envVars: {'FAH_MODE': 'sandboxed'},
      );
      final command = "git commit -m 'hi'";
      final wrapped = backend.wrapCommand(
        command,
        profilePath: '/real/cwd/.fah/cube-profiles/abc123.sb',
      );

      expect(backend.enforces, isTrue);
      // Complete standalone shell line: wrapper, clean env, bash, command.
      expect(
        wrapped,
        startsWith(
          "sandbox-exec -f '/real/cwd/.fah/cube-profiles/abc123.sb' "
          '/usr/bin/env -i ',
        ),
      );
      // env -i trio: fixed PATH, HOME at the workspace, TMPDIR under it.
      expect(wrapped, contains("PATH='/usr/bin:/bin:/usr/sbin:/sbin'"));
      expect(wrapped, contains("HOME='/real/cwd'"));
      expect(wrapped, contains("TMPDIR='/real/cwd/.fah/tmp'"));
      // Injected cube vars ride along inside the clean environment.
      expect(wrapped, contains("FAH_MODE='sandboxed'"));
      // The command runs under bash, shell-escaped.
      expect(wrapped, contains("/bin/bash -c "));
      expect(wrapped, endsWith(shellQuote(command)));
    });

    test('the staged profile is the SBPL profile', () {
      const backend = MacOsSandboxBackend();
      expect(
        backend.buildProfile(spec(networkAllowed: false), workspaceRoot: '/x'),
        backend.buildSandboxProfile(
          spec(networkAllowed: false),
          workspaceRoot: '/x',
        ),
      );
    });

    test('describe names the active mechanism', () {
      final describe = MacOsSandboxBackend().describe();
      expect(describe, contains('sandbox-exec'));
      expect(describe, isNot(contains('Phase 2')));
    });

    test('confined paths are emitted in original and resolved forms', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'test-cube',
          filesystem: const CubeFsPolicy(
            mounts: [
              CubeMount(path: '/etc/hosts', access: CubePathAccess.deny),
              CubeMount(path: '/etc', access: CubePathAccess.readOnly),
              CubeMount(path: '/private/etc', access: CubePathAccess.readOnly),
              CubeMount(path: '/tmp/scratch', access: CubePathAccess.readWrite),
            ],
          ),
        ),
        workspaceRoot: '/tmp/fa-cube-validation',
      );
      // The kernel resolves /etc → /private/etc, so the symlink form alone
      // never matches: both spellings must be in the profile.
      expect(profile, contains('(deny file-read* (subpath "/etc/hosts"))'));
      expect(
        profile,
        contains('(deny file-read* (subpath "/private/etc/hosts"))'),
      );
      expect(profile, contains('(allow file-read* (subpath "/etc"))'));
      expect(profile, contains('(allow file-read* (subpath "/private/etc"))'));
      // An already canonical path is not rewritten twice.
      expect(profile, isNot(contains('/private/private')));
      // A workspace under /tmp gets the same treatment.
      expect(
        profile,
        contains('(allow file-write* (subpath "/tmp/fa-cube-validation"))'),
      );
      expect(
        profile,
        contains(
          '(allow file-write* (subpath "/private/tmp/fa-cube-validation"))',
        ),
      );
    });

    test('caller env rides inside the clean environment, caller wins', () {
      const backend = MacOsSandboxBackend(
        envVars: {'FAH_MODE': 'sandboxed', 'SECRET_KEY': 'cube'},
      );
      final wrapped = backend.wrapCommand(
        'git status',
        profilePath: '/p.sb',
        env: {
          'FAH_SESSION_ID': 'abc 123',
          'FAH_MODE': 'override',
          'SECRET_KEY': "it's",
        },
      );
      expect(wrapped, contains("FAH_SESSION_ID='abc 123'"));
      // Caller entries override the cube-bound ones.
      expect(wrapped, contains("FAH_MODE='override'"));
      expect(wrapped, isNot(contains("FAH_MODE='sandboxed'")));
      expect(wrapped, contains(r"SECRET_KEY='it'\''s'"));
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

    test('wrapCommand rebinds ro mounts, applies ulimits and honors --net', () {
      final backend = LinuxUnshareBackend(
        spec: CubeSpec(
          name: 'test-cube',
          tools: const CubeToolPolicy(allow: {'git'}),
          network: const CubeNetworkPolicy(),
          filesystem: const CubeFsPolicy(
            mounts: [
              CubeMount(path: '/usr/share', access: CubePathAccess.readOnly),
              CubeMount(path: '/etc', access: CubePathAccess.deny),
            ],
          ),
          resources: const CubeResourceLimits(
            memoryBytes: 512 * 1024 * 1024,
            timeout: Duration(seconds: 90),
          ),
        ),
        workspaceRoot: '/real/cwd',
        tmpdir: '/real/cwd/.fah/tmp',
      );
      final wrapped = backend.wrapCommand(
        'git status',
        profilePath: '/real/cwd/.fah/cube-profiles/abc123.sb',
      );

      expect(backend.enforces, isTrue);
      // Full unshare prefix with --net (no network allows) and a clean env.
      expect(
        wrapped,
        startsWith(
          'unshare --user --map-root-user --mount --pid --fork '
          '--mount-proc --net /usr/bin/env -i ',
        ),
      );
      // ro mounts re-bound read-only; the deny mount cannot be unmounted by
      // an unprivileged user, so it must NOT appear (Dart guard covers it).
      expect(wrapped, contains('mount --bind'));
      expect(wrapped, contains('remount,ro,bind'));
      expect(wrapped, contains('/usr/share'));
      expect(wrapped, contains('ulimit -v 524288;'));
      expect(wrapped, contains('ulimit -t 90;'));
      // The command runs under bash inside the namespace, shell-escaped.
      expect(wrapped, contains('/bin/bash -c '));
      expect(wrapped, endsWith("ulimit -t 90; git status'"));
    });

    test('a limit-free spec with allowed network skips the preamble and '
        '--net', () {
      final backend = LinuxUnshareBackend(
        spec: CubeSpec(
          name: 'test-cube',
          tools: const CubeToolPolicy(allow: {'git'}),
          network: const CubeNetworkPolicy(allow: [CubeNetworkRule(host: '*')]),
        ),
      );
      final wrapped = backend.wrapCommand(
        'git status',
        profilePath: '/tmp/unused.sb',
      );
      expect(wrapped, isNot(contains('--net')));
      expect(wrapped, isNot(contains('ulimit')));
      expect(wrapped, isNot(contains('mount --bind')));
      // No preamble: the bash -c payload is just the quoted command.
      expect(wrapped, endsWith("/bin/bash -c 'git status'"));
    });

    test('caller env rides inside the clean environment, caller wins', () {
      final backend = LinuxUnshareBackend(
        spec: CubeSpec(
          name: 'test-cube',
          tools: const CubeToolPolicy(allow: {'git'}),
          env: const CubeEnvPolicy(
            vars: [CubeEnvValue(name: 'FAH_MODE', value: 'sandboxed')],
          ),
        ),
      );
      final wrapped = backend.wrapCommand(
        'git status',
        profilePath: '/tmp/unused.sb',
        env: {'FAH_SESSION_ID': 'abc 123', 'FAH_MODE': 'override'},
      );
      expect(wrapped, contains("FAH_SESSION_ID='abc 123'"));
      expect(wrapped, contains("FAH_MODE='override'"));
      expect(wrapped, isNot(contains("FAH_MODE='sandboxed'")));
    });

    test('describe names the active mechanism', () {
      expect(LinuxUnshareBackend().describe(), contains('unshare'));
    });
  });

  group('WindowsJobBackend', () {
    test('the descriptor maps memory and cpu limits to Job Object flags', () {
      final descriptor = WindowsJobBackend.buildJobDescriptor(
        const CubeResourceLimits(
          memoryBytes: 512 * 1024 * 1024,
          cpu: '50%',
          timeout: Duration(minutes: 5),
        ),
      );
      final flags = descriptor['flags'] as int;
      // JOB_OBJECT_LIMIT_PROCESS_MEMORY, _CPU_RATE and _KILL_ON_JOB_CLOSE.
      expect(flags & 0x100, 0x100);
      expect(flags & 0x4, 0x4);
      expect(flags & 0x2000, 0x2000);
      expect(descriptor['processMemoryLimitBytes'], 512 * 1024 * 1024);
      // 50% → rate 5000.
      expect(descriptor['cpuRate'], 5000);
      expect(descriptor['timeoutMilliseconds'], 5 * 60 * 1000);
    });

    test('absent limits produce no limit flags or entries', () {
      final descriptor = WindowsJobBackend.buildJobDescriptor(
        const CubeResourceLimits(),
      );
      expect(descriptor['flags'], WindowsJobBackend.killOnJobCloseFlag);
      expect(descriptor, isNot(contains('processMemoryLimitBytes')));
      expect(descriptor, isNot(contains('cpuRate')));
      expect(descriptor, isNot(contains('timeoutMilliseconds')));
    });

    test('wrapCommand is a passthrough and does not claim enforcement', () {
      const backend = WindowsJobBackend();
      expect(backend.enforces, isFalse);
      expect(
        backend.wrapCommand('git status', profilePath: '/x.sb'),
        'git status',
      );
      expect(backend.describe(), contains('FFI'));
    });
  });

  group('cubeBackendForPlatform', () {
    test('maps known platforms to their backends', () {
      expect(cubeBackendForPlatform('macos'), isA<MacOsSandboxBackend>());
      expect(cubeBackendForPlatform('linux'), isA<LinuxUnshareBackend>());
      expect(cubeBackendForPlatform('windows'), isA<WindowsJobBackend>());
    });

    test('an unknown platform falls back to the no-op backend', () {
      expect(cubeBackendForPlatform('web'), isA<NoOpCubeBackend>());
    });

    test('binds a run context to the enforcing backends', () {
      final macos = cubeBackendForPlatform('macos', workspaceRoot: '/real/cwd');
      expect(macos, isA<MacOsSandboxBackend>());
      expect(
        macos.wrapCommand('git status', profilePath: '/p.sb'),
        contains("HOME='/real/cwd'"),
      );
    });
  });

  group('NoOpCubeBackend', () {
    test('passes commands through unchanged', () {
      const backend = NoOpCubeBackend();
      expect(backend.enforces, isFalse);
      expect(backend.wrapCommand('rm -rf /', profilePath: '/x.sb'), 'rm -rf /');
      expect(backend.describe(), contains('no-op'));
    });
  });
}
