/// SessionDeadline (gh-1556): the ONE wall-clock budget source for a run —
/// the temporal sibling of the FinalizeGate (gh-1412).
///
/// A host, a CLI flag, or a mid-session `/timer` command arms a single
/// epoch-ms deadline on this clock; every consumer (the per-turn
/// `time-left:` request line, the one-shot wrap-up steering notices, the
/// TUI countdown chip, the `FA_DEADLINE_EPOCH_MS` bash env var) projects
/// THE SAME value. Later setters override earlier ones (env < flag <
/// `/timer`); the TUI chip is a pure projection, never a second timer.
///
/// Contract (the ticket's binding threats):
/// - Never lie about the clock: the deadline comes ONLY from the host env
///   or an explicit user set; fa never invents or extends it.
/// - Missing/invalid env = feature OFF, silent — no errors, no prompts.
/// - An explicit user set with an invalid spec is a CLEAR user-facing
///   error ([FormatException]) — never a silently wrong deadline.
/// - Not a procrastination loop: each ladder crossing fires ONCE per
///   arming (a re-set/adjust re-arms the latch set).
/// - The guillotine stays the host's: notices are steerings the model may
///   ignore.
///
/// Pure Dart: the wall clock is injected (defaulting to [DateTime.now]);
/// no `dart:io` anywhere.
library;

/// Env var a host exports to hand the session its deadline (epoch ms).
/// Injected into bash tool executions live per exec through the
/// session-correlation env seam (see `SessionVarsExecutionEnv`), so a
/// mid-session `/timer` adjustment is picked up by the next command.
const String deadlineEpochMsEnvVar = 'FA_DEADLINE_EPOCH_MS';

/// A bare-integer spec at or above this value is read as an epoch-ms
/// timestamp (1973-09-09 onward); anything smaller is rejected as an
/// ambiguous duration missing its unit — silently reading `90` as 90 ms
/// would be a lying clock.
const int deadlineEpochMsFloor = 100000000000;

/// One crossing of the default notice ladder.
enum DeadlineNoticeKind {
  /// ~50% of the budget elapsed: start converging.
  halfBudget,

  /// T-3min (the load-bearing steer): stop exploring, finalize outputs,
  /// drain/kill background shell jobs, run checks.
  wrapUp,

  /// T-30s: write the final answer NOW.
  finalAnswer,
}

/// A one-shot steering notice produced by [SessionDeadline.pollNotices].
final class DeadlineNotice {
  /// Creates a notice.
  const DeadlineNotice(this.kind, this.text);

  /// Which ladder crossing fired.
  final DeadlineNoticeKind kind;

  /// The model-facing steering text (already rendered with the current
  /// remaining budget).
  final String text;

  @override
  String toString() => 'DeadlineNotice(${kind.name})';
}

/// The default notice ladder: the crossing thresholds plus the steering
/// texts. Injectable so tests can compress the windows without waiting.
final class DeadlineLadder {
  /// Creates a ladder. [wrapUpSteerMs] defaults to T-3min, [finalAnswerMs]
  /// to T-30s.
  const DeadlineLadder({
    this.wrapUpSteerMs = 3 * 60 * 1000,
    this.finalAnswerMs = 30 * 1000,
  });

  /// The wrap-up steer fires when the remaining budget drops to this many
  /// ms (default 3 min).
  final int wrapUpSteerMs;

  /// The final-answer steer fires at this many ms remaining (default 30 s).
  final int finalAnswerMs;

  /// The steering text for [kind], rendered with the current [timeLeft]
  /// (`formatTimeLeft` spelling). The T-3min steer names the
  /// shell-job/background-work drain explicitly — long-running operations
  /// must get their chance to land instead of being SIGKILLed mid-write —
  /// and the grader-parity clause (gh-1652): the LAST verification pass
  /// before finalizing goes through the grader's own invocation path,
  /// not the agent's checklist oracle.
  String text(DeadlineNoticeKind kind, String timeLeft) => switch (kind) {
    DeadlineNoticeKind.halfBudget =>
      'Half of your time budget has elapsed ($timeLeft remaining). '
          'Stop widening the search: converge on the deliverables. '
          'Do not stop while work remains: unfinished work is not a reason '
          'to wrap up — you are interrupted at the deadline anyway.',
    DeadlineNoticeKind.wrapUp =>
      'Deadline in $timeLeft — stop exploring and finalize your outputs '
          'NOW: drain or kill background shell jobs (`bash_job stop <id>`) '
          'and any in-flight subagents so long-running operations '
          '(compiles, uploads, file writes) get their chance to land, run '
          'your final checks, and before finalizing run each produced '
          'entry point the way the grader will (neutral cwd, clean env) '
          'and fix what diverges. Then write your final answer.',
    DeadlineNoticeKind.finalAnswer =>
      '$timeLeft remaining — write your final answer NOW.',
  };
}

/// Parses a user-facing deadline spec into either a duration-from-now or
/// an absolute epoch-ms timestamp.
///
/// Accepted shapes: `25m`, `90s`, `1h30m` (any non-empty combination of
/// `<n>h|m|s` tokens covering the whole string) and a bare epoch-ms
/// integer (>= [deadlineEpochMsFloor]; anything smaller is almost
/// certainly a duration missing its unit).
///
/// Throws [FormatException] with a clear message on anything else — a
/// caller must surface the message to the user, never swallow it into a
/// silently wrong deadline.
DeadlineSpec parseDeadlineSpec(String input) {
  final spec = input.trim();
  if (spec.isEmpty) {
    throw const FormatException('empty deadline — try e.g. 25m, 90s or 1h30m');
  }
  final bareInt = int.tryParse(spec);
  if (bareInt != null) {
    if (bareInt < deadlineEpochMsFloor) {
      throw FormatException(
        '"$spec" is too small to be an epoch-ms timestamp — durations '
        'need a unit (e.g. ${bareInt}s, ${bareInt}m)',
      );
    }
    return DeadlineSpec._epoch(bareInt);
  }
  final token = RegExp(r'(\d+)([hms])');
  var pos = 0;
  var totalMs = 0;
  var matched = false;
  while (pos < spec.length) {
    final match = token.matchAsPrefix(spec, pos);
    if (match == null) {
      throw FormatException(
        'invalid deadline "$spec" — expected a duration like 25m, 90s or '
        '1h30m, or an epoch-ms timestamp',
      );
    }
    matched = true;
    final value = int.parse(match.group(1)!);
    totalMs += switch (match.group(2)!) {
      'h' => value * 60 * 60 * 1000,
      'm' => value * 60 * 1000,
      _ => value * 1000,
    };
    pos = match.end;
  }
  if (!matched || totalMs <= 0) {
    throw FormatException('deadline "$spec" must be a positive duration');
  }
  return DeadlineSpec._duration(Duration(milliseconds: totalMs));
}

/// The parsed shape of a deadline spec: relative ([duration]) or absolute
/// ([epochMs]). Exactly one field is non-null.
final class DeadlineSpec {
  const DeadlineSpec._(this.duration, this.epochMs);

  /// A relative-duration spec.
  factory DeadlineSpec._duration(Duration duration) =>
      DeadlineSpec._(duration, null);

  /// An absolute epoch-ms spec.
  factory DeadlineSpec._epoch(int epochMs) => DeadlineSpec._(null, epochMs);

  /// Relative budget, resolved against the set time.
  final Duration? duration;

  /// Absolute epoch-ms timestamp.
  final int? epochMs;

  /// Whether the spec is an absolute epoch-ms timestamp.
  bool get isEpoch => epochMs != null;
}

/// Formats a remaining budget for the `time-left:` line and the TUI chip:
/// `45s`, `5min`, `1h30m`, `2h`. A non-positive budget reads `0s` — the
/// clock never lies about being out of time.
String formatTimeLeft(int remainingMs) {
  if (remainingMs <= 0) return '0s';
  final seconds = remainingMs ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) return minutes > 0 ? '${hours}h${minutes}m' : '${hours}h';
  if (minutes > 0) return '${minutes}min';
  return '${seconds}s';
}

/// The single session deadline clock (gh-1556). All setters write the one
/// epoch-ms value; every consumer projects it live.
final class SessionDeadline {
  /// Creates a clock. [clock] defaults to [DateTime.now]; tests inject a
  /// fake. [ladder] defaults to the standard T-3min/T-30s windows.
  SessionDeadline({
    DateTime Function()? clock,
    this.ladder = const DeadlineLadder(),
  }) : _clock = clock ?? DateTime.now;

  /// The injected wall clock.
  final DateTime Function() _clock;

  /// The notice ladder (thresholds + texts).
  final DeadlineLadder ladder;

  int? _deadlineEpochMs;
  int _armedAtEpochMs = 0;
  final Set<DeadlineNoticeKind> _fired = <DeadlineNoticeKind>{};

  /// Whether a deadline is currently armed.
  bool get isArmed => _deadlineEpochMs != null;

  /// The armed epoch-ms deadline, or null when unarmed.
  int? get deadlineEpochMs => _deadlineEpochMs;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  /// Milliseconds remaining on the armed deadline (negative once passed).
  /// Throws [StateError] when unarmed — check [isArmed] first.
  int get remainingMs {
    final deadline = _deadlineEpochMs;
    if (deadline == null) {
      throw StateError('no deadline armed');
    }
    return deadline - _nowMs;
  }

  /// Arms (or re-arms) the deadline [budget] from now. Re-arming resets
  /// the one-shot notice latches — each crossing fires once per arming.
  void setDuration(Duration budget) {
    if (budget.inMilliseconds <= 0) {
      throw FormatException('deadline duration must be positive');
    }
    setEpochMs(_nowMs + budget.inMilliseconds);
  }

  /// Arms (or re-arms) an absolute epoch-ms deadline. A past timestamp is
  /// a [FormatException] — never a silently expired clock. Re-arming
  /// resets the one-shot notice latches.
  void setEpochMs(int epochMs) {
    if (epochMs <= _nowMs) {
      throw FormatException('deadline is in the past');
    }
    _deadlineEpochMs = epochMs;
    _armedAtEpochMs = _nowMs;
    _fired.clear();
  }

  /// Arms the deadline from a user-facing spec (`25m`, `90s`, `1h30m`, or
  /// a bare epoch-ms integer). Throws [FormatException] on an invalid or
  /// past spec — the caller surfaces the message.
  void setFromSpec(String spec) {
    final parsed = parseDeadlineSpec(spec);
    if (parsed.epochMs != null) {
      setEpochMs(parsed.epochMs!);
    } else {
      setDuration(parsed.duration!);
    }
  }

  /// Clears the deadline: every consumer falls back to today's
  /// byte-for-byte behavior.
  void clear() {
    _deadlineEpochMs = null;
    _armedAtEpochMs = 0;
    _fired.clear();
  }

  /// The per-turn budget line for the LLM request context
  /// (`time-left: 5min`), or null when unarmed — the caller then leaves
  /// the request payload byte-for-byte untouched.
  String? budgetLine() =>
      isArmed ? 'time-left: ${formatTimeLeft(remainingMs)}' : null;

  /// The one-shot crossing notices newly reached since the last poll (or
  /// the arming). Each ladder crossing fires at most once per arming; a
  /// re-set/adjust re-arms the latches. Empty when unarmed or nothing new
  /// crossed. Poll sites: the steering poll (turn boundaries), so the
  /// notices ride the existing `<system-notice>` machinery.
  List<DeadlineNotice> pollNotices() {
    final deadline = _deadlineEpochMs;
    if (deadline == null) return const [];
    final now = _nowMs;
    final remaining = deadline - now;
    final total = deadline - _armedAtEpochMs;
    final out = <DeadlineNotice>[];
    void fire(DeadlineNoticeKind kind, bool crossed) {
      if (crossed && _fired.add(kind)) {
        out.add(
          DeadlineNotice(kind, ladder.text(kind, formatTimeLeft(remaining))),
        );
      }
    }

    fire(DeadlineNoticeKind.halfBudget, total > 0 && remaining <= total ~/ 2);
    fire(DeadlineNoticeKind.wrapUp, remaining <= ladder.wrapUpSteerMs);
    fire(DeadlineNoticeKind.finalAnswer, remaining <= ladder.finalAnswerMs);
    return out;
  }
}

/// Seeds the session deadline from the two boot sources with the ticket's
/// override order: the host env first, the CLI flag second (later wins).
///
/// The env value is an epoch-ms integer; missing/invalid/past = feature
/// OFF, silent (the host's env is not the user's typo — never nag about
/// it). The flag spec (`--timer`/`--deadline`) is the user's own words:
/// an invalid one throws [FormatException] and the host must surface it
/// as a usage error, never boot with a silently wrong clock.
SessionDeadline resolveSessionDeadline({
  String? envValue,
  String? flagSpec,
  DateTime Function()? clock,
}) {
  final deadline = SessionDeadline(clock: clock);
  final raw = envValue?.trim();
  if (raw != null && raw.isNotEmpty) {
    final epoch = int.tryParse(raw);
    if (epoch != null && epoch >= deadlineEpochMsFloor) {
      try {
        deadline.setEpochMs(epoch);
      } on FormatException {
        // Feature off, silent: the host env is not user input at the
        // keyboard (a past deadline is the host's stale export, not a
        // typo to nag about).
      }
    }
  }
  final flag = flagSpec?.trim();
  if (flag != null && flag.isNotEmpty) {
    deadline.setFromSpec(flag);
  }
  return deadline;
}
