/// [ExecutionEnv] decorator that overrides the working directory seen by the
/// wrapped environment. Every relative filesystem path and every shell
/// execution without an explicit [ShellExecOptions.cwd] is resolved against
/// the mutable [_cwd] instead of the delegate's original cwd.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sandbox/flutter_sandbox.dart';

/// Wraps an [ExecutionEnv] and lets callers change the effective cwd after
/// construction. Used by the CLI when the user switches to a session that was
/// created in a different project folder: the agent's tools continue to
/// operate in the session's original directory without restarting the process.
final class CwdOverrideEnv implements ExecutionEnv, BackgroundShell {
  /// Creates a decorator over [delegate] whose effective cwd starts at
  /// [delegate.cwd].
  CwdOverrideEnv(this._delegate) : _cwd = _delegate.cwd;

  final ExecutionEnv _delegate;
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
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) {
    final resolvedOptions = options?.cwd == null
        ? ShellExecOptions(
            cwd: _cwd,
            env: options?.env,
            timeout: options?.timeout,
            cancelToken: options?.cancelToken,
            onStdout: options?.onStdout,
            onStderr: options?.onStderr,
          )
        : options;
    return _delegate.exec(command, options: resolvedOptions);
  }

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
    final resolvedOptions = options?.cwd == null
        ? ShellExecOptions(
            cwd: _cwd,
            env: options?.env,
            timeout: options?.timeout,
            cancelToken: options?.cancelToken,
            onStdout: options?.onStdout,
            onStderr: options?.onStderr,
          )
        : options;
    return bg.startShellJob(
      command,
      id: id,
      logPath: logPath,
      options: resolvedOptions,
    );
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(_resolve(path));

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(_resolve(path));

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(_resolve(path));

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(_resolve(path), maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(_resolve(path), content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(_resolve(path), content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(_resolve(path), content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(_resolve(path));

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(_resolve(path));

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(_resolve(path));

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(_resolve(path), recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(_resolve(path), recursive: recursive, force: force);
}
