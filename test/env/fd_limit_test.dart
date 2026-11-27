import 'dart:io';

import 'package:flutter_agent_harness/src/env/fd_limit.dart';
import 'package:flutter_agent_harness/src/env/fd_limit_io.dart';
import 'package:test/test.dart';

/// A fake rlimit: the plan's branches without a syscall.
final class _FakeBackend implements FdLimitBackend {
  _FakeBackend({required this.soft, required this.hard, this.accept = true});

  int soft;
  final int hard;
  final bool accept;
  final sets = <int>[];

  @override
  FdLimits? getLimits() => (soft: soft, hard: hard);

  @override
  bool setSoftLimit(int value) {
    sets.add(value);
    if (!accept) return false;
    soft = value;
    return true;
  }
}

void main() {
  final vm = Platform.isMacOS || Platform.isLinux;

  group('FdLimitRaiser (pure, fake backend)', () {
    test('raises the soft limit to min(hard, target) exactly once', () {
      final backend = _FakeBackend(soft: 256, hard: 4096);
      final raiser = FdLimitRaiser(backend: backend);
      expect(raiser.applied, isFalse);
      expect(raiser.apply(), FdLimitOutcome.raised);
      expect(backend.sets, [4096], reason: 'capped at the hard limit');
      expect(backend.soft, 4096);
      expect(raiser.applied, isTrue);
      // Exactly once: a second apply is a no-op answering null.
      expect(raiser.apply(), isNull);
      expect(backend.sets, hasLength(1));
    });

    test('an unlimited hard limit (-1) raises to the target', () {
      final backend = _FakeBackend(soft: 256, hard: -1);
      expect(FdLimitRaiser(backend: backend).apply(), FdLimitOutcome.raised);
      expect(backend.sets, [fdLimitTarget]);
      expect(fdLimitTarget, 10240);
    });

    test('a soft limit already at the target sets nothing', () {
      final backend = _FakeBackend(soft: 10240, hard: -1);
      expect(
        FdLimitRaiser(backend: backend).apply(),
        FdLimitOutcome.alreadySufficient,
      );
      expect(backend.sets, isEmpty);
    });

    test('a hard limit at or below the soft limit has nothing to raise', () {
      final backend = _FakeBackend(soft: 1024, hard: 1024);
      expect(
        FdLimitRaiser(backend: backend).apply(),
        FdLimitOutcome.unsupported,
      );
      expect(backend.sets, isEmpty);
    });

    test('a refusing setrlimit is reported, never retried', () {
      final backend = _FakeBackend(soft: 256, hard: 8192, accept: false);
      final raiser = FdLimitRaiser(backend: backend);
      expect(raiser.apply(), FdLimitOutcome.refused);
      expect(raiser.apply(), isNull, reason: 'no retry on a sandboxed host');
      expect(backend.sets, [8192]);
    });

    test('no backend (web, Windows) is unsupported', () {
      expect(FdLimitRaiser(backend: null).apply(), FdLimitOutcome.unsupported);
    });

    test('planFor is pure over the limits', () {
      final raiser = FdLimitRaiser(backend: null);
      expect(raiser.planFor((soft: 256, hard: 4096)), 4096);
      expect(raiser.planFor((soft: 256, hard: -1)), 10240);
      expect(raiser.planFor((soft: 20000, hard: -1)), isNull);
      expect(raiser.planFor((soft: 1000, hard: 900)), isNull);
    });
  });

  group('VM backend (getrlimit/setrlimit through dart:ffi)', () {
    test(
      'raiseFdLimitOnce lifts the soft limit to min(hard, 10240) and '
      'runs exactly once per process',
      skip: vm ? null : 'needs RLIMIT_NOFILE',
      () {
        final backend = systemFdLimitBackend();
        expect(backend, isNotNull);
        final before = backend!.getLimits()!;
        final outcome = raiseFdLimitOnce();
        final after = backend.getLimits()!;
        if (before.soft >= fdLimitTarget) {
          expect(outcome, FdLimitOutcome.alreadySufficient);
        } else if (before.hard >= 0 && before.hard <= before.soft) {
          expect(outcome, FdLimitOutcome.unsupported);
        } else {
          final expected = before.hard < 0
              ? fdLimitTarget
              : (before.hard < fdLimitTarget ? before.hard : fdLimitTarget);
          expect(outcome, anyOf(FdLimitOutcome.raised, FdLimitOutcome.refused));
          if (outcome == FdLimitOutcome.raised) {
            expect(after.soft, expected);
            expect(after.hard, before.hard, reason: 'hard never lowered');
          }
        }
        // Exactly once: the second call is a no-op.
        expect(raiseFdLimitOnce(), isNull);
      },
    );
  });
}
