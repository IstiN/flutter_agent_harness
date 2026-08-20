/// [ExecutionEnv] decorator that injects secrets into shell executions.
///
/// Wraps any [ExecutionEnv] and merges a secret map into
/// [ShellExecOptions.env] on every [exec], so `$NAME` expands inside the
/// sandbox shell (WASM, in-memory, or local) without the values ever
/// entering the agent context. Pair with `SecretRedactor` (which masks the
/// values in tool results) for the full secrets flow.
///
/// The map is live: [addSecrets] merges entries at runtime (e.g. a key the
/// user grants mid-session through the `request_secret` tool), and later
/// [exec] calls pick them up.
library;

import 'dart:typed_data';

import 'execution_env.dart';

/// An [ExecutionEnv] that injects secret env vars into every [exec].
final class SecretsExecutionEnv implements ExecutionEnv, BackgroundShell {
  /// Creates a decorator over [delegate] injecting [secrets] (name → value).
  SecretsExecutionEnv(this._delegate, Map<String, String> secrets)
    : _secrets = Map.of(secrets);

  final ExecutionEnv _delegate;
  final Map<String, String> _secrets;

  /// The wrapped environment.
  ExecutionEnv get delegate => _delegate;

  /// Merges [secrets] into the injected map at runtime; later [exec] calls
  /// see them. Per-call [ShellExecOptions.env] entries still win over the
  /// injected secrets.
  void addSecrets(Map<String, String> secrets) {
    _secrets.addAll(secrets);
  }

  /// A snapshot copy of the live secret map currently injected into [exec]
  /// (name → value). Hosts read it for their own secret bridges (e.g. an
  /// app-facing keys API); mutating the returned map does not affect the
  /// env.
  Map<String, String> secretsSnapshot() => Map.of(_secrets);

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) {
    if (_secrets.isEmpty) return _delegate.exec(command, options: options);
    // Per-call env entries win over the injected secrets.
    final merged = ShellExecOptions(
      cwd: options?.cwd,
      env: {..._secrets, ...?options?.env},
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
    );
    return _delegate.exec(command, options: merged);
  }

  // Background shell jobs: forwarded with the same secrets merged in —
  // a detached command expands `$NAME` exactly like a foreground one.

  @override
  bool get backgroundJobsSupported {
    final delegate = _delegate;
    if (delegate case final BackgroundShell bg) {
      return bg.backgroundJobsSupported;
    }
    return false;
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) {
    final delegate = _delegate;
    if (delegate is! BackgroundShell) {
      return Future.value(
        const Err(
          ExecutionError(
            ExecutionErrorCode.shellUnavailable,
            'background shell jobs are not supported by this shell',
          ),
        ),
      );
    }
    final bg = delegate as BackgroundShell;
    if (_secrets.isEmpty) {
      return bg.startShellJob(
        command,
        id: id,
        logPath: logPath,
        options: options,
      );
    }
    final merged = ShellExecOptions(
      cwd: options?.cwd,
      env: {..._secrets, ...?options?.env},
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
    );
    return bg.startShellJob(command, id: id, logPath: logPath, options: merged);
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);
}
