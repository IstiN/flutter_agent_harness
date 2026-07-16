// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:wasm_run/wasm_run.dart';

import 'shell_parser.dart';

/// A [Shell] backed by a sandbox of permissive WASI binaries.
///
/// This avoids the GPL licensing and portability problems of BusyBox by using
/// pre-built, MIT-licensed binaries:
///   - `coreutils.wasm` for the POSIX utility set
///   - `rg.wasm` for ripgrep
///   - `find.wasm` for uutils find
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
    this.workingDirectory,
    this.sandboxHostPath,
  });

  /// `coreutils` multicall module.
  final WasmModule coreutils;

  /// ripgrep module.
  final WasmModule rg;

  /// find module.
  final WasmModule find;

  /// Default working directory used when [ShellExecOptions.cwd] is omitted.
  final String? workingDirectory;

  /// Host directory exposed to the WASM guest at `/`.
  final String? sandboxHostPath;

  /// Loads all three WASM modules from the Flutter asset bundle.
  static Future<WasiSandboxShell> load({
    String? workingDirectory,
    String? sandboxHostPath,
  }) async {
    Future<WasmModule> loadAsset(String name) async {
      final byteData = await rootBundle.load('assets/wasm/$name');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      // WASI Preview 1 modules compiled by Rust do not need any extra proposal
      // flags; the default module configuration validates everything we need.
      return compileWasmModule(bytes);
    }

    return WasiSandboxShell(
      coreutils: await loadAsset('coreutils.wasm'),
      rg: await loadAsset('rg.wasm'),
      find: await loadAsset('find.wasm'),
      workingDirectory: workingDirectory,
      sandboxHostPath: sandboxHostPath,
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

  /// Resolves a command to the module and the exact argv that selects it.
  ({WasmModule module, List<String> argv}) _resolve(String command) {
    if (_coreutilsApplets.contains(command)) {
      return (module: coreutils, argv: [command]);
    }
    if (command == 'rg') return (module: rg, argv: ['rg']);
    if (command == 'find') return (module: find, argv: ['find']);
    return (module: coreutils, argv: [command]);
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
      List<String> effectiveArgs = stage.args;
      if (inputSource != null && stage.command != 'rg') {
        // ripgrep reads stdin when no path is given, but because we cannot
        // feed stdin bytes we add the file as a path argument. Most coreutils
        // and find accept a trailing file argument; ripgrep also accepts it.
        effectiveArgs = [...effectiveArgs, inputSource];
      }

      final result = await _runStage(
        command: stage.command,
        args: effectiveArgs,
        options: options,
        captureStdout: stdoutFile == null,
        captureStderr: stderrFile == null,
      );
      if (result.isErr) {
        await _cleanup(tempFiles);
        return Err(result.errorOrNull!);
      }
      final data = result.valueOrNull!;

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

    late WasmInstance instance;
    try {
      instance = await builder.build();
    } on Object catch (error) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          'Failed to build WASM instance: $error',
          cause: error,
        ),
      );
    }

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
        ? instance.stdout.listen(
            (chunk) => collect(stdoutBuffer, chunk, options?.onStdout),
          )
        : null;
    final stderrSub = captureStderr
        ? instance.stderr.listen(
            (chunk) => collect(stderrBuffer, chunk, options?.onStderr),
          )
        : null;

    final timeout = options?.timeout;
    var timedOut = false;
    final timeoutFuture = timeout == null
        ? null
        : Future<void>.delayed(timeout, () => timedOut = true);

    Object? runError;
    final runCompleter = Completer<void>();
    try {
      final start = instance.getFunction('_start');
      if (start == null) {
        return const Err(
          ExecutionError(
            ExecutionErrorCode.spawnError,
            'WASM module has no _start export',
          ),
        );
      }
      Future<void>(() async {
        try {
          start.call([]);
        } on Object catch (e) {
          runError = e;
        } finally {
          if (!runCompleter.isCompleted) runCompleter.complete();
        }
      });
      await Future.any<void>([
        runCompleter.future,
        if (timeoutFuture != null) timeoutFuture,
      ]);
    } finally {
      await stdoutSub?.asFuture<void>().catchError((_) {});
      await stderrSub?.asFuture<void>().catchError((_) {});
      await stdoutSub?.cancel();
      await stderrSub?.cancel();
      instance.dispose();
    }

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

    // wasmtime represents `proc_exit(n)` as `I32Exit(n)`. In older versions the
    // Display format is "i32 exit with value N".
    final i32Match = RegExp(
      r'i32\s+exit\s+with\s+value\s+(\d+)',
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
