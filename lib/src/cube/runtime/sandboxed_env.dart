/// Whole-environment cube enforcement: an [ExecutionEnv] decorator that
/// routes filesystem operations through [CubeFsGuard] and shell executions
/// through [SandboxedShell].
///
/// [SandboxedExecutionEnv] composes the two layers of a cube onto any
/// delegate environment, following the decorator template of
/// `SessionVarsExecutionEnv`: one-line forwards for everything the cube
/// does not constrain, policy checks for everything it does. Detached shell
/// jobs ([BackgroundShell.startShellJob]) run the same command policy as
/// [SandboxedShell.exec] — a denied job is never started.
///
/// The active spec is swappable at runtime ([updateSpec]/[clearSpec]);
/// [activeSpec] reports it (`null` = passthrough).
// ignore_for_file: prefer_initializing_formals
library;

import 'dart:typed_data';

import '../config/cube_spec.dart';
import '../../env/execution_env.dart';
import 'cube_fs_guard.dart';
import 'policy_engine.dart';
import 'sandboxed_shell.dart';

/// An [ExecutionEnv] confined by a cube's policies.
final class SandboxedExecutionEnv implements ExecutionEnv, BackgroundShell {
  /// Creates a sandboxed view over [delegate]. A non-null [spec] is
  /// enforced immediately; `null` starts in passthrough mode (as after
  /// [clearSpec]) — [updateSpec] swaps a cube in later.
  ///
  /// [homeDir] and [workspaceRoot] forward to [CubeFsGuard] (the CLI passes
  /// the real process cwd as [workspaceRoot]; the cube's `/workspace` is
  /// realized as the env cwd, not a literal directory).
  ///
  /// [os] names the host platform for `backend: kernel` specs (the CLI
  /// passes `Platform.operatingSystem`; `lib/src` itself stays pure Dart).
  /// A null [os] — or a platform without an enforcing backend — keeps
  /// kernel-mode cubes in pure policy mode.
  SandboxedExecutionEnv(
    this._delegate,
    CubeSpec? spec, {
    String? homeDir,
    String? workspaceRoot,
    String? os,
  }) : _homeDir = homeDir,
       _workspaceRoot = workspaceRoot,
       _os = os {
    if (spec == null) {
      // Passthrough from the start: the shell exists but enforces nothing.
      _shell = SandboxedShell(_delegate, null);
    } else {
      updateSpec(spec);
    }
  }

  final String? _homeDir;
  final ExecutionEnv _delegate;
  final String? _workspaceRoot;
  final String? _os;

  CubeFsGuard? _guard;
  late SandboxedShell _shell;
  CubePolicyEngine? _engine;

  /// The spec currently enforced, or `null` in passthrough mode.
  CubeSpec? get activeSpec => _shellActiveSpec;

  /// Reads the shell's live spec (the single source of truth for sandbox
  /// mode across the fs guard, shell and job policy checks).
  CubeSpec? get _shellActiveSpec => _guard == null ? null : _shellSpec;

  CubeSpec? _shellSpec;

  @override
  String get cwd => _delegate.cwd;

  /// Routes a filesystem operation through the guard, or straight to the
  /// delegate when no spec is active.
  Future<Result<T, FileError>> _fs<T>(
    Future<Result<T, FileError>> Function(FileSystem fs) op,
  ) {
    final guard = _guard;
    return op(guard ?? _delegate);
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _shell.exec(command, options: options);

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
    final engine = _engine;
    final spec = activeSpec;
    if (engine == null || spec == null) {
      return bg.startShellJob(
        command,
        id: id,
        logPath: logPath,
        options: options,
      );
    }
    final decision = engine.checkCommand(command);
    if (!decision.allowed) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          'fa_cube[${spec.name}]: ${decision.reason}',
        ),
      );
    }
    // backend: kernel wraps background jobs exactly like foreground execs —
    // probe the wrapper up front so a broken sandbox (missing binary, EPERM
    // refusal) denies the job with a clean `fa_cube[<name>]:` note instead
    // of surfacing the raw failure inside the job log.
    final wrapperFailure = await _shell.startupFailure();
    if (wrapperFailure != null) {
      return Err(ExecutionError(ExecutionErrorCode.spawnError, wrapperFailure));
    }
    return bg.startShellJob(
      await _shell.prepare(command, env: options?.env),
      id: id,
      logPath: logPath,
      options: sandboxExecOptions(spec, options),
    );
  }

  /// Swaps the enforced spec live; the fs guard, shell and job policy all
  /// pick it up on their next call.
  void updateSpec(CubeSpec spec) {
    _shellSpec = spec;
    _guard = CubeFsGuard(
      _delegate,
      spec,
      homeDir: _homeDir,
      workspaceRoot: _workspaceRoot,
    );
    _shell = SandboxedShell(_delegate, spec, fs: _delegate, os: _os);
    _engine = CubePolicyEngine(spec);
  }

  /// Leaves sandbox mode: every operation forwards untouched.
  void clearSpec() {
    _shellSpec = null;
    _guard = null;
    _engine = null;
    _shell.clearSpec();
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _fs((fs) => fs.readTextFile(path));

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _fs((fs) => fs.readBinaryFile(path));

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _fs((fs) => fs.readTextLines(path, maxLines: maxLines));

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _fs((fs) => fs.writeBinaryFile(path, content));

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _fs((fs) => fs.writeFile(path, content));

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _fs((fs) => fs.appendFile(path, content));

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _fs((fs) => fs.fileInfo(path));

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _fs((fs) => fs.listDir(path));

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _fs((fs) => fs.exists(path));

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _fs((fs) => fs.createDir(path, recursive: recursive));

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _fs((fs) => fs.remove(path, recursive: recursive, force: force));
}
