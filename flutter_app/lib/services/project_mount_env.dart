import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The mount segment inside the agent's filesystem: the user-selected
/// project folder (macOS sandbox, user-selected read-write entitlement)
/// appears under this path while the env root stays the app container.
const projectMountSegment = '/project';

/// Maps the `/project` mount segment onto a user-selected host directory,
/// delegating everything else to the app-container env.
///
/// When a project folder is mounted, the agent's working directory becomes
/// `/project` and shell executions run inside the host directory. Sessions
/// (and any other cwd-relative state) are therefore scoped to the mounted
/// folder, matching the CLI behavior where each workspace has its own
/// `sessions/` directory.
///
/// Path mapping is idempotent: host paths already under the mounted
/// directory pass through unchanged, so values the env itself hands out
/// ([absolutePath]/[joinPath] results, [FileInfo.path]) stay valid input.
final class ProjectMountEnv extends ForwardingFs
    with
        ForwardingBackgroundShell,
        ForwardingRangedReadFs,
        ForwardingRenamableFs {
  /// Creates an env over the delegate with no active mount.
  ProjectMountEnv(super.delegate);

  String? _mountedRoot;

  /// The currently mounted host directory, or null when nothing is mounted.
  String? get mountedRoot => _mountedRoot;

  /// Mounts [hostPath] (null unmounts). No FS access here — the caller
  /// (store/channel) owns the security-scoped access lifecycle.
  set mountedRoot(String? hostPath) =>
      _mountedRoot = hostPath == null || hostPath.isEmpty ? null : hostPath;

  /// Whether the agent's tools are restricted to operate only inside the
  /// mounted folder. Persists across restarts via [ProjectMountStore.scoped].
  /// The flag is independent of the mount itself — toggling it does not
  /// re-pick the folder; use the workspace dialog to change it.
  bool scoped = false;

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
  String get cwd => _mountedRoot != null ? projectMountSegment : delegate.cwd;

  @override
  String mapPath(String path) => _map(path);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) {
    final root = _mountedRoot;
    if (root == null) return delegate.exec(command, options: options);
    final optsCwd = options?.cwd;
    final cwd = optsCwd == null ? root : _map(optsCwd);
    final mappedOptions = ShellExecOptions(
      cwd: cwd,
      env: options?.env,
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
    );
    return delegate.exec(command, options: mappedOptions);
  }

  // Background shell jobs (desktop: the delegate is the real host shell).
  // The log path comes from the registry under env.cwd — already a host path,
  // so it needs no mount mapping.

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) {
    final root = _mountedRoot;
    final mappedOptions = root == null
        ? options
        : ShellExecOptions(
            cwd: options?.cwd == null ? root : _map(options!.cwd!),
            env: options?.env,
            timeout: options?.timeout,
            cancelToken: options?.cancelToken,
            onStdout: options?.onStdout,
            onStderr: options?.onStderr,
            jobLogMaxBytes: options?.jobLogMaxBytes,
            onJobLogWarning: options?.onJobLogWarning,
            stdinData: options?.stdinData,
            liveStdin: options?.liveStdin,
          );
    final delegate = this.delegate;
    if (delegate case final BackgroundShell bg) {
      return bg.startShellJob(
        command,
        id: id,
        // Log paths computed from env.cwd may use the virtual /project segment;
        // the delegate (real host shell) needs the physical host path.
        logPath: root == null ? logPath : _map(logPath),
        options: mappedOptions,
      );
    }
    return Future.value(
      const Err(
        ExecutionError(
          ExecutionErrorCode.shellUnavailable,
          'background shell jobs are not supported by this shell',
        ),
      ),
    );
  }
}

/// The directory used for session scoping.
///
/// When a project folder is mounted this is the host path, so sessions and
/// messaging are stored at the same physical location as the CLI uses for the
/// same workspace. Otherwise it falls back to [ExecutionEnv.cwd].
extension SessionCwd on ExecutionEnv {
  String get sessionCwd {
    var env = this;
    // Unwrap decorators (secrets/session-vars) that sit between callers
    // and the mount env so the mounted host path is found reliably.
    while (true) {
      if (env is SecretsExecutionEnv) {
        env = env.delegate;
      } else if (env is SessionVarsExecutionEnv) {
        env = env.delegate;
      } else {
        break;
      }
    }
    if (env case final ProjectMountEnv mountEnv) {
      final root = mountEnv.mountedRoot;
      if (root != null) return root;
    }
    return cwd;
  }
}

/// App-container storage root, never the mounted user project. Dedicated
/// credentials and identities must not become project/session artifacts.
extension AppStorageCwd on ExecutionEnv {
  String get appStorageCwd {
    var env = this;
    while (true) {
      if (env is SecretsExecutionEnv) {
        env = env.delegate;
      } else if (env is SessionVarsExecutionEnv) {
        env = env.delegate;
      } else if (env case final ProjectMountEnv mountEnv) {
        env = mountEnv.delegate;
      } else {
        return env.cwd;
      }
    }
  }
}

/// The app-owned environment underneath the decorator/mount stack.
///
/// Where [AppStorageCwd] yields only the container cwd string, this
/// resolves the [ExecutionEnv] itself, so callers can walk or mutate the
/// app container with listDir/remove semantics that never see the mounted
/// user project (gh-2004 review: the first-boot leftover cleanup must
/// operate on app-owned storage only).
extension AppOwnedEnv on ExecutionEnv {
  ExecutionEnv get appOwnedEnv {
    var env = this;
    while (true) {
      if (env is SecretsExecutionEnv) {
        env = env.delegate;
      } else if (env is SessionVarsExecutionEnv) {
        env = env.delegate;
      } else if (env case final ProjectMountEnv mountEnv) {
        env = mountEnv.delegate;
      } else {
        return env;
      }
    }
  }
}
