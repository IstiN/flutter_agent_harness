/// Kernel-level sandbox backends for cubes.
///
/// [CubeSandboxBackend] is the seam between the pure-Dart policy layers
/// (tool/network/fs guards in `lib/src/cube/runtime/`) and real OS
/// confinement. In `policy` mode the [NoOpCubeBackend] changes nothing; in
/// `kernel` mode the platform backend wraps each command in the OS sandbox
/// primitive (sandbox-exec on macOS, unshare on Linux).
library;

import 'linux_unshare.dart';
import 'macos_sandbox.dart';
import 'no_op_backend.dart';
import 'windows_job.dart';
import '../config/cube_spec.dart';

/// A platform strategy for confining a cube's processes at the OS level.
abstract interface class CubeSandboxBackend {
  /// Whether this backend actually confines at the OS level. `false` means
  /// [wrapCommand] is a passthrough and kernel mode degrades to the Dart
  /// policy layers.
  bool get enforces;

  /// Wraps [command] so it runs inside the OS sandbox. [profilePath] names
  /// the profile file staged for the current spec (`.fah/cube-profiles/`);
  /// implementations that confine by other means may ignore it. [env]
  /// carries the caller's per-exec environment ([ShellExecOptions.env]):
  /// kernel wrapping must thread it into the clean child environment or
  /// session vars and secrets are silently dropped — entries override the
  /// backend's cube-bound vars. Implementations that change nothing may
  /// ignore it too.
  String wrapCommand(
    String command, {
    required String profilePath,
    Map<String, String> env = const {},
  });
  String describe();
}

/// A backend whose kernel confinement is driven by a profile artifact that
/// must exist on disk before the wrapped command runs. [SandboxedShell]
/// probes for this capability and stages [buildProfile]'s output to
/// `.fah/cube-profiles/<cacheKey>.sb` (once per spec) before the first
/// wrapped exec.
abstract interface class CubeProfileStaging {
  /// The profile content for [spec]. [workspaceRoot] is the real writable
  /// root (the env cwd); the cube's `/workspace` is realized as that cwd.
  String buildProfile(CubeSpec spec, {required String workspaceRoot});
}

/// Quotes [value] as a single POSIX shell word: wrapped in single quotes
/// with embedded quotes escaped the standard `'\''` way. An empty value
/// becomes `''`.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The `env -i` VAR=value argument words for a kernel-wrapped run: the
/// fixed PATH trio, `HOME` at [workspaceRoot] and `TMPDIR` under it (the
/// only guaranteed-writable area), then the cube's injected [envVars] on
/// top (a same-named var overrides the default). Values are single-quoted
/// so paths with spaces survive the outer shell.
///
/// `env -i` is the clean-environment ceiling: nothing else leaks in from
/// the host, hidden vars stay hidden ([buildProfile]'s callers already
/// exclude them via `CubeEnvPolicy.apply`).
String cubeEnvPrefix({
  required String workspaceRoot,
  required String tmpdir,
  Map<String, String> envVars = const {},
}) {
  final vars = <String, String>{
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'HOME': workspaceRoot,
    'TMPDIR': tmpdir,
    ...envVars,
  };
  return [
    for (final entry in vars.entries) '${entry.key}=${shellQuote(entry.value)}',
  ].join(' ');
}

/// Picks the backend for host platform [os], bound to a run's context.
///
/// Kernel execution always goes through this constructor path —
/// [SandboxedShell] passes the real spec/workspace/tmpdir/env — while bare
/// `cubeBackendForPlatform(os)` calls (display, capability checks) get
/// inert defaults. Mapping: `macos` → sandbox-exec, `linux` → unshare,
/// `windows` → the Job Object descriptor (not enforcing), anything else →
/// the no-op backend.
CubeSandboxBackend cubeBackendForPlatform(
  String os, {
  CubeSpec spec = const CubeSpec(name: 'host'),
  String workspaceRoot = '/workspace',
  String tmpdir = '/tmp',
  Map<String, String> envVars = const {},
}) {
  return switch (os) {
    'macos' => MacOsSandboxBackend(
      workspaceRoot: workspaceRoot,
      tmpdir: tmpdir,
      envVars: envVars,
    ),
    'linux' => LinuxUnshareBackend(
      spec: spec,
      workspaceRoot: workspaceRoot,
      tmpdir: tmpdir,
      envVars: envVars,
    ),
    'windows' => const WindowsJobBackend(),
    _ => const NoOpCubeBackend(),
  };
}
