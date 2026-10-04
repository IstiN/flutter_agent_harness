/// The `bash` tool ([shellTool], a ported subset of pi's `tools/bash.ts`) and the `bash_job` tool ([bashJobTool]): foreground runs with transient-failure retries, the yield-aware job path, password-prompt detection wiring, and background-job status/output/stop actions. Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// bash (ported subset of pi's tools/bash.ts)
// ---------------------------------------------------------------------------

Duration _resolveTimeout(num timeoutSeconds) {
  if (!timeoutSeconds.isFinite || timeoutSeconds <= 0) {
    throw StateError('Invalid timeout: must be a finite number of seconds');
  }
  final timeoutMs = (timeoutSeconds * 1000).round();
  if (timeoutMs > _maxTimeoutMs) {
    throw StateError(
      'Invalid timeout: maximum is ${_maxTimeoutMs / 1000} seconds',
    );
  }
  return Duration(milliseconds: timeoutMs);
}

String _appendStatus(String text, String status) {
  return text.isEmpty ? status : '$text\n\n$status';
}

/// Creates the `bash` tool: executes a shell command via [ExecutionEnv.exec]
/// and returns stdout followed by stderr, truncated to the last
/// [defaultToolMaxLines] lines / [defaultToolMaxBytes] bytes. A non-zero
/// exit code, timeout, or abort throws (the loop turns it into an error
/// tool result, pi semantics).
///
/// With [jobs] (and an environment implementing [BackgroundShell]) the tool
/// gains two background behaviors:
///
/// - `background: true` starts the command detached and returns immediately
///   with the job id; completion is reported back as a follow-up message.
/// - Foreground runs still block, but a user steering message mid-run
///   (the loop's soft-yield token, see [currentYieldToken]) moves the command
///   into a background job WITHOUT killing it: the tool call answers with the
///   job id and a partial-output tail, and the user message is delivered at
///   the next step boundary.
AgentTool shellTool(
  ExecutionEnv env, {
  ShellJobRegistry? jobs,
  Duration retryBackoff = _bashRetryBackoff,
  PasswordPromptCallback? onPasswordPrompt,
  Duration passwordQuiet = _bashPasswordQuiet,
}) {
  return AgentTool(
    name: bashToolName,
    label: 'bash',
    tier: ApprovalTier.exec,
    description:
        'Execute a bash command in the current working directory. Returns '
        'stdout and stderr. Output is truncated to the last '
        '$defaultToolMaxLines lines or ${defaultToolMaxBytes ~/ 1024}KB '
        '(whichever is hit first). Optionally provide a timeout in seconds. '
        'Timeout-class failures are retried automatically '
        '(${bashToolMaxRetries + 1} attempts total) — a hung network call '
        'does not fail the call; retries are visible as [bash attempt N] '
        'notices in the output. '
        'For long-running commands (builds, servers, watchers) pass '
        'background: true — the command keeps running as a job, you get its '
        'id immediately and are notified when it finishes; check progress '
        'with bash_job. A foreground command that is still running when the '
        'user sends a message is moved to a background job untouched (never '
        'killed) so the user gets an answer right away.',
    parameters: const {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'The bash command to execute',
        },
        'timeout': {
          'type': 'number',
          'description': 'Timeout in seconds (optional, no default timeout)',
        },
        'background': {
          'type': 'boolean',
          'description':
              'Run detached and return the job id immediately (optional, '
              'default false). Use for long-running commands.',
        },
        'stdin': {
          'type': 'string',
          'description':
              'Optional text written to the command\'s stdin right after '
              'start (a password/passphrase the USER supplied via the ask '
              'tool, or "y\\n"). Use when the command prompts for input, '
              'e.g. ssh-add or sudo. Never invent secrets — ask first.',
        },
      },
      'required': ['command'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final command = arguments['command'] as String;
      final timeoutArg = arguments['timeout'] as num?;
      final timeout = timeoutArg == null ? null : _resolveTimeout(timeoutArg);
      final background = arguments['background'] as bool? ?? false;
      final stdinData = arguments['stdin'] as String?;
      final canJob = jobs != null && jobs.isSupported;

      if (background) {
        if (!canJob) {
          return ToolExecutionResult.text(
            'Background execution is not supported in this environment — '
            'run the command in the foreground with an explicit timeout.',
          );
        }
        final entry = await jobs.start(
          command,
          options: ShellExecOptions(
            cwd: env.cwd,
            timeout: timeout,
            cancelToken: cancelToken,
            stdinData: stdinData,
          ),
        );
        return ToolExecutionResult.text(
          'Started background job ${entry.id}.\n'
          'Log: ${entry.logPath}\n'
          'You will be notified when it finishes; check progress with '
          'bash_job (action: status | output | stop).',
        );
      }

      // Yield-aware foreground run: executed as a job from the start so a
      // steering message can move it to the background mid-flight without
      // killing the process. Settled before any yield → identical result to
      // the classic inline path.
      if (canJob && currentYieldToken() != null) {
        return _shellViaJob(
          env,
          jobs,
          command,
          stdinData: stdinData,
          timeout: timeout,
          timeoutArg: timeoutArg,
          cancelToken: cancelToken,
          yieldToken: currentYieldToken()!,
          onPasswordPrompt: onPasswordPrompt,
          passwordQuiet: passwordQuiet,
        );
      }

      return _runForegroundBash(
        env,
        command,
        timeout: timeout,
        timeoutArg: timeoutArg,
        cancelToken: cancelToken,
        stdinData: stdinData,
        retryBackoff: retryBackoff,
      );
    },
  );
}

/// The inline foreground bash run with transient-failure retry: a
/// timeout-class failure (the model's own cap, or an outer future cap on a
/// hung transport) is retried up to [bashToolMaxRetries] times — a hung
/// network call should be retried, not fail the turn (user report: a
/// stalled `gh` API call killed the whole run). Aborts and real command
/// failures (non-zero exit, exec errors) are never retried. Every retry
/// lands in the result as a `[bash attempt N]` notice so the model knows
/// earlier attempts hung or timed out.
Future<ToolExecutionResult> _runForegroundBash(
  ExecutionEnv env,
  String command, {
  required Duration? timeout,
  required num? timeoutArg,
  required CancelToken? cancelToken,
  required String? stdinData,
  required Duration retryBackoff,
}) async {
  final notices = <String>[];
  for (var attempt = 1; ; attempt++) {
    final canRetry = attempt <= bashToolMaxRetries;
    final Result<ShellExecResult, ExecutionError> result;
    try {
      result = await env.exec(
        command,
        options: ShellExecOptions(
          cwd: env.cwd,
          timeout: timeout,
          cancelToken: cancelToken,
          stdinData: stdinData,
        ),
      );
    } on TimeoutException {
      // An outer layer's future cap fired (transport hang); the exec
      // itself never answered.
      if (!canRetry) rethrow;
      notices.add(
        '[bash attempt $attempt/${bashToolMaxRetries + 1} hung — '
        'retrying]',
      );
      await Future<void>.delayed(retryBackoff);
      continue;
    }

    if (result.isErr) {
      final error = result.errorOrNull!;
      if (error.code == ExecutionErrorCode.timeout && canRetry) {
        notices.add(
          '[bash attempt $attempt/${bashToolMaxRetries + 1} timed out'
          '${timeoutArg != null ? ' after ${timeoutArg}s' : ''} — '
          'retrying]',
        );
        await Future<void>.delayed(retryBackoff);
        continue;
      }
      throw _bashFailureError(error, notices, timeoutArg);
    }

    final execResult = result.valueOrNull!;
    final rawOutput = _bashOutput(execResult);
    if (execResult.exitCode != 0) {
      throw StateError(
        _appendStatus(
          '${_retryNoticePrefix(notices)}${_truncateBashOutput(rawOutput)}',
          'Command exited with code ${execResult.exitCode}',
        ),
      );
    }
    final output = _truncateBashOutput(rawOutput);
    final text = output.isEmpty ? '(no output)' : output;
    return ToolExecutionResult.text('${_retryNoticePrefix(notices)}$text');
  }
}

/// The user-visible error for a non-retryable bash exec failure.
StateError _bashFailureError(
  ExecutionError error,
  List<String> notices,
  num? timeoutArg,
) {
  // gh-1053 (review rework): a killed call's error carries the captured
  // partial output — render it so the model sees WHERE the call stalled,
  // not just the verdict.
  return switch (error.code) {
    ExecutionErrorCode.aborted => StateError(
      _bashFailureWithCapture(error, _appendStatus('', 'Command aborted')),
    ),
    ExecutionErrorCode.timeout => StateError(
      _bashFailureWithCapture(
        error,
        _appendStatus(
          _retryNoticePrefix(notices),
          'Command timed out after ${timeoutArg ?? 'unknown'} seconds',
        ),
      ),
    ),
    _ => StateError('${_retryNoticePrefix(notices)}$error'),
  };
}

/// Appends the killed call's partial capture (stderr after stdout, each
/// tail-truncated to the tool budget) to a bash failure message.
String _bashFailureWithCapture(ExecutionError error, String message) {
  final parts = <String>[
    if (error.stdout.isNotEmpty)
      '--- partial stdout ---\n${_truncateBashOutput(error.stdout)}',
    if (error.stderr.isNotEmpty)
      '--- partial stderr ---\n${_truncateBashOutput(error.stderr)}',
  ];
  return parts.isEmpty ? message : '$message\n${parts.join('\n')}';
}

/// Joins exec stdout and stderr (stderr after stdout).
String _bashOutput(ShellExecResult execResult) {
  final parts = <String>[
    if (execResult.stdout.isNotEmpty) execResult.stdout,
    if (execResult.stderr.isNotEmpty) execResult.stderr,
  ];
  return parts.join('\n');
}

/// Truncates command output to the tail, annotating what was cut.
String _truncateBashOutput(String output) {
  final truncation = _truncateTail(output);
  if (!truncation.truncated) return output;
  final startLine = truncation.totalLines - truncation.outputLines + 1;
  final endLine = truncation.totalLines;
  var notice =
      '\n\n[Showing lines $startLine-$endLine of ${truncation.totalLines}';
  if (truncation.truncatedBy == _TruncatedBy.bytes) {
    notice += ' (${formatToolSize(defaultToolMaxBytes)} limit)';
  }
  return '${truncation.content}$notice.]';
}

/// Prepends the retry notices (if any) to a tool result so the model sees
/// that earlier attempts hung or timed out before this one succeeded.
String _retryNoticePrefix(List<String> notices) =>
    notices.isEmpty ? '' : '${notices.join('\n')}\n';

/// The yield-aware foreground bash path: the command runs as a registry job
/// from the start; settling before the yield token fires produces the
/// classic inline result, a yield moves it to the background untouched.
Future<ToolExecutionResult> _shellViaJob(
  ExecutionEnv env,
  ShellJobRegistry jobs,
  String command, {
  String? stdinData,
  required Duration? timeout,
  required num? timeoutArg,
  required CancelToken? cancelToken,
  required CancelToken yieldToken,
  PasswordPromptCallback? onPasswordPrompt,
  required Duration passwordQuiet,
}) async {
  // Live stdin + password-ask detection (issue #367): the channel keeps
  // the pipe open so an answer reaches the RUNNING process; the detector
  // watches the live output stream and, on a password ask, calls the host
  // (the masked sheet) and writes the answer through the channel. The
  // password itself never appears in the transcript — only in the sheet.
  final channel = onPasswordPrompt == null ? null : LiveStdinChannel();
  final detector = onPasswordPrompt == null
      ? null
      : PasswordPromptDetector(
          onPrompt: (title) async {
            final answer = await onPasswordPrompt(title);
            channel!.write('${answer ?? ''}\n');
          },
          quiet: passwordQuiet,
        );
  final entry = await jobs.start(
    command,
    options: ShellExecOptions(
      cwd: env.cwd,
      timeout: timeout,
      cancelToken: cancelToken,
      stdinData: stdinData,
      liveStdin: channel,
    ),
  );
  final outputSub = detector == null
      ? null
      : entry.job.output.listen(detector.feed);
  try {
    return await _awaitJobOutcome(
      env,
      jobs,
      entry,
      yieldToken,
      timeoutArg: timeoutArg,
    );
  } finally {
    await outputSub?.cancel();
    detector?.dispose();
  }
}

Future<ToolExecutionResult> _awaitJobOutcome(
  ExecutionEnv env,
  ShellJobRegistry jobs,
  ShellJobEntry entry,
  CancelToken yieldToken, {
  required num? timeoutArg,
}) async {
  final finished = await Future.any<bool>([
    entry.settled.then((_) => true),
    yieldToken.onCancel.then((_) => false),
  ]);

  if (!finished) {
    final supervisorMoved = yieldToken.cancelReason is StuckCallFollowUp;
    final tail = await jobs.tail(entry.id, maxLines: 20);
    return ToolExecutionResult.text(
      stuckBackgroundHandbackText(
        jobId: entry.id,
        logPath: entry.logPath,
        supervisorMoved: supervisorMoved,
        partialOutput: tail,
      ),
    );
  }

  // Settled inline: report exactly like the synchronous path and suppress
  // the registry's settle notification (the result is already here).
  entry.suppressSettleNotification();
  final log = await env.readTextFile(entry.logPath);
  // The log file is newline-terminated; the inline result is not.
  var rawOutput = log.isErr ? '' : log.valueOrNull!;
  if (rawOutput.endsWith('\n')) {
    rawOutput = rawOutput.substring(0, rawOutput.length - 1);
  }
  final truncation = _truncateTail(rawOutput);
  final output = !truncation.truncated
      ? rawOutput
      : '${truncation.content}\n\n[Showing lines '
            '${truncation.totalLines - truncation.outputLines + 1}-'
            '${truncation.totalLines} of ${truncation.totalLines}.]';
  final exitCode = entry.exitCode ?? -1;
  if (entry.stopReason == 'timeout') {
    throw StateError(
      _appendStatus(
        output,
        'Command timed out after ${timeoutArg ?? 'unknown'} seconds',
      ),
    );
  }
  if (entry.stopReason == 'cancelled') {
    throw StateError(_appendStatus(output, 'Command aborted'));
  }
  if (exitCode != 0) {
    throw StateError(
      _appendStatus(output, 'Command exited with code $exitCode'),
    );
  }
  return ToolExecutionResult.text(output.isEmpty ? '(no output)' : output);
}

/// Creates the `bash_job` tool: inspect and stop the session's background
/// shell jobs (see [ShellJobRegistry]).
AgentTool bashJobTool(ShellJobRegistry jobs) {
  return AgentTool(
    name: 'bash_job',
    label: 'bash job',
    // `stop` kills a process, so the whole tool sits at the write tier
    // (task_send precedent); status/output are plain reads.
    tier: ApprovalTier.write,
    description:
        'Manage background shell jobs (started with bash background: true '
        'or moved to background when you were interrupted). Actions: '
        '"status" lists all jobs (or one with id), "output" shows the tail '
        'of a job log (id, optional lines), "stop" terminates a running job '
        '(id).',
    parameters: const {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['status', 'output', 'stop'],
          'description': 'What to do with the job(s)',
        },
        'id': {
          'type': 'string',
          'description': 'The job id (e.g. sh-1); required for output/stop',
        },
        'lines': {
          'type': 'number',
          'description': 'Log tail size for output (default 50)',
        },
      },
      'required': ['action'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final action = arguments['action'] as String;
      final id = arguments['id'] as String?;
      final lines = (arguments['lines'] as num?)?.toInt();
      return switch (action) {
        'status' => _bashJobStatusResult(jobs, id),
        'output' => await _bashJobOutputResult(jobs, id, lines),
        'stop' => await _bashJobStopResult(jobs, id),
        _ => throw StateError('unknown bash_job action: $action'),
      };
    },
  );
}

ToolExecutionResult _bashJobStatusResult(ShellJobRegistry jobs, String? id) {
  if (id == null) {
    if (jobs.jobs.isEmpty) {
      return ToolExecutionResult.text('No background jobs this session.');
    }
    return ToolExecutionResult.text(
      jobs.jobs.map(_shellJobStatusLine).join('\n'),
    );
  }
  final entry = jobs.job(id);
  if (entry == null) throw StateError('unknown background job: $id');
  return ToolExecutionResult.text(_shellJobStatusLine(entry));
}

Future<ToolExecutionResult> _bashJobOutputResult(
  ShellJobRegistry jobs,
  String? id,
  int? lines,
) async {
  if (id == null) throw StateError('bash_job output requires an id');
  final tail = await jobs.tail(id, maxLines: lines ?? 50);
  return ToolExecutionResult.text(tail.isEmpty ? '(no output yet)' : tail);
}

Future<ToolExecutionResult> _bashJobStopResult(
  ShellJobRegistry jobs,
  String? id,
) async {
  if (id == null) throw StateError('bash_job stop requires an id');
  final entry = jobs.job(id);
  if (entry == null) throw StateError('unknown background job: $id');
  if (!entry.isRunning) {
    return ToolExecutionResult.text(
      '$id already finished (exit code ${entry.exitCode})',
    );
  }
  await entry.stop();
  return ToolExecutionResult.text('Stopped $id');
}

String _shellJobStatusLine(ShellJobEntry entry) {
  final state = entry.isRunning ? 'running' : 'exited(${entry.exitCode})';
  final command = entry.command.length > 80
      ? '${entry.command.substring(0, 79)}…'
      : entry.command;
  return '${entry.id}: $state — $command (log: ${entry.logPath})';
}
