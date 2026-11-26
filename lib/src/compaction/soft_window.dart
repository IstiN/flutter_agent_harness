/// The soft-window regime (gh-2411): the context window is a SOFT
/// target, and no trim can ever land a request under it.
///
/// Every wire request carries the fixed overhead — the system prompt
/// and the tool schemas — and the newest real user turn is never dropped
/// (see `newest_user_turn.dart`). When `overhead + newest user turn`
/// already reaches the compaction trigger (`window - reserveTokens`),
/// relief is structurally futile: hiding and trimming can only reach
/// that floor, still over the trigger, so every turn re-fired relief,
/// the local trim valve bounded the transcript again and again, and the
/// model saw its own record tag instead of the question. In that regime
/// the compaction tiers do NOTHING: the request goes out as is (the
/// owner's rule — a slight overrun beats an invisible user turn) and the
/// host warns once. The loop's over-window guard draws the SAME line on
/// its own request (ONE predicate for the guard, the meter and every
/// compaction tier): a request overflowing for any other reason — older
/// tool groups, a long turn — keeps the guard and its relief, which
/// carries the user turn across the cut. Pure predicates; the warning
/// and the skip live in the hosts.
library;

import 'dart:math' as math;

import '../context.dart';
import '../types.dart';
import 'newest_user_turn.dart' show newestRealUserTurnIndex;
import 'overhead_calibration.dart';
import 'token_estimation.dart' show estimateRequestTokens, estimateTokens;

/// Whether the fixed [overheadTokens] plus the never-dropped newest user
/// turn ([newestUserTurnTokens], 0 when unknown) already reaches the
/// trigger of [window] — no trim can land under it. `false` for an
/// unlimited window (`window <= 0`).
bool windowBelowFixedOverhead({
  required int overheadTokens,
  required int window,
  required int reserveTokens,
  int newestUserTurnTokens = 0,
}) {
  if (window <= 0) return false;
  final trigger = math.max(0, window - math.max(0, reserveTokens));
  return overheadTokens + math.max(0, newestUserTurnTokens) >= trigger;
}

/// The calibrated fixed overhead of a request — system prompt + tool
/// schemas, on the same basis as [estimateRequestTokens] — the floor no
/// relief can ever go under.
int fixedOverheadTokens(
  String? systemPrompt,
  List<Tool> tools, {
  OverheadCalibration calibration = OverheadCalibration.uncalibrated,
}) => estimateRequestTokens(
  // The empty transcript keeps the estimate UNANCHORED: the overhead is
  // what the unanchored basis prices in.
  const [],
  systemPrompt: systemPrompt,
  tools: tools,
  calibration: calibration,
);

/// [windowBelowFixedOverhead] over a live transcript: the calibrated
/// fixed overhead of [systemPrompt] + [tools], plus the newest real user
/// turn of [messages] — the compaction trigger's "no trim can ever land
/// under me" test.
bool softWindowRegime({
  required List<Message> messages,
  required String? systemPrompt,
  required List<Tool> tools,
  required int window,
  required int reserveTokens,
  OverheadCalibration calibration = OverheadCalibration.uncalibrated,
}) {
  final turn = newestRealUserTurnIndex(messages);
  return windowBelowFixedOverhead(
    overheadTokens: fixedOverheadTokens(
      systemPrompt,
      tools,
      calibration: calibration,
    ),
    window: window,
    reserveTokens: reserveTokens,
    newestUserTurnTokens: turn < 0 ? 0 : estimateTokens(messages[turn]),
  );
}

/// Whether the soft window lets THIS request through UNTRIMED (gh-2411 +
/// the owner's live test): the regime holds AND the honest estimate of the
/// whole request ([requestTokens] — the loop guard's own number, the ctx
/// meter's) is still UNDER the [window]. The ONE predicate the hosts'
/// compaction skip and the loop guard share:
///
/// - under the window nothing is trimmed — no relief can ever reach the
///   trigger, so the pass would thrash; ONE warning names the real fix;
/// - at or over the window the request is simply over the window: the
///   hide-only relief runs (the newest user turn still carried verbatim)
///   and the guard keeps its stop. Skipping there too is what let the
///   owner's session grow to 114% with no pass ever running.
///
/// `false` for an unlimited window (`window <= 0`).
bool softWindowSkip({
  required List<Message> messages,
  required String? systemPrompt,
  required List<Tool> tools,
  required int window,
  required int reserveTokens,
  required int requestTokens,
  OverheadCalibration calibration = OverheadCalibration.uncalibrated,
}) {
  if (window <= 0 || requestTokens >= window) return false;
  return softWindowRegime(
    messages: messages,
    systemPrompt: systemPrompt,
    tools: tools,
    window: window,
    reserveTokens: reserveTokens,
    calibration: calibration,
  );
}

/// The soft-window warning's once-per-session latch (gh-2411): the
/// regime holds for EVERY turn of the session, so the notice must be
/// visible once and then stay quiet — a warning repeated on every turn
/// is noise the owner stops reading. Keyed on the session id: a new
/// session (resume, `/new`) re-arms it.
///
/// gh-2411 follow-up #5c (C2 — owner live test round 4): ONE latch per
/// DISTINCT warning text within a session, with or without a session id.
/// The old rule let a session whose id was not known yet warn on every
/// sighting, and warned AGAIN the moment the id arrived — a resumed
/// session printed the same line at boot and at its first prompt. The
/// id of a session warned before it had one now carries its latches over.
final class SoftWindowNotice {
  /// Warned texts per session, `'<sessionId>\u0000<text>'` (an empty id
  /// while the session's id is not known yet).
  final Set<String> _warned = <String>{};

  /// A session was warned before its id was known: the next known id
  /// belongs to that same session.
  bool _anonymous = false;

  /// Whether the warning [text] was not yet shown in session [sessionId].
  bool shouldWarn(String? sessionId, {String text = ''}) {
    if (sessionId != null && _anonymous) {
      for (final key in _warned.toList()) {
        if (key.startsWith('\u0000')) {
          _warned
            ..remove(key)
            ..add('$sessionId$key');
        }
      }
      _anonymous = false;
    }
    if (sessionId == null) _anonymous = true;
    return _warned.add('${sessionId ?? ''}\u0000$text');
  }
}
