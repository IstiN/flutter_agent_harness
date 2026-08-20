// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// A [ShellJob] for the in-process sandbox shells ([MemoryShell] on web,
/// [WasiSandboxShell] on mobile): no OS process exists, so the "job" is the
/// script's Future running on a job-local shell clone; its output streams
/// into the log file through the injected [logWriter] (a host file sink for
/// the WASI shell, the memory FS for the web shell).
final class SandboxShellJob implements ShellJob {
  /// Creates a job; [_closeLog] flushes/closes the log writer at completion.
  SandboxShellJob({
    required this.id,
    required this.command,
    required this.logPath,
    required this._logWriter,
    this._closeLog,
  });

  final FutureOr<void> Function(String chunk) _logWriter;
  final FutureOr<void> Function()? _closeLog;
  final _cancelSource = CancelTokenSource();
  final _settled = Completer<void>();
  Future<void> _writeChain = Future<void>.value();
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;

  @override
  final String command;

  @override
  final String logPath;

  /// The token the job's script runs under; [stop] cancels it. Callers wire
  /// an outer abort token to [stop] (the job never shares the caller's token
  /// directly so [stop] stays distinguishable from a plain abort).
  CancelToken get cancelToken => _cancelSource.token;

  @override
  bool get isRunning => _exitCode == null;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get stopReason => _stopReason;

  @override
  Future<void> get settled => _settled.future;

  /// Appends one output chunk to the log, serialized so concurrent
  /// stdout/stderr chunks keep their arrival order.
  void writeLog(String chunk) {
    _writeChain = _writeChain.then((_) => _logWriter(chunk));
  }

  /// Completes the job from the script's exec result (called by the owning
  /// shell's detached run). Idempotent; the first completion wins.
  Future<void> completeWith(
    Result<ShellExecResult, ExecutionError> result,
  ) async {
    if (_exitCode != null) return;
    if (result.isErr) {
      final error = result.errorOrNull!;
      if (error.code != ExecutionErrorCode.aborted) {
        // Surface backend failures in the log, not just the exit code.
        writeLog('[job error: $error]\n');
      }
    }
    await _writeChain;
    await _closeLog?.call();
    if (result.isOk) {
      _exitCode = result.valueOrNull!.exitCode;
    } else {
      final error = result.errorOrNull!;
      _exitCode = switch (error.code) {
        ExecutionErrorCode.aborted => 143,
        ExecutionErrorCode.timeout => 124,
        _ => 1,
      };
      if (error.code == ExecutionErrorCode.aborted) {
        _stopReason ??= 'cancelled';
      } else if (error.code == ExecutionErrorCode.timeout) {
        _stopReason ??= 'timeout';
      }
    }
    _settled.complete();
  }

  @override
  Future<void> stop() async {
    // A stop landing after completion must not rewrite the outcome.
    if (_exitCode == null) _stopReason ??= 'stopped';
    _cancelSource.cancel();
  }
}
