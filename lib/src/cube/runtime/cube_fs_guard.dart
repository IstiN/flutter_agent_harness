/// Filesystem policy enforcement for cubes: a [FileSystem] decorator that
/// routes every operation through the cube's [CubeFsPolicy].
///
/// [CubeFsGuard] wraps any [FileSystem]: writes outside read/write paths are
/// refused with `permissionDenied`, and reads of denied paths *vanish* —
/// they report `notFound` (and [exists] reports `false`) so a sandboxed run
/// cannot even discover that a denied path exists. Reads are denied, not
/// audited.
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
  CubeFsGuard(
    this._delegate,
    this.spec, {
    String? homeDir,
    String? workspaceRoot,
  }) : _homeDir = homeDir,
       _workspaceRoot = workspaceRoot;

  final FileSystem _delegate;
  final CubeSpec spec;
  final String? _homeDir;
  final String? _workspaceRoot;

  @override
  String get cwd => _delegate.cwd;

  /// The policy actually enforced: the spec's filesystem policy, with the
  /// workspace root swapped to [workspaceRoot] when supplied (the cube's
  /// `/workspace` is realized as the process cwd, so the policy must judge
  /// paths against the real root) and every workspace mount remapped with
  /// it via [resolveWorkspacePath] — mounts outside the workspace stay as
  /// written.
  CubeFsPolicy get _policy {
    final root = _workspaceRoot;
    final specPolicy = spec.filesystem;
    if (root == null) return specPolicy;
    return CubeFsPolicy(
      workspace: root,
      mounts: [
        for (final mount in specPolicy.mounts)
          CubeMount(
            path:
                resolveWorkspacePath(mount.path, specPolicy.workspace, root) ??
                mount.path,
            access: mount.access,
          ),
      ],
    );
  }

  /// The access level the policy grants to [path], with relative paths
  /// resolved against the delegate cwd first.
  CubePathAccess _accessFor(String path) {
    final resolved = path.startsWith('/') ? path : '${_delegate.cwd}/$path';
    return _policy.accessFor(resolved, homeDir: _homeDir);
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
    final denied = _writeDeniedError(path);
    if (denied != null) return Future.value(Err(denied));
    return _delegate.writeFile(path, content);
  }

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) {
    final denied = _writeDeniedError(path);
    if (denied != null) return Future.value(Err(denied));
    return _delegate.writeBinaryFile(path, content);
  }

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    final denied = _writeDeniedError(path);
    if (denied != null) return Future.value(Err(denied));
    return _delegate.appendFile(path, content);
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) {
    final denied = _writeDeniedError(path);
    if (denied != null) return Future.value(Err(denied));
    return _delegate.createDir(path, recursive: recursive);
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) {
    final denied = _writeDeniedError(path);
    if (denied != null) return Future.value(Err(denied));
    return _delegate.remove(path, recursive: recursive, force: force);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final denied = _deniedReadError(path);
    if (denied != null) return Err(denied);
    return _delegate.readTextFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    final denied = _deniedReadError(path);
    if (denied != null) return Err(denied);
    return _delegate.readBinaryFile(path);
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    final denied = _deniedReadError(path);
    if (denied != null) return Err(denied);
    return _delegate.readTextLines(path, maxLines: maxLines);
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async {
    final denied = _deniedReadError(path);
    if (denied != null) return Err(denied);
    return _delegate.fileInfo(path);
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final denied = _deniedReadError(path);
    if (denied != null) return Err(denied);
    return _delegate.listDir(path);
  }

  @override
  Future<Result<bool, FileError>> exists(String path) {
    if (_accessFor(path) == CubePathAccess.deny) {
      return Future.value(const Ok(false));
    }
    return _delegate.exists(path);
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  /// The `permissionDenied` error for a refused write to [path], or `null`
  /// when the write may proceed.
  FileError? _writeDeniedError(String path) {
    final access = _accessFor(path);
    if (access == CubePathAccess.readWrite) return null;
    return FileError(FileErrorCode.permissionDenied, _message(path, access));
  }

  /// The `notFound` error swallowed for a denied read of [path], or `null`
  /// when the read may proceed. Denied reads vanish: they never reveal the
  /// path exists.
  FileError? _deniedReadError(String path) {
    if (_accessFor(path) != CubePathAccess.deny) return null;
    return FileError(FileErrorCode.notFound, _deniedReadMessage(path));
  }
}
