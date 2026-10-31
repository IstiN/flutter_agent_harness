/// [ExecutionEnv] decorator that overrides the working directory seen by the
/// wrapped environment. Every relative filesystem path and every shell
/// execution without an explicit [ShellExecOptions.cwd] is resolved against
/// the mutable [_cwd] instead of the delegate's original cwd.
library;

import 'delegating_execution_env.dart';
import 'execution_env.dart';

/// Wraps an [ExecutionEnv] and lets callers change the effective cwd after
/// construction. Used by the CLI when the user switches to a session that was
/// created in a different project folder: the agent's tools continue to
/// operate in the session's original directory without restarting the process.
final class CwdOverrideEnv extends ForwardingFs
    with
        ForwardingBackgroundShell,
        ForwardingRangedReadFs,
        ForwardingRenamableFs {
  /// Creates a decorator over [delegate] whose effective cwd starts at
  /// [delegate.cwd].
  CwdOverrideEnv(super.delegate) : _cwd = delegate.cwd;

  String _cwd;

  /// The effective current working directory. Updating this immediately
  /// changes where relative paths and shell commands are resolved.
  set cwd(String value) => _cwd = value;

  @override
  String get cwd => _cwd;

  /// Returns [path] as-is when absolute, otherwise resolves it against [_cwd].
  String _resolve(String path) {
    if (path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) {
      return path;
    }
    return '$_cwd/$path';
  }

  @override
  String mapPath(String path) => _resolve(path);

  /// Rebuilds [options] with the effective cwd when it carries none —
  /// foreground execs propagate exactly the pre-#1996 field set.
  ShellExecOptions? _optionsWithCwd(ShellExecOptions? options) {
    if (options?.cwd != null) return options;
    return ShellExecOptions(
      cwd: _cwd,
      env: options?.env,
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
    );
  }

  @override
  ShellExecOptions? mergeExecOptions(ShellExecOptions? options) =>
      _optionsWithCwd(options);

  @override
  ShellExecOptions? mergeJobOptions(ShellExecOptions? options) {
    if (options?.cwd != null) return options;
    return ShellExecOptions(
      cwd: _cwd,
      env: options?.env,
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
      jobLogMaxBytes: options?.jobLogMaxBytes,
      onJobLogWarning: options?.onJobLogWarning,
      jobLogRedactor: options?.jobLogRedactor,
    );
  }
}
