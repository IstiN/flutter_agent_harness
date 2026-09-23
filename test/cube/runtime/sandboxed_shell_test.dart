import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A [Shell] returning a canned result and recording its invocations.
class _RecordingShell implements Shell {
  final commands = <String>[];
  final options = <ShellExecOptions?>[];
  Result<ShellExecResult, ExecutionError> result = const Ok(
    ShellExecResult(stdout: 'out', stderr: '', exitCode: 0),
  );

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    this.options.add(options);
    return result;
  }
}

CubeSpec spec({
  Set<String> allow = const {'git', 'echo'},
  bool networkAllowed = false,
  CubeResourceLimits resources = const CubeResourceLimits(),
  CubeEnvPolicy env = const CubeEnvPolicy(),
}) => CubeSpec(
  name: 'test-cube',
  tools: CubeToolPolicy(allow: allow),
  network: CubeNetworkPolicy(
    allow: networkAllowed ? [const CubeNetworkRule(host: '*')] : const [],
  ),
  resources: resources,
  env: env,
);

/// The final staged profile path from the fake fs (renames carry the
/// temp-to-final flip; writes only ever see the temp name).
String _stagedPath(_RenamingFs fs) => fs.renames.last.$2;

void main() {
  group('SandboxedShell', () {
    test('forwards an allowed command to the inner shell', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      final result = await shell.exec('git status');
      expect(result.getOrThrow().stdout, 'out');
      expect(inner.commands, ['git status']);
    });

    test('denied command never reaches the inner shell', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      final result = await shell.exec('rm -rf /');
      final exec = result.getOrThrow();
      expect(exec.exitCode, 127);
      expect(exec.stdout, '');
      expect(exec.stderr, startsWith('fa_cube[test-cube]:'));
      expect(inner.commands, isEmpty);
    });

    test('injects the cube env vars additively', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(
          env: CubeEnvPolicy(
            vars: [CubeEnvValue(name: 'FAH_MODE', value: 'sandboxed')],
          ),
        ),
      );
      await shell.exec('git status');
      expect(inner.options.last?.env, {'FAH_MODE': 'sandboxed'});

      // Per-call env entries win over the injected vars.
      await shell.exec(
        'git status',
        options: ShellExecOptions(env: {'FAH_MODE': 'custom', 'X': '1'}),
      );
      expect(inner.options.last?.env, {'FAH_MODE': 'custom', 'X': '1'});
    });

    test('an empty env policy forwards the options untouched', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      final sentinel = ShellExecOptions(env: {'X': '1'});
      await shell.exec('git status', options: sentinel);
      expect(inner.options.last, same(sentinel));
    });

    test('clamps the caller timeout to the cube timeout', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(resources: CubeResourceLimits(timeout: Duration(seconds: 1))),
      );
      await shell.exec(
        'git status',
        options: ShellExecOptions(timeout: Duration(seconds: 10)),
      );
      expect(inner.options.last?.timeout, const Duration(seconds: 1));
    });

    test('a null caller timeout inherits the cube timeout', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(resources: CubeResourceLimits(timeout: Duration(seconds: 1))),
      );
      await shell.exec('git status');
      expect(inner.options.last?.timeout, const Duration(seconds: 1));
    });

    test('a tighter caller timeout wins over the cube timeout', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(resources: CubeResourceLimits(timeout: Duration(seconds: 1))),
      );
      await shell.exec(
        'git status',
        options: ShellExecOptions(timeout: Duration(milliseconds: 500)),
      );
      expect(inner.options.last?.timeout, const Duration(milliseconds: 500));
    });

    test('updateSpec swaps the policy live', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      expect(
        (await shell.exec('curl https://x.dev')).getOrThrow().exitCode,
        127,
      );
      shell.updateSpec(
        spec(allow: {'git', 'echo', 'curl'}, networkAllowed: true),
      );
      expect(
        (await shell.exec('curl https://x.dev')).getOrThrow().stdout,
        'out',
      );
      expect(inner.commands, hasLength(1));
    });

    test('clearSpec switches to full passthrough', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      shell.clearSpec();
      final sentinel = ShellExecOptions(timeout: Duration(seconds: 3));
      expect(
        (await shell.exec('rm -rf /', options: sentinel)).getOrThrow().stdout,
        'out',
      );
      expect(inner.commands, ['rm -rf /']);
      expect(inner.options.last, same(sentinel));
    });
  });

  group('SandboxedShell kernel mode', () {
    CubeSpec kernelSpec({
      CubeEnvPolicy env = const CubeEnvPolicy(),
      bool networkAllowed = false,
      bool allowDegrade = false,
      String backend = 'kernel',
    }) => CubeSpec(
      name: 'test-cube',
      backend: CubeBackendMode.values.byName(backend),
      allowDegrade: allowDegrade,
      tools: const CubeToolPolicy(allow: {'git', 'echo'}),
      network: CubeNetworkPolicy(
        allow: networkAllowed ? [const CubeNetworkRule(host: '*')] : const [],
      ),
      env: env,
    );

    test(
      'stages the verified profile outside the workspace and wraps commands',
      () async {
        final inner = _RecordingShell();
        final fs = _RenamingFs();
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: '/home',
        );

        await shell.exec('git status');
        final profilePath = _stagedPath(fs);
        expect(profilePath, startsWith('/home/.fah/cube-profiles/'));
        expect(profilePath, isNot(startsWith('/work')));
        expect(fs.files[profilePath], startsWith('(version 1)'));
        expect(
          inner.commands.single,
          contains("sandbox-exec -f '$profilePath'"),
        );
        expect(inner.commands.single, contains('/usr/bin/env -i '));
        expect(inner.commands.single, contains("HOME='/work'"));
        expect(inner.commands.single, contains("TMPDIR='/work/.fah/tmp'"));
        expect(inner.commands.single, endsWith(shellQuote('git status')));

        // Second exec: content verified, no rewrite, same staging.
        await shell.exec('git log');
        expect(fs.renames, hasLength(1));
        expect(inner.commands, hasLength(2));
      },
    );

    test(
      'REG: the staged profile path never resolves under the workspace',
      () async {
        final specs = [
          kernelSpec(),
          kernelSpec(networkAllowed: true),
          CubeSpec(
            name: 'mixed-mounts',
            backend: CubeBackendMode.kernel,
            tools: const CubeToolPolicy(allow: {'git'}),
            filesystem: const CubeFsPolicy(
              workspace: '/work',
              mounts: [
                CubeMount(path: '/etc', access: CubePathAccess.readOnly),
                CubeMount(path: '/data', access: CubePathAccess.deny),
              ],
            ),
          ),
        ];
        for (final spec in specs) {
          for (final cwd in const ['/work', '/Users/dev/project']) {
            final fs = _RenamingFs()..cwd = cwd;
            final shell = SandboxedShell(
              _RecordingShell(),
              spec,
              fs: fs,
              os: 'macos',
              homeDir: '/home/tester',
            );
            final outcome = await shell.exec('git status');
            expect(
              outcome.getOrThrow().exitCode,
              isNot(127),
              reason: '${spec.name} @$cwd should wrap, not deny',
            );
            final staged = _stagedPath(fs);
            expect(
              staged,
              startsWith('/home/tester/.fah/cube-profiles/'),
              reason: '${spec.name} @$cwd',
            );
            expect(
              fs.writes.keys.where((p) => p.startsWith('$cwd/')),
              isEmpty,
              reason: '${spec.name} @$cwd: no artifact under the workspace',
            );
          }
        }
      },
    );

    test('REG: a spec mounting the staging area read-write is refused, '
        'never staged', () async {
      // `~`-rw and `/`-rw mounts both make the profile prisoner-writable
      // (the repository-authored spec is the attacker vehicle here).
      final base = kernelSpec();
      final specs = [
        (
          'home-rw',
          CubeSpec(
            name: base.name,
            backend: base.backend,
            tools: base.tools,
            network: base.network,
            filesystem: const CubeFsPolicy(
              workspace: '/work',
              mounts: [CubeMount(path: '~', access: CubePathAccess.readWrite)],
            ),
          ),
          '/home/tester',
          '/home/tester/.fah/cube-profiles',
        ),
        (
          'root-rw',
          CubeSpec(
            name: base.name,
            backend: base.backend,
            tools: base.tools,
            network: base.network,
            filesystem: const CubeFsPolicy(
              workspace: '/work',
              mounts: [CubeMount(path: '/', access: CubePathAccess.readWrite)],
            ),
          ),
          '/home/tester',
          '/home/tester/.fah/cube-profiles',
        ),
      ];
      for (final (label, spec, home, staging) in specs) {
        for (final cwd in const ['/work', '/Users/dev/project']) {
          final inner = _RecordingShell();
          final fs = _RenamingFs()..cwd = cwd;
          final shell = SandboxedShell(
            inner,
            spec,
            fs: fs,
            os: 'macos',
            homeDir: home,
          );
          final error = (await shell.exec('git status')).errorOrNull;
          expect(error, isNotNull, reason: '$label @$cwd must be refused');
          expect(
            error!.message,
            contains(
              'profile staging directory <$staging> is '
              'guest-writable under the spec mounts',
            ),
            reason: '$label @$cwd',
          );
          // The refusal discloses the escape hatch (round-3 review).
          expect(
            error.message,
            contains('set spec.allowDegrade: true'),
            reason: '$label @$cwd',
          );
          expect(inner.commands, isEmpty, reason: '$label @$cwd');
          expect(fs.writes, isEmpty, reason: '$label @$cwd');
        }
      }
    });

    test('an L3-shaped blocking spec with allowDegrade degrades to policy '
        'mode and fires onDegrade', () async {
      // Same mount shape the L3 presets carry (`/`-rw): with the explicit
      // opt-in the shell degrades instead of hard-locking.
      final base = kernelSpec();
      final spec = CubeSpec(
        name: base.name,
        backend: base.backend,
        tools: base.tools,
        network: base.network,
        allowDegrade: true,
        filesystem: const CubeFsPolicy(
          workspace: '/work',
          mounts: [CubeMount(path: '/', access: CubePathAccess.readWrite)],
        ),
      );
      final inner = _RecordingShell();
      final fs = _RenamingFs();
      final degrades = <String>[];
      final shell = SandboxedShell(
        inner,
        spec,
        fs: fs,
        os: 'macos',
        homeDir: '/home',
        onDegrade: degrades.add,
      );
      final result = await shell.exec('git status');
      expect(result.errorOrNull, isNull);
      expect(inner.commands.single, 'git status');
      expect(fs.writes, isEmpty, reason: 'nothing staged in policy mode');
      expect(shell.effectiveBackend, CubeBackendMode.policy);
      expect(degrades, hasLength(1));
      expect(
        degrades.single,
        allOf(
          contains('guest-writable under the spec mounts'),
          contains('running in policy mode'),
        ),
      );
    });

    test(
      'a pre-seeded profile in the old in-workspace location is inert',
      () async {
        final inner = _RecordingShell();
        final fs = _RenamingFs();
        final oldPath =
            '/work/.fah/cube-profiles/${cubeSpecCacheKey(kernelSpec())}.sb';
        fs.seed(oldPath, '(version 1)\n(allow default)\n');
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: '/home',
        );

        await shell.exec('git status');
        final profilePath = _stagedPath(fs);
        expect(profilePath, startsWith('/home/.fah/cube-profiles/'));
        expect(
          inner.commands.single,
          contains("sandbox-exec -f '$profilePath'"),
        );
        // The old-location file is never read, trusted or passed to exec.
        expect(inner.commands.single, isNot(contains(oldPath)));
        expect(fs.writes.keys, isNot(contains(oldPath)));
      },
    );

    test(
      'a tampered profile in the staging location is restaged before exec',
      () async {
        final inner = _RecordingShell();
        final fs = _RenamingFs();
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: '/home',
        );

        await shell.exec('git status');
        final profilePath = _stagedPath(fs);
        final genuine = fs.files[profilePath]!;

        // The "prisoner" rewrites the staged profile between runs.
        fs.files[profilePath] = '(version 1)\n(allow default)\n';

        await shell.exec('git log');
        // Restaged atomically (temp + rename) and the tampered bytes are
        // gone: exec never saw them.
        expect(fs.renames, hasLength(2));
        expect(fs.renames.last.$2, profilePath);
        expect(fs.files[profilePath], genuine);
        expect(inner.commands, hasLength(2));
        expect(inner.commands.last, contains("sandbox-exec -f '$profilePath'"));
      },
    );

    test(
      'a kernel spec without a home is refused (nothing to stage on)',
      () async {
        final inner = _RecordingShell();
        final fs = _RenamingFs();
        final shell = SandboxedShell(inner, kernelSpec(), fs: fs, os: 'macos');
        final error = (await shell.exec('git status')).errorOrNull;
        expect(error!.message, contains('allowDegrade'));
        expect(inner.commands, isEmpty);
      },
    );

    test(
      'a filesystem without atomic rename refuses staging and never execs',
      () async {
        final inner = _RecordingShell();
        final fs = _FakeFs();
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: '/home',
        );
        final error = (await shell.exec('git status')).errorOrNull;
        expect(error, isNotNull);
        expect(error!.code, ExecutionErrorCode.spawnError);
        expect(error.message, contains('profile staging failed'));
        expect(fs.writes, isEmpty);
        expect(inner.commands, isEmpty);
      },
    );

    test('injected env vars ride inside the clean environment', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        kernelSpec(
          env: const CubeEnvPolicy(
            vars: [CubeEnvValue(name: 'FAH_MODE', value: 'sandboxed')],
          ),
        ),
        fs: _RenamingFs(),
        os: 'macos',
        homeDir: '/home',
      );
      await shell.exec('git status');
      expect(inner.commands.single, contains("FAH_MODE='sandboxed'"));
    });

    test('caller options.env rides inside the clean environment', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        kernelSpec(
          env: const CubeEnvPolicy(
            vars: [CubeEnvValue(name: 'FAH_MODE', value: 'sandboxed')],
          ),
        ),
        fs: _RenamingFs(),
        os: 'macos',
        homeDir: '/home',
      );
      await shell.exec(
        'git status',
        options: const ShellExecOptions(
          env: {'FAH_SESSION_ID': 'sess 42', 'FAH_MODE': 'override'},
        ),
      );
      final wrapped = inner.commands.single;
      expect(wrapped, contains("FAH_SESSION_ID='sess 42'"));
      // Caller wins over the cube-bound value.
      expect(wrapped, contains("FAH_MODE='override'"));
      expect(wrapped, isNot(contains("FAH_MODE='sandboxed'")));
    });

    test('policy mode never stages or wraps', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(
        inner,
        kernelSpec(backend: 'policy'),
        fs: fs,
        os: 'macos',
      );
      await shell.exec('git status');
      expect(fs.writes, isEmpty);
      expect(inner.commands.single, 'git status');
    });

    test('AC1: a kernel spec on a platform without a backend is refused with '
        'zero commands', () async {
      final inner = _RecordingShell();
      final fs = _RenamingFs();
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: fs,
        os: 'windows',
        homeDir: '/home',
      );
      final error = (await shell.exec('git status')).errorOrNull;
      expect(error, isNotNull);
      expect(error!.code, ExecutionErrorCode.spawnError);
      expect(error.message, contains('allowDegrade'));
      expect(error.message, startsWith('fa_cube[test-cube]:'));
      expect(inner.commands, isEmpty);
      expect(fs.writes, isEmpty);
      expect(shell.effectiveBackend, isNull);
    });

    test(
      'AC1: a kernel spec without a platform or home is refused too',
      () async {
        for (final shell in [
          SandboxedShell(_RecordingShell(), kernelSpec(), fs: _RenamingFs()),
          SandboxedShell(
            _RecordingShell(),
            kernelSpec(),
            fs: _RenamingFs(),
            os: 'macos',
          ),
        ]) {
          final error = (await shell.exec('git status')).errorOrNull;
          expect(error, isNotNull);
          expect(error!.message, contains('allowDegrade'));
        }
      },
    );

    test(
      'AC2: allowDegrade runs in policy mode loudly and queryably',
      () async {
        final inner = _RecordingShell();
        final degradations = <String>[];
        final shell = SandboxedShell(
          inner,
          kernelSpec(allowDegrade: true),
          fs: _RenamingFs(),
          os: 'windows',
          homeDir: '/home',
          onDegrade: degradations.add,
        );
        final result = await shell.exec('git status');
        expect(result.getOrThrow().stdout, 'out');
        expect(inner.commands.single, 'git status');
        expect(degradations, hasLength(1));
        expect(degradations.single, startsWith('fa_cube[test-cube]:'));
        expect(degradations.single, contains('policy mode'));
        expect(shell.effectiveBackend, CubeBackendMode.policy);
      },
    );

    test('effectiveBackend reports the mode each spec actually runs', () {
      final shell = SandboxedShell(_RecordingShell(), null);
      expect(shell.effectiveBackend, isNull);
      shell.updateSpec(kernelSpec(backend: 'policy'));
      expect(shell.effectiveBackend, CubeBackendMode.policy);
      shell.clearSpec();
      expect(shell.effectiveBackend, isNull);
      // macos + home + fs deliver the kernel backend.
      final kernelShell = SandboxedShell(
        _RecordingShell(),
        kernelSpec(),
        fs: _RenamingFs(),
        os: 'macos',
        homeDir: '/home',
      );
      expect(kernelShell.effectiveBackend, CubeBackendMode.kernel);
    });

    test('AC3 REG: an explicit kernel spec never silently executes in policy '
        'mode', () async {
      for (final os in const ['macos', 'linux', 'windows', null]) {
        for (final allowDegrade in const [false, true]) {
          final inner = _RecordingShell();
          final degradations = <String>[];
          final withFs = os != null;
          final shell = SandboxedShell(
            inner,
            kernelSpec(allowDegrade: allowDegrade),
            fs: withFs ? _RenamingFs() : null,
            os: os,
            homeDir: withFs ? '/home' : null,
            onDegrade: degradations.add,
          );
          final outcome = await shell.exec('git status');
          final ran = inner.commands;
          if (ran.isEmpty) {
            // Refused: nothing executed, and the refusal names the opt-in.
            expect(
              outcome.errorOrNull!.message,
              contains('allowDegrade'),
              reason: 'os=$os allowDegrade=$allowDegrade',
            );
            expect(
              allowDegrade,
              isFalse,
              reason: 'a degrading spec must run: os=$os',
            );
          } else {
            expect(ran, hasLength(1), reason: 'os=$os');
            if (ran.single == 'git status') {
              // UNWRAPPED execution in policy mode is only ever legal
              // through the explicit allowDegrade opt-in, loudly.
              expect(
                allowDegrade,
                isTrue,
                reason: 'os=$os: explicit kernel silently ran in policy mode',
              );
              expect(degradations, hasLength(1), reason: 'os=$os');
              expect(
                shell.effectiveBackend,
                CubeBackendMode.policy,
                reason: 'os=$os',
              );
            } else {
              // Kernel-wrapped: binary on PATH is irrelevant here — the
              // wrap shape itself proves kernel mode was honored.
              expect(
                ran.single,
                anyOf(contains('sandbox-exec'), contains('unshare')),
                reason: 'os=$os',
              );
              expect(
                shell.effectiveBackend,
                CubeBackendMode.kernel,
                reason: 'os=$os',
              );
            }
          }
        }
      }
    });

    test('an enforcing kernel spec does not report degradation', () async {
      final degradations = <String>[];
      final shell = SandboxedShell(
        _RecordingShell(),
        kernelSpec(),
        fs: _RenamingFs(),
        os: 'macos',
        homeDir: '/home',
        onDegrade: degradations.add,
      );
      await shell.exec('git status');
      expect(degradations, isEmpty);
    });

    group('SEC-02 staging invariant', () {
      test('a workspace-relative homeDir fail-closes kernel mode', () async {
        final inner = _RecordingShell();
        final fs = _RenamingFs();
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: 'relative/home',
        );
        final error = (await shell.exec('git status')).errorOrNull;
        expect(error, isNotNull);
        expect(error!.code, ExecutionErrorCode.spawnError);
        expect(
          error.message,
          startsWith(
            'fa_cube[test-cube]: kernel backend profile staging directory '
            'must be an absolute path '
            '(got <relative/home/.fah/cube-profiles>)',
          ),
        );
        expect(error.message, contains('spec.allowDegrade: true'));
        expect(inner.commands, isEmpty);
        expect(fs.writes, isEmpty);
        expect(fs.renames, isEmpty);
      });

      test('a homeDir inside the workspace fail-closes kernel mode', () async {
        for (final home in ['/work', '/work/home', '/work/../work/steal']) {
          final inner = _RecordingShell();
          final fs = _RenamingFs();
          final shell = SandboxedShell(
            inner,
            kernelSpec(),
            fs: fs,
            os: 'macos',
            homeDir: home,
          );
          final error = (await shell.exec('git status')).errorOrNull;
          expect(error, isNotNull, reason: 'home $home must be refused');
          expect(
            error!.message,
            contains(
              'is inside the guest-writable '
              'workspace </work>',
            ),
            reason: 'home $home must be refused',
          );
          expect(inner.commands, isEmpty, reason: 'home $home');
          expect(fs.writes, isEmpty, reason: 'home $home');
        }
      });

      test('`..` cannot smuggle a home outside the workspace back in', () {
        // '/outside/../work/steal' normalizes to '/work/steal' — inside.
        expect(
          stagingOutsideWorkspace(
            '/outside/../work/steal/.fah/cube-profiles',
            '/work',
          ),
          isNotNull,
        );
        // The inverse is genuinely outside and stays allowed.
        expect(
          stagingOutsideWorkspace('/work/../home/.fah/cube-profiles', '/work'),
          isNull,
        );
        // A sibling directory is not the workspace.
        expect(
          stagingOutsideWorkspace('/workspace/.fah/cube-profiles', '/work'),
          isNull,
        );
      });

      test('kernel staging refuses background preparation when the fs cannot '
          'atomically restage', () async {
        final inner = _RecordingShell();
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _FakeFs(), // no rename capability
          os: 'macos',
          homeDir: '/home',
        );
        final note = await shell.startupFailure();
        expect(note, isNotNull);
        expect(note, startsWith('fa_cube[test-cube]: kernel backend '));
        // One error shape everywhere: the probe note and the staging
        // error render identically.
        expect(note, shell.kernelError(shell.kernelStagingError!));
        expect(await shell.prepare('git status'), isNull);
        expect(inner.commands, isEmpty);
      });

      test(
        'prepare refuses when staging fails after the probe passed',
        () async {
          final inner = _RecordingShell();
          final fs = _RenamingFs();
          final shell = SandboxedShell(
            inner,
            kernelSpec(),
            fs: fs,
            os: 'macos',
            homeDir: '/home',
          );
          // The startup probe passes: the profile stages and verifies.
          expect(await shell.startupFailure(), isNull);
          // Then the "prisoner" tampers and restaging becomes impossible —
          // the probe can no longer vouch for the next exec.
          fs.tamper(_stagedPath(fs));
          fs.broken = true;
          expect(await shell.prepare('git status'), isNull);
          expect(
            shell.kernelStagingError,
            startsWith('profile staging failed:'),
          );
          // Only the startup probe's wrapped no-op ran — never the payload.
          expect(inner.commands, hasLength(1));
          expect(inner.commands.single, contains("'true'"));
        },
      );
    });

    test('staging sweeps its own tmp orphans once per binding and leaves '
        'other bindings alone', () async {
      final inner = _RecordingShell();
      final fs = _RenamingFs();
      const profileDir = '/home/.fah/cube-profiles';
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: fs,
        os: 'macos',
        homeDir: '/home',
      );
      await shell.exec('git status');
      final profilePath = _stagedPath(fs);
      final ownName = profilePath.split('/').last;
      // A crashed restage of THIS binding, a crashed restage of another
      // spec's binding, and another spec's live profile.
      fs.seed('$profileDir/$ownName.42-0.tmp', 'junk');
      fs.seed('$profileDir/othercontenthash.7-1.tmp', 'junk');
      fs.seed('$profileDir/othercontenthash.sb', '(version 1)\nstale');
      fs.removed.clear();

      // Rebind (as `/cube use` would): the fresh binding sweeps once.
      shell.updateSpec(kernelSpec());
      await shell.exec('git log');
      expect(fs.removed, ['$profileDir/$ownName.42-0.tmp']);
      expect(fs.files.containsKey('$profileDir/othercontenthash.sb'), isTrue);
      expect(
        fs.files.containsKey('$profileDir/othercontenthash.7-1.tmp'),
        isTrue,
      );
      expect(inner.commands.last, contains("sandbox-exec -f '$profilePath'"));
      // Swept once, not per exec.
      await shell.exec('git status');
      expect(fs.removed, hasLength(1));
    });

    test(
      'a missing sandbox-exec spawn failure maps to a clean error',
      () async {
        final inner = _RecordingShell()
          ..result = const Err(
            ExecutionError(
              ExecutionErrorCode.spawnError,
              'ProcessException: No such file or directory\n'
              '  Command: sandbox-exec -f /work/.fah/cube-profiles/x.sb ...',
            ),
          );
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _RenamingFs(),
          os: 'macos',
          homeDir: '/home',
        );
        final outcome = await shell.exec('git status');
        final error = outcome.errorOrNull;
        expect(error, isNotNull);
        expect(error!.code, ExecutionErrorCode.spawnError);
        expect(
          error.message,
          'fa_cube[test-cube]: kernel backend requires '
          'sandbox-exec on PATH',
        );
      },
    );

    test('an exit-127 not-found stderr maps to a clean error', () async {
      final inner = _RecordingShell()
        ..result = const Ok(
          ShellExecResult(
            stdout: '',
            stderr: 'sh: sandbox-exec: command not found',
            exitCode: 127,
          ),
        );
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: _RenamingFs(),
        os: 'macos',
        homeDir: '/home',
      );
      final error = (await shell.exec('git status')).errorOrNull;
      expect(
        error!.message,
        'fa_cube[test-cube]: kernel backend requires sandbox-exec on PATH',
      );
    });

    test(
      'a wrapper refusing the sandbox (EPERM) maps to a clean error',
      () async {
        final inner = _RecordingShell()
          ..result = const Ok(
            ShellExecResult(
              stdout: '',
              stderr: 'unshare: unshare failed: Operation not permitted\n',
              exitCode: 1,
            ),
          );
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _RenamingFs(),
          os: 'linux',
          homeDir: '/home',
        );
        final error = (await shell.exec('git status')).errorOrNull;
        expect(error!.code, ExecutionErrorCode.spawnError);
        expect(
          error.message,
          'fa_cube[test-cube]: kernel backend unshare failed: '
          'unshare failed: Operation not permitted',
        );
      },
    );

    test('startupFailure probes once and reports a broken wrapper', () async {
      final inner = _RecordingShell()
        ..result = const Ok(
          ShellExecResult(
            stdout: '',
            stderr: 'unshare: unshare failed: Operation not permitted\n',
            exitCode: 1,
          ),
        );
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: _RenamingFs(),
        os: 'linux',
        homeDir: '/home',
      );
      final note = await shell.startupFailure();
      expect(
        note,
        'fa_cube[test-cube]: kernel backend unshare failed: '
        'unshare failed: Operation not permitted',
      );
      expect(await shell.startupFailure(), note);
      expect(inner.commands.length, 1);
    });

    test('startupFailure returns null when the wrapper works', () async {
      final inner = _RecordingShell()
        ..result = const Ok(
          ShellExecResult(stdout: '', stderr: '', exitCode: 0),
        );
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: _RenamingFs(),
        os: 'linux',
        homeDir: '/home',
      );
      expect(await shell.startupFailure(), isNull);
      expect(inner.commands.length, 1);
    });

    test(
      'a normal non-zero result inside the sandbox passes through',
      () async {
        final inner = _RecordingShell()
          ..result = const Ok(
            ShellExecResult(
              stdout: '',
              stderr: 'fatal: not a git repository',
              exitCode: 128,
            ),
          );
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _RenamingFs(),
          os: 'macos',
          homeDir: '/home',
        );
        final result = (await shell.exec('git status')).getOrThrow();
        expect(result.exitCode, 128);
      },
    );

    test('prepare wraps background job commands identically', () async {
      final inner = _RecordingShell();
      final fs = _RenamingFs();
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: fs,
        os: 'macos',
        homeDir: '/home',
      );
      final job = await shell.prepare('git status');
      expect(job, contains('sandbox-exec'));
      expect(fs.writes, hasLength(1));
    });

    test(
      'a staged profile with matching content is reused without a rewrite',
      () async {
        final inner = _RecordingShell();
        final fs = _RenamingFs();
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: '/home',
        );
        await shell.exec('git status');
        final profilePath = _stagedPath(fs);
        fs.writes.clear();
        fs.renames.clear();
        // Second shell, same spec + workspace: content hash matches, the
        // existing file is trusted without touching it.
        final second = SandboxedShell(
          inner,
          kernelSpec(),
          fs: fs,
          os: 'macos',
          homeDir: '/home',
        );
        await second.exec('git log');
        expect(fs.writes, isEmpty);
        expect(fs.renames, isEmpty);
        expect(inner.commands.last, contains("sandbox-exec -f '$profilePath'"));
      },
    );
  });
}

/// A [FileSystem] recording writes; only the staging-relevant members work.
/// No rename capability — kernel staging against this fake refuses (use
/// [_RenamingFs] for the renamable variant).
class _FakeFs implements FileSystem {
  @override
  String cwd = '/work';

  final Map<String, String> writes = {};
  final Map<String, String> files = {};
  final List<String> removed = [];

  void seed(String path, String content) => files[path] = content;

  @override
  Future<Result<bool, FileError>> exists(String path) async =>
      Ok(files.containsKey(path) || writes.containsKey(path));

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      Future.value(_record(path, content));

  Result<void, FileError> _record(String path, String content) {
    writes[path] = content;
    files[path] = content;
    return const Ok(null);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async =>
      files.containsKey(path)
      ? Ok(files[path]!)
      : const Err(FileError(FileErrorCode.notFound, 'missing'));

  @override
  Future<Result<String, FileError>> absolutePath(String path) async =>
      Ok('$cwd/$path');

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async => const Ok(null);

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async => _record(path, content);

  Err<T, FileError> _missing<T>() =>
      const Err(FileError(FileErrorCode.notFound, 'not supported by _FakeFs'));

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) async =>
      _missing();

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async =>
      _missing();

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async => _missing();

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async => _missing();

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async => _missing();

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final prefix = path.endsWith('/') ? path : '$path/';
    return Ok([
      for (final p in files.keys)
        if (p.startsWith(prefix) && !p.substring(prefix.length).contains('/'))
          FileInfo(
            name: p.substring(prefix.length),
            path: p,
            kind: FileKind.file,
            size: files[p]!.length,
            mtimeMs: 0,
          ),
    ]);
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    files.remove(path);
    writes.remove(path);
    removed.add(path);
    return const Ok(null);
  }
}

/// A renamable [_FakeFs]: the atomic temp+rename restaging path works.
class _RenamingFs extends _FakeFs implements RenamableFileSystem {
  final renames = <(String, String)>[];

  /// When set, restaging becomes impossible (simulates a failure window
  /// after the startup probe passed).
  bool broken = false;

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    if (broken) {
      return const Err(FileError(FileErrorCode.unknown, 'rename broken'));
    }
    if (!files.containsKey(from)) {
      return const Err(FileError(FileErrorCode.notFound, 'missing'));
    }
    renames.add((from, to));
    files[to] = files.remove(from)!;
    return const Ok(null);
  }

  /// Plants tampered bytes at [path], as the sandboxed guest would
  /// between two runs.
  void tamper(String path) => files[path] = '(version 1)\n(allow default)\n';
}
