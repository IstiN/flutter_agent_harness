/// Kernel-level sandbox backends for cubes.
///
/// [CubeSandboxBackend] is the seam between the pure-Dart policy layers
/// (tool/network/fs guards in `lib/src/cube/runtime/`) and real OS
/// confinement. Phase 1 ships profile *generation* plus a [NoOpCubeBackend]
/// runtime; the macOS and Linux backends wrap commands in Phase 2.
library;

import 'linux_unshare.dart';
import 'macos_sandbox.dart';
import 'no_op_backend.dart';

/// A platform strategy for confining a cube's processes at the OS level.
abstract interface class CubeSandboxBackend {
  /// Wraps [command] so it runs inside the OS sandbox.
  String wrapCommand(String command);

  /// A human-readable description of the backend's current capability.
  String describe();
}

/// Picks the backend matching [os] (`macos`, `linux`, anything else falls
/// back to the no-op backend).
CubeSandboxBackend cubeBackendForPlatform(String os) {
  return switch (os) {
    'macos' => MacOsSandboxBackend(),
    'linux' => LinuxUnshareBackend(),
    _ => NoOpCubeBackend(),
  };
}
