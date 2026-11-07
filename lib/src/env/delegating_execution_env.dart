/// Shared forwarding machinery for [ExecutionEnv] decorators.
///
/// Every decorator in the harness (secrets, session vars, cwd override,
/// sandbox-root mapping, the app's project mount and persistent-web
/// wrappers, the extension's chrome-storage twin) wraps a delegate env
/// and forwards almost every operation to it. That forwarding block used
/// to be copy-pasted per decorator across core, flutter_app and
/// browser_ext (issue #1996); this library is its single home.
///
/// Composition: extend [ForwardingFs] and mix in exactly the optional
/// capabilities the decorator declares — [ForwardingBackgroundShell],
/// [ForwardingRangedReadFs], [ForwardingRenamableFs]. Keeping the
/// capability set explicit preserves `is`-probe semantics: a decorator
/// that never advertised `RenamableFileSystem` must not start
/// advertising it just because it moved onto this base (the session
/// lease store and windowed session loader probe those interfaces).
///
/// Hooks, all no-op/identity defaults:
///   * [ForwardingFs.mapPath] — rewrite file paths before forwarding
///     (cwd override, sandbox-root mapping). Never applied to
///     [FileSystem.joinPath], whose parts the decorators join untransformed.
///   * [ForwardingFs.mergeExecOptions] / [mergeJobOptions] — rewrite
///     exec options per phase (inject env vars, override cwd). Each
///     decorator keeps its own exact rebuild shape, so option-field
///     propagation stays byte-identical to the pre-extraction code.
///   * [ForwardingFs.afterMutation] — observe a successful write-family
///     operation (persistence mirrors). Failed writes are never reported.
library;

import 'dart:async';
import 'dart:typed_data';

import 'execution_env.dart';

/// A decorator base that owns a [delegate] and forwards every
/// [ExecutionEnv] operation to it.
abstract class ForwardingFs implements ExecutionEnv {
  /// Creates a forwarding view over [delegate].
  ForwardingFs(this.delegate);

  /// The wrapped environment.
  final ExecutionEnv delegate;

  /// Rewrites [path] before a file operation is forwarded (identity by
  /// default).
  String mapPath(String path) => path;

  /// Rewrites the options for a forwarded [exec] (identity by default).
  /// Returning [options] unchanged forwards the original instance.
  FutureOr<ShellExecOptions?> mergeExecOptions(ShellExecOptions? options) =>
      options;

  /// Observes a successful mutation (writeBinaryFile, writeFile,
  /// appendFile, createDir, remove) at [path]. No-op by default.
  void afterMutation(String path) {}

  @override
  String get cwd => delegate.cwd;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return delegate.exec(command, options: await mergeExecOptions(options));
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      delegate.absolutePath(mapPath(path));

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      delegate.readTextFile(mapPath(path));

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      delegate.readBinaryFile(mapPath(path));

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => delegate.readTextLines(mapPath(path), maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _forwardMutation(
    (fs) => fs.writeBinaryFile(mapPath(path), content),
    path,
  );

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _forwardMutation((fs) => fs.writeFile(mapPath(path), content), path);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _forwardMutation((fs) => fs.appendFile(mapPath(path), content), path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _forwardMutation(
    (fs) => fs.createDir(mapPath(path), recursive: recursive),
    path,
  );

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _forwardMutation(
    (fs) => fs.remove(mapPath(path), recursive: recursive, force: force),
    path,
  );

  /// Runs one write-family operation against the delegate and reports
  /// success through [afterMutation]. Errors return untouched — a failed
  /// write must not trigger a persistence mirror over nothing.
  Future<Result<void, FileError>> _forwardMutation(
    Future<Result<void, FileError>> Function(FileSystem fs) op,
    String path,
  ) async {
    final result = await op(delegate);
    if (result.isOk) afterMutation(path);
    return result;
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      delegate.fileInfo(mapPath(path));

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      delegate.listDir(mapPath(path));

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      delegate.exists(mapPath(path));
}

/// Detached-job forwarding for decorators over a [BackgroundShell]
/// delegate: the capability answer and [startShellJob] forward through
/// the delegate; a non-BackgroundShell delegate answers the standard
/// clean "not supported" error.
mixin ForwardingBackgroundShell on ForwardingFs implements BackgroundShell {
  /// Rewrites the options for a forwarded [startShellJob] (identity by
  /// default). Awaited only after the delegate answered the capability
  /// probe, matching the pre-extraction ordering.
  FutureOr<ShellExecOptions?> mergeJobOptions(ShellExecOptions? options) =>
      options;

  @override
  bool get backgroundJobsSupported {
    final d = delegate;
    if (d case final BackgroundShell bg) return bg.backgroundJobsSupported;
    return false;
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final d = delegate;
    if (d case final BackgroundShell bg) {
      return bg.startShellJob(
        command,
        id: id,
        logPath: logPath,
        options: await mergeJobOptions(options),
      );
    }
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'background shell jobs are not supported by this shell',
      ),
    );
  }
}

/// Byte-range-read forwarding for decorators over a
/// [RangedReadFileSystem] delegate.
mixin ForwardingRangedReadFs on ForwardingFs implements RangedReadFileSystem {
  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) {
    final d = delegate;
    if (d case final RangedReadFileSystem ranged) {
      return ranged.readRange(mapPath(path), start, end);
    }
    return Future.value(
      Err(
        FileError(
          FileErrorCode.notSupported,
          'readRange not supported by $delegate',
          path: path,
        ),
      ),
    );
  }
}

/// Atomic-rename forwarding for decorators over a [RenamableFileSystem]
/// delegate.
mixin ForwardingRenamableFs on ForwardingFs implements RenamableFileSystem {
  @override
  Future<Result<void, FileError>> renamePath(String from, String to) {
    final d = delegate;
    if (d case final RenamableFileSystem renamable) {
      return renamable.renamePath(mapPath(from), mapPath(to));
    }
    return Future.value(
      Err(
        FileError(
          FileErrorCode.notSupported,
          'renamePath not supported by $delegate',
          path: from,
        ),
      ),
    );
  }
}
