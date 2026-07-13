/// The portability boundary of the harness: filesystem and shell capabilities
/// behind abstract interfaces, plus a [Result] type so file operations encode
/// failures in their return value instead of throwing.
///
/// Ported from pi-mono `packages/agent/src/harness/types.ts` (`FileSystem`,
/// `Shell`, `ExecutionEnv`, `Result`). The default `dart:io`-backed
/// implementation lives in `lib/io.dart`; the core library stays pure Dart so
/// it compiles to web, where a browser-storage-backed implementation can be
/// substituted behind the same interfaces.
library;

import '../cancel_token.dart';

/// Result of a fallible operation. Expected failures are returned as [Err]
/// instead of thrown — [FileSystem] operations must never throw.
///
/// Ported from pi's `Result<TValue, TError>` union.
sealed class Result<T, E> {
  const Result();

  /// Whether this is an [Ok] result.
  bool get isOk => this is Ok<T, E>;

  /// Whether this is an [Err] result.
  bool get isErr => this is Err<T, E>;

  /// The success value, or `null` when this is an [Err].
  T? get valueOrNull => switch (this) {
    Ok<T, E>(:final value) => value,
    Err<T, E>() => null,
  };

  /// The failure error, or `null` when this is an [Ok].
  E? get errorOrNull => switch (this) {
    Ok<T, E>() => null,
    Err<T, E>(:final error) => error,
  };

  /// Returns the success value or throws the failure error. Intended for
  /// tests and explicit adapter boundaries (mirrors pi's `getOrThrow`).
  T getOrThrow() => switch (this) {
    Ok<T, E>(:final value) => value,
    Err<T, E>(:final error) => throw error as Object,
  };
}

/// A successful [Result].
final class Ok<T, E> extends Result<T, E> {
  /// Creates an [Ok] wrapping [value].
  const Ok(this.value);

  /// The success value.
  final T value;
}

/// A failed [Result].
final class Err<T, E> extends Result<T, E> {
  /// Creates an [Err] wrapping [error].
  const Err(this.error);

  /// The failure error.
  final E error;
}

/// Kind of filesystem object addressed by a [FileSystem].
///
/// Ported from pi's `FileKind` union. Symlinks are not followed
/// automatically.
enum FileKind {
  /// A regular file.
  file,

  /// A directory.
  directory,

  /// A symbolic link.
  symlink,
}

/// Stable, backend-independent error codes returned by [FileSystem]
/// operations.
///
/// Ported from pi's `FileErrorCode` union.
enum FileErrorCode {
  /// The operation was aborted.
  aborted,

  /// The addressed path does not exist.
  notFound,

  /// The operation was denied by the platform.
  permissionDenied,

  /// A path component that must be a directory is not one.
  notDirectory,

  /// The addressed path is a directory but a file was required.
  isDirectory,

  /// The operation is invalid for the addressed path.
  invalid,

  /// The backend does not support the operation.
  notSupported,

  /// Any other backend failure.
  unknown,
}

/// Error returned by [FileSystem] operations.
///
/// Ported from pi's `FileError`.
final class FileError implements Exception {
  /// Creates a [FileError] with a [code] and [message].
  const FileError(this.code, this.message, {this.path, this.cause});

  /// Backend-independent error code.
  final FileErrorCode code;

  /// Human-readable description of the failure.
  final String message;

  /// The addressed path associated with the failure, when available.
  final String? path;

  /// The original backend error, when available.
  final Object? cause;

  @override
  String toString() =>
      'FileError(${code.name}${path != null ? ', $path' : ''}): $message';
}

/// Metadata for one filesystem object.
///
/// Ported from pi's `FileInfo`.
final class FileInfo {
  /// Creates a [FileInfo].
  const FileInfo({
    required this.name,
    required this.path,
    required this.kind,
    required this.size,
    required this.mtimeMs,
  });

  /// Basename of [path].
  final String name;

  /// Absolute, normalized addressed path. Symlinks are not followed.
  final String path;

  /// Object kind.
  final FileKind kind;

  /// Size in bytes (0 for directories).
  final int size;

  /// Modification time as milliseconds since the Unix epoch.
  final int mtimeMs;
}

/// Filesystem capability used by the harness.
///
/// Ported from pi's `FileSystem` interface, reduced to the operations the
/// session layer needs. Paths may be absolute or relative to [cwd].
///
/// **Invariant: operations must never throw.** All filesystem failures,
/// including unexpected backend failures, are encoded in the returned
/// [Result]. Implementations must preserve this invariant.
abstract interface class FileSystem {
  /// Current working directory for relative paths.
  String get cwd;

  /// Returns an absolute addressed path without requiring it to exist and
  /// without resolving symlinks.
  Future<Result<String, FileError>> absolutePath(String path);

  /// Joins path segments in the filesystem namespace without requiring the
  /// result to exist.
  Future<Result<String, FileError>> joinPath(List<String> parts);

  /// Reads a UTF-8 text file.
  Future<Result<String, FileError>> readTextFile(String path);

  /// Reads UTF-8 text lines. Implementations should stop once [maxLines]
  /// lines have been read.
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  });

  /// Creates or overwrites a file, creating parent directories.
  Future<Result<void, FileError>> writeFile(String path, String content);

  /// Creates or appends to a file, creating parent directories.
  Future<Result<void, FileError>> appendFile(String path, String content);

  /// Returns metadata for the addressed path without following symlinks.
  Future<Result<FileInfo, FileError>> fileInfo(String path);

  /// Lists the direct children of a directory.
  Future<Result<List<FileInfo>, FileError>> listDir(String path);

  /// Returns `false` for missing paths; other errors surface as [Err].
  Future<Result<bool, FileError>> exists(String path);

  /// Creates a directory. When [recursive] is true (the default), missing
  /// parents are created too.
  Future<Result<void, FileError>> createDir(String path, {bool recursive = true});

  /// Removes a file or directory. With [force], a missing path is not an
  /// error.
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  });
}

/// Stable, backend-independent error codes returned by [Shell.exec].
///
/// Ported from pi's `ExecutionErrorCode` union.
enum ExecutionErrorCode {
  /// The command was aborted via [ShellExecOptions.cancelToken].
  aborted,

  /// The command exceeded [ShellExecOptions.timeout].
  timeout,

  /// No shell is available in this environment (e.g. web).
  shellUnavailable,

  /// The process could not be spawned.
  spawnError,

  /// An output callback threw.
  callbackError,

  /// Any other failure.
  unknown,
}

/// Error returned by [Shell.exec].
///
/// Ported from pi's `ExecutionError`.
final class ExecutionError implements Exception {
  /// Creates an [ExecutionError] with a [code] and [message].
  const ExecutionError(this.code, this.message, {this.cause});

  /// Backend-independent error code.
  final ExecutionErrorCode code;

  /// Human-readable description of the failure.
  final String message;

  /// The original backend error, when available.
  final Object? cause;

  @override
  String toString() => 'ExecutionError(${code.name}): $message';
}

/// Options for [Shell.exec].
final class ShellExecOptions {
  /// Creates [ShellExecOptions].
  const ShellExecOptions({
    this.cwd,
    this.env,
    this.timeout,
    this.cancelToken,
    this.onStdout,
    this.onStderr,
  });

  /// Working directory for the command. Defaults to [FileSystem.cwd].
  final String? cwd;

  /// Additional environment variables; values override the defaults.
  final Map<String, String>? env;

  /// Timeout for the command. Implementations should return a
  /// [ExecutionErrorCode.timeout] error when exceeded.
  final Duration? timeout;

  /// Token used to terminate the command early.
  final CancelToken? cancelToken;

  /// Called with stdout chunks as they are produced.
  final void Function(String chunk)? onStdout;

  /// Called with stderr chunks as they are produced.
  final void Function(String chunk)? onStderr;
}

/// Outcome of a completed [Shell.exec] invocation.
final class ShellExecResult {
  /// Creates a [ShellExecResult].
  const ShellExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  /// Captured standard output.
  final String stdout;

  /// Captured standard error.
  final String stderr;

  /// Process exit code.
  final int exitCode;
}

/// Shell execution capability used by the harness.
///
/// Ported from pi's `Shell` interface. Implementations that cannot spawn
/// processes (e.g. web) should return [ExecutionErrorCode.shellUnavailable].
abstract interface class Shell {
  /// Executes a shell command. Must never throw: all failures are encoded in
  /// the returned [Result].
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  });
}

/// Filesystem and process execution environment used by the harness.
///
/// Ported from pi's `ExecutionEnv` (`interface ExecutionEnv extends
/// FileSystem, Shell`). The `dart:io`-backed implementation is exported only
/// from `lib/io.dart`; the core library exports [MemoryExecutionEnv] for
/// tests and web consumers.
abstract interface class ExecutionEnv implements FileSystem, Shell {}
