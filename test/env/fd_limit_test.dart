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
