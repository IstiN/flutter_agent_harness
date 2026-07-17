/// [ExecutionEnv] decorator that injects secrets into shell executions.
///
/// Wraps any [ExecutionEnv] and merges a fixed secret map into
/// [ShellExecOptions.env] on every [exec], so `$NAME` expands inside the
/// sandbox shell (WASM, in-memory, or local) without the values ever
/// entering the agent context. Pair with `SecretRedactor` (which masks the
/// values in tool results) for the full secrets flow.
library;

import 'dart:typed_data';

import 'execution_env.dart';

/// An [ExecutionEnv] that injects secret env vars into every [exec].
final class SecretsExecutionEnv implements ExecutionEnv {
  /// Creates a decorator over [delegate] injecting [secrets] (name → value).
  SecretsExecutionEnv(this._delegate, Map<String, String> secrets)
    : _secrets = Map.unmodifiable(secrets);

  final ExecutionEnv _delegate;
  final Map<String, String> _secrets;

  /// The wrapped environment.
  ExecutionEnv get delegate => _delegate;

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
