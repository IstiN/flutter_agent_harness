import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'project_folder_channel.dart';
import 'project_mount_env.dart';
import 'project_mount_store.dart';
import 'wasm_shell.dart';

/// Creates the execution environment for the current platform.
///
/// Desktop keeps the existing [LocalExecutionEnv] with the host shell. Mobile
/// uses a sandboxed host directory and a WasiSandboxShell backed by
/// MIT-licensed uutils/ripgrep WASM binaries so the agent has a working shell
/// on iOS and Android.
Future<ExecutionEnv> createPlatformEnv({http.Client? httpClient}) async {
  if (kIsWeb) {
    // Fallback for the unlikely case this file is compiled for web; the stub
    // implementation is preferred via conditional import.
    return MemoryExecutionEnv(cwd: '/');
  }

  final appDir = await getApplicationDocumentsDirectory();
  if (Platform.isAndroid || Platform.isIOS) {
    final sandbox = Directory('${appDir.path}/fah_sandbox');
    await sandbox.create(recursive: true);

    // Both Android and iOS run the WASI sandbox shell; on iOS the wasm_run
    // library is statically linked into the app binary (see setUpWasmRuntime).
    final shell = await WasiSandboxShell.load(
      workingDirectory: '/',
      sandboxHostPath: sandbox.path,
      httpClient: httpClient,
    );
    return SandboxedExecutionEnv(
      LocalExecutionEnv(cwd: sandbox.path, shell: shell),
      sandbox.path,
    );
  }

  // Desktop: the container env, plus (macOS) the project-folder mount when
  // one was picked before. A stale bookmark (folder moved/deleted) is
  // remembered for the UI's "pick again" warning instead of mounted.
  final baseEnv = LocalExecutionEnv(cwd: appDir.path);
  if (!Platform.isMacOS) return baseEnv;
  final mountEnv = ProjectMountEnv(baseEnv);
  final stored = await ProjectMountStore.load(baseEnv);
  if (stored != null) {
    if (await ProjectFolderChannelOps().startAccessing(stored.bookmark)) {
      mountEnv.mountedRoot = stored.path;
    } else {
      mountEnv.mountUnavailable = stored.path;
    }
  }
  return mountEnv;
}

/// `true` when running on a mobile OS that needs the WASM shell sandbox.
bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// `true` when running on Android (the WASM shell sandbox works there).
bool get isAndroidPlatform => Platform.isAndroid;

/// `true` when running on iOS (the WASM shell sandbox works there via the
/// statically linked wasm_run library).
bool get isIosPlatform => Platform.isIOS;

/// `true` when running on the web.
bool get isWebPlatform => false;

/// Maps sandbox-absolute paths (`/foo`) into the sandbox host directory for
/// the file tools, so `read`/`write`/`ls`/`edit` agree with the WASM shell's
/// view of `/` as the sandbox root.
///
/// The mapping is idempotent: paths already inside the sandbox host directory
/// pass through unchanged. That matters because this env reports the *host*
/// path as [cwd], so any path derived from values the env itself hands out —
/// `'${env.cwd}/sessions'`, [absolutePath]/[joinPath] results, or
/// [FileInfo.path] from [listDir] — must remain valid input. Without the
/// pass-through, `JsonlSessionRepo(fs: env, sessionsRoot: '${env.cwd}/
/// sessions')` resolved and wrote sessions into a nested
/// `<sandbox>/<sandbox-host-path>/sessions` directory.
///
/// A sandbox-virtual absolute path that textually begins with the host root
/// is indistinguishable from an already-mapped host path and is treated as
/// the latter; both readings stay inside the sandbox, so the sandbox
/// boundary is preserved either way.
final class SandboxedExecutionEnv implements ExecutionEnv {
  /// Creates an env mapping sandbox-absolute paths onto [_sandboxRoot],
  /// delegating everything else (relative paths, [exec]) to [_delegate].
  SandboxedExecutionEnv(this._delegate, this._sandboxRoot);

  final ExecutionEnv _delegate;
  final String _sandboxRoot;

  String _map(String path) {
    if (path == _sandboxRoot || path.startsWith('$_sandboxRoot/')) {
      return path;
    }
    if (path.startsWith('/')) return '$_sandboxRoot$path';
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
