/// Linux backend: `unshare` user-namespace confinement for cube runs.
///
/// Phase 1 exports the argv prefix for review and testing; the actual
/// exec-wrapping lands with the Linux backend phase. User namespaces give
/// an unprivileged process mount+pid+network isolation without root.
library;

import '../config/cube_spec.dart';
import 'cube_backend.dart';

/// The Linux backend: `unshare` argv generation (activation: Phase 2).
final class LinuxUnshareBackend implements CubeSandboxBackend {
  /// Creates the Linux backend.
  const LinuxUnshareBackend();

  @override
  String wrapCommand(String command) => command;

  @override
  String describe() =>
      'Linux unshare user-namespace argv generated (activation: Phase 2)';

  /// Builds the `unshare` argv prefix for [spec]; the cube's command is
  /// appended after the trailing `--` at activation time. `--net` is
  /// included only when the spec allows no network at all.
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
}
