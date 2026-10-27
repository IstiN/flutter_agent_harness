/// Auto-backgrounding of long foreground bash calls (gh-1835): at the
/// liveness threshold a still-running foreground command is CONVERTED to a
/// background shell job — never killed, never restarted. The same process
/// keeps running (it started as a registry job from the beginning), the
/// pending tool call resolves exactly once with the backgrounded result,
/// and the MODEL decides what happens next: wait for the settle, poll
/// `bash_job output`, or stop the job and retry differently.
///
/// The conversion notice rides the TOOL RESULT only (the channel decision
/// in gh-1835): the result lands exactly where the model is already
/// waiting, with zero extra turn and zero extra tokens for a separate
/// steering notification. The settle notification stays armed for the
/// converted job, so the later completion still wakes the model through
/// the existing settle → reaction mechanism, and the headless drain
/// (`headless.shellJobDrainMs`) awaits the job like any other live job.
///
/// Threshold config: `waiting.autoBackgroundSeconds` (default
/// [defaultShellAutoBackgroundSeconds]; `0` is the kill switch — legacy
/// foreground behavior). Hosts without the `BackgroundShell` capability
/// keep the legacy behavior too: without jobs there is nothing to convert
/// to, so the call waits for its result (or its timeout) as before.
///
/// The module is pure Dart (no IO, no dart:io) — the text builder is the
/// single source of the model-facing conversion notice.
library;

import '../agent/stuck_tool.dart' show stuckBackgroundHandbackSentence;

/// Default liveness threshold for the auto-background conversion
/// (`waiting.autoBackgroundSeconds`; `0` disables the feature): about the
/// same order as the display-only liveness reminders
/// (`waiting.toolLivenessSeconds`), so the model learns about a long
/// operation from the tool result instead of a terminal hint.
const defaultShellAutoBackgroundSeconds = 60;

/// The backgrounded tool-result text for a call converted at the liveness
/// threshold: job id, elapsed, log path, and the SHORT inline guidance with
/// both branches — if the duration is unexpected, stop the job
/// (`bash_job stop`) and retry differently; otherwise continue other work
/// (the settle wakes the model) or poll `bash_job output`.
///
/// The text is anchored on [stuckBackgroundHandbackSentence] so the loop's
/// background-hand-back recognition (`_isBackgroundHandback`) classifies it
/// as a real conversion for the stuck supervisor and the budget ladder —
/// the same anchor the steering hand-back uses, without embedding the
/// ambiguous marker word alone.
///
/// [carriedTimeout] names the agent-set cap the job still honors (gh-1835
/// timeout interaction: an explicit `timeout` above the threshold carries
/// over to the background job as its upper bound); null when the call had
/// no timeout — the job then runs until it exits or is stopped.
String autoBackgroundHandbackText({
  required String jobId,
  required String logPath,
  required Duration elapsed,
  Duration? carriedTimeout,
}) {
  final capLine = carriedTimeout == null
      ? ''
      : 'Timeout cap: the job still honors its '
            '${carriedTimeout.inSeconds}s timeout.\n';
  return '$stuckBackgroundHandbackSentence$jobId — auto-backgrounded after '
      '${elapsed.inSeconds}s at the liveness threshold. The process was NOT '
      'restarted; the same process keeps running.\n'
      'Job: $jobId\n'
      'Log: $logPath\n'
      '$capLine'
      '\n'
      'If this duration is unexpected: stop the job (bash_job action: stop, '
      'id: $jobId) and retry with a different approach or a bounded '
      'timeout. Otherwise continue other work — you will be notified when '
      'it finishes, or poll progress with bash_job (action: output, '
      'id: $jobId).';
}
