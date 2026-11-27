// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C3 — the honest context notices (`part of` so it sees the
/// library-private CLI surface).
///
/// - [_maybeEmitNearLimitNotice] — the near-limit notice: once per
///   compaction cycle (`_nearLimitNoticeLatch`), when the pre-request
///   estimate reaches the near-limit point.
/// - [_emitPostHideNotice] — the post-hide notice: exactly one per hide
///   pass, N from the hide records the pass appended (every mechanism),
///   X/Y from the live request estimate, W from the one window; it also
///   re-arms the near-limit latch (the context dropped — the next
///   crossing is a new cycle).
/// - [_deliverContextNotice] — the one delivery path: the model gets the
///   notice as a QUEUED `<system-notice>` synthetic user record riding
///   its next request as the last message (never a turn of its own); the
///   human gets the same line dim; the supervisor gets the
///   `context_notice` HEP frame.
///
/// Numbers are the harness's: the SAME basis as the compaction trigger,
/// the over-window guard and the status meter (`_liveRequestTokens`,
/// `_effectiveContextWindow` — I4). Every text comes from the pure
/// builders in `compaction/context_notices.dart`, so the task executor
/// and every host tell the model the same thing.
part of 'agent_cli.dart';

extension AgentCliContextNotices on AgentCli {
  /// The near-limit notice (gh-2423 C3, AC7). [tokens] is the live
  /// pre-request estimate on the trigger's basis. Emission is latched:
  /// armed at session start, one notice per compaction cycle, re-armed by
  /// every hide ([_emitPostHideNotice]). In the soft-window regime
  /// (gh-2411: compaction skipped for the session) the notice must NOT
  /// fire — its last clause would be false; that regime gates this ONE
  /// call site.
  Future<void> _maybeEmitNearLimitNotice(int tokens) async {
    if (!_nearLimitNoticeLatch.armed) return;
    final window = _noticeContextWindow();
    if (!nearLimitReached(
      tokens: tokens,
      window: window,
      settings: _effectiveCompactionSettings,
    )) {
      return;
    }
    if (!_nearLimitNoticeLatch.take()) return;
    final line = nearLimitNoticeLine(
      tokens: tokens,
      window: window,
      estimated: _noticeNumbersEstimated,
    );
    await _deliverContextNotice(line);
    _hep?.contextNotice(
      kind: 'near-limit',
      tokens: tokens,
      window: window,
      estimated: _noticeNumbersEstimated,
    );
  }

  /// The post-hide notice (gh-2423 C3, AC6). [knownHiddenRanges] is the
  /// hide-record id snapshot taken BEFORE the compaction run; the
  /// notice fires only when the run appended hides (a summary-only or
  /// zero-pass run hid nothing — no notice), naming the total (multi-pass:
  /// one notice, E4). [relief] = the hide ran inside the over-window /
  /// message-cap relief (see [_deliverContextNotice]).
  Future<void> _emitPostHideNotice({
    required Set<String> knownHiddenRanges,
    required int tokensBefore,
    required int tokensNow,
    Session? session,
    bool relief = false,
  }) async {
    session ??= _session;
    if (session == null) return;
    final hidden = newlyHiddenRecordCount(
      await session.getEntries(),
      knownHiddenRanges,
    );
    if (hidden == 0) return;
    final window = _noticeContextWindow();
    final snapshot = await _agent.workingSetStore?.load();
    final line = postHideNoticeLine(
      hiddenRecords: hidden,
      tokensNow: tokensNow,
      tokensBefore: tokensBefore,
      window: window,
      hasWorkingSet: snapshot != null && !snapshot.isClear,
      estimated: _noticeNumbersEstimated,
    );
    if (line.isEmpty) return;
    await _deliverContextNotice(line, relief: relief);
    _hep?.contextNotice(
      kind: 'post-hide',
      tokens: tokensNow,
      window: window,
      hidden: hidden,
      estimated: _noticeNumbersEstimated,
    );
    // The context dropped: the next near-limit crossing is a new cycle.
    _nearLimitNoticeLatch.rearm();
  }

  /// The ONE window the notices name (W): the model's effective context
  /// window — an exact setting, never a heuristic figure. The single
  /// place to re-point when the shared context-usage source of truth
  /// lands (gh-2394 follow-up).
  int _noticeContextWindow() => _effectiveContextWindow;

  /// The provenance of the notices' token figures. Today ALWAYS a
  /// heuristic estimate: every figure comes from the compaction
  /// trigger's own basis (`_liveRequestTokens` — `estimateRequestTokens`
  /// over the live transcript plus the request overhead), and no
  /// provider reports the size of a request that was not sent yet. So
  /// the texts carry the `≈` and the HEP frame `estimate: true`; a
  /// provider-reported figure flips this ONE flag (and is preferred
  /// where it exists for the current request — none does today).
  static const bool _noticeNumbersEstimated = true;

  /// Hands [line] to the model and prints it once, dim. Default: a
  /// QUEUED notice (`Agent.queueContextNotice`) — the loop drains it
  /// right before it injects queued steering, so it rides the agent's
  /// NEXT request as the last message and is persisted there as a
  /// synthetic user record (the `<system-notice>` envelope keeps it
  /// machine content for every classifier). Deliberately NOT
  /// `_agent.steer`: the steering queue's stop-check drain (issue #314)
  /// would open a whole extra model turn for a notice — and under a low
  /// trigger turn every notice into a notice → answer → hide → notice
  /// loop. [relief]: the loop builds its retry request from the relieved
  /// transcript without passing the injection point, so there the notice
  /// is persisted at the session leaf first and mirrored into the
  /// agent's in-memory state at the same position; the relief returns
  /// that very state as the relieved transcript, so the retried request
  /// carries it and nothing stays queued.
  Future<void> _deliverContextNotice(String line, {bool relief = false}) async {
    final message = UserMessage.text(contextNoticeEnvelope(line));
    io.writeln(_style.dim(line));
    if (!relief) {
      _agent.queueContextNotice(message);
      return;
    }
    await _persistOneMessage(message);
    _agent.state.messages = [..._agent.state.messages, message];
  }
}
