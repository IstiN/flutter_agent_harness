/// Per-call foreground liveness reminders (gh-1055): the headless/line-mode
/// console presentation for a tool call that runs long — the analog of the
/// TUI's visible-waiting row, which line mode cannot repaint.
///
/// While a foreground tool call is in flight, the tracker (one instance per
/// CLI host) evaluates on a ~60s chain: past `waiting.toolLivenessSeconds`
/// every tick prints ONE grep-friendly status line (elapsed seconds, tool
/// name, short command tail, and the #1349 background hint); past
/// `waiting.toolEscalateSeconds` the tick instead prints — exactly once per
/// stuck call — the fuller background escape-hatch hint, so an operator
/// tailing the run (and the model reading its own logs) learns the call is
/// a `bash background: true` / `/tasks` / `--wait-for-jobs` candidate.
///
/// One clock only: every elapsed value derives from the host's
/// waiting-clock seam (the same `waitingClock` the #450 waiting layer and
/// the future #1054 stuck-call heartbeat records use — no second clock).
///
/// The class itself is transport-free; the host (CLI) wires the print sink
/// through [ToolLivenessTracker.onRemind]/[onEscalate].
library;

import 'dart:async';

import 'tui_theme.dart';

/// Default threshold before per-call liveness reminders start (`waiting:
/// toolLivenessSeconds`; `0` disables the reminders).
const defaultToolLivenessSeconds = 60;

/// Default reminder cadence in seconds (`waiting: toolLivenessTickSeconds`;
/// `0` disables the production timer chain — the tick seam still evaluates).
const defaultToolLivenessTickSeconds = 60;

/// Default threshold for the one-time background escape-hatch hint
/// (`waiting: toolEscalateSeconds`; `0` disables the hint).
const defaultToolEscalateSeconds = 300;

/// The background escape hatch an escalation line names (gh-1055): the
/// tool flag, the job board, the headless wait flag, and — AC6 — the
/// cancellation affordance per case: a backgrounded call stops via its
/// job id (`fa bash_job stop <id>`); the foreground call this tracker
/// watches has only Ctrl+C (the SIGINT parity exit) / inbox steering,
/// which land only once the call unwinds (until #1053 bounds the shell).
const String toolLivenessEscalationHint =
    'background candidate: bash background: true, job board /tasks, '
    '--wait-for-jobs · cancel: fa bash_job stop <id> once backgrounded; '
    'Ctrl+C / inbox steering takes effect once the call unwinds '
    '(until #1053)';

/// The short background hint every periodic reminder line carries
/// (issue #1349): a warned parked turn is still a parked turn, so each
/// reminder names the escape while the call keeps running — the model
/// reading its own logs sees the option before the 300s escalation.
const String toolLivenessForegroundHint =
    'consider background: true for long waits (settle notification wakes you)';

/// Flatten + clip budget for the command tail inside a liveness line — the
/// line must stay grep-friendly and single-line (repeated every tick).
const int toolLivenessDetailClip = 96;

/// Per-turn cap on #1185 stuck-call nudges (E2, the TTSR
/// `maxInjectionsPerTurn` analog): a turn whose calls keep hanging gets
/// at most this many model-facing nudges, refilled at each real turn
/// start — auto-continue turns deliberately do not refill (the reset
/// sits after the `_beginUserPrompt` auto-continue early-return, so a
/// degenerate empty-reply loop cannot farm fresh nudges). Per-call dedup
/// already bounds one call to one nudge, so breaching the cap takes many
/// DISTINCT stuck calls, and a model that ignores them burns the cap
/// honestly instead of drowning its context.
const int maxToolNudgesPerTurn = 3;

/// The #1185 model-facing nudge's sender anchor — the grep-friendly
/// attribution prefix of every injected notice (`[liveness watchdog] …`).
/// Exported because it is a delivery contract: operators and tests grep
/// for it, so lib and tests must share one literal.
const String toolNudgeAnchor = '[liveness watchdog]';

/// The #1185 model-facing nudge (the steering injection an escalation
/// fires): same facts as the console escalation line, addressed to the
/// MODEL through the steering channel (the agent's follow-up queue —
/// boundary delivery without the soft-yield signal) — decide: keep
/// waiting, background the work, or kill the job. The harness takes no
/// action itself (auto-kill stays a non-goal); the notice is a
/// `<system-notice>` user message, the same shape the background-job
/// settle notice uses.
String toolNudgeNotice(ToolLivenessCall call, DateTime now) {
  final seconds = now.difference(call.startedAt).inSeconds;
  return '<system-notice>\n'
      '$toolNudgeAnchor Foreground tool call `${call.toolName}` '
      '("${clipToolLivenessDetail(call.detail)}") has been running '
      '${seconds}s with no output. Decide and act on your next turn: keep '
      'waiting (continue as-is), background the work (`bash background: '
      'true` for a new command; a call already moved to the background is '
      'a job — manage it with bash_job action: output | status | stop), or '
      'kill the job. This notice does not stop the call.\n'
      '</system-notice>';
}

/// One watched foreground tool call. The tracker owns the instances; the
/// escalated flag flips when the hint fired for THIS call.
final class ToolLivenessCall {
  ToolLivenessCall({
    required this.id,
    required this.toolName,
    required this.detail,
    required this.startedAt,
  });

  /// The tool call id (`ToolCall.id`).
  final String id;

  /// The tool's name (`bash`, `read`, …).
  final String toolName;

  /// The short human detail (the command tail, path, question) — the same
  /// string the tool row showed at start.
  final String detail;

  /// When the call started — read from the tracker's clock (the host's
  /// waiting-clock seam; gh-1055 AC5: one clock for every elapsed value).
  final DateTime startedAt;

  /// Whether the background hint already fired for this call (AC3: exactly
  /// once per stuck call).
  bool escalated = false;
}

/// Watches in-flight foreground tool calls and fires the liveness lines.
///
/// One-shot timer chain, not [Timer.periodic] — the cadence getter is read
/// every leg so a config change applies at the next tick, and the chain
/// disarms the moment the last call ends. Transport-free.
final class ToolLivenessTracker {
  ToolLivenessTracker({
    required void Function(ToolLivenessCall call) onRemind,
    required void Function(ToolLivenessCall call) onEscalate,
    int Function()? livenessSeconds,
    int Function()? tickSeconds,
    int Function()? escalateSeconds,
    DateTime Function()? clock,
  }) : _onRemind = onRemind,
       _onEscalate = onEscalate,
       _livenessSeconds = livenessSeconds ?? (() => defaultToolLivenessSeconds),
       _tickSeconds = tickSeconds ?? (() => defaultToolLivenessTickSeconds),
       _escalateSeconds = escalateSeconds ?? (() => defaultToolEscalateSeconds),
       _clock = clock ?? DateTime.now;

  final void Function(ToolLivenessCall call) _onRemind;
  final void Function(ToolLivenessCall call) _onEscalate;
  final int Function() _livenessSeconds;
  final int Function() _tickSeconds;
  final int Function() _escalateSeconds;
  final DateTime Function() _clock;

  /// In-flight calls by tool-call id; insertion order = call start order.
  final _calls = <String, ToolLivenessCall>{};

  Timer? _timer;

  /// The watched calls, oldest first.
  List<ToolLivenessCall> get inFlight => [..._calls.values];

  /// A foreground tool call started: begin watching it. The chain arms
  /// only when idle — a call starting mid-leg waits for the running leg
  /// (the aggregate tick covers every in-flight call anyway).
  void callStarted(String id, String toolName, String detail) {
    _calls[id] = ToolLivenessCall(
      id: id,
      toolName: toolName,
      detail: detail,
      startedAt: _clock(),
    );
    if (_timer == null) _arm();
  }

  /// The call finished: the watch (and the escalated state) goes with it —
  /// a NEW stuck call escalates afresh.
  void callEnded(String id) {
    _calls.remove(id);
    if (_calls.isEmpty) stop();
  }

  /// Disarms the chain (last call ended, or the host is shutting down).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One evaluation now: for every in-flight call, fire lines by elapsed —
  /// the one-time escalation hint past the escalation threshold (that tick
  /// the hint IS the liveness line), otherwise the periodic reminder past
  /// the liveness threshold (continues after the hint fired, and after it).
  /// `toolLivenessSeconds: 0` is the feature kill switch; a disabled
  /// escalation (`toolEscalateSeconds: 0`) keeps the reminders.
  ///
  /// Mirrors the sibling `WaitingHeartbeat.tick` (issue #450): the pending
  /// leg is cancelled first and the chain re-arms a full cadence from
  /// NOW — so the manual seam is observable (it owns the chain state) and
  /// can never double-fire with the production leg. The production timer
  /// legs land here; tests call it directly.
  void tick() {
    _timer?.cancel();
    _timer = null;
    _evaluate();
    if (_calls.isNotEmpty) _arm();
  }

  void _evaluate() {
    if (_calls.isEmpty) return;
    final remindAfter = _livenessSeconds();
    if (remindAfter <= 0) return;
    final escalateAfter = _escalateSeconds();
    final now = _clock();
    for (final call in inFlight) {
      final elapsed = now.difference(call.startedAt).inSeconds;
      if (elapsed < remindAfter) continue;
      if (escalateAfter > 0 && elapsed >= escalateAfter) {
        if (call.escalated) {
          _onRemind(call);
          continue;
        }
        call.escalated = true;
        _onEscalate(call);
        continue;
      }
      _onRemind(call);
    }
  }

  void _arm() {
    if (_calls.isEmpty) return;
    final seconds = _tickSeconds();
    if (seconds <= 0) return;
    _timer = Timer(Duration(seconds: seconds), () {
      _timer = null;
      tick();
    });
  }
}

/// The periodic reminder line (gh-1055 AC1): a pending glyph + the tool
/// tag + the command tail, e.g. `○ [bash] sleep 500 — running 120s ·
/// consider background: true …` (gh-1446 AC8: the glyph resolves through
/// the symbol table, no hardcoded `⏳`). Single line, tool name, short
/// command tail, elapsed seconds, and the #1349 background hint.
String toolLivenessReminderLine(ToolLivenessCall call, DateTime now) =>
    _livenessLine(call, now, hint: toolLivenessForegroundHint);

/// The escalation line (gh-1055 AC3): the reminder's facts plus the
/// background escape hatch. Emitted once per stuck call.
String toolLivenessEscalationLine(ToolLivenessCall call, DateTime now) =>
    _livenessLine(call, now, hint: toolLivenessEscalationHint);

String _livenessLine(ToolLivenessCall call, DateTime now, {String? hint}) {
  final elapsed = now.difference(call.startedAt).inSeconds;
  final detail = clipToolLivenessDetail(call.detail);
  final pending = FaThemeController.instance.sym('status.pending');
  final head = detail.isEmpty
      ? '$pending [${call.toolName}] running ${elapsed}s'
      : '$pending [${call.toolName}] $detail — running ${elapsed}s';
  return hint == null ? head : '$head · $hint';
}

/// Guarantees the single-line rule: whitespace runs collapse (a heredoc or
/// multi-line command never spans lines), and an overlong tail clips with
/// an ellipsis — the full command lives in the tool row above.
String clipToolLivenessDetail(String detail) {
  final flat = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= toolLivenessDetailClip) return flat;
  return '${flat.substring(0, toolLivenessDetailClip)}…';
}
