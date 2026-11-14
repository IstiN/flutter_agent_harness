/// gh-2101 — the compaction run's cache-aware call policy and its usage
/// accounting:
///
/// - ONE stable routing session id per compaction run (the digest and the
///   judge share it) with a per-call-class retention policy, instead of the
///   legacy blanket `cacheRetention: 'none'` + fresh-per-call ids. Providers
///   with session affinity (OpenAI `prompt_cache_key`, OpenRouter
///   `x-session-id`, Anthropic cache markers) can then serve each call's
///   request prefix from the cache the previous call of the same run wrote;
///   providers without cache knobs ignore the routing (degrade to uncached).
///   The run-scoped id is still NOT the parent session's id, so compaction
///   never pollutes the session's cache-affinity bucket (the invariant the
///   legacy shape existed for).
/// - `CompactionUsageAccumulator`/`CompactionUsageTotals` fold the metered
///   usage of the run's LM calls — call count, token breakdown, cost — into
///   the pass metrics the reports render.
/// - `formatPassDuration` renders pass durations for the one-line report.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Usage _usage({
  int input = 0,
  int output = 0,
  int cacheRead = 0,
  int cacheWrite = 0,
  double cost = 0,
}) {
  return Usage(
    input: input,
    output: output,
    cacheRead: cacheRead,
    cacheWrite: cacheWrite,
    totalTokens: input + output + cacheRead + cacheWrite,
    cost: UsageCost(
      input: cost * 0.8,
      output: cost * 0.1,
      cacheRead: cost * 0.05,
      cacheWrite: cost * 0.05,
      total: cost,
    ),
  );
}

void main() {
  group('CompactionCachePolicy.affine (the default)', () {
    test('judge and digest share ONE stable run-scoped session id', () {
      final policy = CompactionCachePolicy.affine();
      final judge = policy.routingFor(CompactionCallClass.judge);
      final digest = policy.routingFor(CompactionCallClass.digest);
      expect(judge.sessionId, isNotNull);
      expect(judge.sessionId, digest.sessionId,
          reason: 'one cache bucket per compaction run');
      // A second run gets its own id — the cache family is per run.
      final other = CompactionCachePolicy.affine();
      expect(other.routingFor(CompactionCallClass.judge).sessionId,
          isNot(judge.sessionId));
    });

    test('a fixed session id can be seeded (factory wiring tests)', () {
      final policy = CompactionCachePolicy.affine(sessionId: 'run-1');
      expect(policy.routingFor(CompactionCallClass.judge).sessionId, 'run-1');
      expect(policy.routingFor(CompactionCallClass.digest).sessionId, 'run-1');
    });

    test('retention is a deliberate per-call-class policy (never none)', () {
      final policy = CompactionCachePolicy.affine();
      expect(policy.routingFor(CompactionCallClass.judge).cacheRetention,
          CompactionCachePolicy.judgeRetention);
      expect(policy.routingFor(CompactionCallClass.digest).cacheRetention,
          CompactionCachePolicy.digestRetention);
      // The whole point of gh-2101: the compaction calls stop opting OUT of
      // prompt caching. Retention is provider-default-compatible ('short' —
      // ephemeral markers / affinity keys), long enough to cover one
      // compaction run's pass ladder, never the 24h premium.
      expect(CompactionCachePolicy.judgeRetention, isNot('none'));
      expect(CompactionCachePolicy.digestRetention, isNot('none'));
    });
  });

  group('CompactionCachePolicy.isolated (the legacy kill switch)', () {
    test('retention none and a fresh session id per call', () {
      final policy = CompactionCachePolicy.isolated();
      final first = policy.routingFor(CompactionCallClass.judge);
      final second = policy.routingFor(CompactionCallClass.judge);
      expect(first.cacheRetention, 'none');
      expect(second.cacheRetention, 'none');
      expect(first.sessionId, isNotNull);
      expect(second.sessionId, isNotNull);
      expect(first.sessionId, isNot(second.sessionId),
          reason: 'legacy shape: fresh routing id per call');
    });
  });

  group('CompactionUsageAccumulator', () {
    test('folds usage across calls: counts, tokens, cost', () {
      final ledger = CompactionUsageAccumulator();
      ledger.add(_usage(input: 100, output: 10, cacheRead: 900, cost: 0.5));
      ledger.add(_usage(input: 50, output: 5, cacheRead: 400, cost: 0.25));
      final totals = ledger.snapshot();
      expect(totals.calls, 2);
      expect(totals.inputTokens, 150);
      expect(totals.outputTokens, 15);
      expect(totals.cacheReadTokens, 1300);
      expect(totals.cacheWriteTokens, 0);
      expect(totals.costUsd, closeTo(0.75, 1e-9));
    });

    test('deltaFrom subtracts the earlier snapshot, clamped at zero', () {
      final ledger = CompactionUsageAccumulator();
      ledger.add(_usage(input: 100, output: 10, cacheRead: 900, cost: 0.5));
      final before = ledger.snapshot();
      ledger.add(_usage(input: 40, output: 4, cacheRead: 360, cost: 0.2));
      final delta = ledger.snapshot().deltaFrom(before);
      expect(delta.calls, 1);
      expect(delta.inputTokens, 40);
      expect(delta.outputTokens, 4);
      expect(delta.cacheReadTokens, 360);
      expect(delta.costUsd, closeTo(0.2, 1e-9));
      // Re-measuring against the SAME snapshot yields zeros, never negatives.
      final now = ledger.snapshot();
      final zero = now.deltaFrom(now);
      expect(zero.calls, 0);
      expect(zero.costUsd, 0);
      expect(zero.cacheHitRatio, isNull,
          reason: 'no input tokens — no ratio to report');
    });

    test('cacheHitRatio divides cache reads by all input tokens', () {
      final ledger = CompactionUsageAccumulator();
      ledger.add(_usage(input: 100, cacheRead: 900, cacheWrite: 0));
      expect(ledger.snapshot().cacheHitRatio, closeTo(0.9, 1e-9));
      ledger.add(_usage(input: 100, cacheRead: 0, cacheWrite: 400));
      final totals = ledger.snapshot();
      // 900 reads over 200 uncached + 900 cached + 400 written.
      expect(totals.cacheHitRatio, closeTo(900 / 1500, 1e-9));
    });
  });

  group('formatPassDuration', () {
    test('sub-second durations keep one decimal', () {
      expect(formatPassDuration(950), '0.9s');
    });
    test('seconds under a minute render with one decimal', () {
      expect(formatPassDuration(12400), '12.4s');
    });
    test('minutes render as XmSSs', () {
      expect(formatPassDuration(125000), '2m05s');
    });
    test('hours render as XhMMm', () {
      expect(formatPassDuration(3750000), '1h02m');
    });
    test('null and non-positive render nothing (absent metric)', () {
      expect(formatPassDuration(null), isNull);
      expect(formatPassDuration(0), isNull);
    });
  });
}
