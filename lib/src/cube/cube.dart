/// fa_cube: declarative sandbox profiles ("cubes") for sandboxed runs.
///
/// A [CubeSpec] manifest (`.fah/cubes/<name>.yaml`) clamps shell commands,
/// filesystem access and network egress for a run. [CubeResolver] locates
/// manifests, [SandboxedExecutionEnv] enforces them over any
/// [ExecutionEnv], [CubeCacheManager] content-addresses their caches, and
/// `cubeBackendForPlatform` names the OS-level backend (Phase 1: profile
/// generation only).
library;

export 'backends/cube_backend.dart';
export 'backends/linux_unshare.dart';
export 'backends/macos_sandbox.dart';
export 'backends/no_op_backend.dart';
export 'backends/windows_job.dart';
export 'config/cache_policy.dart';
export 'config/cube_settings.dart';
export 'config/cube_spec.dart';
export 'config/env_policy.dart';
export 'config/fs_policy.dart';
export 'config/network_policy.dart';
export 'config/resource_limits.dart';
export 'config/tool_policy.dart';
export 'runtime/cache_manager.dart';
export 'runtime/cube_fs_guard.dart';
export 'runtime/cube_resolver.dart';
export 'runtime/policy_engine.dart';
export 'runtime/sandboxed_env.dart';
export 'runtime/sandboxed_shell.dart';
