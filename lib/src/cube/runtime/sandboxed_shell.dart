/// Shell-level policy enforcement for cubes: a [Shell] decorator that
/// refuses non-allowlisted commands and clamps execution to the cube's
/// resource limits.
///
/// [SandboxedShell] never throws: a denied command is answered with an
/// `Ok` result carrying exit code 127 and an `fa_cube[<name>]:` stderr
/// note, exactly like a shell reporting "command not found". The inner
/// shell is never reached for a denied command.
///
/// The active spec is swappable at runtime ([updateSpec]/[clearSpec]), so a
/// long-lived environment can change cubes (or leave the sandbox entirely)
/// mid-session.
library;

import '../config/cube_spec.dart';
import '../../env/execution_env.dart';
import 'policy_engine.dart';

/// A [Shell] whose commands are gated by a cube's policies.

/// Builds the forwarded options for a permitted command under [spec]:
/// the timeout clamped to the cube's [CubeResourceLimits.timeout] (the
/// smaller of caller and cube wins; a null caller inherits the cube's),
/// plus the cube's injected env vars.
///
/// The env merge is additive only — [ShellExecOptions.env] cannot strip
/// variables the process already inherited; full environment cleanliness
/// is kernel-backend territory (Phase 2+).
ShellExecOptions sandboxExecOptions(CubeSpec spec, ShellExecOptions? options) {
  var timeout = options?.timeout;
  final cubeTimeout = spec.resources.timeout;
  if (cubeTimeout != null && (timeout == null || cubeTimeout < timeout)) {
    timeout = cubeTimeout;
  }
  final injected = spec.env.isEmpty
      ? const <String, String>{}
      : spec.env.apply(const {});
  final unchanged = injected.isEmpty && timeout == options?.timeout;
  if (unchanged) return options ?? const ShellExecOptions();
  return ShellExecOptions(
    cwd: options?.cwd,
    env: injected.isEmpty ? options?.env : {...injected, ...?options?.env},
    timeout: timeout,
    cancelToken: options?.cancelToken,
    onStdout: options?.onStdout,
    onStderr: options?.onStderr,
    stdinData: options?.stdinData,
  );
}

final class SandboxedShell implements Shell {
  /// Creates a sandbox over [inner], enforcing [spec]'s policies; a null
  /// [spec] is passthrough — every command forwards untouched until
  /// [updateSpec].
  SandboxedShell(this._inner, CubeSpec? spec) {
    if (spec != null) updateSpec(spec);
  }

  final Shell _inner;
  CubeSpec? _spec;
  late CubePolicyEngine _engine;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final spec = _spec;
    if (spec == null) return _inner.exec(command, options: options);
    final decision = _engine.checkCommand(command);
    if (!decision.allowed) {
      return Ok(
        ShellExecResult(
          stdout: '',
          stderr: 'fa_cube[${spec.name}]: ${decision.reason}',
          exitCode: 127,
        ),
      );
    }
    return _inner.exec(command, options: sandboxExecOptions(spec, options));
  }

  /// Swaps the enforced spec live; the next [exec] uses the new policies.
  void updateSpec(CubeSpec spec) {
    _spec = spec;
    _engine = CubePolicyEngine(spec);
  }

  /// Leaves sandbox mode: every command is forwarded untouched.
  void clearSpec() {
    _spec = null;
  }
}
