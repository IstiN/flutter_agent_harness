/// The identical-tool-call loop guard (gh-2461): a pure, provider-agnostic
/// streak detector that stops degenerate identical-call loops the 2026-11-27
/// incident class made unbounded — two different models (glm-5.3-flash and
/// gemini-4-argon) burned 71 identical `read` calls in a row (~7 s per
/// provider cycle) after a wire `finish_reason: "error"` replay window, and
/// nothing in the harness noticed.
///
/// The mechanism mirrors the tool-misuse circuit breaker (issue #862), its
/// sibling for the identical-call-FAILS case: this guard owns the
/// identical-call-SUCCEEDS case, where every exchange is healthy and only
/// the repetition is the disease. Loop-owned state machine — the agent loop
/// feeds one verdict per assistant turn and consumes the notice/abort
/// texts; no I/O, no provider coupling, no dialect coupling (the two
/// incidents were different models on the same dialect, so the detector
/// keys on the harness-side turn shape, never on provider wording).
///
/// Turn identity: the ordered list of the assistant message's tool calls,
/// each keyed (name, recursively sorted-key JSON of the arguments) — a
/// byte-identical repeat is a loop signal, a different-args repeat is
/// legitimate work. A turn with no tool calls, an injected user/steering
/// message, or a fresh prompt resets the streak. Tools whose CONTRACT is
/// repetition (watch/polling) are exempted per call site by name
/// (`AgentLoopConfig.identicalCallExemptTools`): exempt turns neither
/// advance nor reset the streak.
///
/// Thresholds: at [noticeThreshold] consecutive identical turns the loop
/// injects ONE enveloped `<system-notice>` ("stop and re-plan") — the same
/// synthetic-envelope channel the gh-2423 C3 context notices use, so every
/// classifier reads it as machine content. If the identical streak then
/// reaches [abortThreshold], the run ends with an honest
/// `StopReason.error` naming the call — a degeneration must never burn
/// unbounded provider calls unattended.
library;

import 'dart:convert';

import '../types.dart';

/// Consecutive identical tool-call turns before the corrective
/// `<system-notice>` rides the next request. Inside the ticket's suggested
/// 4–6 window; 5 leaves legitimate short poll sequences untouched.
const int defaultIdenticalCallNoticeThreshold = 5;

/// Consecutive identical tool-call turns that end the run with an honest
/// error — three more identical calls AFTER the notice were ignored. 0 (or
/// any non-positive value) disables the abort (the notice still fires).
const int defaultIdenticalCallAbortThreshold = 8;

/// Recursively sorts map keys and encodes the arguments as canonical JSON,
/// so `{'a': 1, 'b': 2}` and `{'b': 2, 'a': 1}` are the same call —
/// provider arg maps arrive in wire order, and the loop identity is the
/// CALL, not its serialization.
///
/// Total by construction (gh-2461 review): leaves jsonEncode cannot carry
/// (the `Object()` of the unserializable-args fixture) degrade to their
/// `toString()` form instead of throwing — the guard must never be the
/// thing that wedges a run whose args the CLI renders safely elsewhere.
String normalizedToolCallArgsJson(Map<String, dynamic> arguments) =>
    jsonEncode(_normalizeJson(arguments));

Object? _normalizeJson(Object? value) => switch (value) {
  null => null,
  bool() => value,
  num() => value,
  String() => value,
  Map<Object?, Object?> map => {
    for (final key in map.keys.toList()..sort())
      '$key': _normalizeJson(map[key]),
  },
  List<Object?> list => [for (final item in list) _normalizeJson(item)],
  _ => value.toString(),
};

/// The loop-identity key of one assistant turn: `null` when the message
/// carries NO tool calls (a text answer — the model broke out; the streak
/// resets). Multi-call turns key on the whole ordered set, so a turn that
/// repeats one call while adding another is a DIFFERENT key (real work).
String? identicalCallTurnKey(AssistantMessage message) {
  final calls = [
    for (final block in message.content)
      if (block is ToolCall) block,
  ];
  if (calls.isEmpty) return null;
  return jsonEncode([
    for (final call in calls)
      [call.name, normalizedToolCallArgsJson(call.arguments)],
  ]);
}

/// Whether EVERY tool call of the turn names an exempt tool (a watch or
/// polling call site that owns its repetition by contract).
bool turnIsExempt(AssistantMessage message, Set<String> exemptTools) {
  final calls = [
    for (final block in message.content)
      if (block is ToolCall) block,
  ];
  if (calls.isEmpty) return false;
  return calls.every((call) => exemptTools.contains(call.name));
}

/// What the loop must do after one assistant turn.
enum IdenticalCallAction { none, injectNotice, abortRun }

/// The verdict for one assistant turn: the action plus the exact message
/// text it carries (the enveloped notice, or the honest abort error).
final class IdenticalCallVerdict {
  const IdenticalCallVerdict(this.action, [this.text = '']);

  /// Convenience verdicts.
  const IdenticalCallVerdict.none() : this(IdenticalCallAction.none);

  final IdenticalCallAction action;

  /// The notice line (enveloped) or the abort error text; empty for none.
  final String text;
}

/// The streak state for ONE agent-loop run. The loop creates it at run
/// start (fresh prompt = fresh streak) and feeds every healthy assistant
/// turn before the tool phase.
final class IdenticalCallLoopGuard {
  /// Creates a guard. [noticeThreshold] ≤ 0 disables the whole guard (the
  /// loop then passes no verdicts); [abortThreshold] ≤ 0 disables only the
  /// abort.
  IdenticalCallLoopGuard({
    this.noticeThreshold = defaultIdenticalCallNoticeThreshold,
    this.abortThreshold = defaultIdenticalCallAbortThreshold,
    Set<String> exemptTools = const <String>{},
  }) : assert(noticeThreshold != 0),
       _exemptTools = Set<String>.unmodifiable(exemptTools);

  /// Consecutive identical turns before the notice arms.
  final int noticeThreshold;

  /// Consecutive identical turns that end the run (0 disables).
  final int abortThreshold;

  /// Call sites whose repetition is the tool's contract (watch commands,
  /// polling probes).
  final Set<String> _exemptTools;

  String? _lastKey;
  int _streak = 0;
  bool _noticeDeliveredThisStreak = false;

  /// How many consecutive identical turns the streak stands at.
  int get streak => _streak;

  /// A user/steering message joined between turns — the loop is no longer
  /// unattended; the degenerate-streak evidence resets.
  void resetStreak() {
    _lastKey = null;
    _streak = 0;
    _noticeDeliveredThisStreak = false;
  }

  /// Folds one healthy assistant turn. Verdict order: an exempt turn is
  /// transparent; a tool-free turn resets; an identical turn advances and
  /// may arm the notice (once per streak) or end the run.
  ///
  /// [turnSucceeded] false (every tool result of the turn is an error)
  /// keeps the guard transparent: failing identical calls are the
  /// tool-misuse circuit breaker's jurisdiction (issue #862 — its note and
  /// refusal ladder owns that loop); this guard owns the identical-call-
  /// SUCCEEDS degeneration, where every exchange is healthy and only the
  /// repetition is the disease (gh-2461).
  IdenticalCallVerdict acceptTurn(
    AssistantMessage message, {
    bool turnSucceeded = true,
  }) {
    final key = identicalCallTurnKey(message);
    if (key == null) {
      resetStreak();
      return const IdenticalCallVerdict.none();
    }
    if (turnIsExempt(message, _exemptTools)) {
      return const IdenticalCallVerdict.none();
    }
    if (!turnSucceeded) {
      // The breaker's domain: a run of failing identical calls gets the
      // breaker's corrective note and refusal, never a guard abort.
      return const IdenticalCallVerdict.none();
    }
    if (key == _lastKey) {
      _streak++;
    } else {
      _lastKey = key;
      _streak = 1;
      _noticeDeliveredThisStreak = false;
    }
    if (_streak >= abortThreshold && abortThreshold > 0) {
      return IdenticalCallVerdict(
        IdenticalCallAction.abortRun,
        identicalCallAbortError(message, _streak),
      );
    }
    if (_streak >= noticeThreshold && !_noticeDeliveredThisStreak) {
      _noticeDeliveredThisStreak = true;
      return IdenticalCallVerdict(
        IdenticalCallAction.injectNotice,
        loopGuardNoticeText(message, _streak),
      );
    }
    return const IdenticalCallVerdict.none();
  }
}

/// The enveloped corrective notice the loop injects as a synthetic user
/// message — the gh-2423 C3 context-notice envelope, so every classifier
/// (`isSyntheticUserText`) reads it as machine content and it never
/// becomes a pinned real user turn.
String loopGuardNoticeText(AssistantMessage message, int streak) {
  final call = _firstToolCall(message);
  final label = call == null ? 'the same call' : _callLabel(call);
  return '<system-notice>\n'
      'loop guard: you have issued $label with byte-identical arguments '
      '$streak times in a row. Each call succeeded — repeating it again '
      'cannot produce new information. This pattern matches a degenerate '
      'loop, not deliberate work: do NOT repeat the call. Stop and '
      're-plan — change the approach or the arguments, or use the result '
      'you already have.\n'
      '</system-notice>';
}

/// The honest terminal the run ends with once the identical streak blows
/// past the abort threshold: it names the call, the streak, and the
/// opt-out — a model degeneration must never burn provider calls
/// unattended, and a post-mortem must see the guard's verdict verbatim.
String identicalCallAbortError(AssistantMessage message, int streak) {
  final call = _firstToolCall(message);
  final label = call == null ? 'the same call' : _callLabel(call);
  return 'identical tool-call loop guard: $label was issued $streak times '
      'in a row with byte-identical arguments, including after the loop '
      'guard notice — the run stops here instead of burning unbounded '
      'provider calls on a degenerate loop. If this repetition is '
      'intentional (a watch or polling command), declare the tool in '
      'agent.identicalCallExemptTools to opt it out per call site.';
}

ToolCall? _firstToolCall(AssistantMessage message) {
  for (final block in message.content) {
    if (block is ToolCall) return block;
  }
  return null;
}

/// Stable, bounded call label for the notice/error texts: `name(args)`,
/// canonical JSON, capped so a multi-KB argument map cannot flood a
/// terminal message.
String _callLabel(ToolCall call) {
  final args = normalizedToolCallArgsJson(call.arguments);
  final capped = args.length <= 160 ? args : '${args.substring(0, 160)}…';
  return '${call.name}($capped)';
}
