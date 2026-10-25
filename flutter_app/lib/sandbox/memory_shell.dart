// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/utils/glob_match.dart'
    show globToRegExp;
import 'package:http/http.dart' as http;

import 'package:fa/sandbox/memory_shell/awk.dart';
import 'package:fa/sandbox/memory_shell/grep.dart'
    show GrepAccumulator, GrepQuery, compileGrepQuery, grepText;
import 'package:fa/sandbox/memory_shell/interpreters.dart';
import 'package:fa/sandbox/memory_shell/pipeline.dart';
import 'package:fa/sandbox/memory_shell/paths.dart';
import 'package:fa/sandbox/memory_shell/sed.dart';
import 'package:fa/sandbox/memory_shell/tar.dart';
import 'package:fa/sandbox/memory_shell/test_expr.dart';
import 'package:fa/sandbox/glob_expand.dart';
import 'package:fa/sandbox/grep_args.dart';
import 'package:fa/sandbox/sandbox_builtins.dart';
import 'package:fa/sandbox/sandbox_registry.dart';
import 'package:fa/sandbox/shell_job.dart';
import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/shell_script.dart';
import 'package:fa/sandbox/wasm_shell_builtins.dart'
    show StageRedirects, exportEnvVarName, isNullDevicePath;
import 'package:fa/sandbox/web_git.dart';
import 'package:fa/sandbox/web_interpreters_stub.dart'
    if (dart.library.html) 'web_interpreters_web.dart';

/// The normalized command handler signature of `MemoryShell`'s route
/// table (`_commandRoutes`): one `(shell, ctx)` closure per advertised
/// command (issue #1713, the #558 route-table pattern).
typedef _CommandRoute =
    Future<_StageResult> Function(MemoryShell shell, _Context ctx);

/// A pure-Dart [Shell] that operates on a [MemoryFileSystem].
///
/// This is the web fallback for the WASM-backed `WasiSandboxShell`: the
/// vendored `package:wasm_run` cannot be compiled for the web (its
/// flutter_rust_bridge bindings import `dart:ffi` unconditionally), so no
/// WASM runtime is available in the browser. This shell implements the
/// command subset the agent relies on day to day — pipelines, `&&`/`||`/`;`,
/// redirects, `cd`/`export` state that persists across [exec] calls, and the
/// common POSIX utilities — directly in Dart over the in-memory filesystem.
///
/// On top of the core POSIX utilities, the following are implemented in
/// pure Dart and work in the browser: `curl`/`wget`/`jq`/`yq`/`diff`/`patch`,
/// plus `nslookup`/`dig` (DNS-over-HTTPS via cloudflare-dns.com) and `whois`
/// (RDAP over HTTPS via rdap.org) — all shared with the WASM shell via
/// `sandbox_builtins.dart` — `sed`, `awk`, `find`, `xargs`, `printf`,
/// `realpath`, `tar`/`gzip`/`gunzip`/`zip`/`unzip`/`xz -d`/`bzip2 -d`
/// (+`unxz`/`bunzip2`) and `file` (via `package:archive`), `tree`,
/// `base64`, `md5sum`/`sha*sum` (via `package:crypto`, matching the uutils
/// applets on iOS), and `rg` (an alias of the Dart `grep`
/// implementation, mirroring iOS where `grep` maps to `rg` with grep
/// semantics). `python3`/`qjs`/`sqlite3` run in browser-hosted interpreters
/// loaded from CDNs (pyodide, quickjs-emscripten, sql.js) and `pip`/`pip3`
/// install pure-Python wheels via pyodide's micropip; `lua` has no
/// browser build. All report "command not found" (127). `git` works locally via
/// dart_git; remote clone/push is not supported in the browser (CORS).
/// `ssh`/`scp`/`sftp` are registered (so `which` finds them) but always fail
/// with exit code 127 — browsers cannot open raw TCP connections.
/// Everything else reports exit code 127, which the agent can react to.
///
/// Background jobs (`BackgroundShell`): a job is the script's Future running
/// on a job-local clone (own cwd/shell-vars/output-capture, shared fs), so a
/// detached run never clobbers the foreground shell or a sibling job.
final class MemoryShell implements Shell, BackgroundShell {
  /// Creates a shell without a filesystem. Call [attach] before [exec]; this
  /// indirection lets the shell and the [MemoryExecutionEnv] that owns it
  /// reference each other.
  ///
  /// [httpClient] backs the `curl`/`wget` builtins; tests can inject a
  /// `MockClient` from `package:http/testing.dart`.
  MemoryShell({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  late final MemoryFileSystem _fs;
  late final WebGitCommands _gitCommands;

  /// Binds the shell to [fs]. Must be called exactly once before use.
  void attach(MemoryFileSystem fs) {
    _fs = fs;
    _gitCommands = WebGitCommands(fs);
  }

  String _currentDir = '/';
  final Map<String, String> _shellEnv = {};

  /// Exit code of the last completed pipeline stage (POSIX `$?`, issue
  /// #1335). Assignment-only statements keep the previous value — a
  /// documented subset divergence.
  int _lastExitCode = 0;

  String? _lastStdout;
  String? _lastStderr;

  /// Commands available in the sandbox: [webShellCommandNames] from the
  /// central registry (`sandbox_registry.dart`), used by `which`/`command -v`
  /// and to decide between execution and "command not found".
  static const Set<String> _availableCommands = webShellCommandNames;

  /// Checksum commands dispatched to [_hashsum].
  static const _hashCommands = {
    'md5sum',
    'sha1sum',
    'sha224sum',
    'sha256sum',
    'sha384sum',
    'sha512sum',
  };

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }

    late final ShellScript script;
    try {
      // fd duplication opted in (gh-1393 WS-1 / AC3): `2>&1`/`>&2` parse
      // and fold exactly as the WASI tokenizer always has — the web shell
      // no longer rejects them outright.
      script = parseShellScript(command, allowFdDuplication: true);
    } on ShellParseException catch (e) {
      return Err(ExecutionError(ExecutionErrorCode.unknown, 'parse error: $e'));
    }

    // One output accumulator per exec: pipelines APPEND to it (POSIX — the
    // output of `echo a; echo b` is both lines, not the last one).
    _lastStdout = '';
    _lastStderr = '';
    final result = await runShellScript(script, _scriptRunner, options);
    if (result.isErr) return Err(result.errorOrNull!);

    return Ok(
      ShellExecResult(
        stdout: _lastStdout ?? '',
        stderr: _lastStderr ?? '',
        exitCode: result.valueOrNull!,
      ),
    );
  }

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
    // Issue #919: bound the job log — size ceiling with head+marker+rolling
    // tail. Web has no disk probe (null), so the low-disk guard stays
    // inactive; the warning channel matches the local shell's prefix.
    final warn = options?.onJobLogWarning;
    final ceiling = JobLogCeiling(
      maxBytes: options?.jobLogMaxBytes ?? defaultJobLogMaxBytes,
      onWarn: warn == null
          ? null
          : (message) => warn('background job $id: $message'),
    );
    final job = SandboxShellJob(
      id: id,
      command: command,
      logPath: logPath,
      logWriter: (chunk) async => _fs.appendFile(logPath, chunk),
      ceiling: ceiling,
      applyLogOp: (op) => _applyJobLogOp(logPath, op),
    );
    // An outer abort stops the job too (same contract as the local shell).
    token?.onCancel.then((_) => job.stop());
    unawaited(
      _forJob()
          .exec(
            command,
            options: ShellExecOptions(
              cwd: options?.cwd,
              env: options?.env,
              timeout: options?.timeout,
              cancelToken: job.cancelToken,
              onStdout: job.writeLog,
              onStderr: job.writeLog,
            ),
          )
          .then(job.completeWith),
    );
    return Ok(job);
  }

  /// Executes one ceiling op against the memory FS (issue #919): an append,
  /// or a read-modify-write of the marker+tail region (the memory FS has no
  /// positioned writes). FS errors throw so the job's catchError marks the
  /// log broken — mirroring the RAF hosts.
  Future<void> _applyJobLogOp(String logPath, JobLogWrite op) async {
    if (op.offset == null) {
      final appended = await _fs.appendFile(logPath, op.text);
      if (appended.isErr) {
        throw StateError('job log append failed: ${appended.errorOrNull}');
      }
      return;
    }
    final read = await _fs.readTextFile(logPath);
    if (read.isErr) {
      throw StateError('job log read failed: ${read.errorOrNull}');
    }
    final head = utf8.encode(read.valueOrNull!).sublist(0, op.offset!);
    final region = utf8.encode(op.text);
    final written = await _fs.writeFile(
      logPath,
      utf8.decode([...head, ...region]),
    );
    if (written.isErr) {
      throw StateError('job log write failed: ${written.errorOrNull}');
    }
  }

  /// A job-local clone: shares the filesystem and HTTP client, owns the
  /// mutable interpreter state (cwd, shell vars, output capture stack), so a
  /// detached job never clobbers the foreground shell or a sibling job.
  MemoryShell _forJob() {
    final clone = MemoryShell(httpClient: _httpClient)..attach(_fs);
    clone._currentDir = _currentDir;
    clone._shellEnv.addAll(_shellEnv);
    return clone;
  }

  /// Script interpreter callbacks (control flow + command substitution are
  /// implemented once in `shell_script.dart` and shared with WasiSandboxShell).
  late final ShellScriptRunner _scriptRunner = ShellScriptRunner(
    runPipeline: (pipeline, options, depth) async {
      final result = await _runPipeline(pipeline, options, depth);
      if (result.isErr) return Err(result.errorOrNull!);
      return Ok(result.valueOrNull!.exitCode);
    },
    environment: _effectiveEnv,
    setVariable: (name, value) => _shellEnv[name] = value,
    capture: _capture,
    saveOutputs: () =>
        ShellOutputSnapshot(stdout: _lastStdout, stderr: _lastStderr),
    restoreOutputs: (snapshot) {
      _lastStdout = snapshot.stdout;
      _lastStderr = snapshot.stderr;
    },
  );

  final ShellOutputCapture _capture = ShellOutputCapture();

  Future<Result<_StageResult, ExecutionError>> _runPipeline(
    Pipeline pipeline,
    ShellExecOptions? options, [
    int depth = 0,
  ]) async {
    List<int>? pipeInput;
    var stageResult = const _StageResult(stdout: [], stderr: [], exitCode: 0);

    for (var i = 0; i < pipeline.stages.length; i++) {
      final isLastStage = i == pipeline.stages.length - 1;
      // Expand `$VAR`/`$(...)` references at execution time so earlier
      // statements in the same command line (e.g. `export A=1 && echo $A`)
      // are visible, then pathname-expand unquoted glob words against the
      // in-memory fs (gh-1393 WS-1 — same walker, same semantics as the
      // WASI shell).
      final expansion = await expandShellStage(
        pipeline.stages[i],
        _effectiveEnv(options),
        (source) => _scriptRunner.substitute(source, options, depth),
        expandGlobs: (word) =>
            expandGlobPattern(word, _effectiveCwd(options), _globListDir),
      );
      if (expansion.isErr) return Err(expansion.errorOrNull!);
      final stage = expansion.valueOrNull!;
      final cwd = _effectiveCwd(options);

      final redirects = parseStageRedirects(stage.redirects);

      final (stdinText, stdinFailure) = await _stageStdin(
        redirects,
        cwd,
        pipeInput,
      );
      if (stdinFailure != null) {
        stageResult = stdinFailure;
        _lastExitCode = stageResult.exitCode;
        _lastStderr = (_lastStderr ?? '') + utf8.decode(stageResult.stderr);
        pipeInput = null;
        continue;
      }

      stageResult = await _runCommand(
        stage.command,
        stage.args,
        options,
        cwd,
        stdinText,
      );
      _lastExitCode = stageResult.exitCode;

      // fd duplication (gh-1393 WS-1, WASI parity): `2>&1` folds stderr
      // into stdout's destination (file, pipe, capture); `>&2` the reverse.
      // collectStageRedirects already routes a file-destination dup onto
      // the same target with append mode (POSIX ordering); only the
      // capture/pipe destinations merge here.
      final (outBytes, errBytes) = _foldFdDups(
        redirects,
        stageResult.stdout,
        stageResult.stderr,
      );
      await _emitStageStdout(outBytes, redirects, isLastStage, options, cwd);
      await _emitStageStderr(errBytes, redirects, isLastStage, options, cwd);

      pipeInput = outBytes;
    }

    return Ok(stageResult);
  }

  /// Resolves the stdin source for one pipeline stage: an inline here-doc /
  /// here-string body, `/dev/null` (an empty stream — the null sink never
  /// materializes the file, gh-1393 WS-1), a file's content, or the
  /// previous stage's pipe output; no source means a null stdin. Returns
  /// `(text, null)` on success or `(null, failure)` when the stdin file
  /// cannot be read — the caller records the failure and skips the stage.
  Future<(String?, _StageResult?)> _stageStdin(
    StageRedirects redirects,
    String cwd,
    List<int>? pipeInput,
  ) async {
    final stdinBody = redirects.stdinBody;
    final stdinFile = redirects.stdinFile;
    if (stdinBody != null) return (stdinBody, null);
    if (stdinFile != null &&
        isNullDevicePath(resolveSandboxPath(stdinFile, cwd))) {
      return ('', null);
    }
    if (stdinFile != null) {
      return _readStdinFile(stdinFile, cwd);
    }
    if (pipeInput != null) {
      return (utf8.decode(pipeInput, allowMalformed: true), null);
    }
    return (null, null);
  }

  /// Reads a `< file` stdin source; a missing file yields the shell's
  /// `No such file or directory` failure (exit 1).
  Future<(String?, _StageResult?)> _readStdinFile(
    String stdinFile,
    String cwd,
  ) async {
    final read = await _fs.readTextFile(resolveSandboxPath(stdinFile, cwd));
    if (read.isErr) {
      return (
        null,
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('sh: $stdinFile: No such file or directory\n'),
          exitCode: 1,
        ),
      );
    }
    return (read.valueOrNull, null);
  }

  /// Folds `2>&1` / `>&2` for one stage: stderr merges into stdout (or the
  /// reverse) only while that destination is the capture/pipe; a file
  /// destination was already routed onto the same target with append mode
  /// by collectStageRedirects.
  (List<int>, List<int>) _foldFdDups(
    StageRedirects redirects,
    List<int> outBytes,
    List<int> errBytes,
  ) {
    if (redirects.dupStderrIntoStdout && redirects.stdoutFile == null) {
      return ([...outBytes, ...errBytes], const []);
    }
    if (redirects.dupStdoutIntoStderr && redirects.stderrFile == null) {
      return (const [], [...errBytes, ...outBytes]);
    }
    return (outBytes, errBytes);
  }

  /// Routes one stage's stdout to its redirect file or, on the LAST stage
  /// only, folds the text into the shell's accumulator and capture stack
  /// (plus the live listener when no capture is active) — intermediate
  /// stages must not leak into command-substitution captures or the exec
  /// accumulator.
  Future<void> _emitStageStdout(
    List<int> outBytes,
    StageRedirects redirects,
    bool isLastStage,
    ShellExecOptions? options,
    String cwd,
  ) async {
    if (redirects.stdoutFile != null) {
      await _writeRedirect(
        redirects.stdoutFile!,
        outBytes,
        redirects.appendStdout,
        cwd,
      );
      return;
    }
    final text = utf8.decode(outBytes, allowMalformed: true);
    if (isLastStage && text.isNotEmpty) {
      _lastStdout = (_lastStdout ?? '') + text;
      _capture.feed(text);
      if (!_capture.isActive) options?.onStdout?.call(text);
    }
  }

  /// Routes one stage's stderr the way [_emitStageStdout] routes stdout.
  Future<void> _emitStageStderr(
    List<int> errBytes,
    StageRedirects redirects,
    bool isLastStage,
    ShellExecOptions? options,
    String cwd,
  ) async {
    if (redirects.stderrFile != null) {
      await _writeRedirect(
        redirects.stderrFile!,
        errBytes,
        redirects.appendStderr,
        cwd,
      );
      return;
    }
    final text = utf8.decode(errBytes, allowMalformed: true);
    if (isLastStage && text.isNotEmpty) {
      _lastStderr = (_lastStderr ?? '') + text;
      if (!_capture.isActive) options?.onStderr?.call(text);
    }
  }

  /// Effective cwd for an exec (gh-1393 WS-1): the shell-tracked
  /// [_currentDir], unless the caller explicitly asked for a directory
  /// other than the sandbox root `/`. The harness anchors every exec at
  /// the env cwd (`/` here) — treating that anchor as a per-exec cwd reset
  /// made `cd` a no-op across execs; an explicit non-root cwd still wins.
  String _effectiveCwd(ShellExecOptions? options) {
    final requested = options?.cwd;
    if (requested == null || requested == '/') return _currentDir;
    return requested;
  }

  /// Directory lister for glob expansion (gh-1393 WS-1): sandbox path in,
  /// entries out; `null` when the path is not a directory.
  Future<List<GlobEntry>?> _globListDir(String path) async {
    final info = await _fs.fileInfo(path);
    if (info.isErr || info.valueOrNull!.kind != FileKind.directory) {
      return null;
    }
    final listing = await _fs.listDir(path);
    if (listing.isErr) return null;
    return [
      for (final entry in listing.valueOrNull!)
        GlobEntry(entry.name, isDir: entry.kind == FileKind.directory),
    ];
  }

  Future<void> _writeRedirect(
    String target,
    List<int> bytes,
    bool append,
    String cwd,
  ) async {
    if (isNullDevicePath(resolveSandboxPath(target, cwd))) {
      // The null sink discards and materializes nothing (gh-1393 WS-1).
      return;
    }
    final path = resolveSandboxPath(target, cwd);
    if (append) {
      await _fs.appendFile(path, utf8.decode(bytes, allowMalformed: true));
    } else {
      await _fs.writeBinaryFile(path, Uint8List.fromList(bytes));
    }
  }

  /// Route table: command name → handler (issue #1713, the #558
  /// route-table pattern). One entry per advertised command — aliases
  /// (`[`/`test`, `python`/`python3`, `xz`/`unxz`, …) get their own
  /// entries — and the checksum family is appended by
  /// [_buildCommandRoutes]. Handlers normalize to `(shell, ctx)` so the
  /// dispatch itself stays branch-free.
  static final Map<String, _CommandRoute> _commandRoutes =
      _buildCommandRoutes();

  static Map<String, _CommandRoute> _buildCommandRoutes() {
    final routes = <String, _CommandRoute>{
      'true': (_, _) async => MemoryShell._ok,
      'false': (_, _) async =>
          const _StageResult(stdout: [], stderr: [], exitCode: 1),
      'echo': (shell, ctx) async => shell._echo(ctx.args),
      'cat': (shell, ctx) async => shell._cat(ctx),
      'ls': (shell, ctx) async => shell._ls(ctx),
      'mkdir': (shell, ctx) async => shell._mkdir(ctx),
      'rmdir': (shell, ctx) async => shell._rmdir(ctx),
      'touch': (shell, ctx) async => shell._touch(ctx),
      'cp': (shell, ctx) async => shell._cp(ctx),
      'mv': (shell, ctx) async => shell._mv(ctx),
      'rm': (shell, ctx) async => shell._rm(ctx),
      'pwd': (shell, ctx) async => shell._text('${ctx.cwd}\n'),
      'cd': (shell, ctx) async => shell._cd(ctx),
      'grep': (shell, ctx) async => shell._grep(ctx),
      'head': (shell, ctx) async => shell._headTail(ctx, head: true),
      'tail': (shell, ctx) async => shell._headTail(ctx, head: false),
      'wc': (shell, ctx) async => shell._wc(ctx),
      'sort': (shell, ctx) async => shell._sort(ctx),
      'tr': (shell, ctx) async => shell._tr(ctx),
      'which': (shell, ctx) async => shell._which(ctx.args),
      'command': (shell, ctx) async => shell._command(ctx.args),
      'test': (shell, ctx) async => shell._test('test', ctx),
      '[': (shell, ctx) async => shell._test('[', ctx),
      'env': (shell, ctx) async => shell._env(ctx),
      'export': (shell, ctx) async => shell._export(ctx.args),
      'unset': (shell, ctx) async => shell._unset(ctx.args),
      'git': (shell, ctx) async => shell._git(ctx),
      'curl': (shell, ctx) async => shell._curl(ctx),
      'wget': (shell, ctx) async => shell._wget(ctx),
      'jq': (shell, ctx) async => shell._jq(ctx),
      'yq': (shell, ctx) async => shell._yq(ctx),
      'diff': (shell, ctx) async => shell._diff(ctx),
      'dig': (shell, ctx) async => shell._dig(ctx),
      'patch': (shell, ctx) async => shell._patch(ctx),
      'nslookup': (shell, ctx) async => shell._nslookup(ctx),
      'whois': (shell, ctx) async => shell._whois(ctx),
      'tree': (shell, ctx) async =>
          shell._toStage(shell._builtinsFor(ctx).tree(ctx.args)),
      'file': (shell, ctx) async =>
          shell._toStage(shell._builtinsFor(ctx).file(ctx.args)),
      'xz': (shell, ctx) async => shell._xz(ctx, decompress: false),
      'unxz': (shell, ctx) async => shell._xz(ctx, decompress: true),
      'bzip2': (shell, ctx) async => shell._bzip2(ctx, decompress: false),
      'bunzip2': (shell, ctx) async => shell._bzip2(ctx, decompress: true),
      'base64': (shell, ctx) async => shell._toStage(
        shell._builtinsFor(ctx).base64(ctx.args, stdin: ctx.stdin),
      ),
      'rg': (shell, ctx) async => shell._grep(ctx),
      'sed': (shell, ctx) async => shell._sed(ctx),
      'awk': (shell, ctx) async => shell._awk(ctx),
      'find': (shell, ctx) async => shell._find(ctx),
      'xargs': (shell, ctx) async => shell._xargs(ctx),
      'printf': (shell, ctx) async => shell._printf(ctx),
      'realpath': (shell, ctx) async => shell._realpath(ctx),
      'tar': (shell, ctx) async => shell._tar(ctx),
      'gzip': (shell, ctx) async => shell._gzip(ctx, decompress: false),
      'gunzip': (shell, ctx) async => shell._gzip(ctx, decompress: true),
      'zip': (shell, ctx) async => shell._zip(ctx),
      'unzip': (shell, ctx) async =>
          shell._toStage(shell._builtinsFor(ctx).unzip(ctx.args)),
      'sqlite3': (shell, ctx) async => shell._runSqlite(ctx),
      'python': (shell, ctx) async => shell._runPython(ctx),
      'python3': (shell, ctx) async => shell._runPython(ctx),
      'pip': (shell, ctx) async => shell._runPip(ctx),
      'pip3': (shell, ctx) async => shell._runPip(ctx),
      'qjs': (shell, ctx) async => shell._runQjs(ctx),
      'js': (shell, ctx) async => shell._runQjs(ctx),
      'lua': (shell, _) async => shell._interpreterUnavailable('lua'),
      'whoami': (shell, ctx) async =>
          shell._text('${shell._effectiveEnv(ctx.options)['USER']}\n'),
      'basename': (shell, ctx) async => shell._basename(ctx),
      'dirname': (shell, ctx) async => shell._dirname(ctx),
      'ssh': (shell, ctx) async => shell._sshUnavailable('ssh'),
      'scp': (shell, ctx) async => shell._sshUnavailable('scp'),
      'sftp': (shell, ctx) async => shell._sshUnavailable('sftp'),
      for (final command in _hashCommands)
        command: (shell, ctx) async => shell._hashsum(command, ctx),
    };
    return routes;
  }

  Future<_StageResult> _runCommand(
    String command,
    List<String> args,
    ShellExecOptions? options,
    String cwd,
    String? stdinText,
  ) async {
    if (!_availableCommands.contains(command)) {
      return _StageResult(
        stdout: const [],
        stderr: utf8.encode('$command: command not found\n'),
        exitCode: 127,
      );
    }
    final ctx = _Context(
      args: args,
      options: options,
      stdin: stdinText,
      cwd: cwd,
    );
    final handler = _commandRoutes[command];
    if (handler == null) {
      // Defensive: the route table must cover every advertised command.
      return _StageResult(
        stdout: const [],
        stderr: utf8.encode('$command: command not found\n'),
        exitCode: 127,
      );
    }
    return handler(this, ctx);
  }

  Future<_StageResult> _git(_Context ctx) async {
    final result = await _gitCommands.run(
      ctx.args,
      cwd: ctx.cwd,
      env: _effectiveEnv(ctx.options),
    );
    return _StageResult(
      stdout: utf8.encode(result.stdout),
      stderr: utf8.encode(result.stderr),
      exitCode: result.exitCode,
    );
  }

  // ---------------------------------------------------------------------------
  // Shared network/JSON builtins (curl, wget, jq, yq)
  // ---------------------------------------------------------------------------

  /// Wires the shared [SandboxBuiltins] to the in-memory filesystem, resolving
  /// paths against the stage's working directory.
  SandboxBuiltins _builtinsFor(_Context ctx) {
    return SandboxBuiltins(
      httpClient: _httpClient,
      readTextFile: (path) async {
        final result = await _fs.readTextFile(
          resolveSandboxPath(path, ctx.cwd),
        );
        return result.valueOrNull;
      },
      writeBinaryFile: (path, bytes) async {
        await _fs.writeBinaryFile(
          resolveSandboxPath(path, ctx.cwd),
          Uint8List.fromList(bytes),
        );
      },
      readBinaryFile: (path) async => (await _fs.readBinaryFile(
        resolveSandboxPath(path, ctx.cwd),
      )).valueOrNull,
      listDirectory: (path) async => (await _fs.listDir(
        resolveSandboxPath(path, ctx.cwd),
      )).valueOrNull?.map(_dirEntry).toList(),
      removeFile: (path) async {
        await _fs.remove(resolveSandboxPath(path, ctx.cwd));
      },
      makeDirectory: (path) async {
        await _fs.createDir(resolveSandboxPath(path, ctx.cwd));
      },
    );
  }

  Future<_StageResult> _toStage(Future<SandboxBuiltinResult> future) async {
    final r = await future;
    return _StageResult(
      stdout: r.stdout,
      stderr: r.stderr,
      exitCode: r.exitCode,
    );
  }

  static SandboxDirEntry _dirEntry(FileInfo e) =>
      (name: e.name, isDirectory: e.kind == FileKind.directory);

  Future<_StageResult> _curl(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).curl(
        ctx.args,
        stdinBytes: ctx.stdin == null ? null : utf8.encode(ctx.stdin!),
        timeout: ctx.options?.timeout,
      ),
    );
  }

  Future<_StageResult> _wget(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).wget(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _jq(_Context ctx) {
    return _toStage(_builtinsFor(ctx).jq(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _yq(_Context ctx) {
    return _toStage(_builtinsFor(ctx).yq(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _diff(_Context ctx) {
    return _toStage(_builtinsFor(ctx).diff(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _patch(_Context ctx) {
    return _toStage(_builtinsFor(ctx).patch(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _nslookup(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).nslookup(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _dig(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).dig(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _whois(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).whois(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _xz(_Context ctx, {required bool decompress}) =>
      _toStage(_builtinsFor(ctx).xz(ctx.args, decompress: decompress));

  Future<_StageResult> _bzip2(_Context ctx, {required bool decompress}) =>
      _toStage(_builtinsFor(ctx).bzip2(ctx.args, decompress: decompress));

  Future<_StageResult> _hashsum(String command, _Context ctx) =>
      _toStage(_builtinsFor(ctx).hashsum(command, ctx.args, stdin: ctx.stdin));

  // ---------------------------------------------------------------------------
  // sqlite3 (sql.js in the browser)
  // ---------------------------------------------------------------------------
  Future<_StageResult> _runSqlite(_Context ctx) async => _fromInterpreter(
    await runSqliteCommand(_fs, ctx.cwd, ctx.args, ctx.stdin),
  );

  // ---------------------------------------------------------------------------
  // Text stream utilities (printf)

  /// Wraps a module interpreter result into pipeline bytes.
  _StageResult _fromInterpreter(InterpreterOutcome r) => _StageResult(
    stdout: utf8.encode(r.stdout),
    stderr: utf8.encode(r.stderr),
    exitCode: r.exitCode,
  );

  // ---------------------------------------------------------------------------

  _StageResult _printf(_Context ctx) {
    if (ctx.args.isEmpty) {
      return _error('usage: printf format [arguments...]\n');
    }
    final format = _unescapePrintf(ctx.args.first);
    final args = ctx.args.sublist(1);
    final out = StringBuffer();
    var argIndex = 0;
    // The format string is reused until every argument is consumed (POSIX).
    while (true) {
      final consumedBefore = argIndex;
      argIndex = _formatPrintfPass(format, args, out, argIndex);
      if (argIndex >= args.length || argIndex == consumedBefore) break;
    }
    return _text(out.toString());
  }

  /// One reuse pass of the printf format string over [args], appending to
  /// [out] and returning the advanced argument index.
  int _formatPrintfPass(
    String format,
    List<String> args,
    StringBuffer out,
    int argIndex,
  ) {
    for (var i = 0; i < format.length; i++) {
      final ch = format[i];
      if (ch == '%' && i + 1 < format.length) {
        final spec = format[i + 1];
        if (spec == '%') {
          out.write('%');
          i++;
          continue;
        }
        argIndex = _writePrintfSpec(out, spec, args, argIndex);
        i++;
        continue;
      }
      out.write(ch);
    }
    return argIndex;
  }

  /// Writes one `%` directive ([spec]) with the next argument (empty once
  /// exhausted) to [out]; unknown directives pass through literally and
  /// consume no argument. Returns the advanced argument index.
  int _writePrintfSpec(
    StringBuffer out,
    String spec,
    List<String> args,
    int argIndex,
  ) {
    final arg = argIndex < args.length ? args[argIndex] : '';
    switch (spec) {
      case 's':
        argIndex++;
        out.write(arg);
      case 'd' || 'i':
        argIndex++;
        out.write(int.tryParse(arg) ?? 0);
      case 'c':
        argIndex++;
        if (arg.isNotEmpty) out.write(arg[0]);
      default:
        out.write('%');
        out.write(spec);
    }
    return argIndex;
  }

  /// The printf format escape carried by a `\` + letter (`\n`, `\t`,
  /// `\r`), or null when the letter is not one.
  static String? _printfLetterEscape(String ch) => switch (ch) {
    'n' => '\n',
    't' => '\t',
    'r' => '\r',
    _ => null,
  };

  /// The printf format escape carried by `\` + [ch], or null when printf
  /// writes the pair literally.
  static String? _printfEscape(String ch) {
    final letter = _printfLetterEscape(ch);
    if (letter != null) return letter;
    if (ch == '0') return '\x00';
    if (ch == '\\') return '\\';
    return null;
  }

  /// Whether [i] opens a backslash escape pair in [input].
  static bool _atEscapePair(String input, int i) =>
      input[i] == '\\' && i + 1 < input.length;

  /// Interprets the backslash escapes printf understands in its format
  /// string (`\n`, `\t`, `\r`, `\\`, `\0`).
  String _unescapePrintf(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      if (_atEscapePair(input, i)) {
        final escape = _printfEscape(input[i + 1]);
        if (escape != null) {
          buffer.write(escape);
          i++;
          continue;
        }
      }
      buffer.write(input[i]);
    }
    return buffer.toString();
  }

  Future<_StageResult> _sed(_Context ctx) async {
    final parsed = parseSedArgs(ctx.args);
    final parseError = parsed.error;
    if (parseError != null) {
      return _error(parseError.message, exitCode: parseError.exitCode);
    }
    final commands = <SedCommand>[];
    for (final script in parsed.scripts) {
      final command = SedCommand.tryParse(script);
      if (command == null) {
        return _error('sed: unsupported script: $script\n', exitCode: 1);
      }
      commands.add(command);
    }

    if (parsed.inPlace) {
      for (final arg in parsed.files) {
        final resolved = resolveSandboxPath(arg, ctx.cwd);
        final read = await _fs.readTextFile(resolved);
        if (read.isErr) {
          return _error('sed: $arg: No such file or directory\n');
        }
        await _fs.writeFile(
          resolved,
          runSed(read.valueOrNull!, commands, quiet: false),
        );
      }
      return _ok;
    }

    String? errorPath;
    final input = await readCommandInput(
      _fs,
      ctx.cwd,
      parsed.files,
      ctx.stdin,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error('sed: $errorPath: No such file or directory\n');
    }
    return _text(runSed(input, commands, quiet: parsed.quiet));
  }

  Future<_StageResult> _awk(_Context ctx) async {
    final parsed = parseAwkArgs(ctx.args);
    final argError = parsed.error;
    if (argError != null) {
      return _error(argError.message, exitCode: argError.exitCode);
    }
    final program = parseAwkProgram(parsed.positionals.first);
    final programError = program.error;
    if (programError != null) {
      return _error(programError.message, exitCode: programError.exitCode);
    }
    String? errorPath;
    final input = await readCommandInput(
      _fs,
      ctx.cwd,
      parsed.positionals.sublist(1),
      ctx.stdin,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error('awk: cannot open $errorPath: No such file or directory\n');
    }
    return _text(
      runAwk(input, program.pattern, program.printExpr, parsed.fieldSeparator),
    );
  }

  // ---------------------------------------------------------------------------
  // Filesystem utilities (find, realpath)
  // ---------------------------------------------------------------------------

  Future<_StageResult> _find(_Context ctx) async {
    final paths = <String>[];
    String? namePattern;
    String? type;
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-name' && i + 1 < ctx.args.length) {
        namePattern = ctx.args[++i];
      } else if (arg == '-type' && i + 1 < ctx.args.length) {
        type = ctx.args[++i];
      } else if (arg.startsWith('-')) {
        return _error('find: unsupported option $arg\n', exitCode: 1);
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('.');

    final nameRegex = namePattern == null ? null : _globToRegex(namePattern);
    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;

    Future<void> walk(String resolved, String display, FileInfo info) async {
      final typeOk =
          type == null ||
          (type == 'f' && info.kind == FileKind.file) ||
          (type == 'd' && info.kind == FileKind.directory);
      final nameOk = nameRegex == null || nameRegex.hasMatch(info.name);
      if (typeOk && nameOk) out.writeln(display);
      if (info.kind != FileKind.directory) return;
      final entries = await _fs.listDir(resolved);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
        final childResolved = resolved == '/'
            ? '/${entry.name}'
            : '$resolved/${entry.name}';
        final childDisplay = display == '/'
            ? '/${entry.name}'
            : '$display/${entry.name}';
        await walk(childResolved, childDisplay, entry);
      }
    }

    for (final arg in paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        err.write('find: $arg: No such file or directory\n');
        exitCode = 1;
        continue;
      }
      await walk(resolved, arg, info.valueOrNull!);
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

  /// Converts a `find -name` glob (`*`, `?`) into an anchored [RegExp].
  RegExp _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '*') {
        buffer.write('.*');
      } else if (ch == '?') {
        buffer.write('.');
      } else {
        buffer.write(RegExp.escape(ch));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  Future<_StageResult> _realpath(_Context ctx) async {
    final split = splitArgs(ctx.args);
    if (split.paths.isEmpty) {
      return _error('realpath: missing operand\n');
    }
    final out = StringBuffer();
    for (final arg in split.paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final exists = await _fs.exists(resolved);
      if (!(exists.valueOrNull ?? false)) {
        return _error('realpath: $arg: No such file or directory\n');
      }
      out.writeln(resolved);
    }
    return _text(out.toString());
  }

  // ---------------------------------------------------------------------------
  // xargs
  // ---------------------------------------------------------------------------

  Future<_StageResult> _xargs(_Context ctx) async {
    var batchSize = 0;
    var utilityArgs = const <String>[];
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-n' && i + 1 < ctx.args.length) {
        batchSize = int.tryParse(ctx.args[++i]) ?? 0;
      } else if (arg.startsWith('-n') &&
          int.tryParse(arg.substring(2)) != null) {
        batchSize = int.parse(arg.substring(2));
      } else {
        utilityArgs = ctx.args.sublist(i);
        break;
      }
    }

    final tokens = (ctx.stdin ?? '')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final command = utilityArgs.isEmpty ? 'echo' : utilityArgs.first;
    final prefixArgs = utilityArgs.isEmpty
        ? const <String>[]
        : utilityArgs.sublist(1);

    final batches = <List<String>>[
      if (tokens.isEmpty)
        const <String>[]
      else if (batchSize > 0)
        for (var i = 0; i < tokens.length; i += batchSize)
          tokens.sublist(
            i,
            i + batchSize > tokens.length ? tokens.length : i + batchSize,
          )
      else
        tokens,
    ];

    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;
    for (final batch in batches) {
      final result = await _runCommand(
        command,
        [...prefixArgs, ...batch],
        ctx.options,
        ctx.cwd,
        null,
      );
      out.write(utf8.decode(result.stdout, allowMalformed: true));
      err.write(utf8.decode(result.stderr, allowMalformed: true));
      if (result.exitCode != 0) exitCode = result.exitCode;
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

  // ---------------------------------------------------------------------------
  // Archives (tar, gzip, zip) via the memory_shell/tar.dart module
  // ---------------------------------------------------------------------------

  Future<_StageResult> _tar(_Context ctx) async {
    final parsed = parseTarArgs(ctx.args);
    final parseError = parsed.error;
    if (parseError != null) {
      return _error(parseError.message, exitCode: parseError.exitCode);
    }
    final opError = await (parsed.create
        ? createTarArchive(_fs, ctx.cwd, parsed)
        : extractTarArchive(_fs, ctx.cwd, parsed));
    if (opError != null) {
      return _error(opError.message, exitCode: opError.exitCode);
    }
    return _ok;
  }

  Future<_StageResult> _gzip(_Context ctx, {required bool decompress}) async {
    final parsed = parseGzipArgs(ctx.args, decompress: decompress);
    final parseError = parsed.error;
    if (parseError != null) {
      return _error(parseError.message, exitCode: parseError.exitCode);
    }
    final opError = await runGzip(_fs, ctx.cwd, parsed);
    if (opError != null) {
      return _error(opError.message, exitCode: opError.exitCode);
    }
    return _ok;
  }

  Future<_StageResult> _zip(_Context ctx) async {
    final parsed = parseZipArgs(ctx.args);
    final parseError = parsed.error;
    if (parseError != null) {
      return _error(parseError.message, exitCode: parseError.exitCode);
    }
    final opError = await runZip(_fs, ctx.cwd, parsed);
    if (opError != null) {
      return _error(opError.message, exitCode: opError.exitCode);
    }
    return _ok;
  }

  Future<_StageResult> _runPython(_Context ctx) async =>
      _fromInterpreter(await runPythonCommand(_fs, ctx.cwd, ctx.args));

  /// pip-lite for the web sandbox: installs pure-Python wheels through
  /// pyodide's micropip (loaded from the CDN on first real use; usage errors
  /// short-circuit before any network). See `sandbox_pip.dart`.
  Future<_StageResult> _runPip(_Context ctx) async {
    final r = await WebInterpreters.runPip(ctx.args);
    if (!r.available) return _interpreterUnavailable('pip');
    return _StageResult(
      stdout: utf8.encode(r.stdout),
      stderr: utf8.encode(r.stderr),
      exitCode: r.exitCode,
    );
  }

  Future<_StageResult> _runQjs(_Context ctx) async =>
      _fromInterpreter(await runQjsCommand(_fs, ctx.cwd, ctx.args));

  _StageResult _interpreterUnavailable(String name) {
    return _StageResult(
      stdout: const [],
      stderr: utf8.encode('$name: command not found\n'),
      exitCode: 127,
    );
  }

  /// ssh/scp/sftp exist in the web command set (so `which` reports them and
  /// the agent can react) but raw TCP is impossible in a browser, so every
  /// invocation fails with exit code 127.
  _StageResult _sshUnavailable(String name) {
    return _StageResult(
      stdout: const [],
      stderr: utf8.encode(
        '$name: not available in the web sandbox '
        '(browsers cannot open raw TCP connections)\n',
      ),
      exitCode: 127,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static const _StageResult _ok = _StageResult(
    stdout: [],
    stderr: [],
    exitCode: 0,
  );

  _StageResult _text(String out, {int exitCode = 0}) => _StageResult(
    stdout: utf8.encode(out),
    stderr: const [],
    exitCode: exitCode,
  );

  _StageResult _error(String message, {int exitCode = 1}) => _StageResult(
    stdout: const [],
    stderr: utf8.encode(message),
    exitCode: exitCode,
  );

  /// Effective environment visible to commands and variable expansion:
  /// sandbox defaults, persistent `export`ed variables, and any per-call
  /// overrides (later wins).
  Map<String, String> _effectiveEnv(ShellExecOptions? options) {
    final cwd = options?.cwd ?? _currentDir;
    return <String, String>{
      'HOME': '/',
      'PATH': '/bin',
      'PWD': cwd,
      'SHELL': '/bin/sh',
      'TERM': 'dumb',
      'USER': 'Fa',
      ..._shellEnv,
      ...?options?.env,
      // POSIX `$?` (issue #1335); the `env` builtin filters it from output.
      '?': '$_lastExitCode',
    };
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  _StageResult _echo(List<String> args) {
    var newline = true;
    var interpretEscapes = false;
    var i = 0;
    while (i < args.length) {
      if (args[i] == '-n') {
        newline = false;
      } else if (args[i] == '-e') {
        interpretEscapes = true;
      } else if (args[i] == '-E') {
        interpretEscapes = false;
      } else {
        break;
      }
      i++;
    }
    var out = args.sublist(i).join(' ');
    if (interpretEscapes) out = _interpretEchoEscapes(out);
    return _text(newline ? '$out\n' : out);
  }

  /// POSIX `echo -e` escape char → literal (the subset the sandbox
  /// honors; issue #1713 data table).
  static const _echoEscapes = {
    'n': '\n',
    't': '\t',
    'r': '\r',
    '\\': '\\',
    '0': '\x00',
  };

  String _interpretEchoEscapes(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final escape = _echoEscapeAt(input, i);
      if (escape == null) {
        buffer.write(input[i]);
        continue;
      }
      buffer.write(escape);
      i++;
    }
    return buffer.toString();
  }

  /// The escape sequence starting at [input] index [i], or `null`.
  String? _echoEscapeAt(String input, int i) {
    if (input[i] != '\\' || i + 1 >= input.length) return null;
    return _echoEscapes[input[i + 1]];
  }

  Future<_StageResult> _cat(_Context ctx) async {
    final split = splitArgs(ctx.args);
    final number = split.flags.contains('-n');
    String? errorPath;
    final input = await readCommandInput(
      _fs,
      ctx.cwd,
      split.paths,
      ctx.stdin,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error('cat: $errorPath: No such file or directory\n');
    }
    if (!number) return _text(input);
    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final numbered = [
      for (var i = 0; i < lines.length; i++) '     ${i + 1}\t${lines[i]}',
    ].join('\n');
    return _text(numbered.isEmpty ? '' : '$numbered\n');
  }

  Future<_StageResult> _ls(_Context ctx) async {
    final (showAll, longMode, paths) = _parseLsArgs(ctx.args);
    if (paths.isEmpty) paths.add('.');

    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;
    var first = true;
    for (final arg in paths) {
      final (headerPrinted, failed) = await _listLsPath(
        out: out,
        err: err,
        arg: arg,
        cwd: ctx.cwd,
        showHeader: paths.length > 1,
        showAll: showAll,
        longMode: longMode,
        isFirst: first,
      );
      if (headerPrinted) first = false;
      if (failed) exitCode = 1;
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

  /// Splits `ls` arguments: a dash-prefixed word (`-la`) sets the short
  /// flags (`a` → hidden entries, `l` → long form); a bare `-` is a path,
  /// not a flag. Everything else is a path operand.
  (bool, bool, List<String>) _parseLsArgs(List<String> args) {
    var showAll = false;
    var longMode = false;
    final paths = <String>[];
    for (final arg in args) {
      if (arg.startsWith('-') && arg != '-') {
        if (arg.contains('a')) showAll = true;
        if (arg.contains('l')) longMode = true;
      } else {
        paths.add(arg);
      }
    }
    return (showAll, longMode, paths);
  }

  /// Emits one `ls` path into [out]/[err]: missing paths and unreadable
  /// directories report the shell error (`failed`); files print one line;
  /// directories print a `name:` header (blank-line separated unless this
  /// is the first listing) then their entries, dotfiles hidden unless
  /// [showAll]. Returns `(headerPrinted, failed)`.
  Future<(bool, bool)> _listLsPath({
    required StringBuffer out,
    required StringBuffer err,
    required String arg,
    required String cwd,
    required bool showHeader,
    required bool showAll,
    required bool longMode,
    required bool isFirst,
  }) async {
    final resolved = resolveSandboxPath(arg, cwd);
    final info = await _fs.fileInfo(resolved);
    if (info.isErr) {
      err.write('ls: cannot access $arg: No such file or directory\n');
      return (false, true);
    }
    final fileInfo = info.valueOrNull!;
    if (fileInfo.kind == FileKind.file) {
      out.writeln(_lsLine(fileInfo, longMode));
      return (false, false);
    }
    var headerPrinted = false;
    if (showHeader) {
      if (!isFirst) out.writeln();
      out.writeln('$arg:');
      headerPrinted = true;
    }
    final entries = await _fs.listDir(resolved);
    if (entries.isErr) {
      err.write('ls: cannot open directory $arg\n');
      return (headerPrinted, true);
    }
    _writeLsEntries(
      out,
      entries.valueOrNull!,
      showAll: showAll,
      longMode: longMode,
    );
    return (headerPrinted, false);
  }

  /// Writes the entries of one listed directory, dotfiles hidden unless
  /// [showAll].
  void _writeLsEntries(
    StringBuffer out,
    List<FileInfo> entries, {
    required bool showAll,
    required bool longMode,
  }) {
    for (final entry in entries) {
      if (!showAll && entry.name.startsWith('.')) continue;
      out.writeln(_lsLine(entry, longMode));
    }
  }

  /// One `ls` line: `ls -l` long form or the bare name.
  String _lsLine(FileInfo info, bool longMode) =>
      longMode ? _longLine(info) : info.name;

  String _longLine(FileInfo info) {
    final perms = info.kind == FileKind.directory ? 'drwxr-xr-x' : '-rw-r--r--';
    final size = info.size.toString().padLeft(8);
    return '$perms 1 fah fah $size Jan  1 00:00 ${info.name}';
  }

  Future<_StageResult> _mkdir(_Context ctx) async {
    final split = splitArgs(ctx.args);
    final parents = split.flags.any((f) => f.contains('p'));
    if (split.paths.isEmpty) {
      return _error('mkdir: missing operand\n');
    }
    for (final arg in split.paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final exists = await _fs.exists(resolved);
      if (exists.valueOrNull ?? false) {
        if (parents) continue;
        return _error('mkdir: cannot create directory $arg: File exists\n');
      }
      final result = await _fs.createDir(resolved, recursive: parents);
      if (result.isErr) {
        return _error(
          'mkdir: cannot create directory $arg: No such file or directory\n',
        );
      }
    }
    return _ok;
  }

  Future<_StageResult> _rmdir(_Context ctx) async {
    final split = splitArgs(ctx.args);
    if (split.paths.isEmpty) {
      return _error('rmdir: missing operand\n');
    }
    for (final arg in split.paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr || info.valueOrNull!.kind != FileKind.directory) {
        return _error('rmdir: failed to remove $arg: Not a directory\n');
      }
      final result = await _fs.remove(resolved);
      if (result.isErr) {
        return _error('rmdir: failed to remove $arg: Directory not empty\n');
      }
    }
    return _ok;
  }

  Future<_StageResult> _touch(_Context ctx) async {
    final split = splitArgs(ctx.args);
    if (split.paths.isEmpty) {
      return _error('touch: missing file operand\n');
    }
    for (final arg in split.paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final exists = await _fs.exists(resolved);
      if (!(exists.valueOrNull ?? false)) {
        await _fs.writeFile(resolved, '');
      }
    }
    return _ok;
  }

  Future<_StageResult> _cp(_Context ctx) async {
    final split = splitArgs(ctx.args);
    final recursive = split.flags.any(
      (f) => f.contains('r') || f.contains('R'),
    );
    if (split.paths.length < 2) {
      return _error('cp: missing file operand\n');
    }
    final destArg = split.paths.last;
    final sources = split.paths.sublist(0, split.paths.length - 1);
    final destResolved = resolveSandboxPath(destArg, ctx.cwd);
    final destIsDir = await _targetIsDir(destResolved);
    final targetError = _cpTargetError(sources, destIsDir, destArg);
    if (targetError != null) return targetError;
    final copyError = await _cpSources(
      ctx,
      sources,
      destResolved,
      destIsDir,
      recursive,
    );
    if (copyError != null) return copyError;
    return _ok;
  }

  /// Whether the cp/mv destination exists as a directory.
  Future<bool> _targetIsDir(String destResolved) async {
    final destInfo = await _fs.fileInfo(destResolved);
    return destInfo.isOk && destInfo.valueOrNull!.kind == FileKind.directory;
  }

  /// The cp usage error for a multi-source copy onto a non-directory, if
  /// any.
  _StageResult? _cpTargetError(
    List<String> sources,
    bool destIsDir,
    String destArg,
  ) {
    if (sources.length > 1 && !destIsDir) {
      return _error('cp: target $destArg: Not a directory\n');
    }
    return null;
  }

  /// Copies every source operand onto [destResolved]; the first failure
  /// (as an error result) wins.
  Future<_StageResult?> _cpSources(
    _Context ctx,
    List<String> sources,
    String destResolved,
    bool destIsDir,
    bool recursive,
  ) async {
    for (final srcArg in sources) {
      final copyError = await _cpSource(
        ctx,
        srcArg,
        destResolved,
        destIsDir,
        recursive,
      );
      if (copyError != null) return _error(copyError);
    }
    return null;
  }

  /// Copies one cp source onto its target. Returns the error line, if any.
  Future<String?> _cpSource(
    _Context ctx,
    String srcArg,
    String destResolved,
    bool destIsDir,
    bool recursive,
  ) async {
    final srcResolved = resolveSandboxPath(srcArg, ctx.cwd);
    final srcInfo = await _fs.fileInfo(srcResolved);
    if (srcInfo.isErr) {
      return 'cp: cannot stat $srcArg: No such file or directory\n';
    }
    final target = _copyTarget(destResolved, srcInfo.valueOrNull!, destIsDir);
    return _copyRecursive(
      srcResolved,
      target,
      srcInfo.valueOrNull!,
      recursive,
      srcArg,
    );
  }

  /// The copy destination for one source: the source's name joined under
  /// a directory target, else the target itself.
  String _copyTarget(String destResolved, FileInfo srcInfo, bool destIsDir) =>
      destIsDir
      ? normalizeSandboxPath('$destResolved/${srcInfo.name}')
      : destResolved;

  /// Copies [src] onto [dest]: directories recurse ([-r] required), files
  /// copy byte-wise. Returns the error line, if any.
  Future<String?> _copyRecursive(
    String src,
    String dest,
    FileInfo srcInfo,
    bool recursive,
    String srcArg,
  ) async {
    if (srcInfo.kind == FileKind.directory) {
      return _copyDir(src, dest, recursive, srcArg);
    }
    return _copyFile(src, dest, srcArg);
  }

  /// Copies the directory [src] into [dest] (-r required).
  Future<String?> _copyDir(
    String src,
    String dest,
    bool recursive,
    String srcArg,
  ) async {
    if (!recursive) {
      return 'cp: -r not specified; omitting directory $srcArg\n';
    }
    await _fs.createDir(dest);
    final entries = await _fs.listDir(src);
    return _copyDirEntries(
      src,
      dest,
      entries.valueOrNull ?? <FileInfo>[],
      recursive,
      srcArg,
    );
  }

  /// Copies every entry of [src] into [dest]; the first failure wins.
  Future<String?> _copyDirEntries(
    String src,
    String dest,
    List<FileInfo> entries,
    bool recursive,
    String srcArg,
  ) async {
    for (final entry in entries) {
      final error = await _copyRecursive(
        '$src/${entry.name}',
        '$dest/${entry.name}',
        entry,
        recursive,
        srcArg,
      );
      if (error != null) return error;
    }
    return null;
  }

  /// Copies the file [src] onto [dest].
  Future<String?> _copyFile(String src, String dest, String srcArg) async {
    final data = await _fs.readBinaryFile(src);
    if (data.isErr) {
      return 'cp: cannot stat $srcArg: No such file or directory\n';
    }
    await _fs.writeBinaryFile(dest, data.valueOrNull!);
    return null;
  }

  Future<_StageResult> _mv(_Context ctx) async {
    final split = splitArgs(ctx.args);
    if (split.paths.length < 2) {
      return _error('mv: missing file operand\n');
    }
    final destArg = split.paths.last;
    final sources = split.paths.sublist(0, split.paths.length - 1);
    final destResolved = resolveSandboxPath(destArg, ctx.cwd);
    final destInfo = await _fs.fileInfo(destResolved);
    final destIsDir =
        destInfo.isOk && destInfo.valueOrNull!.kind == FileKind.directory;
    if (sources.length > 1 && !destIsDir) {
      return _error('mv: target $destArg: Not a directory\n');
    }
    for (final srcArg in sources) {
      final srcResolved = resolveSandboxPath(srcArg, ctx.cwd);
      final srcInfo = await _fs.fileInfo(srcResolved);
      if (srcInfo.isErr) {
        return _error('mv: cannot stat $srcArg: No such file or directory\n');
      }
      final target = destIsDir
          ? normalizeSandboxPath('$destResolved/${srcInfo.valueOrNull!.name}')
          : destResolved;
      final moveError = await _moveRecursive(srcResolved, target);
      if (moveError != null) return _error(moveError);
    }
    return _ok;
  }

  Future<String?> _moveRecursive(String src, String dest) async {
    final info = await _fs.fileInfo(src);
    if (info.isErr) return 'mv: cannot stat $src\n';
    if (info.valueOrNull!.kind == FileKind.directory) {
      await _fs.createDir(dest);
      final entries = await _fs.listDir(src);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
        final error = await _moveRecursive(
          '$src/${entry.name}',
          '$dest/${entry.name}',
        );
        if (error != null) return error;
      }
    } else {
      final data = await _fs.readBinaryFile(src);
      if (data.isErr) return 'mv: cannot read $src\n';
      await _fs.writeBinaryFile(dest, data.valueOrNull!);
    }
    await _fs.remove(src, recursive: true, force: true);
    return null;
  }

  Future<_StageResult> _rm(_Context ctx) async {
    final split = splitArgs(ctx.args);
    final recursive = split.flags.any(
      (f) => f.contains('r') || f.contains('R'),
    );
    final force = split.flags.any((f) => f.contains('f'));
    if (split.paths.isEmpty) {
      if (force) return _ok;
      return _error('rm: missing operand\n');
    }
    for (final arg in split.paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        if (force) continue;
        return _error('rm: cannot remove $arg: No such file or directory\n');
      }
      if (info.valueOrNull!.kind == FileKind.directory && !recursive) {
        return _error('rm: cannot remove $arg: Is a directory\n');
      }
      await _fs.remove(resolved, recursive: recursive, force: force);
    }
    return _ok;
  }

  Future<_StageResult> _cd(_Context ctx) async {
    final target = ctx.args.isEmpty ? '/' : ctx.args.first;
    final resolved = resolveSandboxPath(target, ctx.cwd);
    final info = await _fs.fileInfo(resolved);
    if (info.isErr || info.valueOrNull!.kind != FileKind.directory) {
      return _error('cd: $target: No such file or directory\n');
    }
    _currentDir = resolved;
    return _ok;
  }

  Future<_StageResult> _grep(_Context ctx) async {
    final parsed = parseGrepArgs(ctx.args);
    if (parsed == null) {
      return _error('grep: option requires an argument -- e\n', exitCode: 2);
    }
    if (!parsed.isUsable) {
      return _error(parsed.error!, exitCode: 2);
    }
    if (parsed.pattern == null) {
      return _error(
        'usage: grep [-ivwxFcclnq] [-m N] [-A N] [-B N] [-C N] '
        '[--include=GLOB] [--exclude=GLOB] pattern [file...]\n',
        exitCode: 2,
      );
    }
    // The shared parser hands the letters (`-i`, `-v`, … from separate or
    // clustered shorts); the Dart engine compiles the rest. The flag
    // classification lives in `_planGrepEngine` (gh-1393 rework: `-m`/
    // `-o`/`-h` are honored, every flag the engine cannot honor
    // faithfully is a loud POSIX exit-2 — never a silent drop).
    final plan = _planGrepEngine(parsed);
    if (plan.error != null) {
      return _error(plan.error!, exitCode: 2);
    }
    final compiled = compileGrepQuery(
      plan.flags,
      parsed.pattern!,
      maxCount: plan.maxCount,
    );
    final compileError = compiled.error;
    if (compileError != null) {
      return _error(compileError.message, exitCode: compileError.exitCode);
    }
    final q = compiled.query!;
    final acc = GrepAccumulator();
    final err = StringBuffer();
    final (inputs, operandError) = await _grepResolveInputs(ctx, parsed, err);
    final runError = await _grepRunOnInputs(
      ctx,
      parsed,
      plan.flags,
      q,
      acc,
      err,
      inputs,
    );
    return _StageResult(
      stdout: q.quiet ? const [] : utf8.encode(acc.buffer.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: operandError || runError ? 2 : (acc.anyMatch ? 0 : 1),
    );
  }

  /// Adds one short grep letter to [flags] under the engine's mapping
  /// (`-a` is a no-op: operands are read as text anyway).
  static void _addGrepLetter(Set<String> flags, String letter) {
    switch (letter) {
      case 'o':
        flags.add('o');
      case 'a':
        break; // text-only engine: operands are read as text anyway
      default:
        flags.add(letter);
    }
  }

  /// Consumes the `-m` cap token at [i] into [state]; returns the index
  /// of the last token the flag used.
  int _grepMaxCountToken(GrepArgs parsed, _GrepEnginePlanState state, int i) {
    final (count, error, next) = _grepMaxCountAt(parsed.flags, i);
    if (error != null) {
      state.error = error;
      return i;
    }
    state.maxCount = count;
    return next;
  }

  /// Consumes one short letter token at [i] into [state]; unsupported
  /// letters stash the exit-2 error. Returns the index of the last token
  /// used.
  int _grepLetterToken(GrepArgs parsed, _GrepEnginePlanState state, int i) {
    final token = parsed.flags.elementAt(i);
    if (!token.startsWith('-') || token.startsWith('--')) {
      return i; // long tokens and stray value tokens ride through
    }
    final letter = token.substring(1);
    final unsupported = _unsupportedGrepLetter(letter);
    if (unsupported != null) {
      state.error = unsupported;
      return i;
    }
    _addGrepLetter(state.flags, letter);
    return i;
  }

  /// Consumes the flag token at [i] into [state], advancing past the
  /// tokens it used.
  int _grepEngineToken(GrepArgs parsed, _GrepEnginePlanState state, int i) {
    final token = parsed.flags.elementAt(i);
    if (token.startsWith('-') && token.startsWith('-m')) {
      // `-m5` attached or `-m 5` detached — the count rides the next
      // token for the detached shape.
      return _grepMaxCountToken(parsed, state, i);
    }
    return _grepLetterToken(parsed, state, i);
  }

  /// Scans [parsed.flags] into [state]; returns the exit-2 error for the
  /// first flag the engine cannot honor faithfully, if any.
  String? _grepEngineFlags(GrepArgs parsed, _GrepEnginePlanState state) {
    for (var i = 0; i < parsed.flags.length; i++) {
      i = _grepEngineToken(parsed, state, i);
      if (state.error != null) return state.error;
    }
    return null;
  }

  /// The Dart grep engine's view of the parsed flags: the letter set to
  /// compile, the `-m` cap (null = unlimited), or an exit-2 error message
  /// for a flag the engine cannot honor faithfully (gh-1393 E2).
  _GrepEnginePlan _planGrepEngine(GrepArgs parsed) {
    final state = _GrepEnginePlanState();
    if (parsed.quiet) state.flags.add('q');
    final error = _grepEngineFlags(parsed, state);
    if (error != null) {
      return _GrepEnginePlan.invalid(error);
    }
    if (state.flags.contains('v') && state.flags.contains('o')) {
      // GNU prints the non-matching segments with `-v -o`; the engine
      // can't honor that faithfully — a loud error, not a divergence.
      return _GrepEnginePlan.invalid(
        'grep: the sandbox grep engine does not support -v with -o\n',
      );
    }
    return _GrepEnginePlan(state.flags, state.maxCount);
  }

  /// The `-m` cap carried by the flag token at [i]: `-m5` attached, or
  /// `-m 5` with the count riding the next token. Returns the parsed
  /// count (null when malformed), the POSIX error message for that case,
  /// and the index of the last token the flag consumed.
  (int?, String?, int) _grepMaxCountAt(List<String> flags, int i) {
    final token = flags.elementAt(i);
    final value = token.length > 2
        ? token.substring(2)
        : (i + 1 < flags.length ? flags.elementAt(i + 1) : null);
    final count = value == null ? null : int.tryParse(value);
    if (count == null) {
      return (null, 'grep: option requires a numeric argument -- m\n', i);
    }
    return (count, null, token.length == 2 ? i + 1 : i);
  }

  /// The exit-2 message for a short letter the Dart engine cannot honor
  /// faithfully, or null when the letter maps to engine behavior.
  String? _unsupportedGrepLetter(String letter) => switch (letter) {
    'A' || 'B' || 'C' =>
      'grep: the sandbox grep engine does not support the context '
          "option -$letter\n",
    'L' =>
      'grep: the sandbox grep engine does not support -L '
          '(--files-without-match)\n',
    'P' =>
      'grep: the sandbox grep engine does not support -P '
          '(--perl-regexp)\n',
    _ => null,
  };

  /// Operand expansion for grep: a directory operand with -r walks the
  /// subtree (gh-1393 AC1 — `grep -rl 'счёт' apps` matches on every
  /// shell); without -r it is the POSIX "Is a directory" error. Returns
  /// the (display, resolved) input pairs plus whether any operand erred.
  Future<(List<(String, String)>, bool)> _grepResolveInputs(
    _Context ctx,
    GrepArgs parsed,
    StringBuffer err,
  ) async {
    final inputs = <(String, String)>[]; // (display path, resolved path)
    var hadError = false;
    for (final arg in parsed.files) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      final isDir = info.valueOrNull?.kind == FileKind.directory;
      if (isDir && !parsed.recursive) {
        hadError = true;
        err.write('grep: $arg: Is a directory\n');
        continue;
      }
      if (isDir) {
        inputs.addAll(await _walkGrepDir(resolved, arg, parsed));
      } else {
        inputs.add((arg, resolved));
      }
    }
    return (inputs, hadError);
  }

  /// Runs the compiled query over stdin (no operands) or each input file,
  /// appending matches to [acc] and per-file errors to [err]. Returns
  /// whether any read failed. `-h` (translated to `-I` by the shared
  /// parser) suppresses the filename column, exactly like GNU grep.
  Future<bool> _grepRunOnInputs(
    _Context ctx,
    GrepArgs parsed,
    Set<String> flags,
    GrepQuery q,
    GrepAccumulator acc,
    StringBuffer err,
    List<(String, String)> inputs,
  ) async {
    var hadError = false;
    if (inputs.isEmpty && parsed.files.isEmpty) {
      grepText(ctx.stdin ?? '', null, q, acc);
    } else {
      final labelPrefix =
          !flags.contains('I') && (inputs.length > 1 || parsed.recursive);
      for (final (display, resolved) in inputs) {
        final content = await _fs.readTextFile(resolved);
        if (content.isErr) {
          hadError = true;
          err.write('grep: $display: No such file or directory\n');
          continue;
        }
        grepText(content.valueOrNull!, labelPrefix ? display : null, q, acc);
      }
    }
    return hadError;
  }

  /// Depth-first walk of [abs] for recursive grep: files only, sorted per
  /// directory for deterministic output, `--include=`/`--exclude=` basename
  /// globs applied (gh-1393 WS-1). Display paths join the OPERAND spelling
  /// with the walked names, exactly as GNU grep prints them.
  Future<List<(String, String)>> _walkGrepDir(
    String abs,
    String display,
    GrepArgs parsed,
  ) async {
    final include = [
      for (final glob in parsed.includeGlobs) globToRegExp(glob),
    ];
    final exclude = [
      for (final glob in parsed.excludeGlobs) globToRegExp(glob),
    ];
    bool basenameMatches(String name, List<RegExp> patterns) =>
        patterns.any((r) => r.hasMatch(name));
    final out = <(String, String)>[];
    Future<void> walk(String absDir, String displayDir, int depth) async {
      if (depth > 24) return;
      final listing = await _fs.listDir(absDir);
      if (listing.isErr) return;
      final entries = listing.valueOrNull!.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final entry in entries) {
        if (entry.kind == FileKind.directory) {
          await walk(
            '${absDir == '/' ? '' : absDir}/${entry.name}',
            '$displayDir/${entry.name}',
            depth + 1,
          );
          continue;
        }
        if (exclude.any((r) => r.hasMatch(entry.name))) continue;
        if (include.isNotEmpty && !basenameMatches(entry.name, include)) {
          continue;
        }
        out.add((
          '$displayDir/${entry.name}',
          '${absDir == '/' ? '' : absDir}/${entry.name}',
        ));
      }
    }

    await walk(abs, display, 0);
    return out;
  }

  /// The display name of the head/tail builtin.
  static String _headTailName(bool head) => head ? 'head' : 'tail';

  /// Updates the count when [text] parses (a malformed count word keeps
  /// the current one, like GNU).
  static void _applyHeadTailCount(_HeadTailArgsState args, String text) {
    final parsed = int.tryParse(text);
    if (parsed != null) args.count = parsed;
  }

  /// Applies the `-n` count word at [i] to [args] (attached `-nN`, or
  /// detached `-n N`); returns the last token consumed, or null when
  /// [argv[i]] is not an `-n` form. A bare trailing `-n` parses an empty
  /// operand and keeps the count.
  static int? _headTailApplyN(
    _HeadTailArgsState args,
    List<String> argv,
    int i,
  ) {
    final arg = argv[i];
    if (arg == '-n') {
      if (i + 1 < argv.length) _applyHeadTailCount(args, argv[i + 1]);
      return i + 1 < argv.length ? i + 1 : i;
    }
    if (arg.startsWith('-n')) {
      _applyHeadTailCount(args, arg.substring(2));
      return i;
    }
    return null;
  }

  /// Applies the `-N` (digit-run) count word [arg] to [args]; false when
  /// [arg] is not one.
  static bool _headTailApplyDigits(_HeadTailArgsState args, String arg) {
    if (!RegExp(r'^-\d+$').hasMatch(arg)) return false;
    args.count = int.parse(arg.substring(1));
    return true;
  }

  /// Consumes one head/tail argv word at [i] into [args]; returns the
  /// index of the last token consumed, or -1 on the unrecognized-option
  /// error.
  int _headTailConsume(_HeadTailArgsState args, List<String> argv, int i) {
    final nUsed = _headTailApplyN(args, argv, i);
    if (nUsed != null) return nUsed;
    if (_headTailApplyDigits(args, argv[i])) return i;
    final arg = argv[i];
    if (arg.startsWith('-') && arg != '-') {
      return -1;
    }
    args.paths.add(arg);
    return i;
  }

  /// Drops the empty element a trailing newline produces when splitting.
  static void _dropTrailingEmpty(List<String> lines) {
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  }

  /// The head/tail selection of [lines]: the first [count], or the last
  /// [count] for tail (a count past the length keeps everything).
  static List<String> _headTailLines(List<String> lines, int count, bool head) {
    if (head) return lines.take(count).toList();
    return lines.skip(lines.length > count ? lines.length - count : 0).toList();
  }

  /// Line-list output text: the joined lines plus their trailing newline;
  /// empty stays empty.
  static String _joinedLines(List<String> lines) {
    final out = lines.join('\n');
    return out.isEmpty ? '' : '$out\n';
  }

  Future<_StageResult> _headTail(_Context ctx, {required bool head}) async {
    final name = _headTailName(head);
    final args = _HeadTailArgsState();
    for (var i = 0; i < ctx.args.length; i++) {
      final used = _headTailConsume(args, ctx.args, i);
      if (used < 0) {
        return _error(
          '$name: unrecognized option ${ctx.args[i]}\n',
          exitCode: 2,
        );
      }
      i = used;
    }
    String? errorPath;
    final input = await readCommandInput(
      _fs,
      ctx.cwd,
      args.paths,
      ctx.stdin,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error(
        '$name: cannot open $errorPath for reading: No such file or directory\n',
      );
    }
    final lines = input.split('\n');
    _dropTrailingEmpty(lines);
    return _text(_joinedLines(_headTailLines(lines, args.count, head)));
  }

  Future<_StageResult> _wc(_Context ctx) async {
    final split = splitArgs(ctx.args);
    final showLines =
        split.flags.isEmpty || split.flags.any((f) => f.contains('l'));
    final showWords =
        split.flags.isEmpty || split.flags.any((f) => f.contains('w'));
    final showBytes =
        split.flags.isEmpty || split.flags.any((f) => f.contains('c'));

    final out = StringBuffer();
    var totalLines = 0;
    var totalWords = 0;
    var totalBytes = 0;

    void wcContent(String content, String? label) {
      final lines = content.isEmpty ? 0 : '\n'.allMatches(content).length;
      final words = content
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length;
      final bytes = utf8.encode(content).length;
      totalLines += lines;
      totalWords += words;
      totalBytes += bytes;
      final parts = <String>[
        if (showLines) '$lines',
        if (showWords) '$words',
        if (showBytes) '$bytes',
        ?label,
      ];
      out.writeln(parts.join(' '));
    }

    if (split.paths.isEmpty) {
      wcContent(ctx.stdin ?? '', null);
    } else {
      for (final arg in split.paths) {
        final content = await _fs.readTextFile(
          resolveSandboxPath(arg, ctx.cwd),
        );
        if (content.isErr) {
          return _error('wc: $arg: No such file or directory\n');
        }
        wcContent(content.valueOrNull!, arg);
      }
      if (split.paths.length > 1) {
        final parts = <String>[
          if (showLines) '$totalLines',
          if (showWords) '$totalWords',
          if (showBytes) '$totalBytes',
          'total',
        ];
        out.writeln(parts.join(' '));
      }
    }
    return _text(out.toString());
  }

  /// Numeric-aware comparator: unparseable words sort as 0.
  static int _numericCompare(String a, String b) {
    final na = num.tryParse(a.trim()) ?? 0;
    final nb = num.tryParse(b.trim()) ?? 0;
    return na.compareTo(nb);
  }

  /// Reverses [lines] in place.
  static void _sortReverse(List<String> lines) {
    final reversed = lines.reversed.toList();
    lines
      ..clear()
      ..addAll(reversed);
  }

  /// Deduplicates [lines] in place, keeping first occurrences.
  static void _sortUnique(List<String> lines) {
    final seen = <String>{};
    lines.retainWhere(seen.add);
  }

  /// Applies the -r/-u post-ordering: reversal then first-occurrence
  /// deduplication, in place.
  static void _sortPost(
    List<String> lines, {
    required bool reverse,
    required bool unique,
  }) {
    if (reverse) _sortReverse(lines);
    if (unique) _sortUnique(lines);
  }

  /// Sorts [lines] in place: numeric-aware under [numeric], then -r/-u.
  static void _sortLines(
    List<String> lines, {
    required bool reverse,
    required bool unique,
    required bool numeric,
  }) {
    lines.sort(numeric ? _numericCompare : null);
    _sortPost(lines, reverse: reverse, unique: unique);
  }

  Future<_StageResult> _sort(_Context ctx) async {
    final split = splitArgs(ctx.args);
    final reverse = split.flags.any((f) => f.contains('r'));
    final unique = split.flags.any((f) => f.contains('u'));
    final numeric = split.flags.any((f) => f.contains('n'));
    String? errorPath;
    final input = await readCommandInput(
      _fs,
      ctx.cwd,
      split.paths,
      ctx.stdin,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error(
        'sort: cannot read: $errorPath: No such file or directory\n',
      );
    }
    final lines = input.split('\n');
    _dropTrailingEmpty(lines);
    _sortLines(lines, reverse: reverse, unique: unique, numeric: numeric);
    return _text(_joinedLines(lines));
  }

  /// Consumes one tr argv word into [args]: `-d` toggles delete mode,
  /// the first free word is SET1, the next SET2.
  static void _trConsume(_TrArgsState args, String arg) {
    if (arg == '-d') {
      args.delete = true;
    } else if (args.set1 == null) {
      args.set1 = arg;
    } else {
      args.set2 ??= arg;
    }
  }

  /// Parses tr argv: `-d`, then the first free word as SET1 and the next
  /// as SET2.
  _TrArgsState _parseTrArgs(List<String> args) {
    final parsed = _TrArgsState();
    for (final arg in args) {
      _trConsume(parsed, arg);
    }
    return parsed;
  }

  /// The `tr` usage error for these operands, if any: SET1 is required,
  /// and SET2 is required outside delete mode.
  _StageResult? _trUsage(_TrArgsState args) {
    if (args.set1 == null) {
      return _error('tr: missing operand\n', exitCode: 2);
    }
    if (!args.delete && args.set2 == null) {
      return _error('tr: missing operand after "${args.set1}"\n', exitCode: 2);
    }
    return null;
  }

  /// Deletes every character in [chars] from [input].
  static String _trDelete(String input, Set<String> chars) =>
      input.split('').where((c) => !chars.contains(c)).join();

  /// The per-character translate map: SET1[i] → SET2[i], the last SET2
  /// character covering any excess.
  static Map<String, String> _trMap(List<String> set1, List<String> set2) {
    final map = <String, String>{};
    for (var i = 0; i < set1.length; i++) {
      map[set1[i]] = i < set2.length ? set2[i] : set2.last;
    }
    return map;
  }

  /// Translates [input] through [map]; unmapped characters pass through.
  static String _trTranslate(String input, Map<String, String> map) =>
      input.split('').map((c) => map.containsKey(c) ? map[c]! : c).join();

  /// The tr output for stdin [input]: SET2-less deletion or translation.
  static String _trOutput(
    String input,
    List<String> set1,
    List<String>? set2,
    bool delete,
  ) {
    if (delete) {
      return _trDelete(input, set1.toSet());
    }
    return _trTranslate(input, _trMap(set1, set2!));
  }

  _StageResult _tr(_Context ctx) {
    final args = _parseTrArgs(ctx.args);
    final usage = _trUsage(args);
    if (usage != null) return usage;
    final expanded1 = _expandTrSet(args.set1!);
    final expanded2 = args.delete ? null : _expandTrSet(args.set2!);
    return _text(_trOutput(ctx.stdin ?? '', expanded1, expanded2, args.delete));
  }

  /// POSIX `tr` character classes, in match order.
  static const _trClasses = <String, String>{
    '[:lower:]': 'abcdefghijklmnopqrstuvwxyz',
    '[:upper:]': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    '[:digit:]': '0123456789',
    '[:alnum:]':
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
    '[:space:]': ' \t\n\r\f\v',
  };

  /// The characters of the POSIX class starting at [i], or null.
  static String? _trClassAt(String set, int i) {
    for (final entry in _trClasses.entries) {
      if (set.startsWith(entry.key, i)) return entry.value;
    }
    return null;
  }

  /// Whether the `a-z` range form starts at [i].
  static bool _trRangeStartsAt(String set, int i) =>
      i + 2 < set.length && set[i + 1] == '-';

  /// Expands the `a-z` range at [i] into [result]; returns the next index.
  static int _trRangeAt(String set, int i, List<String> result) {
    final start = set.codeUnitAt(i);
    final end = set.codeUnitAt(i + 2);
    for (var c = start; c <= end; c++) {
      result.add(String.fromCharCode(c));
    }
    return i + 3;
  }

  /// Expands the class or range form at [i] into [result]; null when [i]
  /// starts neither (the caller emits the literal character).
  static int? _trExpandedAt(String set, int i, List<String> result) {
    final chars = _trClassAt(set, i);
    if (chars != null) {
      result.addAll(chars.split(''));
      return i + 9;
    }
    if (_trRangeStartsAt(set, i)) {
      return _trRangeAt(set, i, result);
    }
    return null;
  }

  /// Expands POSIX character classes (`[:lower:]`) and ranges (`a-z`) used by
  /// the `tr` command.
  List<String> _expandTrSet(String set) {
    final result = <String>[];
    var i = 0;
    while (i < set.length) {
      final next = _trExpandedAt(set, i, result);
      if (next != null) {
        i = next;
      } else {
        result.add(set[i]);
        i++;
      }
    }
    return result;
  }

  _StageResult _which(List<String> args) {
    if (args.isEmpty) {
      return _error('which: missing argument\n');
    }
    final name = args.first;
    if (_availableCommands.contains(name)) {
      return _text('/bin/$name\n');
    }
    return _error('which: $name: not found\n');
  }

  _StageResult _command(List<String> args) {
    if (args.length >= 2 && args[0] == '-v') {
      final name = args[1];
      if (_availableCommands.contains(name)) {
        return _text('/bin/$name\n');
      }
      return _error('command: $name: not found\n');
    }
    return _error('command: unsupported usage\n');
  }

  Future<_StageResult> _test(String command, _Context ctx) async {
    final rawArgs = ctx.args.toList();
    if (command == '[') {
      if (rawArgs.isEmpty || rawArgs.last != ']') {
        return _error('[[: missing `]]\n', exitCode: 2);
      }
      rawArgs.removeLast();
    }
    if (rawArgs.isEmpty) {
      return _error('test: missing expression\n', exitCode: 2);
    }
    try {
      final value = await evalTestExpr(rawArgs, _MemoryTestFs(_fs, ctx.cwd));
      return _StageResult(
        stdout: const [],
        stderr: const [],
        exitCode: value ? 0 : 1,
      );
    } on FormatException catch (e) {
      return _error('test: integer expected: $e\n', exitCode: 2);
    }
  }

  _StageResult _env(_Context ctx) {
    final env = _effectiveEnv(ctx.options);
    for (final arg in ctx.args) {
      final idx = arg.indexOf('=');
      if (idx > 0 && !arg.startsWith('-')) {
        env[arg.substring(0, idx)] = arg.substring(idx + 1);
      } else {
        return _error('env: running commands is not supported\n');
      }
    }
    // gh-1444 AC4: rostered secret vars render as PRESENT/ABSENT lines —
    // presence is verifiable, values never render.
    return _text(renderEnvListingWithSecretPresence(env));
  }

  _StageResult _export(List<String> args) {
    if (args.isEmpty) {
      final names = _shellEnv.keys.where((n) => n != '?').toList()..sort();
      final lines = names
          .map((n) => 'declare -x $n="${_shellEnv[n]}"')
          .toList();
      return _text(lines.isEmpty ? '' : '${lines.join('\n')}\n');
    }
    for (final arg in args) {
      final idx = arg.indexOf('=');
      if (idx > 0) {
        final name = arg.substring(0, idx);
        // Special parameters (`$?`) are shell-owned (issue #1335).
        if (!exportEnvVarName.hasMatch(name)) continue;
        _shellEnv[name] = arg.substring(idx + 1);
      } else {
        _shellEnv.putIfAbsent(arg, () => '');
      }
    }
    return _ok;
  }

  _StageResult _unset(List<String> args) {
    for (final arg in args) {
      _shellEnv.remove(arg);
    }
    return _ok;
  }

  _StageResult _basename(_Context ctx) {
    if (ctx.args.isEmpty) {
      return _error('basename: missing operand\n');
    }
    var path = ctx.args.first;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    var base = path.split('/').last;
    if (ctx.args.length > 1) {
      final suffix = ctx.args[1];
      if (base.endsWith(suffix) && base.length > suffix.length) {
        base = base.substring(0, base.length - suffix.length);
      }
    }
    return _text('$base\n');
  }

  _StageResult _dirname(_Context ctx) {
    if (ctx.args.isEmpty) {
      return _error('dirname: missing operand\n');
    }
    var path = ctx.args.first;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final idx = path.lastIndexOf('/');
    if (idx < 0) return _text('.\n');
    if (idx == 0) return _text('/\n');
    return _text('${path.substring(0, idx)}\n');
  }
}

/// The Dart grep engine's compiled view of the parsed flags (gh-1393
/// rework): the letter set for `compileGrepQuery`, the `-m` cap (null =
/// unlimited), or an exit-2 message for a flag the engine has no faithful
/// translation for — E2's "never silently divergent".
final class _GrepEnginePlanState {
  final flags = <String>{};
  int? maxCount;
  String? error;
}

final class _GrepEnginePlan {
  const _GrepEnginePlan(this.flags, this.maxCount) : error = null;

  const _GrepEnginePlan.invalid(this.error)
    : flags = const <String>{},
      maxCount = null;

  final Set<String> flags;
  final int? maxCount;

  /// Non-null when a forwarded flag cannot be honored (exit 2).
  final String? error;
}

/// `tr` argv operands (see `MemoryShell._tr`): the delete flag plus
/// SET1/SET2.
final class _TrArgsState {
  var delete = false;
  String? set1;
  String? set2;
}

/// Head/tail argv parse state (see `MemoryShell._headTail`): the line
/// count and operand paths.
final class _HeadTailArgsState {
  var count = 10;
  final paths = <String>[];
}

/// Per-stage execution context passed to command implementations.
final class _Context {
  const _Context({
    required this.args,
    required this.options,
    required this.stdin,
    required this.cwd,
  });

  final List<String> args;
  final ShellExecOptions? options;
  final String? stdin;
  final String cwd;
}

/// Raw result of a single pipeline stage.
final class _StageResult {
  const _StageResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final List<int> stdout;
  final List<int> stderr;
  final int exitCode;
}

/// Wires the `test`/`[` evaluator to the in-memory filesystem.
final class _MemoryTestFs implements TestFs {
  const _MemoryTestFs(this._fs, this._cwd);

  final MemoryFileSystem _fs;
  final String _cwd;

  @override
  Future<bool> exists(String path) async =>
      (await _fs.exists(resolveSandboxPath(path, _cwd))).valueOrNull ?? false;

  @override
  Future<FileInfo?> fileInfo(String path) async =>
      (await _fs.fileInfo(resolveSandboxPath(path, _cwd))).valueOrNull;
}
