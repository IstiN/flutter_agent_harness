import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:wasm_run/wasm_run.dart';

/// A [Shell] backed by a WASI BusyBox WASM module.
///
/// This runs `ash -c "<command>"` inside the sandbox so that iOS, Android, and
/// web targets get a working POSIX-like shell without spawning host processes.
/// The module is loaded from the Flutter asset bundle.
final class WasmShell implements Shell {
  WasmShell({
    required this.module,
    this.workingDirectory,
    this.sandboxHostPath,
  });

  /// Compiled BusyBox WASM module.
  final WasmModule module;

  /// Default working directory used when [ShellExecOptions.cwd] is omitted.
  final String? workingDirectory;

  /// Host directory exposed to the WASM guest at `/`.
  final String? sandboxHostPath;

  /// Loads [module] from `assets/busybox.wasm`.
  static Future<WasmModule> loadModule() async {
    final byteData = await rootBundle.load('assets/busybox.wasm');
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    return compileWasmModule(bytes);
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

    final cwd = options?.cwd ?? workingDirectory;
    final args = ['sh', '-c', command];
    final env = <String, String>{if (cwd != null) 'PWD': cwd, ...?options?.env};

    final preopenedDirs = <PreopenedDir>[];
    final hostSandbox = sandboxHostPath;
    if (hostSandbox != null && hostSandbox.isNotEmpty) {
      preopenedDirs.add(
        PreopenedDir(wasmGuestPath: '/', hostPath: hostSandbox),
      );
    }

    final builder = module.builder(
      wasiConfig: WasiConfig(
        args: args,
        env: env.entries
            .map((e) => EnvVariable(name: e.key, value: e.value))
            .toList(),
        preopenedDirs: preopenedDirs,
        webBrowserFileSystem: const <String, WasiDirectory>{},
        captureStdout: true,
        captureStderr: true,
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

    final stdout = StringBuffer();
    final stderr = StringBuffer();
    ExecutionError? callbackError;

    void collect(
      StringBuffer target,
      Uint8List chunk,
      void Function(String)? callback,
    ) {
      final text = utf8.decode(chunk, allowMalformed: true);
      target.write(text);
      if (callback == null) return;
      try {
        callback(text);
      } on Object catch (error) {
        callbackError = ExecutionError(
          ExecutionErrorCode.callbackError,
          error.toString(),
          cause: error,
        );
      }
    }

    final stdoutSub = instance.stdout.listen(
      (chunk) => collect(stdout, chunk, options?.onStdout),
    );
    final stderrSub = instance.stderr.listen(
      (chunk) => collect(stderr, chunk, options?.onStderr),
    );

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
      await stdoutSub.asFuture<void>().catchError((_) {});
      await stderrSub.asFuture<void>().catchError((_) {});
      await stdoutSub.cancel();
      await stderrSub.cancel();
      instance.dispose();
    }

    if (callbackError != null) return Err(callbackError!);
    if (timedOut) {
      return Err(
        ExecutionError(ExecutionErrorCode.timeout, 'timeout: $timeout'),
      );
    }
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }

    // WASI modules call proc_exit on normal exit; wasm_run surfaces it as a
    // trap. We treat a trap after producing output as a successful shell
    // invocation with exit code 0. A trap before any output is reported as an
    // unknown error so the caller can see the failure.
    if (runError != null &&
        stdout.toString().isEmpty &&
        stderr.toString().isEmpty) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.unknown,
          runError.toString(),
          cause: runError,
        ),
      );
    }

    return Ok(
      ShellExecResult(
        stdout: stdout.toString(),
        stderr: stderr.toString(),
        exitCode: runError == null ? 0 : 0,
      ),
    );
  }
}
