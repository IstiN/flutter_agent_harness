// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:wasm_run/wasm_run.dart';

import 'sandbox_builtins.dart';
import 'shell_parser.dart';
import 'wasm_shell_git.dart';

/// A [Shell] backed by a sandbox of permissive WASI binaries.
///
/// This avoids the GPL licensing and portability problems of BusyBox by using
/// pre-built, MIT-licensed binaries:
///   - `coreutils.wasm` for the POSIX utility set
///   - `rg.wasm` for ripgrep
///   - `find.wasm` for uutils find
///   - `sed.wasm` for the uutils sed stream editor
///   - `awk.wasm` for goawk
///   - `tar.wasm` for tar archive creation/extraction
///   - `gzip.wasm` for gzip compression/decompression
///   - `zip.wasm` for zip archive creation/extraction
///
/// A tiny shell parser supports pipelines, `\u0026\u0026` / `||`, `;`, and
/// redirects. Each stage runs in its own WASM instance, so there is no need
/// for `fork`, `exec`, or process-level pipes — WASM does not expose those on
/// iOS/Android/Web.
final class WasiSandboxShell implements Shell {
  /// Creates a shell backed by the provided WASM modules.
  WasiSandboxShell({
    required this.coreutils,
    required this.rg,
    required this.find,
    required this.sed,
    required this.awk,
    required this.tar,
    required this.gzip,
    required this.zip,
    required this.python,
    required this.qjs,
    required this.sqlite3,
    this.workingDirectory,
    this.sandboxHostPath,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _currentDir = workingDirectory ?? '/';

  /// `coreutils` multicall module.
  final WasmModule coreutils;

  /// ripgrep module.
  final WasmModule rg;

  /// find module.
  final WasmModule find;

  /// sed module.
  final WasmModule sed;

  /// awk module.
  final WasmModule awk;

  /// tar module.
  final WasmModule tar;

  /// gzip module.
  final WasmModule gzip;

  /// zip/unzip module.
  final WasmModule zip;

  /// CPython module (Python 3.14, WASI build).
  final WasmModule python;

  /// QuickJS module (JavaScript engine, WASI build).
  final WasmModule qjs;

  /// SQLite CLI module (WASI build from the official amalgamation).
  final WasmModule sqlite3;

  /// Default working directory used when [ShellExecOptions.cwd] is omitted.
  final String? workingDirectory;

  /// Host directory exposed to the WASM guest at `/`.
  final String? sandboxHostPath;

  final http.Client _httpClient;

  bool _pythonStdlibReady = false;

  /// Extracts the bundled CPython standard library into the sandbox at
  /// `/usr/local/lib` (CPython's default WASI prefix) on first use.
  Future<void> _ensurePythonStdlib() async {
    if (_pythonStdlibReady) return;
    final host = sandboxHostPath;
    if (host == null || host.isEmpty) {
      _pythonStdlibReady = true;
      return;
    }
    final marker = io.File('$host/usr/local/lib/python3.14/json/__init__.py');
    if (marker.existsSync()) {
      _pythonStdlibReady = true;
      return;
    }
    final data = await rootBundle.load('assets/wasm/python_stdlib.zip');
    final zip = ZipDecoder().decodeBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    for (final file in zip.files) {
      if (!file.isFile) continue;
      // Archive entries are `lib/python3.14/...`; the WASI build expects the
      // stdlib at /usr/local/lib/python3.14.
      final out = io.File('$host/usr/local/${file.name}');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(file.content as List<int>);
    }
    _pythonStdlibReady = true;
  }

  /// Current working directory of the shell, mutated by the `cd` builtin.
  /// Initialized from [workingDirectory] and persisted across [exec] calls.
  String _currentDir;

  /// Variables set by the `export` builtin, persisted across [exec] calls and
  /// visible to later WASM commands and builtins.
  final Map<String, String> _shellEnv = <String, String>{};

  late final GitSandboxCommands _git = GitSandboxCommands(this);

  /// Host path for a sandbox-absolute path (public surface for git commands).
  String hostPathOf(String sandboxPath) => _hostPath(sandboxPath);

  /// Resolves a sandbox path against [cwd] (public surface for git commands).
  String resolveSandboxPathFor(String path, String cwd) =>
      _resolveSandboxPath(path, cwd);

  /// Current working directory of the shell (public surface for git commands).
  String get shellCwd => _currentDir;

  /// HTTP client used by network builtins (public surface for git commands).
  http.Client get shellHttpClient => _httpClient;

  /// Runs a sandbox command (public surface for git commands, e.g. tar).
  Future<Result<StageResult, ExecutionError>> runSandboxCommand(
    String command,
    List<String> args,
  ) => _runCommand(
    command: command,
    args: args,
    options: null,
    inputSource: null,
    captureStdout: true,
    captureStderr: true,
  );

  Future<Result<StageResult, ExecutionError>> _gitBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) => _git.run(stage, options);

  /// Loads all three WASM modules from the Flutter asset bundle.
  static Future<WasiSandboxShell> load({
    String? workingDirectory,
    String? sandboxHostPath,
    http.Client? httpClient,
  }) async {
    Future<WasmModule> loadAsset(String name) async {
      final byteData = await rootBundle.load('assets/wasm/$name');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      // The bundled WASI binaries are built without SIMD; only enable the
      // baseline SIMD proposal so validation passes on hosts that support it.
      return compileWasmModule(
        bytes,
        config: const ModuleConfig(
          wasmtime: ModuleConfigWasmtime(wasmSimd: false),
        ),
      );
    }

    return WasiSandboxShell(
      coreutils: await loadAsset('coreutils.wasm'),
      rg: await loadAsset('rg.wasm'),
      find: await loadAsset('find.wasm'),
      sed: await loadAsset('sed.wasm'),
      awk: await loadAsset('awk.wasm'),
      tar: await loadAsset('tar.wasm'),
      gzip: await loadAsset('gzip.wasm'),
      zip: await loadAsset('zip.wasm'),
      python: await loadAsset('python.wasm'),
      qjs: await loadAsset('qjs.wasm'),
      sqlite3: await loadAsset('sqlite3.wasm'),
      workingDirectory: workingDirectory,
      sandboxHostPath: sandboxHostPath,
      httpClient: httpClient,
    );
  }

  /// Applets exported by the `coreutils.wasm` multicall binary.
  static const Set<String> _coreutilsApplets = {
    'arch',
    'b2sum',
    'base32',
    'base64',
    'basename',
    'basenc',
    'cat',
    'cksum',
    'comm',
    'cp',
    'csplit',
    'cut',
    'date',
    'dd',
    'dir',
    'dircolors',
    'dirname',
    'echo',
    'expand',
    'factor',
    'false',
    'fmt',
    'fold',
    'head',
    'join',
    'link',
    'ln',
    'ls',
    'md5sum',
    'mkdir',
    'mktemp',
    'mv',
    'nl',
    'nproc',
    'numfmt',
    'od',
    'paste',
    'pathchk',
    'pr',
    'printenv',
    'printf',
    'ptx',
    'pwd',
    'readlink',
    'realpath',
    'rm',
    'rmdir',
    'seq',
    'sha1sum',
    'sha224sum',
    'sha256sum',
    'sha384sum',
    'sha512sum',
    'shred',
    'shuf',
    'sleep',
    'sort',
    'split',
    'sum',
    'tail',
    'tee',
    'touch',
    'tr',
    'true',
    'truncate',
    'tsort',
    'tty',
    'uname',
    'unexpand',
    'uniq',
    'unlink',
    'vdir',
    'wc',
    'yes',
  };

  /// Shell builtins implemented in Dart. These do not need a WASM module and
  /// do not increase the IPA size.
  static const Set<String> _builtinCommands = {
    'curl',
    'wget',
    'git',
    'jq',
    'yq',
    'env',
    'test',
    '[',
    'which',
    'command',
    'whoami',
    'xargs',
    'tr',
    'cd',
    'pwd',
    'export',
    'unset',
    'grep',
    'du',
    'stat',
    'tac',
    'expr',
    'id',
    'relpath',
    'diff',
    'patch',
  };

  /// Whether [command] can be resolved to a WASM applet or a builtin.
  bool _isCommandAvailable(String command) {
    return _coreutilsApplets.contains(command) ||
        const {
          'rg',
          'find',
          'sed',
          'awk',
          'tar',
          'gzip',
          'zip',
          'unzip',
          'python',
          'python3',
          'qjs',
          'js',
          'sqlite3',
        }.contains(command) ||
        _builtinCommands.contains(command);
  }

  /// Resolves a command to the module and the exact argv that selects it.
  ({WasmModule module, List<String> argv}) _resolve(String command) {
    if (_coreutilsApplets.contains(command)) {
      return (module: coreutils, argv: [command]);
    }
    return switch (command) {
      'rg' => (module: rg, argv: const ['rg']),
      'find' => (module: find, argv: const ['find']),
      'sed' => (module: sed, argv: const ['sed']),
      'awk' => (module: awk, argv: const ['awk']),
      'tar' => (module: tar, argv: const ['tar']),
      'gzip' => (module: gzip, argv: const ['gzip']),
      'zip' => (module: zip, argv: const ['zip']),
      'unzip' => (module: zip, argv: const ['zip_util']),
      'python' || 'python3' => (module: python, argv: const ['python']),
      'qjs' || 'js' => (module: qjs, argv: const ['qjs']),
      'sqlite3' => (module: sqlite3, argv: const ['sqlite3']),
      _ => (module: coreutils, argv: [command]),
    };
  }

  /// Dispatches a builtin command to its Dart implementation.
  Future<Result<StageResult, ExecutionError>> _runBuiltin({
    required Stage stage,
    required ShellExecOptions? options,
    required String? inputSource,
  }) async {
    return switch (stage.command) {
      'curl' => _curlBuiltin(stage, options),
      'wget' => _wgetBuiltin(stage, options),
      'git' => _gitBuiltin(stage, options),
      'jq' => _jqBuiltin(stage, inputSource),
      'yq' => _yqBuiltin(stage, inputSource),
      'env' => _envBuiltin(stage, options),
      'test' || '[' => _testBuiltin(stage),
      'which' => _whichBuiltin(stage),
      'command' => _commandBuiltin(stage),
      'whoami' => _whoamiBuiltin(),
      'xargs' => _xargsBuiltin(stage, options, inputSource),
      'tr' => _trBuiltin(stage, inputSource),
      'cd' => _cdBuiltin(stage, options),
      'pwd' => _pwdBuiltin(options),
      'export' => _exportBuiltin(stage),
      'unset' => _unsetBuiltin(stage),
      'grep' => _grepBuiltin(stage, options, inputSource),
      'du' => _duBuiltin(stage, options),
      'stat' => _statBuiltin(stage, options),
      'tac' => _tacBuiltin(stage, options, inputSource),
      'expr' => _exprBuiltin(stage),
      'id' => _idBuiltin(stage),
      'relpath' => _relpathBuiltin(stage, options),
      'diff' => _diffBuiltin(stage, options, inputSource),
      'patch' => _patchBuiltin(stage, options, inputSource),
      _ => Err(
        ExecutionError(
          ExecutionErrorCode.unknown,
          'Unknown builtin: ${stage.command}',
        ),
      ),
    };
  }

  /// Runs either a builtin command or a WASM stage with stdin/source handling.
  Future<Result<StageResult, ExecutionError>> _runCommand({
    required String command,
    required List<String> args,
    required ShellExecOptions? options,
    required String? inputSource,
    required bool captureStdout,
    required bool captureStderr,
  }) async {
    if (_builtinCommands.contains(command)) {
      return _runBuiltin(
        stage: Stage(command: command, args: args),
        options: options,
        inputSource: inputSource,
      );
    }
    final cwd = options?.cwd ?? _currentDir;
    final cwdArgs = _rewriteRelativeArgs(command, args, cwd);
    final effectiveArgs = inputSource != null && command != 'rg'
        ? [...cwdArgs, inputSource]
        : cwdArgs;
    return _runStage(
      command: command,
      args: effectiveArgs,
      options: options,
      captureStdout: captureStdout,
      captureStderr: captureStderr,
    );
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }

    late final ShellCommand parsed;
    try {
      parsed = parseCommandLine(command);
    } on ShellParseException catch (e) {
      return Err(ExecutionError(ExecutionErrorCode.unknown, 'parse error: $e'));
    }

    var exitCode = 0;
    for (var i = 0; i < parsed.statements.length; i++) {
      final statement = parsed.statements[i];
      if (statement.operator == StatementOperator.and && exitCode != 0) {
        continue;
      }
      if (statement.operator == StatementOperator.or && exitCode == 0) {
        continue;
      }

      final result = await _runPipeline(statement.pipeline, options);
      if (result.isErr) return Err(result.errorOrNull!);
      exitCode = result.valueOrNull!.exitCode;

      if (token != null && token.isCancelled) {
        return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
      }
    }

    return Ok(
      ShellExecResult(
        stdout: _lastStdout ?? '',
        stderr: _lastStderr ?? '',
        exitCode: exitCode,
      ),
    );
  }

  String? _lastStdout;
  String? _lastStderr;

  Future<Result<ShellExecResult, ExecutionError>> _runPipeline(
    Pipeline pipeline,
    ShellExecOptions? options,
  ) async {
    _lastStdout = '';
    _lastStderr = '';

    final tempFiles = <io.File>[];
    String? previousOutputFile;

    for (var i = 0; i < pipeline.stages.length; i++) {
      final stage = pipeline.stages[i];
      final isLast = i == pipeline.stages.length - 1;

      // Expand `$VAR` references at execution time so earlier statements in
      // the same command line (e.g. `export A=1 && echo $A`) are visible.
      final stageEnv = _effectiveEnv(options);
      final expandedStage = _expandStage(stage, stageEnv);

      String? stdoutFile;
      String? stderrFile;
      var appendStdout = false;
      var appendStderr = false;
      String? stdinFile;

      for (final redirect in expandedStage.redirects) {
        if (redirect.fd == 0 && redirect.kind == RedirectKind.read) {
          stdinFile = redirect.target;
        } else if (redirect.fd == 1 || redirect.fd == -1) {
          if (redirect.kind == RedirectKind.write) {
            stdoutFile = redirect.target;
            appendStdout = false;
          } else if (redirect.kind == RedirectKind.append) {
            stdoutFile = redirect.target;
            appendStdout = true;
          }
        } else if (redirect.fd == 2 || redirect.fd == -1) {
          if (redirect.kind == RedirectKind.write) {
            stderrFile = redirect.target;
            appendStderr = false;
          } else if (redirect.kind == RedirectKind.append) {
            stderrFile = redirect.target;
            appendStderr = true;
          }
        }
      }

      // Resolve input source for this stage.
      final inputSource = stdinFile != null
          ? _resolveSandboxPath(stdinFile, options?.cwd ?? _currentDir)
          : previousOutputFile;

      final result = await _runCommand(
        command: expandedStage.command,
        args: expandedStage.args,
        options: options,
        inputSource: inputSource,
        captureStdout: true,
        captureStderr: true,
      );
      if (result.isErr) {
        await _cleanup(tempFiles);
        return Err(result.errorOrNull!);
      }
      final data = result.valueOrNull!;
      _lastStageExitCode = data.exitCode;

      if (stdoutFile != null) {
        final file = _hostFile(
          _resolveSandboxPath(stdoutFile, options?.cwd ?? _currentDir),
        );
        await file.parent.create(recursive: true);
        if (appendStdout) {
          await file.writeAsBytes(data.stdout, mode: io.FileMode.append);
        } else {
          await file.writeAsBytes(data.stdout);
        }
        _lastStdout = '';
      } else {
        _lastStdout = utf8.decode(data.stdout, allowMalformed: true);
      }

      if (stderrFile != null) {
        final file = _hostFile(
          _resolveSandboxPath(stderrFile, options?.cwd ?? _currentDir),
        );
        await file.parent.create(recursive: true);
        if (appendStderr) {
          await file.writeAsBytes(data.stderr, mode: io.FileMode.append);
        } else {
          await file.writeAsBytes(data.stderr);
        }
      } else {
        _lastStderr = utf8.decode(data.stderr, allowMalformed: true);
      }

      if (!isLast) {
        final temp = _hostFile('.fah_pipe_$i');
        await temp.parent.create(recursive: true);
        await temp.writeAsBytes(data.stdout);
        tempFiles.add(temp);
        previousOutputFile = '/${temp.path.split('/').last}';
      }
    }

    await _cleanup(tempFiles);

    return Ok(
      ShellExecResult(
        stdout: _lastStdout ?? '',
        stderr: _lastStderr ?? '',
        exitCode: _lastStageExitCode ?? 0,
      ),
    );
  }

  Future<void> _cleanup(List<io.File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // ignore cleanup failures
      }
    }
  }

  int? _lastStageExitCode;

  io.File _hostFile(String sandboxPath) {
    final host = sandboxHostPath ?? '';
    final stripped = sandboxPath.startsWith('/')
        ? sandboxPath.substring(1)
        : sandboxPath;
    return io.File('$host/$stripped');
  }

  String _hostPath(String sandboxPath) {
    final host = sandboxHostPath ?? '';
    final stripped = sandboxPath.startsWith('/')
        ? sandboxPath.substring(1)
        : sandboxPath;
    return host.isEmpty ? stripped : '$host/$stripped';
  }

  /// Effective environment visible to WASM commands, builtins, and variable
  /// expansion: sandbox defaults, persistent `export`ed variables, and any
  /// per-call overrides (later wins).
  Map<String, String> _effectiveEnv(ShellExecOptions? options) {
    final cwd = options?.cwd ?? _currentDir;
    return <String, String>{
      'HOME': '/',
      'PATH': '/bin',
      'PWD': cwd,
      'SHELL': '/bin/sh',
      'TERM': 'dumb',
      'USER': io.Platform.environment['USER'] ?? 'fah',
      ..._shellEnv,
      ...?options?.env,
    };
  }

  /// Normalizes a sandbox path: collapses `.` and `..` segments and always
  /// returns an absolute path starting at the sandbox root `/`.
  String _normalizeSandboxPath(String path) {
    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return '/${segments.join('/')}';
  }

  /// Resolves [path] against [cwd] inside the sandbox, returning an absolute
  /// sandbox path.
  String _resolveSandboxPath(String path, String cwd) {
    if (path.startsWith('/')) return _normalizeSandboxPath(path);
    return _normalizeSandboxPath('$cwd/$path');
  }

  /// Expands `$NAME` and `${NAME}` references in [input] using [env]. Unknown
  /// variables expand to the empty string; other `$` forms are kept literal.
  String _expandVars(String input, Map<String, String> env) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < input.length) {
      final ch = input[i];
      if (ch != '\$') {
        buffer.write(ch);
        i++;
        continue;
      }
      if (i + 1 >= input.length) {
        buffer.write('\$');
        i++;
        continue;
      }
      final next = input[i + 1];
      if (next == '{') {
        final end = input.indexOf('}', i + 2);
        if (end == -1) {
          buffer.write('\${');
          i += 2;
          continue;
        }
        buffer.write(env[input.substring(i + 2, end)] ?? '');
        i = end + 1;
        continue;
      }
      final code = next.codeUnitAt(0);
      final isVarStart =
          (code >= 65 && code <= 90) ||
          (code >= 97 && code <= 122) ||
          code == 95;
      if (!isVarStart) {
        buffer.write('\$');
        i++;
        continue;
      }
      var j = i + 1;
      while (j < input.length) {
        final c = input.codeUnitAt(j);
        final isVarChar =
            (c >= 65 && c <= 90) ||
            (c >= 97 && c <= 122) ||
            (c >= 48 && c <= 57) ||
            c == 95;
        if (!isVarChar) break;
        j++;
      }
      buffer.write(env[input.substring(i + 1, j)] ?? '');
      i = j;
    }
    return buffer.toString();
  }

  /// Applies `$VAR` expansion to a parsed [stage] using [env], honoring the
  /// per-word `expandable` flags set by the parser for single quotes and
  /// `\$` escapes.
  Stage _expandStage(Stage stage, Map<String, String> env) {
    final expandedCommand = stage.isExpandable(0)
        ? _expandVars(stage.command, env)
        : stage.command;
    final expandedArgs = <String>[
      for (var k = 0; k < stage.args.length; k++)
        stage.isExpandable(k + 1)
            ? _expandVars(stage.args[k], env)
            : stage.args[k],
    ];
    final expandedRedirects = <Redirect>[
      for (final redirect in stage.redirects)
        Redirect(
          kind: redirect.kind,
          fd: redirect.fd,
          target: redirect.expandable
              ? _expandVars(redirect.target, env)
              : redirect.target,
        ),
    ];
    return Stage(
      command: expandedCommand,
      args: expandedArgs,
      redirects: expandedRedirects,
    );
  }

  /// Commands whose positional arguments are file paths and therefore get
  /// rewritten relative to the shell's current directory.
  static const Set<String> _pathPositionalCommands = {
    'basename',
    'cat',
    'cksum',
    'comm',
    'cp',
    'csplit',
    'cut',
    'dir',
    'dirname',
    'du',
    'expand',
    'fmt',
    'fold',
    'gzip',
    'head',
    'install',
    'join',
    'link',
    'ln',
    'ls',
    'md5sum',
    'mkdir',
    'mv',
    'nl',
    'od',
    'paste',
    'readlink',
    'realpath',
    'relpath',
    'rm',
    'rmdir',
    'sha1sum',
    'sha224sum',
    'sha256sum',
    'sha384sum',
    'sha512sum',
    'b2sum',
    'shred',
    'sort',
    'split',
    'stat',
    'sum',
    'tac',
    'tail',
    'tar',
    'tee',
    'touch',
    'truncate',
    'tsort',
    'unexpand',
    'uniq',
    'unlink',
    'vdir',
    'wc',
  };

  /// Flags whose following argument is NOT a path, per command. Used by
  /// [_rewriteRelativeArgs] to avoid rewriting flag values.
  static const Map<String, Set<String>> _nonPathFlagValues = {
    'cut': {'-b', '-c', '-d', '-f'},
    'head': {'-c', '-n'},
    'join': {'-1', '-2', '-e', '-t'},
    'rg': {'-A', '-B', '-C', '-e', '-g', '-m', '-t', '-T'},
    'sort': {'-k', '-t'},
    'split': {'-a', '-b', '-l', '-n'},
    'tail': {'-c', '-n'},
    'find': {'-iname', '-mmin', '-mtime', '-name', '-size', '-type'},
    'mktemp': {'-t'},
  };

  /// Rewrites relative path arguments to absolute sandbox paths based on
  /// [cwd]. The WASI guest is rooted at `/`, so `cat file.txt` run after
  /// `cd /work` would otherwise look for `/file.txt`.
  List<String> _rewriteRelativeArgs(
    String command,
    List<String> args,
    String cwd,
  ) {
    if (command == 'dd') {
      return [for (final arg in args) _rewriteDdArg(arg, cwd)];
    }
    final skipFlags = _nonPathFlagValues[command] ?? const <String>{};
    final result = <String>[];
    var positionalIndex = 0;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('-') && arg != '-') {
        result.add(arg);
        continue;
      }
      if (i > 0 && skipFlags.contains(args[i - 1])) {
        result.add(arg);
        continue;
      }
      positionalIndex++;
      // sed/awk: the first positional argument is the script, not a path.
      if ((command == 'sed' || command == 'awk') && positionalIndex == 1) {
        result.add(arg);
        continue;
      }
      result.add(_maybeRewritePath(command, arg, cwd));
    }
    return result;
  }

  String _rewriteDdArg(String arg, String cwd) {
    final idx = arg.indexOf('=');
    if (idx <= 0) return arg;
    final key = arg.substring(0, idx);
    if (key != 'if' && key != 'of') return arg;
    final value = arg.substring(idx + 1);
    if (value.isEmpty || value.startsWith('/')) return arg;
    return '$key=${_resolveSandboxPath(value, cwd)}';
  }

  String _maybeRewritePath(String command, String arg, String cwd) {
    if (arg.isEmpty || arg == '-') return arg;
    if (arg.startsWith('/')) return arg;
    if (arg.startsWith('./') || arg.startsWith('../') || arg.contains('/')) {
      return _resolveSandboxPath(arg, cwd);
    }
    if (_pathPositionalCommands.contains(command)) {
      return _resolveSandboxPath(arg, cwd);
    }
    // Heuristic for commands with mixed argument kinds (e.g. rg): rewrite a
    // bare word only when it names an existing file or directory.
    final resolved = _resolveSandboxPath(arg, cwd);
    if (io.FileSystemEntity.typeSync(_hostPath(resolved)) !=
        io.FileSystemEntityType.notFound) {
      return resolved;
    }
    return arg;
  }

  Future<Result<StageResult, ExecutionError>> _runStage({
    required String command,
    required List<String> args,
    required ShellExecOptions? options,
    required bool captureStdout,
    required bool captureStderr,
  }) async {
    final resolved = _resolve(command);
    final module = resolved.module;
    final argv = [...resolved.argv, ...args];

    if (module == python) {
      try {
        await _ensurePythonStdlib();
      } on Object catch (e) {
        return Err(
          ExecutionError(
            ExecutionErrorCode.unknown,
            'python stdlib setup failed: $e',
          ),
        );
      }
    }

    final env = _effectiveEnv(options);

    final preopenedDirs = <PreopenedDir>[];
    final hostSandbox = sandboxHostPath;
    if (hostSandbox != null && hostSandbox.isNotEmpty) {
      preopenedDirs.add(
        PreopenedDir(wasmGuestPath: '/', hostPath: hostSandbox),
      );
    }

    final builder = module.builder(
      wasiConfig: WasiConfig(
        args: argv,
        env: env.entries
            .map((e) => EnvVariable(name: e.key, value: e.value))
            .toList(),
        preopenedDirs: preopenedDirs,
        webBrowserFileSystem: const <String, WasiDirectory>{},
        captureStdout: captureStdout,
        captureStderr: captureStderr,
        inheritStdin: false,
        inheritEnv: false,
        inheritArgs: false,
      ),
    );

    debugPrint('[wasm_shell] building instance for $command...');
    late WasmInstance instance;
    try {
      instance = await builder.build();
    } on Object catch (error) {
      debugPrint('[wasm_shell] build failed: $error');
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          'Failed to build WASM instance: $error',
          cause: error,
        ),
      );
    }
    debugPrint('[wasm_shell] instance built, subscribing to stdio...');

    final stdoutBuffer = <int>[];
    final stderrBuffer = <int>[];
    ExecutionError? callbackError;

    void collect(
      List<int> target,
      Uint8List chunk,
      void Function(String)? callback,
    ) {
      target.addAll(chunk);
      if (callback == null) return;
      try {
        callback(utf8.decode(chunk, allowMalformed: true));
      } on Object catch (error) {
        callbackError ??= ExecutionError(
          ExecutionErrorCode.callbackError,
          error.toString(),
          cause: error,
        );
      }
    }

    final stdoutSub = captureStdout
        ? instance.stdout.listen((chunk) {
            debugPrint('[wasm_shell] stdout chunk: ${chunk.length} bytes');
            collect(stdoutBuffer, chunk, options?.onStdout);
          }, onDone: () => debugPrint('[wasm_shell] stdout done'))
        : null;
    final stderrSub = captureStderr
        ? instance.stderr.listen((chunk) {
            debugPrint('[wasm_shell] stderr chunk: ${chunk.length} bytes');
            collect(stderrBuffer, chunk, options?.onStderr);
          }, onDone: () => debugPrint('[wasm_shell] stderr done'))
        : null;

    final timeout = options?.timeout ?? const Duration(seconds: 30);
    debugPrint('[wasm_shell] starting _start with timeout $timeout...');
    var timedOut = false;
    final timeoutFuture = Future<void>.delayed(timeout, () => timedOut = true);

    Object? runError;
    final runCompleter = Completer<void>();
    try {
      Future<void>(() async {
        try {
          await instance.runWasiStartAsync();
          debugPrint('[wasm_shell] _start completed');
        } on Object catch (e) {
          debugPrint('[wasm_shell] _start error: $e');
          runError = e;
        } finally {
          if (!runCompleter.isCompleted) runCompleter.complete();
        }
      });
      await Future.any<void>([runCompleter.future, timeoutFuture]);
    } finally {
      debugPrint('[wasm_shell] cancelling stdio subscriptions...');
      await stdoutSub?.cancel();
      await stderrSub?.cancel();
      instance.dispose();
    }

    debugPrint('[wasm_shell] run finished timedOut=$timedOut error=$runError');
    if (callbackError != null) return Err(callbackError!);
    if (timedOut) {
      return Err(
        ExecutionError(ExecutionErrorCode.timeout, 'timeout: $timeout'),
      );
    }

    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }

    final exitCode = _parseExitCode(runError);
    _lastStageExitCode = exitCode;

    // If we could not determine an exit code and the process produced no
    // output, surface the raw trap as an unknown error.
    if (exitCode == null) {
      if (stdoutBuffer.isEmpty && stderrBuffer.isEmpty) {
        return Err(
          ExecutionError(
            ExecutionErrorCode.unknown,
            runError.toString(),
            cause: runError,
          ),
        );
      }
      _lastStageExitCode = 1;
    }

    return Ok(
      StageResult(
        stdout: stdoutBuffer,
        stderr: stderrBuffer,
        exitCode: _lastStageExitCode ?? 0,
      ),
    );
  }

  /// Parses the exit code from a wasmtime I32Exit trap.
  ///
  /// Returns `null` when [error] cannot be parsed as a normal WASI exit.
  int? _parseExitCode(Object? error) {
    if (error == null) return 0;
    final message = error.toString();

    // wasmtime represents `proc_exit(n)` as `I32Exit(n)`. Older versions use
    // "i32 exit with value N", newer versions wrap it as
    // "Exited with i32 exit status N".
    final i32Match = RegExp(
      r'i32\s+(?:exit\s+with\s+value|exit\s+status)\s*(\d+)',
    ).firstMatch(message);
    if (i32Match != null) {
      return int.tryParse(i32Match.group(1)!);
    }

    // wasmtime 14 with the wasi command adapter can report an invalid exit
    // status; treat that as a non-zero failure.
    if (message.contains('exit with invalid exit status')) {
      return 1;
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Builtin command implementations
  // ---------------------------------------------------------------------------

  Future<Result<StageResult, ExecutionError>> _testBuiltin(Stage stage) async {
    final rawArgs = stage.args.toList();
    if (stage.command == '[') {
      if (rawArgs.isEmpty || rawArgs.last != ']') {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode('[[: missing `]]\n'),
            exitCode: 2,
          ),
        );
      }
      rawArgs.removeLast();
    }
    if (rawArgs.isEmpty) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('test: missing expression\n'),
          exitCode: 2,
        ),
      );
    }
    try {
      final evaluator = _TestEvaluator(
        fileExists: (path) async {
          try {
            return await io.File(
              _hostFile(_resolveSandboxPath(path, _currentDir)).path,
            ).exists();
          } on Object {
            return false;
          }
        },
        dirExists: (path) async {
          try {
            return await io.Directory(
              _hostFile(_resolveSandboxPath(path, _currentDir)).path,
            ).exists();
          } on Object {
            return false;
          }
        },
        fileSize: (path) async {
          try {
            return await io.File(
              _hostFile(_resolveSandboxPath(path, _currentDir)).path,
            ).length();
          } on Object {
            return 0;
          }
        },
      );
      final value = await evaluator.evaluate(rawArgs);
      return Ok(
        StageResult(
          stdout: const [],
          stderr: const [],
          exitCode: value ? 0 : 1,
        ),
      );
    } on _TestError catch (e) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('test: ${e.message}\n'),
          exitCode: 2,
        ),
      );
    } on FormatException catch (e) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('test: integer expected: $e\n'),
          exitCode: 2,
        ),
      );
    }
  }

  Future<Result<StageResult, ExecutionError>> _whichBuiltin(Stage stage) async {
    if (stage.args.isEmpty) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('which: missing argument\n'),
          exitCode: 1,
        ),
      );
    }
    final name = stage.args.first;
    if (_isCommandAvailable(name)) {
      return Ok(
        StageResult(
          stdout: utf8.encode('/bin/$name\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }
    return Ok(
      StageResult(
        stdout: const [],
        stderr: utf8.encode('which: $name: not found\n'),
        exitCode: 1,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _commandBuiltin(
    Stage stage,
  ) async {
    if (stage.args.length >= 2 && stage.args[0] == '-v') {
      final name = stage.args[1];
      if (_isCommandAvailable(name)) {
        return Ok(
          StageResult(
            stdout: utf8.encode('/bin/$name\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('command: $name: not found\n'),
          exitCode: 1,
        ),
      );
    }
    return Ok(
      StageResult(
        stdout: const [],
        stderr: utf8.encode('command: unsupported usage\n'),
        exitCode: 1,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _envBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final env = _effectiveEnv(options);

    final assignments = <String, String>{};
    final remaining = <String>[];
    for (final arg in stage.args) {
      final idx = arg.indexOf('=');
      if (idx > 0 && !arg.startsWith('-')) {
        assignments[arg.substring(0, idx)] = arg.substring(idx + 1);
      } else {
        remaining.add(arg);
      }
    }

    if (remaining.isNotEmpty) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode(
            "env: '${remaining.first}': No such file or directory\n",
          ),
          exitCode: 127,
        ),
      );
    }

    final merged = <String, String>{...env, ...assignments};
    final lines = merged.entries.map((e) => '${e.key}=${e.value}').toList()
      ..sort();
    return Ok(
      StageResult(
        stdout: utf8.encode(lines.join('\n') + (lines.isNotEmpty ? '\n' : '')),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  /// Wires the shared [SandboxBuiltins] to the sandbox host filesystem,
  /// resolving paths against [cwd].
  SandboxBuiltins _sandboxBuiltins(String cwd) {
    return SandboxBuiltins(
      httpClient: _httpClient,
      readTextFile: (path) async {
        final file = _hostFile(_resolveSandboxPath(path, cwd));
        if (!await file.exists()) return null;
        return file.readAsString();
      },
      writeBinaryFile: (path, bytes) async {
        final file = _hostFile(_resolveSandboxPath(path, cwd));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      },
    );
  }

  Ok<StageResult, ExecutionError> _builtinOk(SandboxBuiltinResult result) {
    return Ok(
      StageResult(
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _curlBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final result = await _sandboxBuiltins(
      options?.cwd ?? _currentDir,
    ).curl(stage.args, timeout: options?.timeout);
    return _builtinOk(result);
  }

  Future<Result<StageResult, ExecutionError>> _jqBuiltin(
    Stage stage,
    String? inputSource,
  ) async {
    final result = await _sandboxBuiltins(
      _currentDir,
    ).jq(stage.args, stdin: await _stdinFromSource(stage, inputSource));
    return _builtinOk(result);
  }

  Future<Result<StageResult, ExecutionError>> _yqBuiltin(
    Stage stage,
    String? inputSource,
  ) async {
    final result = await _sandboxBuiltins(
      _currentDir,
    ).yq(stage.args, stdin: await _stdinFromSource(stage, inputSource));
    return _builtinOk(result);
  }

  Future<Result<StageResult, ExecutionError>> _diffBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final builtins = _sandboxBuiltins(options?.cwd ?? _currentDir);
    // Only a `-` operand reads the piped/redirected input; plain
    // `diff a b` ignores stdin like GNU diff.
    final stdin = stage.args.contains('-') && inputSource != null
        ? await builtins.readTextFile(inputSource)
        : null;
    final result = await builtins.diff(stage.args, stdin: stdin);
    return _builtinOk(result);
  }

  Future<Result<StageResult, ExecutionError>> _patchBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final builtins = _sandboxBuiltins(options?.cwd ?? _currentDir);
    final stdin = inputSource != null
        ? await builtins.readTextFile(inputSource)
        : null;
    final result = await builtins.patch(stage.args, stdin: stdin);
    return _builtinOk(result);
  }

  /// Reads the piped/redirected input for jq/yq when no file argument is
  /// given; [inputSource] is an absolute sandbox path (pipe temp file).
  Future<String?> _stdinFromSource(Stage stage, String? inputSource) async {
    if (stage.args.length > 1 || inputSource == null) return null;
    final file = _hostFile(_resolveSandboxPath(inputSource, _currentDir));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<Result<StageResult, ExecutionError>> _whoamiBuiltin() async {
    final user =
        io.Platform.environment['USER'] ??
        io.Platform.environment['USERNAME'] ??
        'fah';
    return Ok(
      StageResult(
        stdout: utf8.encode('$user\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _cdBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final target = stage.args.isEmpty ? '/' : stage.args.first;
    final cwd = options?.cwd ?? _currentDir;
    final resolved = _resolveSandboxPath(target, cwd);
    try {
      final dir = io.Directory(_hostPath(resolved));
      if (!dir.existsSync()) {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode('cd: $target: No such file or directory\n'),
            exitCode: 1,
          ),
        );
      }
      _currentDir = resolved;
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    } on Object catch (e) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('cd: $target: $e\n'),
          exitCode: 1,
        ),
      );
    }
  }

  Future<Result<StageResult, ExecutionError>> _pwdBuiltin(
    ShellExecOptions? options,
  ) async {
    final cwd = options?.cwd ?? _currentDir;
    return Ok(
      StageResult(stdout: utf8.encode('$cwd\n'), stderr: const [], exitCode: 0),
    );
  }

  Future<Result<StageResult, ExecutionError>> _exportBuiltin(
    Stage stage,
  ) async {
    if (stage.args.isEmpty) {
      final names = _shellEnv.keys.toList()..sort();
      final lines = names
          .map((n) => 'declare -x $n="${_shellEnv[n]}"')
          .toList();
      return Ok(
        StageResult(
          stdout: utf8.encode(lines.isEmpty ? '' : '${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }
    for (final arg in stage.args) {
      final idx = arg.indexOf('=');
      if (idx > 0) {
        _shellEnv[arg.substring(0, idx)] = arg.substring(idx + 1);
      } else {
        _shellEnv.putIfAbsent(arg, () => '');
      }
    }
    return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
  }

  Future<Result<StageResult, ExecutionError>> _unsetBuiltin(Stage stage) async {
    for (final arg in stage.args) {
      _shellEnv.remove(arg);
    }
    return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
  }

  Future<Result<StageResult, ExecutionError>> _grepBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final flags = <String>[];
    String? pattern;
    final files = <String>[];
    var quiet = false;

    for (var i = 0; i < stage.args.length; i++) {
      final arg = stage.args[i];
      if (arg == '--') continue;
      if (arg == '-e') {
        if (i + 1 >= stage.args.length) {
          return Ok(
            StageResult(
              stdout: const [],
              stderr: utf8.encode('grep: option requires an argument -- e\n'),
              exitCode: 2,
            ),
          );
        }
        pattern = stage.args[++i];
        continue;
      }
      if (arg == '-q' || arg == '--quiet' || arg == '--silent') {
        quiet = true;
        continue;
      }
      if (arg == '-r' || arg == '-R' || arg == '-E') {
        // rg searches recursively and uses regex syntax by default.
        continue;
      }
      if (arg == '-i' ||
          arg == '-v' ||
          arg == '-w' ||
          arg == '-x' ||
          arg == '-F' ||
          arg == '-n' ||
          arg == '-c' ||
          arg == '-l') {
        flags.add(arg);
        continue;
      }
      if (arg.startsWith('-m')) {
        flags.add(arg);
        if (arg == '-m' && i + 1 < stage.args.length) {
          flags.add(stage.args[++i]);
        }
        continue;
      }
      if (pattern == null) {
        pattern = arg;
      } else {
        files.add(arg);
      }
    }

    if (pattern == null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode(
            'usage: grep [-ivwxFcclnq] [-m N] pattern [file...]\n',
          ),
          exitCode: 2,
        ),
      );
    }
    if (files.isEmpty && inputSource != null) {
      files.add(inputSource);
    }
    final cwd = options?.cwd ?? _currentDir;
    final rewrittenFiles = [
      for (final file in files) _maybeRewritePath('rg', file, cwd),
    ];

    final rgResult = await _runStage(
      command: 'rg',
      args: [...flags, '-e', pattern, ...rewrittenFiles],
      options: options,
      captureStdout: true,
      captureStderr: true,
    );
    if (rgResult.isErr) return rgResult;
    final data = rgResult.valueOrNull!;
    return Ok(
      StageResult(
        stdout: quiet ? const [] : data.stdout,
        stderr: data.stderr,
        exitCode: data.exitCode,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _wgetBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final result = await _sandboxBuiltins(
      options?.cwd ?? _currentDir,
    ).wget(stage.args, timeout: options?.timeout);
    return _builtinOk(result);
  }

  Future<Result<StageResult, ExecutionError>> _duBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    var human = false;
    var summarize = false;
    final paths = <String>[];
    for (final arg in stage.args) {
      if (arg == '-h' || arg == '--human-readable') {
        human = true;
      } else if (arg == '-s' || arg == '--summarize') {
        summarize = true;
      } else if (!arg.startsWith('-')) {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('.');

    final cwd = options?.cwd ?? _currentDir;
    final lines = <String>[];
    for (final path in paths) {
      final resolved = _resolveSandboxPath(path, cwd);
      final host = _hostPath(resolved);
      final type = io.FileSystemEntity.typeSync(host);
      if (type == io.FileSystemEntityType.notFound) {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode('du: $path: No such file or directory\n'),
            exitCode: 1,
          ),
        );
      }
      final bytes = await _duSize(host, recursive: !summarize);
      final size = human
          ? _formatHumanSize(bytes)
          : '${(bytes + 1023) ~/ 1024}';
      lines.add('$size\t$resolved');
    }
    return Ok(
      StageResult(
        stdout: utf8.encode('${lines.join('\n')}\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<int> _duSize(String hostPath, {required bool recursive}) async {
    final type = io.FileSystemEntity.typeSync(hostPath);
    if (type == io.FileSystemEntityType.file) {
      return io.File(hostPath).length();
    }
    if (type != io.FileSystemEntityType.directory) return 0;
    if (!recursive) {
      // Non-recursive du still counts the directory itself only.
      return 4096;
    }
    var total = 0;
    try {
      await for (final entity in io.Directory(
        hostPath,
      ).list(recursive: true, followLinks: false)) {
        if (entity is io.File) {
          try {
            total += await entity.length();
          } on Object {
            // Skip unreadable files.
          }
        }
      }
    } on Object {
      // Skip unreadable directories.
    }
    return total;
  }

  String _formatHumanSize(int bytes) {
    const units = ['B', 'K', 'M', 'G', 'T'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final text = size >= 10 || unit == 0
        ? size.round().toString()
        : size.toStringAsFixed(1);
    return '$text${units[unit]}';
  }

  Future<Result<StageResult, ExecutionError>> _statBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    String? format;
    final files = <String>[];
    for (var i = 0; i < stage.args.length; i++) {
      final arg = stage.args[i];
      if (arg == '-c' || arg == '--format') {
        if (i + 1 >= stage.args.length) {
          return Ok(
            StageResult(
              stdout: const [],
              stderr: utf8.encode('stat: option requires an argument -- c\n'),
              exitCode: 1,
            ),
          );
        }
        format = stage.args[++i];
      } else if (arg.startsWith('--format=')) {
        format = arg.substring('--format='.length);
      } else if (!arg.startsWith('-')) {
        files.add(arg);
      }
    }
    if (files.isEmpty) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('stat: missing operand\n'),
          exitCode: 1,
        ),
      );
    }

    final cwd = options?.cwd ?? _currentDir;
    final out = StringBuffer();
    for (final file in files) {
      final resolved = _resolveSandboxPath(file, cwd);
      io.FileStat stat;
      try {
        stat = await io.FileStat.stat(_hostPath(resolved));
      } on Object {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode(
              'stat: cannot stat \'$file\': No such file or directory\n',
            ),
            exitCode: 1,
          ),
        );
      }
      if (stat.type == io.FileSystemEntityType.notFound) {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode(
              'stat: cannot stat \'$file\': No such file or directory\n',
            ),
            exitCode: 1,
          ),
        );
      }

      if (format != null) {
        final rendered = format
            .replaceAll('%s', '${stat.size}')
            .replaceAll('%n', resolved)
            .replaceAll('%F', _statTypeName(stat.type))
            .replaceAll('%Y', '${stat.modified.millisecondsSinceEpoch ~/ 1000}')
            .replaceAll('%y', stat.modified.toIso8601String());
        out.write('$rendered\n');
        continue;
      }

      out
        ..write('  File: $resolved\n')
        ..write('  Size: ${stat.size}\n')
        ..write('  Type: ${_statTypeName(stat.type)}\n')
        ..write('Modify: ${stat.modified.toIso8601String()}\n')
        ..write('Change: ${stat.changed.toIso8601String()}\n');
    }
    return Ok(
      StageResult(
        stdout: utf8.encode(out.toString()),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  String _statTypeName(io.FileSystemEntityType type) {
    return switch (type) {
      io.FileSystemEntityType.file => 'regular file',
      io.FileSystemEntityType.directory => 'directory',
      io.FileSystemEntityType.link => 'symbolic link',
      _ => 'unknown',
    };
  }

  Future<Result<StageResult, ExecutionError>> _tacBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final cwd = options?.cwd ?? _currentDir;
    final files = <String>[
      for (final arg in stage.args)
        if (!arg.startsWith('-')) arg,
    ];
    if (files.isEmpty && inputSource != null) files.add(inputSource);
    if (files.isEmpty) {
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    }

    final out = StringBuffer();
    for (final file in files) {
      final resolved = _resolveSandboxPath(file, cwd);
      final hostFile = io.File(_hostPath(resolved));
      if (!hostFile.existsSync()) {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode('tac: $file: No such file or directory\n'),
            exitCode: 1,
          ),
        );
      }
      final content = await hostFile.readAsString();
      final hadTrailingNewline = content.endsWith('\n');
      final lines = content.split('\n');
      if (hadTrailingNewline) lines.removeLast();
      final reversed = lines.reversed.join('\n');
      out.write(reversed);
      if (hadTrailingNewline || reversed.isNotEmpty) out.write('\n');
    }
    return Ok(
      StageResult(
        stdout: utf8.encode(out.toString()),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _exprBuiltin(Stage stage) async {
    try {
      final value = _evalExpr(stage.args);
      // GNU expr: exit status is 1 when the result is 0 or the empty string.
      final exitCode = value == '0' || value.isEmpty ? 1 : 0;
      return Ok(
        StageResult(
          stdout: utf8.encode('$value\n'),
          stderr: const [],
          exitCode: exitCode,
        ),
      );
    } on FormatException catch (e) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('expr: ${e.message}\n'),
          exitCode: 2,
        ),
      );
    }
  }

  String _evalExpr(List<String> args) {
    if (args.isEmpty) throw const FormatException('missing operand');

    // String functions: length, substr.
    if (args[0] == 'length') {
      if (args.length != 2) throw const FormatException('syntax error');
      return '${args[1].length}';
    }
    if (args[0] == 'substr') {
      if (args.length != 4) throw const FormatException('syntax error');
      final str = args[1];
      final pos = int.tryParse(args[2]);
      final len = int.tryParse(args[3]);
      if (pos == null || len == null) {
        throw const FormatException('non-numeric argument');
      }
      final start = (pos - 1).clamp(0, str.length);
      final end = (start + len).clamp(0, str.length);
      return str.substring(start, end);
    }

    // Integer arithmetic / comparisons with precedence climbing.
    var pos = 0;
    int peek() => pos < args.length ? 0 : -1;

    int parseValue() {
      if (pos >= args.length) throw const FormatException('syntax error');
      final value = int.tryParse(args[pos]);
      if (value == null) {
        throw FormatException('non-integer argument: ${args[pos]}');
      }
      pos++;
      return value;
    }

    int parseTerm() {
      var value = parseValue();
      while (pos < args.length &&
          (args[pos] == '*' || args[pos] == '/' || args[pos] == '%')) {
        final op = args[pos++];
        final rhs = parseValue();
        if (op == '*') value *= rhs;
        if (op == '/') {
          if (rhs == 0) throw const FormatException('division by zero');
          value ~/= rhs;
        }
        if (op == '%') {
          if (rhs == 0) throw const FormatException('division by zero');
          value %= rhs;
        }
      }
      return value;
    }

    int parseSum() {
      var value = parseTerm();
      while (pos < args.length && (args[pos] == '+' || args[pos] == '-')) {
        final op = args[pos++];
        final rhs = parseTerm();
        if (op == '+') value += rhs;
        if (op == '-') value -= rhs;
      }
      return value;
    }

    final left = parseSum();
    if (peek() == -1) return '$left';
    if (pos < args.length) {
      const comparisons = {'=', '!=', '<', '<=', '>', '>='};
      final op = args[pos++];
      if (!comparisons.contains(op)) {
        throw FormatException('syntax error: $op');
      }
      final right = parseSum();
      if (pos != args.length) throw const FormatException('syntax error');
      final result = switch (op) {
        '=' => left == right,
        '!=' => left != right,
        '<' => left < right,
        '<=' => left <= right,
        '>' => left > right,
        '>=' => left >= right,
        _ => false,
      };
      return result ? '1' : '0';
    }
    return '$left';
  }

  Future<Result<StageResult, ExecutionError>> _idBuiltin(Stage stage) async {
    const user = 'fah';
    if (stage.args.contains('-u')) {
      final name = stage.args.contains('-n') ? user : '0';
      return Ok(
        StageResult(
          stdout: utf8.encode('$name\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }
    if (stage.args.contains('-g')) {
      final name = stage.args.contains('-n') ? user : '0';
      return Ok(
        StageResult(
          stdout: utf8.encode('$name\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }
    return Ok(
      StageResult(
        stdout: utf8.encode('uid=0($user) gid=0($user) groups=0($user)\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _relpathBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final paths = <String>[
      for (final arg in stage.args)
        if (!arg.startsWith('-')) arg,
    ];
    if (paths.isEmpty) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('relpath: missing operand\n'),
          exitCode: 1,
        ),
      );
    }
    final cwd = options?.cwd ?? _currentDir;
    final from = _resolveSandboxPath(paths[0], cwd);
    final start = paths.length > 1 ? _resolveSandboxPath(paths[1], cwd) : cwd;
    final relative = p.relative(
      from == '/' ? '/' : from.substring(1),
      from: start == '/' ? '/' : start.substring(1),
    );
    return Ok(
      StageResult(
        stdout: utf8.encode('$relative\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<StageResult, ExecutionError>> _trBuiltin(
    Stage stage,
    String? inputSource,
  ) async {
    if (inputSource == null) {
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    }
    final file = _hostFile(inputSource);
    if (!await file.exists()) {
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    }

    var delete = false;
    String? set1;
    String? set2;
    for (final arg in stage.args) {
      if (arg == '-d') {
        delete = true;
      } else if (set1 == null) {
        set1 = arg;
      } else {
        set2 ??= arg;
      }
    }

    if (set1 == null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('tr: missing operand\n'),
          exitCode: 2,
        ),
      );
    }
    if (!delete && set2 == null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('tr: missing operand after "$set1"\n'),
          exitCode: 2,
        ),
      );
    }

    final input = await file.readAsString();
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

    return Ok(
      StageResult(stdout: utf8.encode(output), stderr: const [], exitCode: 0),
    );
  }

  /// Expands POSIX character classes (`[:lower:]`) and ranges (`a-z`) used by
  /// the `tr` builtin.
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

  Future<Result<StageResult, ExecutionError>> _xargsBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    if (inputSource == null) {
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    }
    final file = _hostFile(inputSource);
    if (!await file.exists()) {
      return Ok(const StageResult(stdout: [], stderr: [], exitCode: 0));
    }
    final lines = await file.readAsLines();

    String? placeholder;
    var commandIndex = 0;
    for (var i = 0; i < stage.args.length; i++) {
      final arg = stage.args[i];
      if (arg.startsWith('-I')) {
        placeholder = arg.length > 2
            ? arg.substring(2)
            : (i + 1 < stage.args.length ? stage.args[++i] : null);
        if (placeholder == null || placeholder.isEmpty) placeholder = '{}';
        commandIndex = i + 1;
        continue;
      }
      if (arg.startsWith('-')) {
        commandIndex = i + 1;
        continue;
      }
      commandIndex = i;
      break;
    }

    if (commandIndex >= stage.args.length) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('xargs: missing command\n'),
          exitCode: 1,
        ),
      );
    }

    final command = stage.args[commandIndex];
    final initialArgs = stage.args.sublist(commandIndex + 1);

    final stdout = <int>[];
    final stderr = <int>[];
    var exitCode = 0;

    if (placeholder != null) {
      final ph = placeholder;
      for (final line in lines) {
        final args = initialArgs.map((a) => a.replaceAll(ph, line)).toList();
        final result = await _runCommand(
          command: command,
          args: args,
          options: options,
          inputSource: null,
          captureStdout: true,
          captureStderr: true,
        );
        if (result.isErr) return result;
        final data = result.valueOrNull!;
        stdout.addAll(data.stdout);
        stderr.addAll(data.stderr);
        if (data.exitCode != 0) exitCode = data.exitCode;
      }
    } else {
      final allArgs = [...initialArgs, ...lines];
      final result = await _runCommand(
        command: command,
        args: allArgs,
        options: options,
        inputSource: null,
        captureStdout: true,
        captureStderr: true,
      );
      if (result.isErr) return result;
      final data = result.valueOrNull!;
      stdout.addAll(data.stdout);
      stderr.addAll(data.stderr);
      exitCode = data.exitCode;
    }

    return Ok(StageResult(stdout: stdout, stderr: stderr, exitCode: exitCode));
  }
}

/// Error thrown by [_TestEvaluator] for malformed `test` expressions.
final class _TestError implements Exception {
  _TestError(this.message);
  final String message;
}

/// Minimal evaluator for POSIX `test`/`[` expressions.
final class _TestEvaluator {
  _TestEvaluator({
    required this.fileExists,
    required this.dirExists,
    required this.fileSize,
  });

  final Future<bool> Function(String path) fileExists;
  final Future<bool> Function(String path) dirExists;
  final Future<int> Function(String path) fileSize;

  late List<String> _args;
  int _pos = 0;

  Future<bool> evaluate(List<String> args) async {
    _args = args;
    _pos = 0;
    return _parseOr();
  }

  String? get _peek => _pos < _args.length ? _args[_pos] : null;

  String _advance() {
    final token = _args[_pos];
    _pos++;
    return token;
  }

  Future<bool> _parseOr() async {
    var result = await _parseAnd();
    while (_peek == '-o') {
      _advance();
      result = result || await _parseAnd();
    }
    return result;
  }

  Future<bool> _parseAnd() async {
    var result = await _parseUnary();
    while (_peek == '-a') {
      _advance();
      result = result && await _parseUnary();
    }
    return result;
  }

  Future<bool> _parseUnary() async {
    if (_peek == '!') {
      _advance();
      return !(await _parseUnary());
    }
    return _parsePrimary();
  }

  Future<bool> _parsePrimary() async {
    final token = _advance();
    if (token == '(') {
      final result = await _parseOr();
      if (_peek != ')') throw _TestError('missing `)`');
      _advance();
      return result;
    }
    if (token.startsWith('-')) {
      final path = _advance();
      switch (token) {
        case '-e':
          return await fileExists(path);
        case '-f':
          return await fileExists(path) && !await dirExists(path);
        case '-d':
          return await dirExists(path);
        case '-s':
          return await fileExists(path) && await fileSize(path) > 0;
        case '-z':
          return _advance().isEmpty;
        case '-n':
          return _advance().isNotEmpty;
        default:
          throw _TestError('unsupported unary operator: $token');
      }
    }
    final left = token;
    final op = _advance();
    final right = _advance();
    switch (op) {
      case '=':
        return left == right;
      case '!=':
        return left != right;
      case '-eq':
        return int.parse(left) == int.parse(right);
      case '-ne':
        return int.parse(left) != int.parse(right);
      case '-lt':
        return int.parse(left) < int.parse(right);
      case '-le':
        return int.parse(left) <= int.parse(right);
      case '-gt':
        return int.parse(left) > int.parse(right);
      case '-ge':
        return int.parse(left) >= int.parse(right);
      default:
        throw _TestError('unsupported binary operator: $op');
    }
  }
}

final class StageResult {
  const StageResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
  final List<int> stdout;
  final List<int> stderr;
  final int exitCode;
}
