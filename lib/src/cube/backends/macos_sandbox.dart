/// macOS sandbox-exec backend: generates an SBPL profile from a cube spec.
///
/// Phase 1 exports the profile (and tests it) for review; activating it
/// around child processes lands with the macOS backend phase. The
/// generated policy mirrors [CubeSpec]: the workspace is writable, `ro`
/// mounts are readable but not writable, `deny` mounts vanish, and the
/// network is fully denied unless the spec allows it.
library;

import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import 'cube_backend.dart';

/// The macOS backend: `sandbox-exec` profile generation (activation:
/// Phase 2).
final class MacOsSandboxBackend implements CubeSandboxBackend {
  /// Creates the macOS backend.
  const MacOsSandboxBackend();

  @override
  String wrapCommand(String command) => command;

  @override
  String describe() =>
      'macOS sandbox-exec profile generated (activation: Phase 2)';

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
