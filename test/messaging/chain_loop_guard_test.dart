import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The smart agent↔agent chain guard (issue #2226): loop detection via
/// masked-text similarity fused with fresh-state signals, the autonomous
/// chain token budget, sticky pauses, and restart-safe persistence.
void main() {
  ChainLoopGuard guard({
    double similarityThreshold = 0.92,
    int stuckRounds = 4,
    int budgetTokens = 0,
    bool enabled = true,
  }) => ChainLoopGuard(
    similarityThreshold: similarityThreshold,
    stuckRounds: stuckRounds,
    budgetTokens: budgetTokens,
    enabled: enabled,
  );

  test('#2226 AC2: a LOOPING chain pauses after stuckRounds — identical '
      'exchanges with no new state (TDD)', () {
    final g = guard(stuckRounds: 4);
    // The first exchange arms the window; every further identical
    // exchange is a stuck round.
    expect(g.evaluate([_mail('e1', 'are you there? please confirm.')]), isNull);
    expect(
      g.evaluate([_mail('e2', 'are you there? please confirm.')]),
      isNull,
      reason: 'stuck 1',
    );
    expect(
      g.evaluate([_mail('e3', 'are you there? please confirm.')]),
      isNull,
      reason: 'stuck 2',
    );
    expect(
      g.evaluate([_mail('e4', 'are you there? please confirm.')]),
      isNull,
      reason: 'stuck 3',
    );
    final pause = g.evaluate([_mail('e5', 'are you there? please confirm.')]);
    expect(pause, isNotNull, reason: 'stuck 4 reaches the verdict');
    expect(pause!.reason, ChainPauseReason.loop);
    expect(pause.evidence, contains('similar'));
    expect(pause.evidence, contains('no new ids/files'));
  });

  test('#2226 AC1: the money-project shape NEVER pauses — templated '
      'updates carrying fresh ids/commits every round', () {
    final g = guard(stuckRounds: 4);
    for (var round = 1; round <= 12; round++) {
      final pause = g.evaluate([
        _mail(
          'r$round',
          'build fixed: cost blocker resolved, bear_naive recalculated, '
              'commit abc000$round delivered, top-set package r$round '
              'ready for audit',
        ),
      ]);
      expect(
        pause,
        isNull,
        reason: 'round $round carries fresh ids — productive work',
      );
    }
  });

  test('#2226 AC3: same-format status updates with fresh numbers stay '
      'alive — high masked similarity is NEVER the verdict alone', () {
    final g = guard(stuckRounds: 4);
    for (var round = 1; round <= 8; round++) {
      final pause = g.evaluate([
        _mail(
          's$round',
          'status: tests 4$round of 50 pass, job 990$round '
              'running, eta 1$round minutes',
        ),
      ]);
      expect(pause, isNull, reason: 'round $round has fresh numbers');
    }
  });

  test('#2226: genuinely different content never sticks — similarity below '
      'the threshold resets the stuck counter', () {
    final g = guard(stuckRounds: 2);
    expect(g.evaluate([_mail('a', 'deploy finished, all green')]), isNull);
    expect(g.evaluate([_mail('b', 'review comments addressed in pr')]), isNull);
    expect(g.evaluate([_mail('c', 'docs updated and pushed')]), isNull);
  });

  test('#2226 AC4: budget exhaustion pauses with a budget digest; '
      'continueChain resets it once per user ack (fake cost meter)', () {
    final g = guard(budgetTokens: 1000);
    g.recordSpend(400);
    g.recordSpend(600);
    expect(g.paused, isFalse, reason: 'exactly at budget is not over it');
    final pause = g.evaluate([_mail('x', 'status update')]);
    expect(pause, isNotNull);
    expect(pause!.reason, ChainPauseReason.budget);
    expect(pause.evidence, contains('1000/1000'));
    // Sticky: further spends during the pause are not booked.
    g.recordSpend(5000);
    expect(g.tokensSpent, 1000);
    // The user's continue ack resets the budget and the verdict.
    g.continueChain();
    expect(g.paused, isFalse);
    expect(g.tokensSpent, 0);
    expect(g.evaluate([_mail('y', 'status update')]), isNull);
  });

  test('#2226: a delivered user input resets everything (the human is '
      'watching) — verdict, spend, and windows', () {
    final g = guard(budgetTokens: 10, stuckRounds: 1);
    g.recordSpend(10);
    expect(g.evaluate([_mail('x', 'ping')]), isNotNull);
    g.resetFromUserInput();
    expect(g.paused, isFalse);
    expect(g.tokensSpent, 0);
    // Windows cleared: the first post-reset exchange arms, not sticks.
    expect(g.evaluate([_mail('y', 'ping')]), isNull);
    expect(
      g.evaluate([_mail('z', 'ping')]),
      isNotNull,
      reason: 'stuckRounds 1: the second identical exchange is the verdict',
    );
  });

  test('#2226: the pause is sticky and stable — repeated evaluates during '
      'a pause return the same verdict without consuming budget', () {
    final g = guard(stuckRounds: 1);
    g.evaluate([_mail('a', 'ping')]);
    final first = g.evaluate([_mail('b', 'ping')]);
    expect(first, isNotNull);
    final again = g.evaluate([_mail('c', 'ping')]);
    expect(
      again!.evidence,
      first!.evidence,
      reason: 'frozen evidence — the window stopped moving',
    );
  });

  test('#2226: chains are per-counterparty — a looping pair pauses while a '
      'fresh counterparty is unaffected until it loops too', () {
    final g = guard(stuckRounds: 2);
    // Pair 1 (echo) accumulates stuck rounds.
    g.evaluate([_mail('p1', 'echo one', from: 'echo/main')]);
    g.evaluate([_mail('p1', 'echo one', from: 'echo/main')]);
    // Pair 2 (productive) interleaves freely.
    for (var round = 0; round < 5; round++) {
      expect(
        g.evaluate([_mail('p2', 'fresh report $round', from: 'work/main')]),
        isNull,
        reason: 'a different counterparty has its own window',
      );
    }
    // The echo pair's third identical exchange hits its own verdict.
    final pause = g.evaluate([_mail('p1', 'echo one', from: 'echo/main')]);
    expect(pause, isNotNull);
    expect(pause!.reason, ChainPauseReason.loop);
  });

  test('#2226: detection disabled removes loop verdicts; the budget still '
      'bounds (degrades, never disappears)', () {
    final g = guard(enabled: false, stuckRounds: 1, budgetTokens: 5);
    g.evaluate([_mail('a', 'ping')]);
    expect(
      g.evaluate([_mail('b', 'ping')]),
      isNull,
      reason: 'no loop verdicts while disabled',
    );
    g.recordSpend(5);
    expect(g.evaluate([_mail('c', 'ping')])!.reason, ChainPauseReason.budget);
  });

  test('#2226: the snapshot round-trips spend and windows so a restart '
      'never grants a fresh budget mid-chain', () {
    final g = guard(stuckRounds: 4, budgetTokens: 100);
    g.recordSpend(60);
    g.evaluate([_mail('a', 'status: job 77 running')]);
    g.evaluate([_mail('b', 'status: job 77 running')]);
    g.evaluate([_mail('c', 'status: job 77 running')]);
    final snapshot = g.snapshot();
    final restored = guard(stuckRounds: 4, budgetTokens: 100)
      ..restore(snapshot);
    expect(restored.tokensSpent, 60);
    // One more identical exchange reaches the verdict on the RESTORED
    // guard — the stuck counter survived.
    expect(restored.budgetExhausted, isFalse);
    expect(
      restored.evaluate([_mail('d', 'status: job 77 running')]),
      isNull,
      reason: 'stuck 3 after restore',
    );
    expect(
      restored.evaluate([_mail('e', 'status: job 77 running')]),
      isNotNull,
      reason: 'stuck 4 — the restored window still loops',
    );
  });

  test('#2226 AC5: the digest card names the evidence, the queued mail, '
      'and both choices — never a silent refusal', () {
    final lines = chainPauseDigestLines(
      reason: ChainPauseReason.loop,
      evidence: 'last 4 exchanges 96% similar with no new ids/files',
      pendingCount: 3,
      counterparty: 'peer-session/main',
    );
    final text = lines.join('\n');
    expect(text, contains('loop'));
    expect(text, contains('96% similar'));
    expect(text, contains('QUEUED'));
    expect(text, contains('/chain continue'));
    expect(text, contains('/chain stop'));
    final budget = chainPauseDigestLines(
      reason: ChainPauseReason.budget,
      evidence: 'autonomous chain spend 400/400 tokens',
      pendingCount: 1,
    );
    expect(budget.join('\n'), contains('budget'));
  });
}

AgentMessage _mail(String id, String text, {String from = 'peer/main'}) =>
    AgentMessage(
      id: id,
      fromId: from,
      toId: 'me/main',
      text: text,
      kind: AgentMessageKind.agent,
      sentAt: DateTime.now().toUtc().toIso8601String(),
    );
