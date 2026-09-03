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
import 'dart:typed_data';

import 'package:flutter_sandbox/flutter_sandbox.dart';

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
final class SessionVarsExecutionEnv implements ExecutionEnv, BackgroundShell {
  /// Creates a decorator over [delegate] injecting the vars returned by
  /// [vars] (consulted live on every [exec]).
  SessionVarsExecutionEnv(this._delegate, this._vars);

  final ExecutionEnv _delegate;
  final FutureOr<Map<String, String>> Function() _vars;

  /// The wrapped environment.
  ExecutionEnv get delegate => _delegate;

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final vars = await _vars();
    if (vars.isEmpty) return _delegate.exec(command, options: options);
    // Per-call env entries win over the injected session vars.
    final merged = ShellExecOptions(
      cwd: options?.cwd,
      env: {...vars, ...?options?.env},
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
    );
    return _delegate.exec(command, options: merged);
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
  }) async {
    final delegate = _delegate;
    if (delegate is! BackgroundShell) {
      return const Err(
        ExecutionError(
          ExecutionErrorCode.shellUnavailable,
          'background shell jobs are not supported by this shell',
        ),
      );
    }
    final bg = delegate as BackgroundShell;
    final vars = await _vars();
    if (vars.isEmpty) {
      return bg.startShellJob(
        command,
        id: id,
        logPath: logPath,
        options: options,
      );
    }
    // Per-call env entries win over the injected session vars.
    final merged = ShellExecOptions(
      cwd: options?.cwd,
      env: {...vars, ...?options?.env},
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
