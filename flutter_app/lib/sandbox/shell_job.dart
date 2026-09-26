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

  /// Whether the log writer failed once (issue #925): stop feeding it —
  /// the job keeps running headless, mirroring the local shell job.
  bool _logBroken = false;
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;

  @override
  final String command;

  @override
  final String logPath;

  /// No host process on the sandboxed shell: the sweep has nothing to
  /// record for web/WASI jobs.
  @override
  int? get pid => null;

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

  /// No live output stream: sandbox jobs stream into the log file only
  /// (no OS process to attach to).
  @override
  Stream<String> get output => const Stream.empty();

  /// No OS process: a sandbox job cannot accept live stdin writes
  /// (issue #367 E3 - the ask stays visible in the job log, documented).
  @override
  bool writeStdin(String data) => false;

  /// Appends one output chunk to the log, serialized so concurrent
  /// stdout/stderr chunks keep their arrival order. A failing log writer
  /// marks the log broken (further writes are skipped) instead of
  /// poisoning the chain — completeWith drains it before settling
  /// (issue #925: a broken log must never kill the host or hang the job).
  void writeLog(String chunk) {
    if (_logBroken) return;
    _writeChain = _writeChain.then((_) => _logWriter(chunk)).catchError((
      Object _,
    ) {
      _logBroken = true;
    });
  }

  /// Completes the job from the script's exec result (called by the owning
  /// shell's detached run). Idempotent; the first completion wins. Never
  /// throws and always settles — a broken log (issue #925) may freeze the
  /// log content, never the job lifecycle.
  Future<void> completeWith(
    Result<ShellExecResult, ExecutionError> result,
  ) async {
    if (_exitCode != null) return;
    _noteBackendFailure(result);
    try {
      await _writeChain;
      await _closeLogQuietly();
      _applyOutcome(result);
    } finally {
      _settled.complete();
    }
  }

  /// Surfaces backend failures in the log, not just the exit code.
  void _noteBackendFailure(Result<ShellExecResult, ExecutionError> result) {
    if (!result.isErr) return;
    final error = result.errorOrNull!;
    if (error.code != ExecutionErrorCode.aborted) {
      writeLog('[job error: $error]\n');
    }
  }

  /// Drains the close hook; a throwing log close must not escape into the
  /// zone or leave the job unsettled (issue #925).
  Future<void> _closeLogQuietly() async {
    try {
      await _closeLog?.call();
    } on Object {}
  }

  /// Exit codes for a failed exec result, by error code.
  static const _errorExitCodes = <ExecutionErrorCode, int>{
    ExecutionErrorCode.aborted: 143,
    ExecutionErrorCode.timeout: 124,
  };

  /// Stop reasons recorded for a failed exec result, by error code.
  static const _errorStopReasons = <ExecutionErrorCode, String>{
    ExecutionErrorCode.aborted: 'cancelled',
    ExecutionErrorCode.timeout: 'timeout',
  };

  /// Maps the exec result onto exit code and stop reason (first-completion
  /// wins: a [stop] reason recorded earlier is never overwritten).
  void _applyOutcome(Result<ShellExecResult, ExecutionError> result) {
    if (result.isOk) {
      _exitCode = result.valueOrNull!.exitCode;
      return;
    }
    final code = result.errorOrNull!.code;
    _exitCode = _errorExitCodes[code] ?? 1;
    final reason = _errorStopReasons[code];
    if (reason != null) _stopReason ??= reason;
  }

  @override
  Future<void> stop() async {
    // A stop landing after completion must not rewrite the outcome.
    if (_exitCode == null) _stopReason ??= 'stopped';
    _cancelSource.cancel();
  }
}
