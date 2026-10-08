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

/// Foreground sleep deny threshold (issue #1349): a bare `sleep` longer
/// than this is rejected at call validation. A bare long sleep is never
/// legitimate foreground work — it parks the whole turn (steering and the
/// cancel path cannot reach the agent while the call stays open) — while
/// real long work (builds, test suites) keeps its foreground path.
const int maxForegroundSleepSeconds = 60;

/// One `sleep` duration argument: a plain number or a GNU-suffixed one
/// (`30`, `1.5s`, `2m`, `1h`, `7d`, case-insensitive).
final RegExp _sleepDurationArg = RegExp(
  r'^(\d+(?:\.\d+)?)([smhd]?)$',
  caseSensitive: false,
);

/// The total requested duration in seconds iff [command] is a BARE
/// `sleep <duration>…` (nothing but sleep and its duration arguments),
/// else null. Deliberately conservative (issue #1349): sleeps wrapped in
/// shell constructs are phase 2 — extend detection only if the deny data
/// shows the class survives.
///
/// Known false negatives — intentional phase-1 bypasses, recorded where
/// the deny data is collected (phase 2 candidates, dmtools-agents#767):
/// quoted durations (`sleep "300"`), env prefixes (`FOO=1 sleep 300`),
/// case variants (`SLEEP 300`), and trailing separators (`sleep 300;`).
double? bareForegroundSleepSeconds(String command) {
  final words = command.trim().split(RegExp(r'\s+'));
  if (words.first != 'sleep' || words.length < 2) return null;
  var total = 0.0;
  for (final word in words.skip(1)) {
    final match = _sleepDurationArg.firstMatch(word);
    if (match == null) return null;
    final value = double.parse(match.group(1)!);
    total += switch (match.group(2)!.toLowerCase()) {
      'm' => value * 60,
      'h' => value * 3600,
      'd' => value * 86400,
      _ => value, // '' | 's'
    };
  }
  return total;
}

/// The instructive validation denial for a bare long foreground `sleep`,
/// or null when the command may run in the foreground. The caller gates on
/// `timeout == null` (an explicit timeout is a deliberate bail cap — the
/// call unwinds there, steering and cancel included) and passes [canJob]
/// so the escape advice matches what the environment actually offers —
/// background advice would dead-end in a no-jobs host.
String? foregroundSleepDenial(String command, {required bool canJob}) {
  final seconds = bareForegroundSleepSeconds(command);
  if (seconds == null || seconds <= maxForegroundSleepSeconds) return null;
  final label = seconds == seconds.truncateToDouble()
      ? '${seconds.truncate()}'
      : '$seconds';
  final escape = canJob
      ? 'Re-run it with background: true: the command keeps running as a '
            'job, the job id returns immediately, and a settle notification '
            'wakes you when it finishes; collect progress with bash_job '
            '(action: output).'
      : 'Background jobs are not supported in this environment; bound the '
            'wait with an explicit timeout (seconds) instead — the call '
            'unwinds at the cap, so steering and cancel can reach you.';
  return 'Denied: a bare foreground sleep of ${label}s parks the whole '
      'turn — owner steering and cancel cannot reach the agent while the '
      'call stays open. $escape Never poll in the foreground.';
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
  /// The host's resolved redaction config for the shape interceptor
  /// (issue #1408 AC3, review 5456649624): the same `redact:` section
  /// steers command rewriting and result/job-log masking. Null = the
  /// default config (vendor shapes on) for direct tool users; the CLI
  /// passes its boot-resolved config (disabled when redaction is off).
  RedactionConfig? redactionConfig,
  /// Live snapshot of the values the host registered as secrets
  /// (`request_secret`, preconfig keys): those literals are EXEMPT from
  /// command rewriting so an approved value still materializes while the
  /// pipeline masks it in transcripts (review 5456649624).
  Set<String> Function()? approvedSecretLiterals,
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
      // Issue #1408 AC3: the shape interceptor rewrites recognized secret
      // SHAPES (and only those — key-like-but-unmatched text, e.g. a
      // filename the agent is creating, stays byte-identical) and the
      // result notice names every rewrite so the agent sees what changed
      // instead of discovering corruption by I/O error.
      final rewrite = redactBashCommandSecretShapes(
        command,
        config: redactionConfig ?? const RedactionConfig(),
        approvedLiterals: approvedSecretLiterals?.call() ?? const {},
      );
      final effectiveCommand = rewrite?.command ?? command;
      final rewriteNotice = rewrite?.notice;
      final timeoutArg = arguments['timeout'] as num?;
      final timeout = timeoutArg == null ? null : _resolveTimeout(timeoutArg);
      final background = arguments['background'] as bool? ?? false;
      final stdinData = arguments['stdin'] as String?;
      final canJob = jobs != null && jobs.isSupported;

      // Issue #1349: a bare long foreground sleep is rejected at call
      // validation — it parks the turn; background: true is the fix. An
      // explicit `timeout` is a deliberate bail cap (the call unwinds at
      // the cap, so steering and cancel reach the agent), not a park.
      if (!background && timeout == null) {
        final sleepDenial = foregroundSleepDenial(command, canJob: canJob);
        if (sleepDenial != null) return ToolExecutionResult.text(sleepDenial);
      }

      if (background) {
        if (!canJob) {
          return ToolExecutionResult.text(
            'Background execution is not supported in this environment — '
            'run the command in the foreground with an explicit timeout.',
          );
        }
        final entry = await jobs.start(
          effectiveCommand,
          options: ShellExecOptions(
            cwd: env.cwd,
            timeout: timeout,
            cancelToken: cancelToken,
            stdinData: stdinData,
          ),
        );
        return ToolExecutionResult.text(
          '${rewriteNotice == null ? '' : '$rewriteNotice\n'}'
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
          effectiveCommand,
          stdinData: stdinData,
          timeout: timeout,
          timeoutArg: timeoutArg,
          cancelToken: cancelToken,
          yieldToken: currentYieldToken()!,
          onPasswordPrompt: onPasswordPrompt,
          passwordQuiet: passwordQuiet,
          rewriteNotice: rewriteNotice,
        );
      }

      return _runForegroundBash(
        env,
        effectiveCommand,
        timeout: timeout,
        timeoutArg: timeoutArg,
        cancelToken: cancelToken,
        stdinData: stdinData,
        retryBackoff: retryBackoff,
        rewriteNotice: rewriteNotice,
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
  String? rewriteNotice,
}) async {
  final notices = <String>[if (rewriteNotice != null) rewriteNotice];
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
  String? rewriteNotice,
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
      rewriteNotice: rewriteNotice,
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
  String? rewriteNotice,
}) async {
  final finished = await Future.any<bool>([
    entry.settled.then((_) => true),
    yieldToken.onCancel.then((_) => false),
  ]);

  if (!finished) {
    final supervisorMoved = yieldToken.cancelReason is StuckCallFollowUp;
    final tail = await jobs.tail(entry.id, maxLines: 20);
    final handback = stuckBackgroundHandbackText(
      jobId: entry.id,
      logPath: entry.logPath,
      supervisorMoved: supervisorMoved,
      partialOutput: tail,
    );
    return ToolExecutionResult.text(
      rewriteNotice == null ? handback : '$rewriteNotice\n$handback',
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
  // Issue #1408 AC3 (review 5456649624): the notice rides AFTER
  // tail-truncation — _truncateTail keeps the TAIL, so a head-prefixed
  // notice is cut exactly when the output is long enough to truncate,
  // silently defeating the "the agent sees the rewrite" contract.
  final truncation = _truncateTail(rawOutput);
  var output = !truncation.truncated
      ? rawOutput
      : '${truncation.content}\n\n[Showing lines '
            '${truncation.totalLines - truncation.outputLines + 1}-'
            '${truncation.totalLines} of ${truncation.totalLines}.]';
  if (rewriteNotice != null) output = '$rewriteNotice\n$output';
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
