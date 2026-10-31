/// [ExecutionEnv] decorator that injects session-correlation env vars
/// (`FAH_SESSION_ID`, `FAH_SESSION_FILE`, `FAH_PROVIDER`, `FAH_MODEL`) into
/// shell executions.
///
/// Wraps any [ExecutionEnv] and merges the vars from a live [vars] provider
/// into [ShellExecOptions.env] on every [exec], so scripts can correlate
/// their output with the running agent session (pi's bash tool does the
/// same with `PI_SESSION_*`). The provider is consulted per call, so a
/// session created or a model switched after wiring is picked up
/// immediately.
///
/// The vars are never secrets: ids, paths, provider kinds, and model ids
/// only. Compose with `SecretsExecutionEnv` for the full flow; the var
/// names use the reserved `FAH_` prefix and never collide with secret
/// names.
library;

import 'dart:async';

import 'delegating_execution_env.dart';
import 'execution_env.dart';

/// Env var name carrying the current session id.
const sessionIdEnvVar = 'FAH_SESSION_ID';

/// Env var name carrying the current session's JSONL file path.
const sessionFileEnvVar = 'FAH_SESSION_FILE';

/// Env var name carrying the active provider kind.
const providerEnvVar = 'FAH_PROVIDER';

/// Env var name carrying the active model id.
const modelEnvVar = 'FAH_MODEL';

/// An [ExecutionEnv] that injects session-correlation env vars into every
/// [exec]. See the library doc for the contract.
final class SessionVarsExecutionEnv extends ForwardingFs
    with
        ForwardingBackgroundShell,
        ForwardingRangedReadFs,
        ForwardingRenamableFs {
  /// Creates a decorator over [delegate] injecting the vars returned by
  /// [vars] (consulted live on every [exec]).
  SessionVarsExecutionEnv(super.delegate, this._vars);

  final FutureOr<Map<String, String>> Function() _vars;

  @override
  Future<ShellExecOptions?> mergeExecOptions(ShellExecOptions? options) async {
    final vars = await _vars();
    if (vars.isEmpty) return options;
    // Per-call env entries win over the injected session vars.
    return ShellExecOptions(
      cwd: options?.cwd,
      env: {...vars, ...?options?.env},
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
      // stdinData + liveStdin (issue #367): the live stdin channel keeps
      // the pipe open so a mid-run password ask can be answered; the
      // launch-time stdin param rides the same merge.
      stdinData: options?.stdinData,
      liveStdin: options?.liveStdin,
    );
  }

  @override
  Future<ShellExecOptions?> mergeJobOptions(ShellExecOptions? options) async {
    final vars = await _vars();
    if (vars.isEmpty) return options;
    // Per-call env entries win over the injected session vars.
    return ShellExecOptions(
      cwd: options?.cwd,
      env: {...vars, ...?options?.env},
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
      // stdinData + liveStdin (issue #367): see exec above.
      stdinData: options?.stdinData,
      liveStdin: options?.liveStdin,
      jobLogMaxBytes: options?.jobLogMaxBytes,
      onJobLogWarning: options?.onJobLogWarning,
      jobLogRedactor: options?.jobLogRedactor,
    );
  }
}
