/// macOS sandbox-exec backend: generates an SBPL profile from a cube spec
/// and wraps commands in `sandbox-exec -f <profile>`.
///
/// The generated policy mirrors [CubeSpec]: the workspace is writable, `ro`
/// mounts are readable but not writable, `deny` mounts vanish, and the
/// network is fully denied unless the spec allows it. The wrapped command
/// runs under `/usr/bin/env -i` — the clean-environment ceiling: inherited
/// host variables are gone, only the PATH/HOME/TMPDIR trio plus the cube's
/// injected vars are present.
library;

import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import 'cube_backend.dart';

/// The macOS backend: SBPL profile generation plus `sandbox-exec` wrapping.
final class MacOsSandboxBackend
    implements CubeSandboxBackend, CubeProfileStaging {
  /// Creates the backend bound to a run's context. The defaults exist for
  /// bare display/backends-picked-outside-a-run; kernel execution always
  /// passes the real workspace, tmpdir and injected env.
  const MacOsSandboxBackend({
    this.workspaceRoot = '/workspace',
    this.tmpdir = '/tmp',
    this.envVars = const {},
  });

  /// The real writable root (the env cwd) — `HOME` inside the sandbox.
  final String workspaceRoot;

  /// Writable scratch directory handed to the child as `TMPDIR`.
  final String tmpdir;

  /// The cube's injected environment variables (hidden vars excluded).
  final Map<String, String> envVars;

  @override
  bool get enforces => true;

  @override
  String wrapCommand(
    String command, {
    required String profilePath,
    Map<String, String> env = const {},
  }) {
    final prefix = cubeEnvPrefix(
      workspaceRoot: workspaceRoot,
      tmpdir: tmpdir,
      envVars: {...envVars, ...env},
    );
    return 'sandbox-exec -f ${shellQuote(profilePath)} '
        '/usr/bin/env -i $prefix /bin/bash -c ${shellQuote(command)}';
  }

  @override
  String buildProfile(CubeSpec spec, {required String workspaceRoot}) =>
      buildSandboxProfile(spec, workspaceRoot: workspaceRoot);

  @override
  String describe() =>
      'macOS sandbox-exec (SBPL profile + clean env -i; kernel enforcement '
      'active in backend: kernel mode)';

  /// Renders [spec] as an SBPL profile.
  ///
  /// [workspaceRoot] overrides the spec's workspace as the writable subpath
  /// (the CLI passes the real process cwd; the cube's `/workspace` is
  /// realized as the env cwd).
  ///
  /// The kernel matches SBPL patterns against the RESOLVED path: macOS
  /// firmware symlinks (`/etc`, `/tmp`, `/var` → `/private/...`) make a
  /// symlink-form pattern silently match nothing, so every confined path is
  /// emitted in BOTH forms. The shape stays allow-default + explicit denies
  /// — a catch-all `(deny file-read*)` aborts exec — and per-path rules
  /// always use `file-read*`/`file-write*` with `subpath` (the
  /// `file-read-data`/`literal` single-file forms do not hold).
  ///
  /// Resource honesty: SBPL has no cpu or memory primitive — `cpu` is
  /// accepted and round-tripped in the spec but enforced by no backend
  /// today, `memory` ceilings are Linux `ulimit -v` territory and the
  /// timeout is a harness wall-clock clamp, and `disk` is only ever the
  /// cache-prune bound, not a quota.
  String buildSandboxProfile(CubeSpec spec, {String? workspaceRoot}) {
    final workspace = workspaceRoot ?? spec.filesystem.workspace;
    final buffer = StringBuffer('(version 1)\n(allow default)\n');
    for (final path in _resolvedVariants(workspace)) {
      buffer.writeln('(allow file-write* (subpath "$path"))');
    }
    for (final mount in spec.filesystem.mounts) {
      for (final path in _resolvedVariants(mount.path)) {
        switch (mount.access) {
          case CubePathAccess.readOnly:
            buffer
              ..writeln('(allow file-read* (subpath "$path"))')
              ..writeln('(deny file-write* (subpath "$path"))');
          case CubePathAccess.deny:
            buffer
              ..writeln('(deny file-read* (subpath "$path"))')
              ..writeln('(deny file-write* (subpath "$path"))');
          case CubePathAccess.readWrite:
            buffer.writeln('(allow file-write* (subpath "$path"))');
        }
      }
    }
    buffer.writeln(
      spec.network.allowsAnyNetwork ? '(allow network*)' : '(deny network*)',
    );
    return buffer.toString();
  }
}

/// Both SBPL spellings for [path]: itself plus the `/private`-resolved form
/// when it lives under one of the firmware symlink roots. An already
/// canonical path maps to itself only.
List<String> _resolvedVariants(String path) {
  const roots = ['/etc', '/tmp', '/var'];
  for (final root in roots) {
    if (path == root || path.startsWith('$root/')) {
      return [path, '/private$path'];
    }
  }
  return [path];
}
