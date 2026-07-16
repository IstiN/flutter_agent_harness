// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_git/dart_git.dart' as dart_git;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/plumbing/commit_iterator.dart';
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/objects/blob.dart';
import 'package:dart_git/plumbing/objects/object.dart';
import 'package:dart_git/plumbing/reference.dart';
import 'package:dart_git/status.dart';
import 'package:dart_git/utils/file_mode.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:wasm_run/wasm_run.dart';
import 'package:yaml/yaml.dart' as yaml;

import 'shell_parser.dart';

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
    this.workingDirectory,
    this.sandboxHostPath,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

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

  /// Default working directory used when [ShellExecOptions.cwd] is omitted.
  final String? workingDirectory;

  /// Host directory exposed to the WASM guest at `/`.
  final String? sandboxHostPath;

  final http.Client _httpClient;

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
      _ => (module: coreutils, argv: [command]),
    };
  }

  /// Dispatches a builtin command to its Dart implementation.
  Future<Result<_StageResult, ExecutionError>> _runBuiltin({
    required Stage stage,
    required ShellExecOptions? options,
    required String? inputSource,
  }) async {
    return switch (stage.command) {
      'curl' => _curlBuiltin(stage, options),
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
      _ => Err(
        ExecutionError(
          ExecutionErrorCode.unknown,
          'Unknown builtin: ${stage.command}',
        ),
      ),
    };
  }

  /// Runs either a builtin command or a WASM stage with stdin/source handling.
  Future<Result<_StageResult, ExecutionError>> _runCommand({
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
    final effectiveArgs = inputSource != null && command != 'rg'
        ? [...args, inputSource]
        : args;
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

      String? stdoutFile;
      String? stderrFile;
      var appendStdout = false;
      var appendStderr = false;
      String? stdinFile;

      for (final redirect in stage.redirects) {
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
      final inputSource = stdinFile ?? previousOutputFile;

      final result = await _runCommand(
        command: stage.command,
        args: stage.args,
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
        final file = _hostFile(stdoutFile);
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
        final file = _hostFile(stderrFile);
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

  String _sandboxPath(String hostPath) {
    final host = sandboxHostPath ?? '';
    if (host.isEmpty) return hostPath;
    final prefix = host.endsWith('/') ? host : '$host/';
    if (hostPath.startsWith(prefix)) {
      return '/${hostPath.substring(prefix.length)}';
    }
    return hostPath;
  }

  String _resolveGitPath(String arg, String hostCwd) {
    if (arg.startsWith('/')) return _hostPath(arg);
    return p.normalize(p.join(hostCwd, arg));
  }

  String? _findGitRoot(String hostPath) {
    var dir = hostPath;
    while (true) {
      if (io.Directory(p.join(dir, '.git')).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  Future<Result<_StageResult, ExecutionError>> _runStage({
    required String command,
    required List<String> args,
    required ShellExecOptions? options,
    required bool captureStdout,
    required bool captureStderr,
  }) async {
    final resolved = _resolve(command);
    final module = resolved.module;
    final argv = [...resolved.argv, ...args];

    final cwd = options?.cwd ?? workingDirectory;
    final env = <String, String>{
      // ignore: use_null_aware_elements
      if (cwd != null) 'PWD': cwd,
      'PATH': '/bin',
      ...?options?.env,
    };

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
      _StageResult(
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

  Future<Result<_StageResult, ExecutionError>> _testBuiltin(Stage stage) async {
    final rawArgs = stage.args.toList();
    if (stage.command == '[') {
      if (rawArgs.isEmpty || rawArgs.last != ']') {
        return Ok(
          _StageResult(
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
        _StageResult(
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
            return await io.File(_hostFile(path).path).exists();
          } on Object {
            return false;
          }
        },
        dirExists: (path) async {
          try {
            return await io.Directory(_hostFile(path).path).exists();
          } on Object {
            return false;
          }
        },
        fileSize: (path) async {
          try {
            return await io.File(_hostFile(path).path).length();
          } on Object {
            return 0;
          }
        },
      );
      final value = await evaluator.evaluate(rawArgs);
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: const [],
          exitCode: value ? 0 : 1,
        ),
      );
    } on _TestError catch (e) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('test: ${e.message}\n'),
          exitCode: 2,
        ),
      );
    } on FormatException catch (e) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('test: integer expected: $e\n'),
          exitCode: 2,
        ),
      );
    }
  }

  Future<Result<_StageResult, ExecutionError>> _whichBuiltin(
    Stage stage,
  ) async {
    if (stage.args.isEmpty) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('which: missing argument\n'),
          exitCode: 1,
        ),
      );
    }
    final name = stage.args.first;
    if (_isCommandAvailable(name)) {
      return Ok(
        _StageResult(
          stdout: utf8.encode('/bin/$name\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }
    return Ok(
      _StageResult(
        stdout: const [],
        stderr: utf8.encode('which: $name: not found\n'),
        exitCode: 1,
      ),
    );
  }

  Future<Result<_StageResult, ExecutionError>> _commandBuiltin(
    Stage stage,
  ) async {
    if (stage.args.length >= 2 && stage.args[0] == '-v') {
      final name = stage.args[1];
      if (_isCommandAvailable(name)) {
        return Ok(
          _StageResult(
            stdout: utf8.encode('/bin/$name\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('command: $name: not found\n'),
          exitCode: 1,
        ),
      );
    }
    return Ok(
      _StageResult(
        stdout: const [],
        stderr: utf8.encode('command: unsupported usage\n'),
        exitCode: 1,
      ),
    );
  }

  Future<Result<_StageResult, ExecutionError>> _envBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final env = <String, String>{
      // ignore: use_null_aware_elements
      if (workingDirectory != null) 'PWD': workingDirectory!,
      'PATH': '/bin',
      ...?options?.env,
    };

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
        _StageResult(
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
      _StageResult(
        stdout: utf8.encode(lines.join('\n') + (lines.isNotEmpty ? '\n' : '')),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<_StageResult, ExecutionError>> _curlBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final parsed = _parseCurlArgs(stage.args);
    if (parsed.url == null) {
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 2));
    }

    Uri uri;
    try {
      uri = Uri.parse(parsed.url!);
    } on FormatException {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('curl: invalid URL\n'),
          exitCode: 3,
        ),
      );
    }

    final request = http.Request(parsed.method, uri);
    request.headers.addAll(parsed.headers);
    if (parsed.body != null) request.body = parsed.body!;
    request.followRedirects = parsed.followRedirects;

    final timeout = options?.timeout ?? const Duration(seconds: 30);
    final streamedResponse = await _httpClient.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamedResponse);

    final statusLine =
        'HTTP ${response.statusCode} '
        '${response.reasonPhrase ?? ""}\n';
    final stderr = parsed.silent ? const <int>[] : utf8.encode(statusLine);

    if (parsed.outputFile != null) {
      final file = _hostFile(parsed.outputFile!);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes);
      return Ok(_StageResult(stdout: const [], stderr: stderr, exitCode: 0));
    }

    return Ok(
      _StageResult(stdout: response.bodyBytes, stderr: stderr, exitCode: 0),
    );
  }

  ({
    String? url,
    String method,
    Map<String, String> headers,
    String? body,
    String? outputFile,
    bool silent,
    bool followRedirects,
  })
  _parseCurlArgs(List<String> args) {
    var method = 'GET';
    final headers = <String, String>{};
    String? body;
    String? outputFile;
    var silent = false;
    var followRedirects = false;
    String? url;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-X' || arg == '--request') {
        if (i + 1 < args.length) method = args[++i];
      } else if (arg == '-H' || arg == '--header') {
        if (i + 1 < args.length) {
          final header = args[++i];
          final idx = header.indexOf(':');
          if (idx > 0) {
            headers[header.substring(0, idx).trim()] = header
                .substring(idx + 1)
                .trim();
          }
        }
      } else if (arg == '-d' || arg == '--data' || arg == '--data-raw') {
        if (i + 1 < args.length) body = args[++i];
      } else if (arg == '-o' || arg == '--output') {
        if (i + 1 < args.length) outputFile = args[++i];
      } else if (arg == '-s' || arg == '--silent') {
        silent = true;
      } else if (arg == '-L' || arg == '--location') {
        followRedirects = true;
      } else if (arg == '--url') {
        if (i + 1 < args.length) url = args[++i];
      } else if (!arg.startsWith('-')) {
        url = arg;
      }
    }

    return (
      url: url,
      method: method,
      headers: headers,
      body: body,
      outputFile: outputFile,
      silent: silent,
      followRedirects: followRedirects,
    );
  }

  Future<Result<_StageResult, ExecutionError>> _jqBuiltin(
    Stage stage,
    String? inputSource,
  ) async {
    if (stage.args.isEmpty) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('jq: missing filter\n'),
          exitCode: 2,
        ),
      );
    }
    final filter = stage.args.first;
    final inputFile = stage.args.length > 1 ? stage.args[1] : inputSource;

    if (inputFile == null) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('jq: missing input\n'),
          exitCode: 2,
        ),
      );
    }

    final file = _hostFile(inputFile);
    if (!await file.exists()) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('jq: $inputFile: No such file or directory\n'),
          exitCode: 2,
        ),
      );
    }

    final content = await file.readAsString();
    dynamic json;
    try {
      json = jsonDecode(content);
    } on FormatException catch (e) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('jq: parse error: $e\n'),
          exitCode: 5,
        ),
      );
    }

    final results = _applyJqFilter(json, filter);
    const encoder = JsonEncoder.withIndent('  ');
    final output = results.map((r) => encoder.convert(r)).join('\n');
    return Ok(
      _StageResult(
        stdout: utf8.encode(output.isNotEmpty ? '$output\n' : ''),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<_StageResult, ExecutionError>> _yqBuiltin(
    Stage stage,
    String? inputSource,
  ) async {
    if (stage.args.isEmpty) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('yq: missing filter\n'),
          exitCode: 2,
        ),
      );
    }
    final filter = stage.args.first;
    final inputFile = stage.args.length > 1 ? stage.args[1] : inputSource;

    if (inputFile == null) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('yq: missing input\n'),
          exitCode: 2,
        ),
      );
    }

    final file = _hostFile(inputFile);
    if (!await file.exists()) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('yq: $inputFile: No such file or directory\n'),
          exitCode: 2,
        ),
      );
    }

    final content = await file.readAsString();
    dynamic yamlDoc;
    try {
      yamlDoc = yaml.loadYaml(content);
    } on yaml.YamlException catch (e) {
      return Ok(
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('yq: parse error: $e\n'),
          exitCode: 5,
        ),
      );
    }

    final json = _yamlToJson(yamlDoc);
    final results = _applyJqFilter(json, filter);
    const encoder = JsonEncoder.withIndent('  ');
    final output = results.map((r) => encoder.convert(r)).join('\n');
    return Ok(
      _StageResult(
        stdout: utf8.encode(output.isNotEmpty ? '$output\n' : ''),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  dynamic _yamlToJson(dynamic value) {
    if (value is yaml.YamlMap) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _yamlToJson(entry.value),
      };
    }
    if (value is yaml.YamlList) {
      return value.map(_yamlToJson).toList();
    }
    return value;
  }

  List<dynamic> _applyJqFilter(dynamic input, String filter) {
    if (filter == '.') return [input];
    if (filter == 'length') {
      if (input is List || input is String || input is Map) {
        return [(input as dynamic).length as Object];
      }
      return const [];
    }
    if (filter == 'keys') {
      if (input is Map) return [input.keys.toList()];
      return const [];
    }

    final parts = filter.split('.').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return [input];

    dynamic current = input;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final isLast = i == parts.length - 1;
      if (part == '[]') {
        if (current is List) {
          final rest = parts.sublist(i + 1).join('.');
          return current
              .expand((e) => _applyJqFilter(e, rest.isEmpty ? '.' : '.$rest'))
              .toList();
        }
        return const [];
      }
      if (isLast && part == 'length') {
        if (current is List || current is String || current is Map) {
          return [(current as dynamic).length as Object];
        }
        return const [];
      }
      if (isLast && part == 'keys') {
        if (current is Map) return [current.keys.toList()];
        return const [];
      }
      if (current is Map) {
        current = current[part];
      } else {
        return const [];
      }
    }
    return [current];
  }

  Future<Result<_StageResult, ExecutionError>> _gitBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final args = List<String>.from(stage.args);
    String cwd = options?.cwd ?? workingDirectory ?? '/';

    // Parse a single global -C option (common for git).
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-C') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option -C requires a value');
        }
        cwd = args[i + 1];
        args.removeRange(i, i + 2);
        break;
      }
    }

    if (args.isEmpty) {
      return _gitError(
        'usage: git [--version] [--help] [-C <path>] <command> [<args>]',
      );
    }

    final subcommand = args[0];
    final subArgs = args.sublist(1);

    if (subcommand == '--version' || subcommand == '-v') {
      return Ok(
        _StageResult(
          stdout: utf8.encode('git version 2.47.0-fah\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    }

    final hostCwd = _hostPath(cwd);

    // Commands that do not require an existing repository.
    if (subcommand == 'clone') {
      return _gitClone(subArgs, hostCwd);
    }
    if (subcommand == 'init') {
      return _gitInit(subArgs, hostCwd);
    }

    final root = _findGitRoot(hostCwd);
    if (root == null) {
      return _gitError(
        'fatal: not a git repository (or any of the parent directories): .git',
      );
    }

    try {
      final repo = dart_git.GitRepository.load(root);
      switch (subcommand) {
        case 'add':
          return _gitAdd(repo, subArgs, hostCwd);
        case 'rm':
          return _gitRm(repo, subArgs, hostCwd);
        case 'commit':
          return _gitCommit(repo, subArgs, options?.env);
        case 'log':
          return _gitLog(repo, subArgs);
        case 'status':
          return _gitStatus(repo);
        case 'branch':
          return _gitBranch(repo, subArgs);
        case 'checkout':
          return _gitCheckout(repo, subArgs, hostCwd);
        case 'show':
          return _gitShow(repo, subArgs);
        case 'cat-file':
          return _gitCatFile(repo, subArgs);
        case 'hash-object':
          return _gitHashObject(repo, subArgs, hostCwd);
        case 'ls-tree':
          return _gitLsTree(repo, subArgs);
        case 'write-tree':
          return _gitWriteTree(repo);
        case 'merge-base':
          return _gitMergeBase(repo, subArgs);
        case 'reset':
          return _gitReset(repo, subArgs);
        default:
          return _gitError('git: \'$subcommand\' is not a git command.');
      }
    } catch (e) {
      return _gitError('error: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitError(String message) => Ok(
    _StageResult(
      stdout: const [],
      stderr: utf8.encode('$message\n'),
      exitCode: 1,
    ),
  );

  Future<Result<_StageResult, ExecutionError>> _gitClone(
    List<String> args,
    String hostCwd,
  ) async {
    if (args.isEmpty) {
      return _gitError('usage: git clone <repository> [<directory>]');
    }
    final repoUrl = args[0];
    String dest;
    if (args.length > 1 && !args[1].startsWith('-')) {
      dest = args[1];
    } else {
      dest = p.basenameWithoutExtension(repoUrl);
    }
    final hostDest = _resolveGitPath(dest, hostCwd);

    final githubRepo = _parseGitHubRepo(repoUrl);
    if (githubRepo == null) {
      return _gitError(
        'git clone: only public GitHub HTTPS URLs are supported in this subset',
      );
    }
    final (:owner, :repo) = githubRepo;
    final archiveUrl = 'https://api.github.com/repos/$owner/$repo/tarball';

    try {
      final response = await _httpClient.get(Uri.parse(archiveUrl));
      if (response.statusCode != 200) {
        return _gitError(
          'git clone: failed to download archive: HTTP ${response.statusCode}',
        );
      }

      final archiveFile = io.File(p.join(hostDest, '.fah_clone.tar.gz'));
      await archiveFile.parent.create(recursive: true);
      await archiveFile.writeAsBytes(response.bodyBytes);

      final tarFile = io.File(p.join(hostDest, '.fah_clone.tar'));
      await tarFile.writeAsBytes(io.gzip.decode(archiveFile.readAsBytesSync()));

      final tarSandboxPath = _sandboxPath(tarFile.path);
      final destSandboxPath = _sandboxPath(hostDest);
      final tarResult = await _runCommand(
        command: 'tar',
        args: ['-xf', tarSandboxPath, '-C', destSandboxPath],
        options: null,
        inputSource: null,
        captureStdout: true,
        captureStderr: true,
      );
      if (tarResult.isErr) return tarResult;
      final tarData = tarResult.valueOrNull!;
      if (tarData.exitCode != 0) {
        final errMsg = utf8.decode(tarData.stderr, allowMalformed: true);
        return _gitError('git clone: tar extraction failed: $errMsg');
      }
      await archiveFile.delete();
      await tarFile.delete();

      // GitHub tarballs unpack into a single `owner-repo-sha` directory.
      // Move the contents up so the destination itself is the repository root.
      final entries = await io.Directory(hostDest).list().toList();
      final innerDir = entries.whereType<io.Directory>().firstOrNull;
      if (innerDir != null) {
        await for (final entity in innerDir.list()) {
          final name = p.basename(entity.path);
          final target = p.join(hostDest, name);
          await entity.rename(target);
        }
        await innerDir.delete();
      }

      // Initialize a git repo so subsequent git commands work on the clone.
      dart_git.GitRepository.init(hostDest);

      return Ok(
        _StageResult(
          stdout: utf8.encode('Cloned into \'$dest\'\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: unable to clone: $e');
    }
  }

  ({String owner, String repo})? _parseGitHubRepo(String url) {
    final https = RegExp(r'https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$');
    final match = https.firstMatch(url);
    if (match != null) {
      return (owner: match.group(1)!, repo: match.group(2)!);
    }
    final ssh = RegExp(r'git@github\.com:([^/]+)/([^/]+?)(?:\.git)?/?$');
    final sshMatch = ssh.firstMatch(url);
    if (sshMatch != null) {
      return (owner: sshMatch.group(1)!, repo: sshMatch.group(2)!);
    }
    return null;
  }

  Future<Result<_StageResult, ExecutionError>> _gitInit(
    List<String> args,
    String hostCwd,
  ) async {
    var path = hostCwd;
    String? virtualName;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--bare' || arg == '--shared') {
        return _gitError('git init: unsupported flag $arg');
      }
      if (arg == '-b' || arg == '--initial-branch') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option $arg requires a value');
        }
        i++;
        continue;
      }
      if (!arg.startsWith('-')) {
        virtualName = arg;
        path = _resolveGitPath(arg, hostCwd);
      }
    }

    try {
      dart_git.GitRepository.init(path);
      final display = virtualName ?? path;
      return Ok(
        _StageResult(
          stdout: utf8.encode(
            'Initialized empty Git repository in $display/.git/\n',
          ),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitAdd(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git add <pathspec>...');
    }
    try {
      for (final arg in args.where((a) => !a.startsWith('-'))) {
        repo.add(_resolveGitPath(arg, hostCwd));
      }
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitRm(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git rm <pathspec>...');
    }
    try {
      for (final arg in args.where((a) => !a.startsWith('-'))) {
        repo.rm(_resolveGitPath(arg, hostCwd));
      }
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitCommit(
    dart_git.GitRepository repo,
    List<String> args,
    Map<String, String>? env,
  ) {
    String? message;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-m' || arg == '--message') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option $arg requires a value');
        }
        message = args[i + 1];
        i++;
      }
    }
    if (message == null || message.isEmpty) {
      return _gitError(
        'fatal: cannot create an empty commit without a message',
      );
    }

    final author = _gitAuthor(env);
    try {
      final commit = repo.commit(
        message: message,
        author: author,
        committer: author,
      );
      return Ok(
        _StageResult(
          stdout: utf8.encode(
            '[${repo.currentBranch()} ${commit.hash.toOid()}] $message\n',
          ),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } on GitEmptyCommit {
      return _gitError(
        'On branch ${repo.currentBranch()}\nnothing to commit, working tree clean',
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  dart_git.GitAuthor _gitAuthor(Map<String, String>? env) {
    final name =
        env?['GIT_AUTHOR_NAME'] ??
        io.Platform.environment['GIT_AUTHOR_NAME'] ??
        'fah';
    final email =
        env?['GIT_AUTHOR_EMAIL'] ??
        io.Platform.environment['GIT_AUTHOR_EMAIL'] ??
        'fah@example.com';
    return dart_git.GitAuthor(name: name, email: email);
  }

  Result<_StageResult, ExecutionError> _gitLog(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    var maxCount = 0;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-n' || arg == '--max-count') {
        if (i + 1 >= args.length) {
          return _gitError('fatal: option $arg requires a value');
        }
        maxCount = int.tryParse(args[i + 1]) ?? 0;
        i++;
      }
    }

    try {
      final from = repo.headHash();
      final commits = commitIteratorBFS(
        objStorage: repo.objStorage,
        from: from,
      );
      final lines = <String>[];
      var count = 0;
      for (final commit in commits) {
        if (maxCount > 0 && count >= maxCount) break;
        final msg = commit.message.trim().split('\n').first;
        lines.add('${commit.hash.toOid()} $msg');
        count++;
      }
      return Ok(
        _StageResult(
          stdout: utf8.encode(lines.isEmpty ? '' : '${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitStatus(dart_git.GitRepository repo) {
    try {
      final result = repo.status();
      bool notGitEntry(String f) =>
          f != '.git' && !f.endsWith('/.git') && !f.contains('/.git/');
      final added = result.added.where(notGitEntry).toList();
      final modified = result.modified.where(notGitEntry).toList();
      final removed = result.removed.where(notGitEntry).toList();

      final lines = <String>[];
      if (added.isNotEmpty) {
        lines.add('Untracked:');
        for (final f in added) {
          lines.add('  ${repo.toPathSpec(f)}');
        }
      }
      if (modified.isNotEmpty) {
        lines.add('Modified:');
        for (final f in modified) {
          lines.add('  ${repo.toPathSpec(f)}');
        }
      }
      if (removed.isNotEmpty) {
        lines.add('Deleted:');
        for (final f in removed) {
          lines.add('  ${repo.toPathSpec(f)}');
        }
      }
      if (lines.isEmpty) {
        lines.add('nothing to commit, working tree clean');
      }
      return Ok(
        _StageResult(
          stdout: utf8.encode('${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitBranch(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    try {
      if (args.isEmpty) {
        final current = repo.currentBranch();
        final branches = repo.branches()..sort();
        final lines = branches.map((b) => b == current ? '* $b' : '  $b');
        return Ok(
          _StageResult(
            stdout: utf8.encode('${lines.join('\n')}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }

      if (args[0] == '-d' || args[0] == '-D') {
        if (args.length < 2) {
          return _gitError('usage: git branch -d <branch>');
        }
        repo.deleteBranch(args[1]);
        return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
      }

      final branchName = args.lastWhere((a) => !a.startsWith('-'));
      repo.createBranch(branchName);
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitCheckout(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git checkout <branch>|<path>');
    }
    final target = args.lastWhere((a) => !a.startsWith('-'));
    try {
      if (repo.branches().contains(target)) {
        repo.checkoutBranch(target);
        return Ok(
          _StageResult(
            stdout: utf8.encode('Switched to branch \'$target\'\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      final count = repo.checkout(_resolveGitPath(target, hostCwd));
      return Ok(
        _StageResult(
          stdout: utf8.encode('Updated $count paths\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitShow(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    final spec = args.isEmpty
        ? 'HEAD'
        : args.firstWhere((a) => !a.startsWith('-'));
    final colonIdx = spec.indexOf(':');
    try {
      if (colonIdx == -1) {
        final commit = _gitResolveCommit(repo, spec);
        final lines = <String>[
          'commit ${commit.hash}',
          'Author: ${commit.author.name} <${commit.author.email}>',
          'Date:   ${commit.author.date}',
          '',
          commit.message.trim(),
        ];
        return Ok(
          _StageResult(
            stdout: utf8.encode('${lines.join('\n')}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }

      final commitish = spec.substring(0, colonIdx);
      final pathSpec = spec.substring(colonIdx + 1);
      final commit = _gitResolveCommit(repo, commitish);
      final tree = repo.objStorage.readTree(commit.treeHash);
      final entry = repo.objStorage.refSpec(tree, pathSpec);
      final blob = repo.objStorage.readBlob(entry.hash);
      return Ok(
        _StageResult(stdout: blob.blobData, stderr: const [], exitCode: 0),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  dart_git.GitCommit _gitResolveCommit(
    dart_git.GitRepository repo,
    String spec,
  ) {
    if (spec == 'HEAD') return repo.headCommit();
    if (repo.branches().contains(spec)) {
      final commit = repo.branchCommit(spec);
      if (commit != null) return commit;
    }
    // Treat as a full hash.
    final hash = GitHash(spec);
    return repo.objStorage.readCommit(hash);
  }

  Result<_StageResult, ExecutionError> _gitCatFile(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _gitError('usage: git cat-file (-p|-t) <object>');
    }
    final flag = args[0];
    final spec = args[1];
    try {
      GitObject? obj;
      final colonIdx = spec.indexOf(':');
      if (colonIdx != -1) {
        final commitish = spec.substring(0, colonIdx);
        final pathSpec = spec.substring(colonIdx + 1);
        final commit = _gitResolveCommit(repo, commitish);
        final tree = repo.objStorage.readTree(commit.treeHash);
        final entry = repo.objStorage.refSpec(tree, pathSpec);
        obj = repo.objStorage.read(entry.hash);
      } else {
        GitHash hash;
        if (spec == 'HEAD') {
          hash = repo.headHash();
        } else if (repo.branches().contains(spec)) {
          hash = repo.resolveReferenceName(ReferenceName.branch(spec))!.hash;
        } else {
          hash = GitHash(spec);
        }
        obj = repo.objStorage.read(hash);
      }
      if (obj == null) throw Exception('object not found');

      if (flag == '-t') {
        return Ok(
          _StageResult(
            stdout: utf8.encode('${obj.formatStr()}\n'),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      if (flag == '-p') {
        if (obj is GitBlob) {
          return Ok(
            _StageResult(stdout: obj.blobData, stderr: const [], exitCode: 0),
          );
        }
        return Ok(
          _StageResult(
            stdout: utf8.encode(
              '${utf8.decode(obj.serializeData(), allowMalformed: true)}\n',
            ),
            stderr: const [],
            exitCode: 0,
          ),
        );
      }
      return _gitError('git cat-file: unsupported flag $flag');
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitHashObject(
    dart_git.GitRepository repo,
    List<String> args,
    String hostCwd,
  ) {
    var write = false;
    String? path;
    for (final arg in args) {
      if (arg == '-w') {
        write = true;
      } else if (!arg.startsWith('-')) {
        path = arg;
      }
    }
    if (path == null) {
      return _gitError('usage: git hash-object [-w] <file>');
    }
    try {
      final data = io.File(_resolveGitPath(path, hostCwd)).readAsBytesSync();
      final blob = GitBlob(data, null);
      final hash = GitHash.computeForObject(blob);
      if (write) {
        repo.objStorage.writeObject(blob);
      }
      return Ok(
        _StageResult(
          stdout: utf8.encode('$hash\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitLsTree(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git ls-tree <tree-ish>');
    }
    final spec = args.lastWhere((a) => !a.startsWith('-'));
    try {
      GitHash hash;
      if (repo.branches().contains(spec)) {
        final commit = repo.branchCommit(spec)!;
        hash = commit.treeHash;
      } else if (spec == 'HEAD') {
        hash = repo.headCommit().treeHash;
      } else {
        hash = GitHash(spec);
      }
      final tree = repo.objStorage.readTree(hash);
      final lines = tree.entries.map((e) {
        final mode = e.mode.val.toRadixString(8).padLeft(6, '0');
        final typeStr = e.mode == GitFileMode.Dir
            ? 'tree'
            : e.mode == GitFileMode.Submodule
            ? 'commit'
            : 'blob';
        return '$mode $typeStr ${e.hash}\t${e.name}';
      });
      return Ok(
        _StageResult(
          stdout: utf8.encode('${lines.join('\n')}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitWriteTree(
    dart_git.GitRepository repo,
  ) {
    try {
      final index = repo.indexStorage.readIndex();
      final hash = repo.writeTree(index);
      return Ok(
        _StageResult(
          stdout: utf8.encode('$hash\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitMergeBase(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.length < 2) {
      return _gitError('usage: git merge-base <commit> <commit>');
    }
    try {
      final a = _gitResolveCommit(repo, args[0]);
      final b = _gitResolveCommit(repo, args[1]);
      final bases = repo.mergeBase(a, b);
      if (bases.isEmpty) {
        return _gitError('fatal: no merge base found');
      }
      return Ok(
        _StageResult(
          stdout: utf8.encode('${bases.first.hash}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Result<_StageResult, ExecutionError> _gitReset(
    dart_git.GitRepository repo,
    List<String> args,
  ) {
    if (args.isEmpty) {
      return _gitError('usage: git reset [--hard] <commit>');
    }
    var hard = false;
    String? target;
    for (final arg in args) {
      if (arg == '--hard') {
        hard = true;
      } else if (!arg.startsWith('-')) {
        target = arg;
      }
    }
    if (!hard) {
      return _gitError('git reset: only --hard is supported');
    }
    if (target == null) {
      return _gitError('usage: git reset --hard <commit>');
    }
    try {
      final commit = _gitResolveCommit(repo, target);
      repo.resetHard(commit.hash);
      return Ok(
        _StageResult(
          stdout: utf8.encode('HEAD is now at ${commit.hash.toOid()}\n'),
          stderr: const [],
          exitCode: 0,
        ),
      );
    } catch (e) {
      return _gitError('fatal: $e');
    }
  }

  Future<Result<_StageResult, ExecutionError>> _whoamiBuiltin() async {
    final user =
        io.Platform.environment['USER'] ??
        io.Platform.environment['USERNAME'] ??
        'fah';
    return Ok(
      _StageResult(
        stdout: utf8.encode('$user\n'),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  Future<Result<_StageResult, ExecutionError>> _trBuiltin(
    Stage stage,
    String? inputSource,
  ) async {
    if (inputSource == null) {
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
    }
    final file = _hostFile(inputSource);
    if (!await file.exists()) {
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
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
        _StageResult(
          stdout: const [],
          stderr: utf8.encode('tr: missing operand\n'),
          exitCode: 2,
        ),
      );
    }
    if (!delete && set2 == null) {
      return Ok(
        _StageResult(
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
      _StageResult(stdout: utf8.encode(output), stderr: const [], exitCode: 0),
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

  Future<Result<_StageResult, ExecutionError>> _xargsBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    if (inputSource == null) {
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
    }
    final file = _hostFile(inputSource);
    if (!await file.exists()) {
      return Ok(const _StageResult(stdout: [], stderr: [], exitCode: 0));
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
        _StageResult(
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

    return Ok(_StageResult(stdout: stdout, stderr: stderr, exitCode: exitCode));
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
