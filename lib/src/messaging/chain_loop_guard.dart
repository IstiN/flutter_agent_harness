/// The smart agent↔agent chain guard (issue #2226): replaces the blunt
/// inbox-wake streak cap with EVIDENCE of looping.
///
/// A wake chain (per counterparty pair) tracks:
/// - **Content novelty**: consecutive cross-agent mails compared on
///   normalized text (ids/numbers masked) via local shingle-overlap
///   similarity — no model calls, no network (the documented fallback
///   path IS the implementation; there is no embedding provider in the
///   wake path by the issue's own non-goals).
/// - **Progress signals**: fresh identifiers (new ids/numbers/hashes in
///   the raw text). Templated-but-productive updates carry fresh state
///   every round, so high masked similarity alone is NEVER the verdict —
///   the money-project shape passes.
/// - **Loop verdict**: `stuckRounds` consecutive exchanges that are both
///   near-identical AND carry no fresh state → the chain is LOOPING.
/// - **Budget**: an autonomous-chain token budget (`recordSpend`, fed by
///   the host's turn usage); exhaustion pauses exactly like a verdict.
///
/// A pause is ADVISORY wake-gating only: mail stays queued and visible,
/// delivery semantics are untouched. The host renders the digest
/// ([chainPauseDigestLines]) and offers continue/stop; any delivered user
/// input resets everything (the human is watching).
library;

import 'agent_message.dart';
import 'chain_state_store.dart';

/// Why a chain paused.
enum ChainPauseReason {
  /// Near-identical content with no fresh state across `stuckRounds`.
  loop,

  /// The autonomous-chain token budget is exhausted.
  budget,
}

/// A pause verdict for one wake decision.
final class ChainPause {
  const ChainPause({required this.reason, required this.evidence});

  final ChainPauseReason reason;

  /// The human-readable evidence line ("last 4 exchanges ≥92% similar,
  /// no new ids/files" / "autonomous spend 412000/400000 tokens").
  final String evidence;
}

/// One counterparty pair-window's state.
final class _ChainWindow {
  String prevMasked = '';
  Set<String> prevStateTokens = {};
  int stuckRounds = 0;
  double lastSimilarity = 0;
}

/// The deterministic loop detector + chain budget. Pure — no I/O; the
/// host persists [snapshot]/[restore] via [ChainStateStore].
final class ChainLoopGuard {
  ChainLoopGuard({
    required this.similarityThreshold,
    required this.stuckRounds,
    required this.budgetTokens,
    this.enabled = true,
  }) : assert(stuckRounds >= 1),
       assert(similarityThreshold >= 0 && similarityThreshold <= 1);

  /// Masked-text pairwise similarity above which a no-progress exchange
  /// counts as a stuck round.
  final double similarityThreshold;

  /// Consecutive no-progress rounds before a loop verdict.
  final int stuckRounds;

  /// The autonomous-chain spend bound in tokens; `0` disables.
  final int budgetTokens;

  /// When false, loop verdicts never fire (the budget still does).
  final bool enabled;

  int tokensSpent = 0;

  bool _paused = false;
  ChainPause? _pause;
  final Map<String, _ChainWindow> _windows = {};

  /// Whether the chain is currently paused (sticky until
  /// [continueChain]/[resetFromUserInput]/[stopChain]).
  bool get paused => _paused;

  /// The current pause verdict (null when not paused).
  ChainPause? get pause => _pause;

  /// Whether the chain budget is exhausted.
  bool get budgetExhausted => budgetTokens > 0 && tokensSpent >= budgetTokens;

  /// The host books the wake run's turn usage here. Returns whether the
  /// booking crossed the budget (the NEXT decision pauses).
  void recordSpend(int tokens) {
    if (tokens <= 0 || _paused) return;
    tokensSpent += tokens;
  }

  /// Decides the wake for one pending agent-kind batch. Returns null
  /// (allow) or the pause verdict; a paused guard stays paused — the
  /// host's episode latch gates digest spam.
  ChainPause? evaluate(List<AgentMessage> pending) {
    if (_paused) return _pause;
    if (budgetExhausted) {
      _paused = true;
      return _pause = ChainPause(
        reason: ChainPauseReason.budget,
        evidence:
            'autonomous chain spend $tokensSpent/$budgetTokens tokens '
            'without user input',
      );
    }
    if (!enabled) return null;
    for (final message in pending) {
      if (message.kind != agentKind) continue;
      final pause = _feed(message.fromId, message.text);
      if (pause != null) {
        _paused = true;
        return _pause = pause;
      }
    }
    return null;
  }

  static const agentKind = AgentMessageKind.agent;

  /// Feeds one exchange into [sender]'s pair-window; a loop verdict when
  /// the stuck counter reaches [stuckRounds].
  ChainPause? _feed(String sender, String text) {
    final window = _windows.putIfAbsent(sender, _ChainWindow.new);
    final masked = maskText(normalizeText(text));
    final stateTokens = extractStateTokens(normalizeText(text));
    if (window.prevMasked.isEmpty) {
      // First exchange of the window: arm the comparison, never pause.
      window.prevMasked = masked;
      window.prevStateTokens = stateTokens;
      return null;
    }
    final similarity = shingleSimilarity(window.prevMasked, masked);
    final fresh = stateTokens.difference(window.prevStateTokens).isNotEmpty;
    window.lastSimilarity = similarity;
    if (similarity >= similarityThreshold && !fresh) {
      window.stuckRounds++;
    } else {
      // Genuinely different content OR fresh state: progress resets.
      window.stuckRounds = 0;
    }
    window.prevMasked = masked;
    window.prevStateTokens = stateTokens;
    if (window.stuckRounds >= stuckRounds) {
      return ChainPause(
        reason: ChainPauseReason.loop,
        evidence:
            'last $stuckRounds exchanges with ${senderMailbox(sender)} are '
            '${(similarity * 100).round()}% similar with no new ids/files',
      );
    }
    return null;
  }

  /// A delivered user input IS the user talking: streaks reset, the
  /// budget re-arms, the verdict clears (the human is watching).
  void resetFromUserInput() {
    _paused = false;
    _pause = null;
    tokensSpent = 0;
    _windows.clear();
  }

  /// The user's explicit "continue" on the digest: same reset, kept
  /// distinct for intent.
  void continueChain() => resetFromUserInput();

  /// The user's explicit "stop": the host drops the pending mail; the
  /// guard just clears state so a future chain starts fresh.
  void stopChain() => resetFromUserInput();

  ChainSnapshot snapshot() => ChainSnapshot(
    tokensSpent: tokensSpent,
    windows: {
      for (final MapEntry(key: sender, value: window) in _windows.entries)
        sender: ChainWindowState(
          stuckRounds: window.stuckRounds,
          prevMasked: window.prevMasked,
          prevStateTokens: window.prevStateTokens.toList(),
          lastSimilarity: window.lastSimilarity,
        ),
    },
  );

  void restore(ChainSnapshot snapshot) {
    tokensSpent = snapshot.tokensSpent;
    _windows
      ..clear()
      ..addEntries([
        for (final MapEntry(key: sender, value: state)
            in snapshot.windows.entries)
          MapEntry(
            sender,
            _ChainWindow()
              ..stuckRounds = state.stuckRounds
              ..prevMasked = state.prevMasked
              ..prevStateTokens = state.prevStateTokens.toSet()
              ..lastSimilarity = state.lastSimilarity,
          ),
      ]);
  }

  static String senderMailbox(String sender) => sender;
}

/// Lowercases and collapses whitespace; punctuation is stripped so
/// "Done." and "done" compare equal.
String normalizeText(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\w\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Masks digit runs (ids, counts, timestamps, hashes all contain digits)
/// so templated updates compare on SHAPE, not on the numbers that changed.
String maskText(String normalized) =>
    normalized.replaceAll(RegExp(r'\d+'), '#');

/// The raw identifiers of one exchange: digit-runs and hex-ish tokens.
/// A round with identifiers the previous round lacked has FRESH STATE —
/// the progress signal that keeps templated-but-productive chains alive.
Set<String> extractStateTokens(String normalized) => {
  for (final token in normalized.split(' '))
    if (token.contains(RegExp(r'\d')) ||
        RegExp(r'^[0-9a-f]{7,}$').hasMatch(token))
      token,
};

/// Jaccard overlap over word 3-grams (texts shorter than 3 words compare
/// as one shingle). 0 = disjoint, 1 = identical.
double shingleSimilarity(String a, String b) {
  final shinglesA = _shingles(a);
  final shinglesB = _shingles(b);
  if (shinglesA.isEmpty && shinglesB.isEmpty) return 1;
  if (shinglesA.isEmpty || shinglesB.isEmpty) return 0;
  final common = shinglesA.intersection(shinglesB).length;
  return common / shinglesA.union(shinglesB).length;
}

Set<String> _shingles(String text) {
  final words = text.split(' ').where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return {};
  if (words.length < 3) return {words.join(' ')};
  return {
    for (var i = 0; i <= words.length - 3; i++)
      '${words[i]} ${words[i + 1]} ${words[i + 2]}',
  };
}

/// The user-facing pause digest card (both hosts render these lines —
/// AC5: never silent). [pendingCount] is the host's queued-mail count.
List<String> chainPauseDigestLines({
  required ChainPauseReason reason,
  required String evidence,
  required int pendingCount,
  String? counterparty,
}) {
  final title = switch (reason) {
    ChainPauseReason.loop => 'chain paused — loop detected',
    ChainPauseReason.budget => 'chain paused — budget exhausted',
  };
  return [
    '┌─ $title',
    if (counterparty != null) '│ counterparty: $counterparty',
    '│ evidence: $evidence',
    '│ pending mail: $pendingCount message(s) — QUEUED, nothing dropped',
    '│ continue: /chain continue (resets the budget, overrides the verdict)',
    '│ stop: /chain stop (drops the pending mail with a tombstone receipt)',
    '└─ any user input also resumes the chain',
  ];
}
