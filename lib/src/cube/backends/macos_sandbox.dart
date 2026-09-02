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
  String wrapCommand(String command, {required String profilePath}) {
    final prefix = cubeEnvPrefix(
      workspaceRoot: workspaceRoot,
      tmpdir: tmpdir,
      envVars: envVars,
    );
    return 'sandbox-exec -f ${shellQuote(profilePath)} '
        '/usr/bin/env -i $prefix /bin/bash -c ${shellQuote(command)}';
  }

  @override
  String describe() =>
      'macOS sandbox-exec (SBPL profile + clean env -i; kernel enforcement '
      'active in backend: kernel mode)';

  @override
  String buildProfile(CubeSpec spec, {required String workspaceRoot}) =>
      buildSandboxProfile(spec, workspaceRoot: workspaceRoot);

  /// Renders [spec] as an SBPL profile.
  ///
  /// [workspaceRoot] overrides the spec's workspace as the writable subpath
  /// (the CLI passes the real process cwd; the cube's `/workspace` is
  /// realized as the env cwd).
  String buildSandboxProfile(CubeSpec spec, {String? workspaceRoot}) {
    final workspace = workspaceRoot ?? spec.filesystem.workspace;
    final buffer = StringBuffer('(version 1)\n(allow default)\n');
    buffer.writeln('(allow file-write* (subpath "$workspace"))');
    for (final mount in spec.filesystem.mounts) {
      switch (mount.access) {
        case CubePathAccess.readOnly:
          buffer
            ..writeln('(allow file-read* (subpath "${mount.path}"))')
            ..writeln('(deny file-write* (subpath "${mount.path}"))');
        case CubePathAccess.deny:
          buffer
            ..writeln('(deny file-read* (subpath "${mount.path}"))')
            ..writeln('(deny file-write* (subpath "${mount.path}"))');
        case CubePathAccess.readWrite:
          buffer.writeln('(allow file-write* (subpath "${mount.path}"))');
      }
    }
    buffer.writeln(
      spec.network.allowsAnyNetwork ? '(allow network*)' : '(deny network*)',
    );
    return buffer.toString();
  }
}
