/// Linux backend: `unshare` user-namespace confinement for cube runs.
///
/// User namespaces give an unprivileged process mount+pid+network isolation
/// without root. The wrapped command re-binds `ro` mounts read-only, applies
/// `ulimit` resource ceilings and starts from a clean environment
/// (`env -i`), then runs the command in bash.
///
/// Test-environment note: user namespaces are unavailable on many CI
/// containers (`unshare --user --map-root-user true` → EPERM), so kernel
/// mode is covered by argv/staging unit tests here; live enforcement is
/// validated on hosts where user namespaces are enabled.
library;

import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import 'cube_backend.dart';

/// The Linux backend: `unshare` argv generation plus command wrapping.
final class LinuxUnshareBackend
    implements CubeSandboxBackend, CubeProfileStaging {
  /// Creates the backend bound to a run's context. The spec drives the
  /// mount/limit preamble and the `--net` decision; the defaults exist for
  /// bare display/backends-picked-outside-a-run.
  const LinuxUnshareBackend({
    this.spec = const CubeSpec(name: 'host'),
    this.workspaceRoot = '/workspace',
    this.tmpdir = '/tmp',
    this.envVars = const {},
  });

  /// The cube spec whose mounts, limits and network policy apply.
  final CubeSpec spec;

  /// The real writable root (the env cwd) — `HOME` inside the sandbox.
  final String workspaceRoot;

  /// Writable scratch directory handed to the child as `TMPDIR`.
  final String tmpdir;

  /// The cube's injected environment variables (hidden vars excluded).
  final Map<String, String> envVars;

  @override
  bool get enforces => true;

  @override
  String wrapCommand(String command, {required String profilePath}) {
    // The preamble is inlined into the wrapped bash script, so the staged
    // profile file is an audit artifact only — the exec never reads it.
    final argv = buildUnshareArgv(spec);
    final prefix = argv.sublist(0, argv.length - 1).join(' ');
    final script = '${_preamble(spec)}$command';
    final env = cubeEnvPrefix(
      workspaceRoot: workspaceRoot,
      tmpdir: tmpdir,
      envVars: envVars,
    );
    return '$prefix -i $env /bin/bash -c ${shellQuote(script)}';
  }

  @override
  String describe() =>
      'Linux unshare user-namespace (mount/pid/net isolation, ulimit '
      'ceilings, clean env -i; kernel enforcement active in backend: '
      'kernel mode)';

  @override
  String buildProfile(CubeSpec spec, {required String workspaceRoot}) =>
      _preamble(spec);

  /// Builds the `unshare` argv for [spec]; the cube's command is appended
  /// after the trailing `--` at activation time. `--net` is included only
  /// when the spec allows no network at all.
  ///
  // ponytail: no network at all beats a leaky allowlist — fine-grained
  // egress filtering waits for the proxy phase.
  List<String> buildUnshareArgv(CubeSpec spec, {String? workspaceRoot}) {
    return [
      'unshare',
      '--user',
      '--map-root-user',
      '--mount',
      '--pid',
      '--fork',
      '--mount-proc',
      if (!spec.network.allowsAnyNetwork) '--net',
      '/usr/bin/env',
      '--',
    ];
  }

  /// The bash preamble inlined before the command inside the wrapped script.
  ///
  /// - `ro` mounts are re-bound read-only (`mount --bind` + `remount,ro`).
  /// - `memoryBytes` becomes `ulimit -v` (KiB, rounded up).
  /// - the wall-clock timeout doubles as a CPU-seconds ceiling
  ///   (`ulimit -t`).
  ///
  // ponytail: cpu "50%" has no ulimit equivalent and is ignored here —
  // cgroup/cpu.rate enforcement is a follow-up; deny mounts likewise cannot
  // be unmounted by an unprivileged user, so on Linux they stay covered by
  // the Dart fs guard only (SBPL covers them on macOS).
  String _preamble(CubeSpec spec) {
    final parts = <String>[
      for (final mount in spec.filesystem.mounts)
        if (mount.access == CubePathAccess.readOnly)
          'mount --bind ${shellQuote(mount.path)} ${shellQuote(mount.path)} '
              '&& mount -o remount,ro,bind ${shellQuote(mount.path)};',
    ];
    final memory = spec.resources.memoryBytes;
    if (memory != null) {
      parts.add('ulimit -v ${(memory + 1023) ~/ 1024};');
    }
    final timeout = spec.resources.timeout;
    if (timeout != null) {
      parts.add('ulimit -t ${timeout.inSeconds};');
    }
    return parts.isEmpty ? '' : '${parts.join(' ')} ';
  }
}
