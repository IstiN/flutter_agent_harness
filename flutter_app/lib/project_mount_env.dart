import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The mount segment inside the agent's filesystem: the user-selected
/// project folder (macOS sandbox, user-selected read-write entitlement)
/// appears under this path while the env root stays the app container.
const projectMountSegment = '/project';

/// Maps the `/project` mount segment onto a user-selected host directory,
/// delegating everything else to the app-container env.
///
/// The app shares ONE [ExecutionEnv] between the agent's tools, the Files
/// panel, and the internal stores (sessions, settings, caches) — the mount
/// keeps that single-instance design: setting [mountedRoot] makes the
/// project visible everywhere the env flows, without recreating the agent
/// service, and app data never leaks into the user's folder.
///
/// Path mapping is idempotent: host paths already under the mounted
/// directory pass through unchanged, so values the env itself hands out
/// ([absolutePath]/[joinPath] results, [FileInfo.path]) stay valid input.
final class ProjectMountEnv implements ExecutionEnv {
  /// Creates an env over [delegate] with no active mount.
  ProjectMountEnv(this._delegate);

  final ExecutionEnv _delegate;
  String? _mountedRoot;

  /// The currently mounted host directory, or null when nothing is mounted.
  String? get mountedRoot => _mountedRoot;

  /// Mounts [hostPath] (null unmounts). No FS access here — the caller
  /// (store/channel) owns the security-scoped access lifecycle.
  set mountedRoot(String? hostPath) =>
      _mountedRoot = hostPath == null || hostPath.isEmpty ? null : hostPath;

  /// A stored mount whose bookmark no longer resolves (folder moved or
  /// deleted): the UI offers to pick again. Set at startup remount only.
  String? mountUnavailable;

  String _map(String path) {
    final root = _mountedRoot;
    if (root == null) return path;
    if (path == projectMountSegment) return root;
    if (path.startsWith('$projectMountSegment/')) {
      return '$root/${path.substring(projectMountSegment.length + 1)}';
    }
    return path;
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(_map(path));

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(_map(path));

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(_map(path));

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(_map(path), maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(_map(path), content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(_map(path), content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(_map(path), content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(_map(path));

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(_map(path));

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(_map(path));

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(_map(path), recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(_map(path), recursive: recursive, force: force);
}
