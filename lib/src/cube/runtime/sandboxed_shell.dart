// ignore_for_file: prefer_initializing_formals
/// Shell-level policy enforcement for cubes: a [Shell] decorator that
/// refuses non-allowlisted commands and clamps execution to the cube's
/// resource limits.
///
/// [SandboxedShell] never throws: a denied command is answered with an
/// `Ok` result carrying exit code 127 and an `fa_cube[<name>]:` stderr
/// note, exactly like a shell reporting "command not found". The inner
/// shell is never reached for a denied command.
///
/// In `backend: kernel` mode with an enforcing backend for the host
/// platform, an allowed command is additionally wrapped in the OS sandbox
/// primitive (sandbox-exec / unshare) and the backend's profile artifact is
/// staged under `<homeDir>/.fah/cube-profiles/<content-hash>.sb` — a
/// user-level directory outside every guest-writable area — and is
/// re-verified against the recomputed profile immediately before every
/// wrapped exec (SEC-02: a profile inside the sandbox-writable workspace,
/// trusted by existence, would let the prisoner rewrite the prison). A
/// wrapper that never starts (binary missing from
/// PATH) or refuses the sandbox (EPERM on user namespaces, a rejected SBPL
/// profile) surfaces as a clean `fa_cube[<name>]:` spawn error, never a raw
/// crash.
///
/// The active spec is swappable at runtime ([updateSpec]/[clearSpec]), so a
/// long-lived environment can change cubes (or leave the sandbox entirely)
/// mid-session.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../backends/cube_backend.dart';
import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import '../../env/execution_env.dart';
import 'policy_engine.dart';

/// The user-level staging directory for kernel sandbox profiles: under the
/// host user's home, never under the workspace/cwd. The staged profile
/// itself grants workspace writes, so anything under the workspace is
/// prisoner-writable and cannot hold an enforcement artifact (SEC-02).
String cubeProfileStagingDir(String homeDir) => '$homeDir/.fah/cube-profiles';

/// Why [stagingDir] must not be trusted as the kernel profile staging
/// location, or `null` when it is provably outside the guest-writable
/// workspace ([workspaceRoot] — the area the sandboxed guest may write).
/// SEC-02 runtime invariant: an enforcement profile staged inside the
/// enforced zone (a workspace-relative `homeDir`, a home nested in or
/// equal to the workspace) is attacker-writable, so kernel mode refuses
/// instead of trusting it. Purely lexical: both paths must be absolute
/// (`..`/`.` segments normalized); a relative path can never be proven
/// outside, so it is rejected outright.
String? stagingOutsideWorkspace(String stagingDir, String workspaceRoot) {
  String? normalize(String p) {
    if (!p.startsWith('/')) return null;
    final out = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(seg);
    }
    return '/${out.join('/')}';
  }

  final stage = normalize(stagingDir);
  if (stage == null) {
    return 'profile staging directory must be an absolute path '
        '(got <$stagingDir>)';
  }
  final work = normalize(workspaceRoot);
  if (work == null) return null; // non-absolute cwd: nothing to prove against
  if (stage == work || stage.startsWith('$work/')) {
    return 'profile staging directory <$stagingDir> is inside the '
        'guest-writable workspace <$workspaceRoot>';
  }
  return null;
}

/// The full SEC-02 staging trust check for one spec binding: the
/// staging location must be provably outside the guest-writable
/// workspace *and* not writable by the guest through the spec's own
/// mounts (`~`- or `/`-rw mounts would let the repository rewrite the
/// enforcement profile). Returns the refusal note, or `null` when the
/// location is trustworthy.
String? stagingViolation(
  CubeSpec spec,
  String stagingDir, {
  required String homeDir,
  required String workspaceRoot,
}) {
  return stagingOutsideWorkspace(stagingDir, workspaceRoot) ??
      (spec.filesystem.accessFor(stagingDir, homeDir: homeDir) ==
              CubePathAccess.readWrite
          ? 'profile staging directory <$stagingDir> is guest-writable '
                'under the spec mounts'
          : null);
}

/// A [Shell] whose commands are gated by a cube's policies.

/// Builds the forwarded options for a permitted command under [spec]:
/// the timeout clamped to the cube's [CubeResourceLimits.timeout] (the
/// smaller of caller and cube wins; a null caller inherits the cube's),
/// plus the cube's injected env vars.
///
/// The env merge is additive only — [ShellExecOptions.env] cannot strip
/// variables the process already inherited; full environment cleanliness
/// is kernel-backend territory (Phase 2+).
ShellExecOptions sandboxExecOptions(CubeSpec spec, ShellExecOptions? options) {
  var timeout = options?.timeout;
  final cubeTimeout = spec.resources.timeout;
  if (cubeTimeout != null && (timeout == null || cubeTimeout < timeout)) {
    timeout = cubeTimeout;
  }
  final injected = spec.env.isEmpty
      ? const <String, String>{}
      : spec.env.apply(const {});
  final unchanged = injected.isEmpty && timeout == options?.timeout;
  if (unchanged) return options ?? const ShellExecOptions();
  return ShellExecOptions(
    cwd: options?.cwd,
    env: injected.isEmpty ? options?.env : {...injected, ...?options?.env},
    timeout: timeout,
    cancelToken: options?.cancelToken,
    onStdout: options?.onStdout,
    onStderr: options?.onStderr,
    stdinData: options?.stdinData,
  );
}

final class SandboxedShell implements Shell {
  /// Creates a sandbox over [inner], enforcing [spec]'s policies; a null
  /// [spec] is passthrough — every command forwards untouched until
  /// [updateSpec].
  ///
  /// [fs] and [os] enable `backend: kernel` mode: [fs] stages the backend's
  /// profile artifact and [os] names the host platform (`macos` or
  /// `linux`). [homeDir] anchors the user-level profile staging directory.
  /// Any of the three missing — or a backend that does not enforce on the
  /// given platform — leaves a `backend: kernel` spec undeliverable: by
  /// default the shell REFUSES (a named error on every [exec], zero
  /// commands run); with `spec.allowDegrade: true` it degrades to pure
  /// policy mode and [onDegrade] announces it. Either way the actual
  /// backend is queryable via [effectiveBackend].
  ///
  /// [homeDir] resolves `~` redirection targets in the policy engine.
  SandboxedShell(
    this._inner,
    CubeSpec? spec, {
    FileSystem? fs,
    String? os,
    String? homeDir,
    void Function(String message)? onDegrade,
  }) : _fs = fs,
       _os = os,
       _homeDir = homeDir,
       onDegrade = onDegrade {
    if (spec != null) updateSpec(spec);
  }

  final Shell _inner;
  final FileSystem? _fs;
  final String? _os;
  final String? _homeDir;
  CubeSpec? _spec;
  late CubePolicyEngine _engine;
  _KernelRun? _kernel;

  /// The named refusal for a `backend: kernel` spec that cannot be honored
  /// and was not allowed to degrade: every [exec] answers with it and no
  /// command ever runs.
  String? _refusal;

  /// Called when a `backend: kernel` spec degrades to policy mode because
  /// no enforcing backend exists for the host — only when the spec opted
  /// in via `allowDegrade`.
  final void Function(String message)? onDegrade;

  /// The backend this shell actually executes with: [CubeBackendMode.kernel]
  /// when commands are OS-wrapped, [CubeBackendMode.policy] when only the
  /// Dart policy layers run (a plain policy spec, or a kernel spec allowed
  /// to degrade), `null` in passthrough mode or while a kernel spec is
  /// refused (nothing executes at all). Hosts query this to display/audit
  /// what actually ran.
  CubeBackendMode? get effectiveBackend {
    if (_spec == null || _refusal != null) return null;
    return _kernel == null ? CubeBackendMode.policy : CubeBackendMode.kernel;
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final spec = _spec;
    if (spec == null) return _inner.exec(command, options: options);
    final refusal = _refusal;
    if (refusal != null) {
      // backend: kernel was requested and cannot be delivered: kernel or
      // refuse, zero commands run (SEC-05).
      return Err(ExecutionError(ExecutionErrorCode.spawnError, refusal));
    }
    final decision = _engine.checkCommand(command);
    if (!decision.allowed) {
      return Ok(
        ShellExecResult(
          stdout: '',
          stderr: 'fa_cube[${spec.name}]: ${decision.reason}',
          exitCode: 127,
        ),
      );
    }
    final kernel = _kernel;
    if (kernel == null) {
      return _inner.exec(command, options: sandboxExecOptions(spec, options));
    }
    final wrapped = await kernel.wrap(command, env: options?.env);
    if (wrapped == null) {
      // The profile could not be delivered intact — fail closed, never run
      // outside the kernel wrapper.
      return _kernelErr(kernel.stagingError!);
    }
    final result = await _inner.exec(
      wrapped,
      options: sandboxExecOptions(spec, options),
    );
    return _mapKernelFailure(wrapped, result);
  }

  /// The command a background job should start for [command]: unchanged in
  /// policy mode, wrapped in the kernel backend in kernel mode (verifying
  /// and if necessary restaging the profile first — `null` when staging
  /// failed, see [kernelStagingError]; the caller must refuse to start the
  /// job). [env] is the caller's per-exec environment —
  /// threaded into the clean child env so jobs keep session vars and
  /// secrets. The policy check stays with the caller.
  Future<String?> prepare(String command, {Map<String, String>? env}) =>
      _kernel?.wrap(command, env: env) ?? Future.value(command);

  /// The staging failure note from the last kernel staging attempt, or
  /// `null` (set when [prepare] returns `null`).
  String? get kernelStagingError => _kernel?.stagingError;

  /// The single error shape every kernel failure surfaces — foreground
  /// execs, the background startup probe and background-job refusals
  /// ([kernelStagingError] consumers) all render their note through this,
  /// so callers and tests match exactly one prefix.
  String kernelError(String note) =>
      'fa_cube[${_spec?.name ?? 'cube'}]: kernel backend $note';

  /// Swaps the enforced spec live; the next [exec] uses the new policies.
  /// A `backend: kernel` spec with no enforcing backend for the host
  /// refuses (every command denied, nothing runs) unless the spec opts in
  /// via `allowDegrade`, in which case it degrades to policy mode and
  /// fires [onDegrade].
  void updateSpec(CubeSpec spec) {
    _spec = spec;
    _refusal = null;
    _engine = CubePolicyEngine(
      spec,
      homeDir: _homeDir,
      workspaceRoot: _fs?.cwd,
    );
    _kernel = _kernelRunFor(spec);
    if (_kernel == null && spec.backend == CubeBackendMode.kernel) {
      if (spec.allowDegrade) {
        onDegrade?.call(
          'fa_cube[${spec.name}]: kernel backend unavailable, '
          'running in policy mode',
        );
      } else {
        _refusal =
            'fa_cube[${spec.name}]: backend: kernel is not available on '
            'this platform and the run refuses to fall back to policy '
            'mode — set spec.allowDegrade: true to allow the degrade';
      }
      return;
    }
    final blocked = _kernel?.blockedNote;
    if (blocked != null) {
      if (spec.allowDegrade) {
        // The explicit escape hatch: the staging location cannot be
        // trusted, so kernel mode is undeliverable — degrade instead of
        // hard-locking the spec (same contract as the unavailable
        // backend above).
        _kernel = null;
        onDegrade?.call(
          'fa_cube[${spec.name}]: kernel backend $blocked, '
          'allowDegrade set — running in policy mode',
        );
      }
      // Without the opt-in the per-exec path fail-closes with the
      // remediation in the note (see [_KernelRun.stageVerified]).
    }
  }

  /// Leaves sandbox mode: every command is forwarded untouched.
  void clearSpec() {
    _spec = null;
    _kernel = null;
    _refusal = null;
  }

  /// Binds the kernel backend for a `backend: kernel` spec, or `null` when
  /// kernel mode is undeliverable: no filesystem to stage with, no user
  /// home to stage outside the workspace, no platform named, no backend
  /// for the platform, or the backend not enforcing there (Windows/web).
  /// The caller decides the outcome — refusal by default, policy mode
  /// under `allowDegrade`.
  _KernelRun? _kernelRunFor(CubeSpec spec) {
    final fs = _fs;
    final os = _os;
    final home = _homeDir;
    if (spec.backend != CubeBackendMode.kernel ||
        fs == null ||
        os == null ||
        home == null) {
      return null;
    }
    final backend = cubeBackendForPlatform(
      os,
      spec: spec,
      workspaceRoot: fs.cwd,
      tmpdir: '${fs.cwd}/.fah/tmp',
      envVars: spec.env.apply(const {}),
    );
    if (!backend.enforces) return null;
    final content = switch (backend) {
      final CubeProfileStaging staging => staging.buildProfile(
        spec,
        workspaceRoot: fs.cwd,
      ),
      _ => backend.describe(),
    };
    // Content-addressed file name: the exact bytes we trust are the bytes
    // the name hashes. The spec cacheKey alone would collide across
    // workspaces (presets share one spec; the profile bakes in the cwd).
    final name = md5.convert(utf8.encode(content)).toString().substring(0, 16);
    final stagingDir = cubeProfileStagingDir(home);
    // SEC-02 runtime invariant: the staging location must be outside every
    // guest-writable area. Verified here, before anything is trusted or
    // written — a violation fail-closes the run (every command refused
    // with a remediation in the error), or degrades to policy mode when
    // the spec explicitly opted in via allowDegrade.
    return _KernelRun(
      backend: backend,
      fs: fs,
      profilePath: '$stagingDir/$name.sb',
      profileContent: content,
      blockedNote: stagingViolation(
        spec,
        stagingDir,
        homeDir: home,
        workspaceRoot: fs.cwd,
      ),
    );
  }

  /// One-shot capability probe for `backend: kernel` background jobs: a
  /// job started through [prepare] only reports a wrapper failure inside
  /// its job log, so [startupFailure] runs a wrapped no-op command once
  /// per spec first and yields the clean failure note up front (`null` =
  /// the wrapper works). Foreground execs skip this — [exec] maps the
  /// failure from the result directly.
  Future<String?> startupFailure() async {
    final kernel = _kernel;
    final spec = _spec;
    if (spec == null) return null;
    final refusal = _refusal;
    if (refusal != null) return refusal;
    if (kernel == null) return null;
    if (kernel.probed) return kernel.failureNote;
    kernel.probed = true;
    if (!await kernel.stageVerified()) {
      return kernel.failureNote = kernelError(kernel.stagingError!);
    }
    final wrapped = kernel.backend.wrapCommand(
      'true',
      profilePath: kernel.profilePath,
    );
    final failure = _wrapperFailureNote(
      wrapped,
      await _inner.exec(wrapped, options: sandboxExecOptions(spec, null)),
    );
    if (failure == null) return null;
    return kernel.failureNote = kernelError(failure.note);
  }

  /// Maps kernel-wrapper startup failures to clean spawn errors (the
  /// failure shapes live in [_wrapperFailureNote]).
  Result<ShellExecResult, ExecutionError> _mapKernelFailure(
    String wrapped,
    Result<ShellExecResult, ExecutionError> result,
  ) {
    final failure = _wrapperFailureNote(wrapped, result);
    if (failure == null) return result;
    return _kernelErr(failure.note, cause: failure.cause);
  }

  /// Maps kernel failures to the one clean error shape (see
  /// [kernelError]).
  Err<ShellExecResult, ExecutionError> _kernelErr(
    String note, {
    Object? cause,
  }) {
    return Err(
      ExecutionError(
        ExecutionErrorCode.spawnError,
        kernelError(note),
        cause: cause,
      ),
    );
  }
}

/// Classifies a kernel-wrapper startup failure for the wrapped command
/// [wrapped] (the wrapper is its first word: `sandbox-exec`, `unshare`).
/// Two failure shapes carry a note: the binary missing from PATH (a spawn
/// [ExecutionError] naming it, or exit 127 with a `not found` stderr), and
/// the binary spawning but refusing the sandbox — a non-zero exit whose
/// stderr line starts with `<wrapper>: ` (unshare EPERM without user
/// namespaces, a rejected SBPL profile); the payload never ran in either.
/// A payload failure keeps its own output: the wrapper never prefixes a
/// payload's stderr. Returns the note and its cause, or `null`.
({String note, Object? cause})? _wrapperFailureNote(
  String wrapped,
  Result<ShellExecResult, ExecutionError> result,
) {
  final wrapper = wrapped.split(' ').first;
  final missing = switch (result) {
    Err(error: final error) =>
      error.code == ExecutionErrorCode.spawnError &&
          error.message.contains(wrapper),
    Ok(value: final value) =>
      value.exitCode == 127 &&
          value.stderr.contains(wrapper) &&
          value.stderr.contains('not found'),
  };
  if (missing) {
    return (
      note: 'requires $wrapper on PATH',
      cause: result.errorOrNull?.cause,
    );
  }
  if (result case Ok(:final value) when value.exitCode != 0) {
    final complaint = value.stderr
        .split('\n')
        .firstWhere((line) => line.startsWith('$wrapper: '), orElse: () => '');
    if (complaint.isNotEmpty) {
      return (
        note:
            '$wrapper failed: '
            '${complaint.substring('$wrapper: '.length)}',
        cause: value.stderr,
      );
    }
  }
  return null;
}

/// The kernel-mode binding of one spec: the enforcing backend, its staged
/// profile path and the content-verified staging state.
final class _KernelRun {
  _KernelRun({
    required this.backend,
    required this.fs,
    required this.profilePath,
    required this.profileContent,
    this.blockedNote,
  });

  final CubeSandboxBackend backend;
  final FileSystem fs;
  final String profilePath;
  final String profileContent;

  /// Pre-set trust failure: the staging location itself violates the
  /// SEC-02 invariant (never provably outside the guest-writable area).
  /// Staging refuses before touching the disk; the caller fail-closes.
  final String? blockedNote;

  /// The staging failure note when the last [stageVerified] gave up.
  String? stagingError;

  /// Set by the [SandboxedShell.startupFailure] probe: the clean wrapper
  /// failure note, or `null` when the probe never ran or succeeded.
  bool probed = false;
  String? failureNote;

  int _tmpSeq = 0;
  bool _swept = false;

  /// Verifies the staged profile against the recomputed content and
  /// restages atomically when it is missing or tampered with (SEC-02).
  /// Trust is content, never existence — there is no once-only latch: the
  /// file is re-read and compared immediately before every wrapped exec.
  /// Returns `false` and sets [stagingError] when the profile cannot be
  /// delivered intact (the caller must refuse to exec).
  Future<bool> stageVerified() async {
    final blocked = blockedNote;
    if (blocked != null) {
      stagingError = '$blocked — set spec.allowDegrade: true to run in '
          'policy mode, or narrow the read-write mounts';
      return false;
    }
    if (!_swept) {
      _swept = true;
      await _sweepStagingDir();
    }
    final existing = await fs.readTextFile(profilePath);
    if (existing.valueOrNull == profileContent) {
      // A stale note from an earlier failed attempt must not outlive a
      // successful verification.
      stagingError = null;
      return true;
    }
    // Restage out-of-band and flip the directory entry atomically: no
    // reader ever sees partial bytes, and anything planted at
    // [profilePath] (a symlink, tampered bytes) is replaced, not followed
    // or trusted. The profile directory is user-level (outside every
    // guest-writable area), so only we and the user write here.
    if (fs is! RenamableFileSystem) {
      stagingError =
          'profile staging failed: filesystem cannot atomically restage '
          '$profilePath';
      return false;
    }
    // ponytail: instance-scoped temp names; a freak cross-instance
    // identityHashCode collision just fails one rename and the next exec
    // restages again — no latch, self-healing.
    final tmp = '$profilePath.${identityHashCode(this)}-${_tmpSeq++}.tmp';
    final write = await fs.writeFile(tmp, profileContent);
    if (write.isErr) {
      stagingError = 'profile staging failed: ${write.errorOrNull!.message}';
      return false;
    }
    final rename = await (fs as RenamableFileSystem).renamePath(
      tmp,
      profilePath,
    );
    if (rename.isErr) {
      stagingError = 'profile staging failed: ${rename.errorOrNull!.message}';
      return false;
    }
    stagingError = null;
    return true;
  }

  /// Best-effort staging-dir hygiene, once per binding (the "boot" of
  /// this spec's kernel mode): crashed restages leave
  /// `<profile>.<instance>-<n>.tmp` orphans behind. Strictly scoped to
  /// this binding's own debris — files prefixed with this profile's own
  /// content-hash name; other bindings' files (their live `<md5>.sb`
  /// profiles and their tmp files) are theirs to verify and sweep, so an
  /// alternating or concurrent session never evicts a profile in use.
  /// Never fails staging — a sweep error is swallowed.
  ///
  // TODO(cube): retired bindings' stale `<md5>.sb` profiles are never
  // swept — the staging dir grows unboundedly across spec churn
  // (per-binding scoping is the price of never evicting a live profile;
  // needs an age- or refcount-based follow-up).
  // TODO(cube): the sweep runs once per binding and is best-effort — a
  // failed sweep leaves this binding's `.tmp` orphans until the next
  // boot; a retry keyed off [stagingError] would close the window.
  Future<void> _sweepStagingDir() async {
    final slash = profilePath.lastIndexOf('/');
    if (slash <= 0) return;
    final dir = profilePath.substring(0, slash);
    final ownPrefix = '${profilePath.substring(slash + 1)}.';
    final entries = (await fs.listDir(dir)).valueOrNull;
    if (entries == null) return;
    for (final entry in entries) {
      final path = entry.path;
      if (path == profilePath) continue;
      if (entry.name.startsWith(ownPrefix) && path.endsWith('.tmp')) {
        await fs.remove(path, force: true);
      }
    }
  }

  /// Verifies/stages the profile, then returns [command] wrapped for the
  /// backend — or `null` when staging failed ([stagingError] carries the
  /// note; the caller must refuse the exec). [env] (the caller's per-exec
  /// variables) overrides the cube-bound ones inside the clean child
  /// environment.
  Future<String?> wrap(String command, {Map<String, String>? env}) async {
    if (!await stageVerified()) return null;
    return backend.wrapCommand(
      command,
      profilePath: profilePath,
      env: env ?? const {},
    );
  }
}
