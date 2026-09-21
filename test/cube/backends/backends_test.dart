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

    test(
      'a workspace-only spec (L1 shape) confines writes and sensitive reads',
      () {
        final profile = MacOsSandboxBackend().buildSandboxProfile(
          const CubeSpec(
            name: 'l1-core',
            filesystem: CubeFsPolicy(workspace: '/Users/agent/proj'),
          ),
        );
        // Writes: blanket deny, the workspace re-allowed on top of it, and
        // the persistence-free device sinks left writable (2>/dev/null must
        // keep working).
        expect(profile, contains('(deny file-write*)'));
        expect(
          profile,
          contains('(allow file-write* (subpath "/Users/agent/proj"))'),
        );
        expect(profile, contains('(allow file-write* (subpath "/dev/null"))'));
        expect(profile, contains('(allow file-write* (subpath "/dev/fd"))'));
        // Reads: a curated deny set — /etc in both spellings and every home —
        // with the workspace re-allowed over the /Users deny. A blanket read
        // deny is impossible: exec needs /bin/bash and /usr/lib/dyld.
        expect(profile, contains('(deny file-read* (subpath "/etc"))'));
        expect(profile, contains('(deny file-read* (subpath "/private/etc"))'));
        expect(profile, contains('(deny file-read* (subpath "/Users"))'));
        expect(
          profile,
          contains('(allow file-read* (subpath "/Users/agent/proj"))'),
        );
      },
    );

    test('a ro-root spec (L2 shape) confines writes, reads stay broad', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        const CubeSpec(
          name: 'l2-core',
          filesystem: CubeFsPolicy(
            workspace: '/work',
            mounts: [CubeMount(path: '/', access: CubePathAccess.readOnly)],
          ),
        ),
      );
      expect(profile, contains('(deny file-write*)'));
      expect(profile, isNot(contains('(deny file-read* (subpath "/Users"))')));
      expect(profile, isNot(contains('(deny file-read* (subpath "/etc"))')));
    });

    test('a rw-root spec (L3 shape) stays allow-default', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        const CubeSpec(
          name: 'l3-core',
          filesystem: CubeFsPolicy(
            workspace: '/work',
            mounts: [CubeMount(path: '/', access: CubePathAccess.readWrite)],
          ),
        ),
      );
      expect(profile, isNot(contains('(deny file-write*)')));
      expect(profile, isNot(contains('(deny file-read* (subpath "/Users"))')));
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

  // Issue #709: an rw mount under a read-denied prefix must be kernel-
  // readable, not only kernel-writable — the SBPL emission has to match the
  // Dart fs guard's readWrite = read AND write.
  group('rw mount emission (issue 709)', () {
    test('an rw mount under a read-denied prefix allows reads AND writes '
        '(UT1)', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'l1-dev',
          filesystem: const CubeFsPolicy(
            mounts: [
              CubeMount(
                path: '/Users/agents/.pub-cache',
                access: CubePathAccess.readWrite,
              ),
              CubeMount(path: '/etc/ssl', access: CubePathAccess.readWrite),
            ],
          ),
        ),
        workspaceRoot: '/Users/agents/proj',
      );

      // The blanket read denies stay — the fix re-allows over them, it does
      // not loosen the curated read confinement.
      expect(profile, contains('(deny file-read* (subpath "/Users"))'));
      expect(profile, contains('(deny file-read* (subpath "/etc"))'));

      // Each rw mount emits BOTH allows, in both resolved spellings: rw is
      // read+write in the kernel exactly as in the Dart guard.
      for (final path in [
        '/Users/agents/.pub-cache',
        '/etc/ssl',
        '/private/etc/ssl',
      ]) {
        expect(profile, contains('(allow file-read* (subpath "$path"))'));
        expect(profile, contains('(allow file-write* (subpath "$path"))'));
      }

      // Ordering is load-bearing: the kernel applies the LAST matching rule
      // per operation class (P1), so the mount's read allow must come after
      // the blanket /Users deny it re-allows over.
      final denyAt = profile.indexOf('(deny file-read* (subpath "/Users"))');
      final allowAt = profile.indexOf(
        '(allow file-read* (subpath "/Users/agents/.pub-cache"))',
      );
      expect(denyAt, greaterThanOrEqualTo(0));
      expect(allowAt, greaterThan(denyAt));
    });

    test('ro and deny mounts emit byte-identical rule sets (UT2)', () {
      // The rw fix must not perturb ro/deny emission (AC4): the exact
      // per-mount lines, in order, in both spellings, stay frozen.
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'test-cube',
          filesystem: const CubeFsPolicy(
            mounts: [
              CubeMount(path: '/usr/share', access: CubePathAccess.readOnly),
              CubeMount(path: '/etc/secrets', access: CubePathAccess.deny),
            ],
          ),
        ),
        workspaceRoot: '/real/cwd',
      );
      expect(
        profile
            .split('\n')
            .where(
              (l) => l.contains('/usr/share') || l.contains('/etc/secrets'),
            )
            .toList(),
        [
          '(allow file-read* (subpath "/usr/share"))',
          '(deny file-write* (subpath "/usr/share"))',
          '(deny file-read* (subpath "/etc/secrets"))',
          '(deny file-write* (subpath "/etc/secrets"))',
          '(deny file-read* (subpath "/private/etc/secrets"))',
          '(deny file-write* (subpath "/private/etc/secrets"))',
        ],
      );
    });

    test('an rw mount on the denied prefix root itself wins by order (E1)', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'l1-open-home',
          filesystem: const CubeFsPolicy(
            mounts: [
              CubeMount(path: '/Users', access: CubePathAccess.readWrite),
            ],
          ),
        ),
        workspaceRoot: '/work',
      );
      // The curated deny is still emitted (no root-read mount), and the
      // mount's own allows land after it: last match wins, so /Users itself
      // becomes read+write while /etc stays confined.
      expect(profile, contains('(deny file-read* (subpath "/Users"))'));
      expect(
        profile.indexOf('(allow file-read* (subpath "/Users"))'),
        greaterThan(profile.indexOf('(deny file-read* (subpath "/Users"))')),
      );
      expect(profile, contains('(allow file-write* (subpath "/Users"))'));
      expect(profile, contains('(deny file-read* (subpath "/etc"))'));
    });

    test('ro+rw twin mounts stay deterministic: last entry wins per class '
        '(E2)', () {
      // The l1-dev twin stopgap (.fah/cubes/l1-dev.yaml) keeps working after
      // the fix: the ro twin's deny-write is emitted first, the rw twin's
      // allows after it — per P1 the allows hold, deterministically, because
      // mount-list order fixes rule order.
      const twin = '/Users/agents/.pub-cache';
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'l1-dev',
          filesystem: const CubeFsPolicy(
            mounts: [
              CubeMount(path: twin, access: CubePathAccess.readOnly),
              CubeMount(path: twin, access: CubePathAccess.readWrite),
            ],
          ),
        ),
        workspaceRoot: '/Users/agents/proj',
      );
      final denyWriteAt = profile.indexOf(
        '(deny file-write* (subpath "$twin"))',
      );
      final allowWriteAt = profile.indexOf(
        '(allow file-write* (subpath "$twin"))',
      );
      expect(denyWriteAt, greaterThanOrEqualTo(0));
      expect(allowWriteAt, greaterThan(denyWriteAt));
      // One deny-write (ro twin) and one allow-write (rw twin) — no
      // duplicate emission, no dropped twin.
      expect(
        RegExp(
          r'\(deny file-write\* \(subpath "/Users/agents/\.pub-cache"\)\)',
        ).allMatches(profile),
        hasLength(1),
      );
      expect(
        RegExp(
          r'\(allow file-write\* \(subpath "/Users/agents/\.pub-cache"\)\)',
        ).allMatches(profile),
        hasLength(1),
      );
      // Both twins contribute their read allow; the path stays readable.
      expect(
        RegExp(
          r'\(allow file-read\* \(subpath "/Users/agents/\.pub-cache"\)\)',
        ).allMatches(profile),
        hasLength(2),
      );
    });

    test('a nested deny child emits AFTER its broader parent (E4)', () {
      // PR #718 review finding #1: the guard resolves mounts longest-
      // prefix-wins, but list-order emission let a parent declared after a
      // deny child land its allows LAST — kernel-re-allowing the child the
      // guard denies (the `[deny ~/.ssh, rw ~]` shape). The deepest-last
      // emission sort must put every child after all of its ancestors.
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'l1-nested',
          filesystem: const CubeFsPolicy(
            mounts: [
              // Declared first, deepest — the exact adversarial order.
              CubeMount(
                path: '/Users/agents/.ssh',
                access: CubePathAccess.deny,
              ),
              CubeMount(
                path: '/Users/agents',
                access: CubePathAccess.readWrite,
              ),
            ],
          ),
        ),
        workspaceRoot: '/work',
      );
      for (final op in ['read', 'write']) {
        final denyAt = profile.indexOf(
          '(deny file-$op* (subpath "/Users/agents/.ssh"))',
        );
        final parentAt = profile.indexOf(
          '(allow file-$op* (subpath "/Users/agents"))',
        );
        expect(denyAt, greaterThanOrEqualTo(0), reason: 'deny $op missing');
        expect(parentAt, greaterThanOrEqualTo(0), reason: 'parent $op');
        // The child's deny is the LAST match under last-match-wins — the
        // kernel verdict equals the guard's longest-prefix verdict: deny.
        expect(
          denyAt,
          greaterThan(parentAt),
          reason: 'deny child $op rule must emit after the rw parent',
        );
      }
    });
  });

  // Issue #732: SBPL is LAST-match-wins per operation class, so emission
  // order is load-bearing and must be canonical — broadest path first,
  // narrowest last, independent of yaml declaration order. The live uv
  // break: a later, broader `ro /Users/agents/.local` deny-write landed
  // after the nested rw mount's allow and silently killed it.
  group('mount emission ordering (issue 732)', () {
    CubeSpec nested({required bool childFirst}) => CubeSpec(
      name: 'order-pinning',
      filesystem: CubeFsPolicy(
        workspace: '/work',
        mounts: childFirst
            ? const [
                CubeMount(
                  path: '/work/data/uv',
                  access: CubePathAccess.readWrite,
                ),
                CubeMount(path: '/work', access: CubePathAccess.readOnly),
              ]
            : const [
                CubeMount(path: '/work', access: CubePathAccess.readOnly),
                CubeMount(
                  path: '/work/data/uv',
                  access: CubePathAccess.readWrite,
                ),
              ],
      ),
    );

    test('declaration order does not change the emitted profile (AC2)', () {
      final childFirst = MacOsSandboxBackend().buildSandboxProfile(
        nested(childFirst: true),
      );
      final parentFirst = MacOsSandboxBackend().buildSandboxProfile(
        nested(childFirst: false),
      );
      // The kernel resolves conflicts by rule order, so both declaration
      // orders must compile to the SAME rule sequence: broad → narrow.
      expect(childFirst, equals(parentFirst));
    });

    test('the nested rw mount emits after the broader ro deny-write '
        '(the uv break)', () {
      // Child declared FIRST, broader ro parent LAST — the adversarial
      // order that used to make the parent's deny-write the last matching
      // write rule. The sorted emitter puts the narrowest mount last, so
      // its read AND write allows win per class.
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        nested(childFirst: true),
      );
      final parentDeny = profile.indexOf(
        '(deny file-write* (subpath "/work"))',
      );
      final childRead = profile.indexOf(
        '(allow file-read* (subpath "/work/data/uv"))',
      );
      final childWrite = profile.indexOf(
        '(allow file-write* (subpath "/work/data/uv"))',
      );
      expect(parentDeny, greaterThanOrEqualTo(0));
      expect(
        childRead,
        greaterThan(parentDeny),
        reason: 'rw read allow must outlast the broader ro deny-write',
      );
      expect(
        childWrite,
        greaterThan(parentDeny),
        reason: 'rw write allow must outlast the broader ro deny-write',
      );
    });

    test('/private-resolved variants stay adjacent, bare spelling first '
        '(E2)', () {
      final profile = MacOsSandboxBackend().buildSandboxProfile(
        CubeSpec(
          name: 'variants',
          filesystem: const CubeFsPolicy(
            workspace: '/work',
            mounts: [
              // Child first, ro parent last — the adversarial order again.
              CubeMount(path: '/etc/ssl', access: CubePathAccess.readWrite),
              CubeMount(path: '/etc', access: CubePathAccess.readOnly),
            ],
          ),
        ),
      );
      final lines = profile.split('\n');
      int at(String line) {
        final index = lines.indexOf(line);
        // A missing line must fail loudly — an absent -1 would slide
        // through every lessThan below.
        expect(index, isNonNegative, reason: '$line not emitted');
        return index;
      }

      // The sort keys on the declared path, so both spellings of one mount
      // emit adjacently, variants never interleave across mounts, and the
      // nested mount's variants land after the parent's.
      expect(
        at('(deny file-write* (subpath "/etc"))'),
        lessThan(at('(deny file-write* (subpath "/private/etc"))')),
      );
      expect(
        at('(deny file-write* (subpath "/private/etc"))'),
        lessThan(at('(allow file-write* (subpath "/etc/ssl"))')),
      );
      expect(
        at('(allow file-write* (subpath "/etc/ssl"))'),
        lessThan(at('(allow file-write* (subpath "/private/etc/ssl"))')),
      );
    });
  });

  // Issue #709 REG1: the macOS emission fix must not drift the other
  // backends' rule generation — linux re-binds ro mounts only, windows maps
  // limits to Job Object flags, no-op stays a passthrough.
  group('REG1: non-macOS backends unchanged (issue 709)', () {
    test(
      'linux unshare re-binds ro mounts only; an rw mount binds nothing',
      () {
        final wrapped = LinuxUnshareBackend(
          spec: CubeSpec(
            name: 'test-cube',
            filesystem: const CubeFsPolicy(
              mounts: [
                CubeMount(path: '/Users/ro', access: CubePathAccess.readOnly),
                CubeMount(path: '/Users/rw', access: CubePathAccess.readWrite),
              ],
            ),
          ),
          workspaceRoot: '/real/cwd',
          tmpdir: '/real/cwd/.fah/tmp',
        ).wrapCommand('git status', profilePath: '/p.sb');
        // ro: re-bound read-only. rw: no bind at all (reads are unconfined in
        // the namespace; writes flow from the mount's host writability).
        expect(wrapped, contains('mount --bind'));
        expect(wrapped, contains('remount,ro,bind'));
        expect(wrapped, contains('/Users/ro'));
        expect(wrapped, isNot(contains('/Users/rw')));
      },
    );

    test('windows descriptor and no-op passthrough are untouched', () {
      final descriptor = WindowsJobBackend.buildJobDescriptor(
        const CubeResourceLimits(memoryBytes: 512 * 1024 * 1024),
      );
      expect((descriptor['flags'] as int) & 0x100, 0x100);
      expect(descriptor['processMemoryLimitBytes'], 512 * 1024 * 1024);
      const noOp = NoOpCubeBackend();
      expect(
        noOp.wrapCommand('git status', profilePath: '/x.sb'),
        'git status',
      );
      expect(noOp.enforces, isFalse);
    });
  });
}
