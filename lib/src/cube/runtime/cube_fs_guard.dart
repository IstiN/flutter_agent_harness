/// Filesystem policy enforcement for cubes: a [FileSystem] decorator that
/// routes every operation through the cube's [CubeFsPolicy].
///
/// [CubeFsGuard] wraps any [FileSystem]: writes outside read/write paths are
/// refused with `permissionDenied`, and reads of denied paths *vanish* —
/// they report `notFound` (and [exists] reports `false`) so a sandboxed run
/// cannot even discover that a denied path exists. Reads are denied, not
/// audited.
///
/// With a [pathProbe], every check resolves the real path first: symlink
/// chains are followed (to a fixed depth; unreadable indirections such as
/// Windows reparse points fail closed), `..` applies after resolution, and
/// both the verdict and the path handed to the delegate judge the file the
/// OS will actually open — a link to outside the workspace can no longer
/// smuggle reads or writes out. Residual race, documented honestly: the
/// target can still be swapped between check and open (a much smaller
/// window than a standing symlink; full closure needs file-tool execution
/// inside the sandboxed worker). Without a probe the guard falls back to
/// the lexical traversal check of the written path.
///
/// Relative paths are resolved against the delegate's [FileSystem.cwd] first
/// ([CubeFsPolicy.accessFor] resolves them against the spec's `/workspace`,
/// which is only realized as the process cwd in a real sandbox).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:typed_data';

import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import '../../env/execution_env.dart';

/// A [FileSystem] whose operations are gated by a cube's filesystem policy.
///
/// The policy is consulted per operation, so a spec swapped at runtime is
/// picked up by the next call.
final class CubeFsGuard implements FileSystem {
  /// Creates a guard over [delegate], enforcing [spec]'s filesystem policy.
  ///
  /// [homeDir] resolves `~` paths in the policy; [workspaceRoot] overrides
  /// `spec.filesystem.workspace` as the policy's workspace root — the CLI
  /// passes the real process cwd here, because the cube's `/workspace` is
  /// realized as the env cwd rather than a literal `/workspace` directory.
  /// [pathProbe] enables symlink resolution (see the class docs); real
  /// hosts pass `LocalCubeFsProbe`.
  CubeFsGuard(
    this._delegate,
    this.spec, {
    String? homeDir,
    String? workspaceRoot,
    CubeFsProbe? pathProbe,
  }) : _homeDir = homeDir,
       _workspaceRoot = workspaceRoot,
       _pathProbe = pathProbe;

  final FileSystem _delegate;
  final CubeSpec spec;
  final String? _homeDir;
  final String? _workspaceRoot;
  final CubeFsProbe? _pathProbe;

  @override
  String get cwd => _delegate.cwd;

  /// The policy actually enforced: the spec's filesystem policy, with the
  /// workspace root swapped to [workspaceRoot] when supplied (the cube's
  /// `/workspace` is realized as the process cwd, so the policy must judge
  /// paths against the real root).
  CubeFsPolicy get _policy => _workspaceRoot == null
      ? spec.filesystem
      : CubeFsPolicy(workspace: _workspaceRoot, mounts: spec.filesystem.mounts);

  /// The access level for [path] plus — with a probe — the resolved
  /// canonical path to open, with relative paths resolved against the
  /// delegate cwd first.
  ({CubePathAccess access, String? resolved}) _accessFor(String path) {
    final resolved = path.startsWith('/') ? path : '${_delegate.cwd}/$path';
    return _policy.accessForResolved(resolved, homeDir: _homeDir, probe: _pathProbe);
  }

  /// The guard-prefixed denial message for [path] at [access].
  String _message(String path, CubePathAccess access) =>
      'fa_cube[${spec.name}]: $path is '
      '${access == CubePathAccess.readOnly ? 'read-only' : 'denied'}';

  /// The guard-prefixed not-found message for a denied [path].
  String _deniedReadMessage(String path) =>
      'fa_cube[${spec.name}]: $path does not exist in this cube';

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) {
    final (error, target) = _writeCheck(path);
    if (error != null) return Future.value(Err(error));
    return _delegate.writeFile(target, content);
  }

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) {
    final (error, target) = _writeCheck(path);
    if (error != null) return Future.value(Err(error));
    return _delegate.writeBinaryFile(target, content);
  }

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    final (error, target) = _writeCheck(path);
    if (error != null) return Future.value(Err(error));
    return _delegate.appendFile(target, content);
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) {
    final (error, target) = _writeCheck(path);
    if (error != null) return Future.value(Err(error));
    return _delegate.createDir(target, recursive: recursive);
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) {
    final (error, target) = _writeCheck(path);
    if (error != null) return Future.value(Err(error));
    return _delegate.remove(target, recursive: recursive, force: force);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final (error, target) = _readCheck(path);
    if (error != null) return Err(error);
    return _delegate.readTextFile(target);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    final (error, target) = _readCheck(path);
    if (error != null) return Err(error);
    return _delegate.readBinaryFile(target);
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    final (error, target) = _readCheck(path);
    if (error != null) return Err(error);
    return _delegate.readTextLines(target, maxLines: maxLines);
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async {
    final (error, target) = _readCheck(path);
    if (error != null) return Err(error);
    return _delegate.fileInfo(target);
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final (error, target) = _readCheck(path);
    if (error != null) return Err(error);
    return _delegate.listDir(target);
  }

  @override
  Future<Result<bool, FileError>> exists(String path) {
    final (:access, :resolved) = _accessFor(path);
    if (access == CubePathAccess.deny) {
      return Future.value(const Ok(false));
    }
    return _delegate.exists(resolved ?? path);
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  /// The `permissionDenied` error for a refused write to [path], plus the
  /// path to open (the resolved target when a probe is active), or a null
  /// error when the write may proceed.
  (FileError?, String) _writeCheck(String path) {
    final (:access, :resolved) = _accessFor(path);
    if (access != CubePathAccess.readWrite) {
      return (FileError(FileErrorCode.permissionDenied, _message(path, access)), path);
    }
    return (null, resolved ?? path);
  }

  /// The `notFound` error swallowed for a denied read of [path] — denied
  /// reads vanish, they never reveal the path exists — plus the path to
  /// open (the resolved target when a probe is active), or a null error
  /// when the read may proceed.
  (FileError?, String) _readCheck(String path) {
    final (:access, :resolved) = _accessFor(path);
    if (access == CubePathAccess.deny) {
      return (FileError(FileErrorCode.notFound, _deniedReadMessage(path)), path);
    }
    return (null, resolved ?? path);
  }
}
