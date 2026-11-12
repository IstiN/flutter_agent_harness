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
abstract interface class AppOwnedStorage {
  /// The app-container environment, excluding any user-mounted project view.
  ExecutionEnv get appOwnedStorage;
}

abstract interface class LiveProjectMount {
  /// The user-granted host folder, updated by the file-browser mount flow.
  String? get liveMountedProjectPath;
}

/// Platform-neutral view of a host that owns a [ProjectMountEnv].
///
/// Mobile keeps its mount beside (rather than underneath) the persistent
/// container so snapshots never copy the granted folder. This seam lets the
/// shared UI/session code find that mount without importing the IO factory.
abstract interface class ProjectMountHost {
  /// The live mount metadata shared with the shell and mount UI.
  ProjectMountEnv get projectMount;

  /// Whether the active backend can honor a native folder grant.
  bool get supportsNativeProjectMount;
}

final class ProjectMountEnv extends ForwardingFs
    with
        ForwardingBackgroundShell,
        ForwardingRangedReadFs,
        ForwardingRenamableFs
    implements LiveProjectMount {
  /// Creates an env over the delegate with no active mount.
  ProjectMountEnv(super.delegate);

  String? _mountedRoot;
  ExecutionEnv? _containerStorage;

  /// Storage-only attachment for the mobile live-mount view. The shell uses
  /// this mount object for metadata; the mobile env owns actual FS/shell
  /// dispatch, so this never becomes a recursive execution delegate.
  set containerStorage(ExecutionEnv value) => _containerStorage = value;

  @override
  ExecutionEnv get delegate => _containerStorage ?? super.delegate;

  /// The currently mounted host directory, or null when nothing is mounted.
  String? get mountedRoot => _mountedRoot;

  @override
  String? get liveMountedProjectPath => _mountedRoot;

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
    if (path == 'project_mount.json') return path;
    if (path == projectMountSegment) return root;
    if (path.startsWith('$projectMountSegment/')) {
      return '$root/${path.substring(projectMountSegment.length + 1)}';
    }
    return path;
  }

  @override
  String get cwd => _mountedRoot != null
      ? projectMountSegment
      : _containerStorage?.cwd ?? delegate.cwd;

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
    final background = delegate;
    if (background case final BackgroundShell bg) {
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

/// Finds the live project mount below the host's secrets/session wrappers.
/// Returns null when this host has no native project-folder entitlement.
///
/// A [CwdOverrideEnv] session env (a per-chat sandbox folder wrapped
/// around the full stack) is transparent here: the mount lives below it,
/// and a session that picks a project folder AFTER creation must still
/// surface the mount (identity chip, mount-aware [visibleFolderRoot],
/// mount-root listing) — gh-2131 "mounted files not visible".
ProjectMountEnv? resolveProjectMountEnv(ExecutionEnv env) {
  ExecutionEnv current = env;
  for (var depth = 0; depth < 8; depth++) {
    if (current case final ProjectMountEnv mount) return mount;
    if (current case final ProjectMountHost host) return host.projectMount;
    if (current case final SecretsExecutionEnv secrets) {
      current = secrets.delegate;
      continue;
    }
    if (current case final SessionVarsExecutionEnv vars) {
      current = vars.delegate;
      continue;
    }
    if (current case final CwdOverrideEnv override) {
      current = override.delegate;
      continue;
    }
    return null;
  }
  return null;
}

/// Whether the active backend can access a native project folder.
/// The MemoryShell fallback keeps the container usable but cannot satisfy
/// this entitlement; presenting a picker there would promise a false mount.
bool projectMountBackendAvailable(ExecutionEnv env) {
  ExecutionEnv current = env;
  for (var depth = 0; depth < 8; depth++) {
    if (current case final ProjectMountHost host) {
      return host.supportsNativeProjectMount;
    }
    if (current case final SecretsExecutionEnv secrets) {
      current = secrets.delegate;
    } else if (current case final SessionVarsExecutionEnv vars) {
      current = vars.delegate;
    } else if (current case final CwdOverrideEnv override) {
      current = override.delegate;
    } else {
      break;
    }
  }
  return true;
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
    // A cwd override IS the session's working directory: its folder
    // scopes the session even when a mount lives below the override.
    if (env is CwdOverrideEnv) return env.cwd;
    final root = resolveProjectMountEnv(env)?.mountedRoot;
    if (root != null) return root;
    return cwd;
  }
}

/// Whether cwd-relative paths resolve against the mount segment: the
/// stack's [ExecutionEnv.cwd] IS `/project` only when no cwd override
/// sits between the caller and the live mount. The file browser branches
/// on this — a mount-rooted session navigates through
/// [projectMountSegment], an override session (sandbox folder) keeps
/// plain cwd-relative paths.
bool envCwdResolvesToMountSegment(ExecutionEnv env) {
  ExecutionEnv current = env;
  for (var depth = 0; depth < 8; depth++) {
    if (current case final ProjectMountEnv mount) {
      return mount.mountedRoot != null;
    }
    if (current case final SecretsExecutionEnv secrets) {
      current = secrets.delegate;
    } else if (current case final SessionVarsExecutionEnv vars) {
      current = vars.delegate;
    } else {
      // A CwdOverrideEnv (or any other decorator) owns the cwd.
      return false;
    }
  }
  return false;
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
      } else if (env case final AppOwnedStorage storage) {
        return storage.appOwnedStorage.cwd;
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
      } else if (env case final AppOwnedStorage storage) {
        return storage.appOwnedStorage;
      } else {
        return env;
      }
    }
  }
}
