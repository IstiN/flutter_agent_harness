// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Issue #2415: fd-limit handling. The real rlimit raise runs on POSIX
// (raising the soft limit is the harmless direction; the hard limit is
// unlimited on the macOS host class the issue measured). The classifier
// tests are pure — no fd is ever exhausted here.

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

final class _RLimit extends ffi.Struct {
  @ffi.Uint64()
  external int rlimCur;

  @ffi.Uint64()
  external int rlimMax;
}

/// Lowers the soft fd limit (test-only `setrlimit` — the agent shell runs
/// with a soft limit of 1048576, so the prod raise path needs a forced
/// low start to run at all). Returns the previous soft value, or null
/// when the host refuses limit changes.
int? _lowerSoftLimit(int soft) {
  try {
    final libc = ffi.DynamicLibrary.process();
    final setrlimit = libc
        .lookupFunction<
          ffi.Int32 Function(ffi.Int32, ffi.Pointer<_RLimit>),
          int Function(int, ffi.Pointer<_RLimit>)
        >('setrlimit');
    final nofile = Platform.isMacOS ? 8 : 7;
    final rl = calloc<_RLimit>();
    try {
      rl.ref.rlimCur = soft;
      rl.ref.rlimMax = 0x7fffffffffffffff; // keep hard unlimited
      return setrlimit(nofile, rl) == 0 ? soft : null;
    } finally {
      calloc.free(rl);
    }
  } on Object {
    return null;
  }
}

void main() {
  group('fdLimits', () {
    test('reports consistent soft/hard limits on POSIX', () {
      if (!Platform.isMacOS && !Platform.isLinux) {
        expect(fdLimits(), isNull);
        return;
      }
      final limits = fdLimits();
      expect(limits, isNotNull);
      expect(limits!.soft, greaterThan(0));
      // Soft never exceeds hard; the unlimited hard limit loads as a
      // huge/negative uint64, which still satisfies soft <= hard.
      expect(limits.soft <= limits.hard, isTrue);
    });
  });

  group('raiseFdLimitOnce', () {
    test('is a sane no-op when the soft limit already covers the target', () {
      if (!Platform.isMacOS && !Platform.isLinux) {
        expect(raiseFdLimitOnce(), isNull);
        return;
      }
      final before = fdLimits()!;
      final after = raiseFdLimitOnce()!;
      expect(after.soft, greaterThanOrEqualTo(before.soft));
      expect(after.soft <= after.hard || after.hard < 0, isTrue);
      // Second call: a no-op returning the same state.
      final again = raiseFdLimitOnce()!;
      expect(again.soft, after.soft);
    });

    test('raises a launchd-default 256 soft limit to the target '
        '(the issue #2415 scenario, real syscall)', () {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final original = fdLimits()!.soft;
      if (_lowerSoftLimit(256) == null) {
        return; // host refuses limit changes — the raise stays untestable
      }
      try {
        expect(fdLimits()!.soft, 256);
        final raised = raiseFdLimitOnce()!;
        // Hard is unlimited on this host class → the target lands.
        expect(
          raised.soft,
          fdLimitTarget,
          reason: 'soft 256 must raise to min(hard, $fdLimitTarget)',
        );
      } finally {
        _lowerSoftLimit(original);
      }
    });
  });

  group('FdLimitRaise decision core (branch matrix, scripted seams)', () {
    test('null limits answers null — the setter is never consulted', () {
      final calls = <(int, int)>[];
      final raise = FdLimitRaise();
      final out = raise.apply(
        limits: () => null,
        setSoft: (soft, hard) {
          calls.add((soft, hard));
          return true;
        },
      );
      expect(out, isNull);
      expect(calls, isEmpty);
    });

    test('an unlimited hard limit raises to the target (the launchd '
        'shape) and returns the re-read post-state', () {
      final raise = FdLimitRaise();
      var reads = 0;
      final out = raise.apply(
        limits: () {
          reads++;
          // Read #1 pre-state: 256/unlimited; read #2 post-raise: 10240.
          return reads == 1 ? (soft: 256, hard: -1) : (soft: 10240, hard: -1);
        },
        setSoft: (soft, hard) => true,
      );
      expect(out, (soft: 10240, hard: -1));
      expect(raise.armed, isTrue);
    });

    test('a hard limit below the target clamps the raise to the hard cap', () {
      final raise = FdLimitRaise();
      int? askedSoft;
      raise.apply(
        limits: () => (soft: 256, hard: 4096),
        setSoft: (soft, hard) {
          askedSoft = soft;
          return true;
        },
      );
      expect(askedSoft, 4096, reason: 'min(hard, target) — never above hard');
    });

    test('a soft limit already at/above the wanted value is a no-op — '
        'the setter is not consulted', () {
      final raise = FdLimitRaise();
      var setterCalls = 0;
      final out = raise.apply(
        limits: () => (soft: 10240, hard: -1),
        setSoft: (soft, hard) {
          setterCalls++;
          return true;
        },
      );
      expect(out, (soft: 10240, hard: -1));
      expect(setterCalls, 0);
      // The no-op does NOT arm: a later lower-start raise must still run.
      expect(raise.armed, isFalse);
    });

    test('an already-armed raise is a process-lifetime no-op', () {
      final raise = FdLimitRaise();
      var setterCalls = 0;
      // First call arms (the raise happens).
      raise.apply(
        limits: () => (soft: 256, hard: -1),
        setSoft: (soft, hard) => true,
      );
      expect(raise.armed, isTrue);
      // Second call: untouched pre-state, setter never consulted.
      final out = raise.apply(
        limits: () => (soft: 256, hard: -1),
        setSoft: (soft, hard) {
          setterCalls++;
          return true;
        },
      );
      expect(out, (soft: 256, hard: -1));
      expect(setterCalls, 0);
    });

    test('a setter refusal returns the pre-state and STAYS armed — the '
        'refusal is a host property, never retried', () {
      final raise = FdLimitRaise();
      var setterCalls = 0;
      final out = raise.apply(
        limits: () => (soft: 256, hard: -1),
        setSoft: (soft, hard) {
          setterCalls++;
          return false; // setrlimit refused
        },
      );
      expect(out, (soft: 256, hard: -1));
      expect(setterCalls, 1);
      expect(raise.armed, isTrue);
      // The refusal persists: a later call cannot retry the syscall.
      raise.apply(
        limits: () => (soft: 256, hard: -1),
        setSoft: (soft, hard) {
          setterCalls++;
          return true;
        },
      );
      expect(setterCalls, 1);
    });

    test('a throwing setter is contained: pre-state returned, armed', () {
      final raise = FdLimitRaise();
      final out = raise.apply(
        limits: () => (soft: 256, hard: -1),
        setSoft: (soft, hard) => throw StateError('ffi gone'),
      );
      expect(out, (soft: 256, hard: -1));
      expect(raise.armed, isTrue);
    });
  });

  group('isFdExhaustion', () {
    test('matches the EMFILE/ENFILE spawn failures', () {
      expect(
        isFdExhaustion(
          ProcessException(
            'sh',
            ['-c', 'ls'],
            'ProcessException: Too many open files',
            24,
          ),
        ),
        isTrue,
      );
      expect(
        isFdExhaustion(
          ProcessException(
            'sh',
            ['-c', 'ls'],
            'ProcessException: Too many open files in system',
            23,
          ),
        ),
        isTrue,
      );
    });

    test('matches the strerror text without relying on errno alone', () {
      expect(
        isFdExhaustion(
          ProcessException(
            'sh',
            ['-c', 'ls'],
            'ProcessException: Cannot open process — Too many open files',
            5,
          ),
        ),
        isTrue,
      );
    });

    test('rejects unrelated spawn failures and error types', () {
      expect(
        isFdExhaustion(ProcessException('sh', ['-c', 'ls'], 'not found', 2)),
        isFalse,
      );
      expect(isFdExhaustion(StateError('boom')), isFalse);
    });
  });
}
