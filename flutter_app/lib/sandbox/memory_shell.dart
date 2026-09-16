// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'package:fa/sandbox/memory_shell/awk.dart';
import 'package:fa/sandbox/memory_shell/grep.dart';
import 'package:fa/sandbox/memory_shell/interpreters.dart';
import 'package:fa/sandbox/memory_shell/pipeline.dart';
import 'package:fa/sandbox/memory_shell/paths.dart';
import 'package:fa/sandbox/memory_shell/sed.dart';
import 'package:fa/sandbox/memory_shell/tar.dart';
import 'package:fa/sandbox/memory_shell/test_expr.dart';
import 'package:fa/sandbox/sandbox_builtins.dart';
import 'package:fa/sandbox/sandbox_registry.dart';
import 'package:fa/sandbox/shell_job.dart';
import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/shell_script.dart';
import 'package:fa/sandbox/web_git.dart';
import 'package:fa/sandbox/web_interpreters_stub.dart'
    if (dart.library.html) 'web_interpreters_web.dart';

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
      script = parseShellScript(command);
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
    final job = SandboxShellJob(
      id: id,
      command: command,
      logPath: logPath,
      logWriter: (chunk) async => _fs.appendFile(logPath, chunk),
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
      // are visible.
      final expansion = await expandShellStage(
        pipeline.stages[i],
        _effectiveEnv(options),
        (source) => _scriptRunner.substitute(source, options, depth),
      );
      if (expansion.isErr) return Err(expansion.errorOrNull!);
      final stage = expansion.valueOrNull!;
      final cwd = options?.cwd ?? _currentDir;

      final redirects = parseStageRedirects(stage.redirects);
      final stdoutFile = redirects.stdoutFile;
      final stderrFile = redirects.stderrFile;
      final appendStdout = redirects.appendStdout;
      final appendStderr = redirects.appendStderr;
      final stdinFile = redirects.stdinFile;

      String? stdinText;
      if (stdinFile != null) {
        final read = await _fs.readTextFile(resolveSandboxPath(stdinFile, cwd));
        if (read.isErr) {
          stageResult = _StageResult(
            stdout: const [],
            stderr: utf8.encode('sh: $stdinFile: No such file or directory\n'),
            exitCode: 1,
          );
          _lastStderr = (_lastStderr ?? '') + utf8.decode(stageResult.stderr);
          pipeInput = null;
          continue;
        }
        stdinText = read.valueOrNull;
      } else if (pipeInput != null) {
        stdinText = utf8.decode(pipeInput, allowMalformed: true);
      }

      stageResult = await _runCommand(
        stage.command,
        stage.args,
        options,
        cwd,
        stdinText,
      );

      if (stdoutFile != null) {
        await _writeRedirect(stdoutFile, stageResult.stdout, appendStdout, cwd);
      } else {
        final text = utf8.decode(stageResult.stdout, allowMalformed: true);
        // Only the LAST stage's stdout leaves the pipeline (the rest goes
        // into the pipe) — intermediate stages must not leak into command
        // substitution captures or the exec accumulator.
        if (isLastStage && text.isNotEmpty) {
          _lastStdout = (_lastStdout ?? '') + text;
          _capture.feed(text);
          if (!_capture.isActive) options?.onStdout?.call(text);
        }
      }

      if (stderrFile != null) {
        await _writeRedirect(stderrFile, stageResult.stderr, appendStderr, cwd);
      } else {
        final text = utf8.decode(stageResult.stderr, allowMalformed: true);
        if (isLastStage && text.isNotEmpty) {
          _lastStderr = (_lastStderr ?? '') + text;
          if (!_capture.isActive) options?.onStderr?.call(text);
        }
      }

      pipeInput = stageResult.stdout;
    }

    return Ok(stageResult);
  }

  Future<void> _writeRedirect(
    String target,
    List<int> bytes,
    bool append,
    String cwd,
  ) async {
    final path = resolveSandboxPath(target, cwd);
    if (append) {
      await _fs.appendFile(path, utf8.decode(bytes, allowMalformed: true));
    } else {
      await _fs.writeBinaryFile(path, Uint8List.fromList(bytes));
    }
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
    return switch (command) {
      'true' => _ok,
      'false' => const _StageResult(stdout: [], stderr: [], exitCode: 1),
      'echo' => _echo(args),
      'cat' => _cat(ctx),
      'ls' => _ls(ctx),
      'mkdir' => _mkdir(ctx),
      'rmdir' => _rmdir(ctx),
      'touch' => _touch(ctx),
      'cp' => _cp(ctx),
      'mv' => _mv(ctx),
      'rm' => _rm(ctx),
      'pwd' => _text('${ctx.cwd}\n'),
      'cd' => _cd(ctx),
      'grep' => _grep(ctx),
      'head' => _headTail(ctx, head: true),
      'tail' => _headTail(ctx, head: false),
      'wc' => _wc(ctx),
      'sort' => _sort(ctx),
      'tr' => _tr(ctx),
      'which' => _which(args),
      'command' => _command(args),
      'test' || '[' => _test(command, ctx),
      'env' => _env(ctx),
      'export' => _export(args),
      'unset' => _unset(args),
      'git' => _git(ctx),
      'curl' => _curl(ctx),
      'wget' => _wget(ctx),
      'jq' => _jq(ctx),
      'yq' => _yq(ctx),
      'diff' => _diff(ctx),
      'dig' => _dig(ctx),
      'patch' => _patch(ctx),
      'nslookup' => _nslookup(ctx),
      'whois' => _whois(ctx),
      'tree' => _toStage(_builtinsFor(ctx).tree(ctx.args)),
      'file' => _toStage(_builtinsFor(ctx).file(ctx.args)),
      'xz' || 'unxz' => _xz(ctx, decompress: command == 'unxz'),
      'bzip2' || 'bunzip2' => _bzip2(ctx, decompress: command == 'bunzip2'),
      'base64' => _toStage(
        _builtinsFor(ctx).base64(ctx.args, stdin: ctx.stdin),
      ),
      _ when _hashCommands.contains(command) => _hashsum(command, ctx),
      'rg' => _grep(ctx),
      'sed' => _sed(ctx),
      'awk' => _awk(ctx),
      'find' => _find(ctx),
      'xargs' => _xargs(ctx),
      'printf' => _printf(ctx),
      'realpath' => _realpath(ctx),
      'tar' => _tar(ctx),
      'gzip' => _gzip(ctx, decompress: false),
      'gunzip' => _gzip(ctx, decompress: true),
      'zip' => _zip(ctx),
      'unzip' => _toStage(_builtinsFor(ctx).unzip(ctx.args)),
      'sqlite3' => _runSqlite(ctx),
      'python' || 'python3' => _runPython(ctx),
      'pip' || 'pip3' => _runPip(ctx),
      'qjs' || 'js' => _runQjs(ctx),
      'lua' => _interpreterUnavailable('lua'),
      'whoami' => _text('${_effectiveEnv(ctx.options)['USER']}\n'),
      'basename' => _basename(ctx),
      'dirname' => _dirname(ctx),
      'ssh' || 'scp' || 'sftp' => _sshUnavailable(command),
      _ => _StageResult(
        stdout: const [],
        stderr: utf8.encode('$command: command not found\n'),
        exitCode: 127,
      ),
    };
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
      for (var i = 0; i < format.length; i++) {
        final ch = format[i];
        if (ch == '%' && i + 1 < format.length) {
          final spec = format[i + 1];
          if (spec == '%') {
            out.write('%');
            i++;
            continue;
          }
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
          i++;
          continue;
        }
        out.write(ch);
      }
      if (argIndex >= args.length || argIndex == consumedBefore) break;
    }
    return _text(out.toString());
  }

  /// Interprets the backslash escapes printf understands in its format
  /// string (`\n`, `\t`, `\r`, `\\`, `\0`).
  String _unescapePrintf(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      if (input[i] == '\\' && i + 1 < input.length) {
        final escape = switch (input[i + 1]) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          '0' => '\x00',
          '\\' => '\\',
          _ => null,
        };
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

  String _interpretEchoEscapes(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      if (input[i] == '\\' && i + 1 < input.length) {
        final next = input[i + 1];
        final escape = switch (next) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          '\\' => '\\',
          '0' => '\x00',
          _ => null,
        };
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
    var showAll = false;
    var long = false;
    final paths = <String>[];
    for (final arg in ctx.args) {
      if (arg.startsWith('-') && arg != '-') {
        if (arg.contains('a')) showAll = true;
        if (arg.contains('l')) long = true;
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('.');

    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;
    var first = true;
    for (final arg in paths) {
      final resolved = resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        err.write('ls: cannot access $arg: No such file or directory\n');
        exitCode = 1;
        continue;
      }
      final fileInfo = info.valueOrNull!;
      if (fileInfo.kind == FileKind.file) {
        out.writeln(long ? _longLine(fileInfo) : fileInfo.name);
        continue;
      }
      if (paths.length > 1) {
        if (!first) out.writeln();
        out.writeln('$arg:');
      }
      first = false;
      final entries = await _fs.listDir(resolved);
      if (entries.isErr) {
        err.write('ls: cannot open directory $arg\n');
        exitCode = 1;
        continue;
      }
      for (final entry in entries.valueOrNull!) {
        if (!showAll && entry.name.startsWith('.')) continue;
        out.writeln(long ? _longLine(entry) : entry.name);
      }
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

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
    final destInfo = await _fs.fileInfo(destResolved);
    final destIsDir =
        destInfo.isOk && destInfo.valueOrNull!.kind == FileKind.directory;
    if (sources.length > 1 && !destIsDir) {
      return _error('cp: target $destArg: Not a directory\n');
    }
    for (final srcArg in sources) {
      final srcResolved = resolveSandboxPath(srcArg, ctx.cwd);
      final srcInfo = await _fs.fileInfo(srcResolved);
      if (srcInfo.isErr) {
        return _error('cp: cannot stat $srcArg: No such file or directory\n');
      }
      final target = destIsDir
          ? normalizeSandboxPath('$destResolved/${srcInfo.valueOrNull!.name}')
          : destResolved;
      final copyError = await _copyRecursive(
        srcResolved,
        target,
        srcInfo.valueOrNull!,
        recursive,
        srcArg,
      );
      if (copyError != null) return _error(copyError);
    }
    return _ok;
  }

  Future<String?> _copyRecursive(
    String src,
    String dest,
    FileInfo srcInfo,
    bool recursive,
    String srcArg,
  ) async {
    if (srcInfo.kind == FileKind.directory) {
      if (!recursive) {
        return 'cp: -r not specified; omitting directory $srcArg\n';
      }
      await _fs.createDir(dest);
      final entries = await _fs.listDir(src);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
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
    final parseError = parsed.error;
    if (parseError != null) {
      return _error(parseError.message, exitCode: parseError.exitCode);
    }
    final compiled = compileGrepQuery(parsed.flags, parsed.pattern!);
    final compileError = compiled.error;
    if (compileError != null) {
      return _error(compileError.message, exitCode: compileError.exitCode);
    }
    final q = compiled.query!;
    final acc = GrepAccumulator();
    final err = StringBuffer();
    var hadError = false;

    if (parsed.files.isEmpty) {
      grepText(ctx.stdin ?? '', null, q, acc);
    } else {
      final labelPrefix = parsed.files.length > 1;
      for (final arg in parsed.files) {
        final resolved = resolveSandboxPath(arg, ctx.cwd);
        final content = await _fs.readTextFile(resolved);
        if (content.isErr) {
          hadError = true;
          err.write('grep: $arg: No such file or directory\n');
          continue;
        }
        grepText(content.valueOrNull!, labelPrefix ? arg : null, q, acc);
      }
    }

    return _StageResult(
      stdout: q.quiet ? const [] : utf8.encode(acc.buffer.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: hadError ? 2 : (acc.anyMatch ? 0 : 1),
    );
  }

  Future<_StageResult> _headTail(_Context ctx, {required bool head}) async {
    final name = head ? 'head' : 'tail';
    var count = 10;
    final paths = <String>[];
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-n' && i + 1 < ctx.args.length) {
        count = int.tryParse(ctx.args[++i]) ?? count;
      } else if (RegExp(r'^-\d+$').hasMatch(arg)) {
        count = int.parse(arg.substring(1));
      } else if (arg.startsWith('-n')) {
        count = int.tryParse(arg.substring(2)) ?? count;
      } else if (arg.startsWith('-') && arg != '-') {
        return _error('$name: unrecognized option $arg\n', exitCode: 2);
      } else {
        paths.add(arg);
      }
    }
    String? errorPath;
    final input = await readCommandInput(
      _fs,
      ctx.cwd,
      paths,
      ctx.stdin,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error(
        '$name: cannot open $errorPath for reading: No such file or directory\n',
      );
    }
    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final selected = head
        ? lines.take(count)
        : lines.skip(lines.length > count ? lines.length - count : 0);
    final out = selected.join('\n');
    return _text(out.isEmpty ? '' : '$out\n');
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
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (numeric) {
      lines.sort((a, b) {
        final na = num.tryParse(a.trim()) ?? 0;
        final nb = num.tryParse(b.trim()) ?? 0;
        return na.compareTo(nb);
      });
    } else {
      lines.sort();
    }
    if (reverse) {
      final reversed = lines.reversed.toList();
      lines
        ..clear()
        ..addAll(reversed);
    }
    if (unique) {
      final seen = <String>{};
      lines.retainWhere(seen.add);
    }
    final out = lines.join('\n');
    return _text(out.isEmpty ? '' : '$out\n');
  }

  _StageResult _tr(_Context ctx) {
    var delete = false;
    String? set1;
    String? set2;
    for (final arg in ctx.args) {
      if (arg == '-d') {
        delete = true;
      } else if (set1 == null) {
        set1 = arg;
      } else {
        set2 ??= arg;
      }
    }

    if (set1 == null) {
      return _error('tr: missing operand\n', exitCode: 2);
    }
    if (!delete && set2 == null) {
      return _error('tr: missing operand after "$set1"\n', exitCode: 2);
    }

    final input = ctx.stdin ?? '';
    final expanded1 = _expandTrSet(set1);
    final expanded2 = delete ? null : _expandTrSet(set2!);

    String output;
    if (delete) {
      final chars = expanded1.toSet();
      output = input.split('').where((c) => !chars.contains(c)).join();
    } else {
      final map = <String, String>{};
      for (var i = 0; i < expanded1.length; i++) {
        map[expanded1[i]] = i < expanded2!.length
            ? expanded2[i]
            : expanded2.last;
      }
      output = input
          .split('')
          .map((c) => map.containsKey(c) ? map[c]! : c)
          .join();
    }
    return _text(output);
  }

  /// Expands POSIX character classes (`[:lower:]`) and ranges (`a-z`) used by
  /// the `tr` command.
  List<String> _expandTrSet(String set) {
    final result = <String>[];
    var i = 0;
    while (i < set.length) {
      if (set.startsWith('[:lower:]', i)) {
        result.addAll('abcdefghijklmnopqrstuvwxyz'.split(''));
        i += 9;
        continue;
      }
      if (set.startsWith('[:upper:]', i)) {
        result.addAll('ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''));
        i += 9;
        continue;
      }
      if (set.startsWith('[:digit:]', i)) {
        result.addAll('0123456789'.split(''));
        i += 9;
        continue;
      }
      if (set.startsWith('[:alnum:]', i)) {
        result.addAll(
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
              .split(''),
        );
        i += 9;
        continue;
      }
      if (set.startsWith('[:space:]', i)) {
        result.addAll(' \t\n\r\f\v'.split(''));
        i += 9;
        continue;
      }
      if (i + 2 < set.length && set[i + 1] == '-') {
        final start = set.codeUnitAt(i);
        final end = set.codeUnitAt(i + 2);
        for (var c = start; c <= end; c++) {
          result.add(String.fromCharCode(c));
        }
        i += 3;
        continue;
      }
      result.add(set[i]);
      i++;
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
    final names = env.keys.toList()..sort();
    return _text('${names.map((n) => '$n=${env[n]}').join('\n')}\n');
  }

  _StageResult _export(List<String> args) {
    if (args.isEmpty) {
      final names = _shellEnv.keys.toList()..sort();
      final lines = names
          .map((n) => 'declare -x $n="${_shellEnv[n]}"')
          .toList();
      return _text(lines.isEmpty ? '' : '${lines.join('\n')}\n');
    }
    for (final arg in args) {
      final idx = arg.indexOf('=');
      if (idx > 0) {
        _shellEnv[arg.substring(0, idx)] = arg.substring(idx + 1);
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
