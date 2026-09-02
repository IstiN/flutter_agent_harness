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
/// staged to `<cwd>/.fah/cube-profiles/<cacheKey>.sb` once per spec before
/// the first wrapped exec. A wrapper that never starts (binary missing from
/// PATH) or refuses the sandbox (EPERM on user namespaces, a rejected SBPL
/// profile) surfaces as a clean `fa_cube[<name>]:` spawn error, never a raw
/// crash.
///
/// The active spec is swappable at runtime ([updateSpec]/[clearSpec]), so a
/// long-lived environment can change cubes (or leave the sandbox entirely)
/// mid-session.
library;

import '../backends/cube_backend.dart';
import '../config/cube_spec.dart';
import '../../env/execution_env.dart';
import 'cache_manager.dart';
import 'policy_engine.dart';

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
  /// `linux`). Either missing — or a backend that does not enforce on the
  /// given platform — keeps the shell in pure policy mode.
  SandboxedShell(this._inner, CubeSpec? spec, {FileSystem? fs, String? os})
    : _fs = fs,
      _os = os {
    if (spec != null) updateSpec(spec);
  }

  final Shell _inner;
  final FileSystem? _fs;
  final String? _os;
  CubeSpec? _spec;
  late CubePolicyEngine _engine;
  _KernelRun? _kernel;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final spec = _spec;
    if (spec == null) return _inner.exec(command, options: options);
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
    final result = await _inner.exec(
      wrapped,
      options: sandboxExecOptions(spec, options),
    );
    return _mapKernelFailure(wrapped, result);
  }

  /// The command a background job should start for [command]: unchanged in
  /// policy mode, wrapped in the kernel backend in kernel mode (staging the
  /// profile on first use). [env] is the caller's per-exec environment —
  /// threaded into the clean child env so jobs keep session vars and
  /// secrets. The policy check stays with the caller.
  Future<String> prepare(String command, {Map<String, String>? env}) =>
      _kernel?.wrap(command, env: env) ?? Future.value(command);

  /// Swaps the enforced spec live; the next [exec] uses the new policies.
  void updateSpec(CubeSpec spec) {
    _spec = spec;
    _engine = CubePolicyEngine(spec);
    _kernel = _kernelRunFor(spec);
  }

  /// Leaves sandbox mode: every command is forwarded untouched.
  void clearSpec() {
    _spec = null;
    _kernel = null;
  }

  /// Binds the kernel backend for a `backend: kernel` spec, or `null` when
  /// the run stays in pure policy mode: no filesystem to stage with, no
  /// platform named, no backend for the platform, or the backend not
  /// enforcing there (Windows/web) — a kernel spec degrades to policy mode
  /// rather than failing the run.
  _KernelRun? _kernelRunFor(CubeSpec spec) {
    final fs = _fs;
    final os = _os;
    if (spec.backend != CubeBackendMode.kernel || fs == null || os == null) {
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
    final profilePath =
        '${fs.cwd}/.fah/cube-profiles/${cubeSpecCacheKey(spec)}.sb';
    final content = switch (backend) {
      final CubeProfileStaging staging => staging.buildProfile(
        spec,
        workspaceRoot: fs.cwd,
      ),
      _ => backend.describe(),
    };
    return _KernelRun(
      backend: backend,
      fs: fs,
      profilePath: profilePath,
      profileContent: content,
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
    if (kernel == null || spec == null) return null;
    return kernel.startupProbe(() async {
      await kernel.ensureStaged();
      final wrapped = kernel.backend.wrapCommand(
        'true',
        profilePath: kernel.profilePath,
      );
      final failure = _wrapperFailureNote(
        wrapped,
        await _inner.exec(wrapped, options: sandboxExecOptions(spec, null)),
      );
      if (failure == null) return null;
      return 'fa_cube[${spec.name}]: kernel backend ${failure.note}';
    });
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

  /// The clean `fa_cube[<name>]: kernel backend <note>` spawn error.
  Err<ShellExecResult, ExecutionError> _kernelErr(
    String note, {
    Object? cause,
  }) {
    return Err(
      ExecutionError(
        ExecutionErrorCode.spawnError,
        'fa_cube[${_spec?.name ?? 'cube'}]: kernel backend $note',
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
/// profile path and the one-shot staging state.
final class _KernelRun {
  _KernelRun({
    required this.backend,
    required this.fs,
    required this.profilePath,
    required this.profileContent,
  });

  final CubeSandboxBackend backend;
  final FileSystem fs;
  final String profilePath;
  final String profileContent;

  /// The one-shot startup probe (started by the first
  /// [SandboxedShell.startupFailure]): every caller awaits the same future,
  /// so nobody reads an outcome the probe has not produced yet.
  Future<String?>? _probe;

  /// The one-shot profile staging: concurrent first callers share the same
  /// future instead of writing (or execing) around an unfinished write.
  Future<void>? _staging;

  /// Starts [probe] once; later calls await the first run's outcome.
  Future<String?> startupProbe(Future<String?> Function() probe) =>
      _probe ??= probe();

  /// Stages the profile once per spec (reused when the file already
  /// exists). Concurrent first callers await the same write.
  Future<void> ensureStaged() => _staging ??= _stage();

  Future<void> _stage() async {
    if ((await fs.exists(profilePath)).valueOrNull != true) {
      await fs.writeFile(profilePath, profileContent);
    }
  }

  /// Stages the profile, then returns [command] wrapped for the backend.
  /// [env] (the caller's per-exec variables) overrides the cube-bound ones
  /// inside the clean child environment.
  Future<String> wrap(String command, {Map<String, String>? env}) async {
    await ensureStaged();
    return backend.wrapCommand(
      command,
      profilePath: profilePath,
      env: env ?? const {},
    );
  }
}
