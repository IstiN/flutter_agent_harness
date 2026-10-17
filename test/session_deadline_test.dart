/// SessionDeadline (gh-1556 AC5/AC6): the pure clock — spec parsing, the
/// time-left formatter, the one-shot crossing state machine on a fake
/// clock, the env/flag seeding override order, and the silent-off
/// contract for missing/invalid env.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('parseDeadlineSpec', () {
    test('parses unit durations', () {
      expect(parseDeadlineSpec('25m').duration, const Duration(minutes: 25));
      expect(parseDeadlineSpec('90s').duration, const Duration(seconds: 90));
      expect(parseDeadlineSpec('1h').duration, const Duration(hours: 1));
    });

    test('parses combined durations covering the whole string', () {
      expect(parseDeadlineSpec('1h30m').duration, const Duration(minutes: 90));
      expect(
        parseDeadlineSpec('2h15m30s').duration,
        const Duration(hours: 2, minutes: 15, seconds: 30),
      );
    });

    test('parses a bare epoch-ms integer', () {
      final spec = parseDeadlineSpec('1893456000000');
      expect(spec.isEpoch, isTrue);
      expect(spec.epochMs, 1893456000000);
      expect(spec.duration, isNull);
    });

    test('rejects a bare small integer (ambiguous, missing its unit)', () {
      expect(
        () => parseDeadlineSpec('90'),
        throwsFormatException,
        reason: '90 must never silently read as 90 ms',
      );
      expect(() => parseDeadlineSpec('25'), throwsFormatException);
    });

    test('rejects garbage, trailing units, zero and negative shapes', () {
      for (final bad in ['', 'abc', '25x', '1h30', '-5m', '5 m', '0s', '1m1']) {
        expect(
          () => parseDeadlineSpec(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('formatTimeLeft', () {
    test('formats seconds, minutes and hours', () {
      expect(formatTimeLeft(45 * 1000), '45s');
      expect(formatTimeLeft(5 * 60 * 1000), '5min');
      expect(formatTimeLeft(60 * 60 * 1000), '1h');
      expect(formatTimeLeft(90 * 60 * 1000), '1h30m');
      expect(formatTimeLeft(2 * 60 * 60 * 1000), '2h');
    });

    test('a non-positive budget reads 0s — the clock never lies', () {
      expect(formatTimeLeft(0), '0s');
      expect(formatTimeLeft(-5000), '0s');
    });
  });

  group('SessionDeadline', () {
    late int nowMs;
    late SessionDeadline deadline;

    setUp(() {
      nowMs = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      deadline = SessionDeadline(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      );
    });

    test('unarmed: budgetLine null, pollNotices empty, remainingMs throws', () {
      expect(deadline.isArmed, isFalse);
      expect(deadline.budgetLine(), isNull);
      expect(deadline.pollNotices(), isEmpty);
      expect(() => deadline.remainingMs, throwsStateError);
    });

    test('setDuration arms from now; remaining ticks down with the clock', () {
      deadline.setDuration(const Duration(minutes: 25));
      expect(deadline.isArmed, isTrue);
      expect(deadline.remainingMs, 25 * 60 * 1000);
      expect(deadline.budgetLine(), 'time-left: 25min');
      nowMs += const Duration(minutes: 5).inMilliseconds;
      expect(deadline.remainingMs, 20 * 60 * 1000);
      expect(deadline.budgetLine(), 'time-left: 20min');
    });

    test('setFromSpec accepts a duration or an epoch; past epochs error', () {
      deadline.setFromSpec('1h30m');
      expect(deadline.remainingMs, 90 * 60 * 1000);
      final future = nowMs + const Duration(minutes: 10).inMilliseconds;
      deadline.setFromSpec('$future');
      expect(deadline.deadlineEpochMs, future);
      expect(() => deadline.setFromSpec('$nowMs'), throwsFormatException);
    });

    test('clear() returns every consumer to the unarmed shape', () {
      deadline.setDuration(const Duration(minutes: 25));
      deadline.clear();
      expect(deadline.isArmed, isFalse);
      expect(deadline.budgetLine(), isNull);
      expect(deadline.pollNotices(), isEmpty);
    });

    test('crossings fire once per arming, in ladder order', () {
      deadline.setDuration(const Duration(minutes: 20));
      expect(deadline.pollNotices(), isEmpty);

      // Past 50%: exactly the halfBudget notice, once.
      nowMs += const Duration(minutes: 11).inMilliseconds;
      final first = deadline.pollNotices();
      expect(first.map((n) => n.kind), [DeadlineNoticeKind.halfBudget]);
      expect(first.single.text, contains('Half of your time budget'));
      // gh-1646: mid-run anti-stop — never wrap up early, the deadline
      // interrupts by itself.
      expect(first.single.text, contains('interrupted at the deadline'));
      expect(deadline.pollNotices(), isEmpty, reason: 'once per crossing');

      // T-3min: the wrap-up steer names the shell-job drain explicitly.
      nowMs += const Duration(minutes: 6).inMilliseconds;
      final second = deadline.pollNotices();
      expect(second.map((n) => n.kind), [DeadlineNoticeKind.wrapUp]);
      expect(second.single.text, contains('background shell jobs'));
      expect(second.single.text, contains('bash_job stop'));
      expect(second.single.text, contains('finalize your outputs'));
      expect(deadline.pollNotices(), isEmpty);

      // T-30s: write the final answer NOW.
      nowMs += const Duration(minutes: 2, seconds: 40).inMilliseconds;
      final third = deadline.pollNotices();
      expect(third.map((n) => n.kind), [DeadlineNoticeKind.finalAnswer]);
      expect(third.single.text, contains('write your final answer NOW'));
      expect(deadline.pollNotices(), isEmpty);

      // Past the deadline: nothing more fires (no procrastination loop).
      nowMs += const Duration(minutes: 5).inMilliseconds;
      expect(deadline.pollNotices(), isEmpty);
      expect(deadline.budgetLine(), 'time-left: 0s');
    });

    test('a jump across several crossings batches them in ladder order', () {
      deadline.setDuration(const Duration(minutes: 25));
      nowMs += const Duration(minutes: 24, seconds: 45).inMilliseconds;
      final notices = deadline.pollNotices();
      expect(notices.map((n) => n.kind), [
        DeadlineNoticeKind.halfBudget,
        DeadlineNoticeKind.wrapUp,
        DeadlineNoticeKind.finalAnswer,
      ]);
      expect(deadline.pollNotices(), isEmpty);
    });

    test('re-setting re-arms every latch (once per NEW arming)', () {
      deadline.setDuration(const Duration(minutes: 20));
      nowMs += const Duration(minutes: 12).inMilliseconds;
      expect(deadline.pollNotices(), hasLength(1));

      // Adjust mid-flight: the latches reset and the full budget restarts.
      deadline.setDuration(const Duration(minutes: 30));
      expect(deadline.remainingMs, 30 * 60 * 1000);
      nowMs += const Duration(minutes: 16).inMilliseconds;
      final again = deadline.pollNotices();
      expect(again.map((n) => n.kind), [DeadlineNoticeKind.halfBudget]);
    });

    test('a compressed ladder fires at the injected thresholds', () {
      final compressed = SessionDeadline(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
        ladder: const DeadlineLadder(wrapUpSteerMs: 5000, finalAnswerMs: 1000),
      );
      compressed.setDuration(const Duration(seconds: 20));
      // 9s left: past the 50% mark (10s), not yet the 5s wrap-up steer.
      nowMs += 11000;
      expect(compressed.pollNotices().map((n) => n.kind), [
        DeadlineNoticeKind.halfBudget,
      ]);
      // 5s left: the wrap-up steer.
      nowMs += 4000;
      expect(compressed.pollNotices().map((n) => n.kind), [
        DeadlineNoticeKind.wrapUp,
      ]);
      // 0.9s left: the final-answer steer.
      nowMs += 4100;
      expect(compressed.pollNotices().map((n) => n.kind), [
        DeadlineNoticeKind.finalAnswer,
      ]);
    });
  });

  group('resolveSessionDeadline (env < flag override order)', () {
    final bootMs = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
    DateTime fakeClock() => DateTime.fromMillisecondsSinceEpoch(bootMs);

    test('missing env and no flag → unarmed (feature off)', () {
      final d = resolveSessionDeadline(clock: fakeClock);
      expect(d.isArmed, isFalse);
    });

    test('invalid env is silent off, never an error', () {
      for (final bad in ['garbage', '90', '-5', '100', '99999999999']) {
        final d = resolveSessionDeadline(envValue: bad, clock: fakeClock);
        expect(d.isArmed, isFalse, reason: 'env "$bad"');
      }
    });

    test('a valid env epoch arms the clock', () {
      final epoch = bootMs + const Duration(minutes: 25).inMilliseconds;
      final d = resolveSessionDeadline(envValue: '$epoch', clock: fakeClock);
      expect(d.isArmed, isTrue);
      expect(d.deadlineEpochMs, epoch);
    });

    test('a past env epoch is silent off (the host exported a stale cap)', () {
      final d = resolveSessionDeadline(
        envValue: '${bootMs - 1000}',
        clock: fakeClock,
      );
      expect(d.isArmed, isFalse);
    });

    test('the flag overrides the env value', () {
      final envEpoch = bootMs + const Duration(hours: 2).inMilliseconds;
      final d = resolveSessionDeadline(
        envValue: '$envEpoch',
        flagSpec: '25m',
        clock: fakeClock,
      );
      expect(
        d.deadlineEpochMs,
        bootMs + const Duration(minutes: 25).inMilliseconds,
      );
    });

    test('an invalid flag spec throws (user-facing, never silent)', () {
      expect(
        () => resolveSessionDeadline(flagSpec: 'nope', clock: fakeClock),
        throwsFormatException,
      );
      expect(
        () => resolveSessionDeadline(flagSpec: '25', clock: fakeClock),
        throwsFormatException,
      );
    });

    test('an env-armed clock survives when no flag is given', () {
      final epoch = bootMs + const Duration(minutes: 90).inMilliseconds;
      final d = resolveSessionDeadline(envValue: '$epoch', clock: fakeClock);
      expect(d.budgetLine(), 'time-left: 1h30m');
    });
  });
}
