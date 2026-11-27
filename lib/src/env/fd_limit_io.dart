/// Process file-descriptor limit handling (issue #2415).
///
/// A long-lived orchestrator session spikes its fd table (3 pipes per bash
/// call, subagent hooks, directory watchers, adopted-job polls) against the
/// macOS launchd default soft limit of 256 — `ulimit -Hn` is unlimited, so
/// the soft limit is raised once at host startup, best-effort, through
/// libc's `getrlimit`/`setrlimit` (every Dart VM process links libc).
///
/// Exported only from `lib/io.dart` — web has no FFI; Windows has no
/// equivalent soft limit (the stub answers null).
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The soft limit the CLI raises to (`min(hard, 10240)` — the value the
/// issue measured as safe headroom for a 3-subagent orchestrator).
const fdLimitTarget = 10240;

/// Darwin `RLIM_INFINITY` (max int64); Linux uses max uint64, which loads
/// as a negative Dart int. Anything in this class is "unlimited".
const int _rlimInfinitySentinel = 0x7fffffffffffffff;

/// `RLIMIT_NOFILE`: 8 on macOS, 7 on Linux (both in `sys/resource.h`).
int get _rlimitNofile => Platform.isMacOS ? 8 : 7;

final class _RLimit extends ffi.Struct {
  @ffi.Uint64()
  external int rlimCur;

  @ffi.Uint64()
  external int rlimMax;
}

typedef _RLimitOpC = ffi.Int32 Function(ffi.Int32, ffi.Pointer<_RLimit>);
typedef _RLimitOpDart = int Function(int, ffi.Pointer<_RLimit>);

/// The current (soft, hard) fd limits; null when unsupported or the libc
/// lookup fails (never throws — callers are best-effort boot paths). The
/// gate is (macOS || Linux) — an exotic POSIX would answer the WRONG
/// RLIMIT_NOFILE constant (review round 1).
({int soft, int hard})? fdLimits() {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  try {
    final libc = ffi.DynamicLibrary.process();
    final getrlimit = libc.lookupFunction<_RLimitOpC, _RLimitOpDart>(
      'getrlimit',
    );
    final rl = calloc<_RLimit>();
    try {
      if (getrlimit(_rlimitNofile, rl) != 0) return null;
      return (soft: rl.ref.rlimCur, hard: rl.ref.rlimMax);
    } finally {
      calloc.free(rl);
    }
  } on Object {
    return null;
  }
}

/// One-shot soft-limit raise decision over INJECTED seams (issue #2415;
/// review round 2 demanded the branch matrix be testable — the ffi shape
/// made the refusal/clamp/armed arms uncoverable). Pure decision, no
/// dart:ffi: `raiseFdLimitOnce` drives it with the real libc seams; tests
/// script [limits]/[setSoft]. The arm flag is process-lifetime state on
/// the instance: a raise happens at most once, and a REFUSAL also arms
/// (a setrlimit refusal is a host property — sandbox/hardened profile —
/// not a transient condition; retrying would burn a syscall per later
/// call).
final class FdLimitRaise {
  /// Whether this instance already attempted its raise.
  bool get armed => _armed;
  bool _armed = false;

  /// Reads the limits, raises the soft limit to `min(hard, [target])`
  /// unless already armed or at/above the wanted value, and answers the
  /// post-state limits (the re-read state on success, the untouched
  /// pre-state when the setter refused, threw, or the raise was a
  /// no-op). Null limits (unsupported platform) answer null. Best-effort:
  /// never throws.
  ({int soft, int hard})? apply({
    required ({int soft, int hard})? Function() limits,
    required bool Function(int soft, int hard) setSoft,
    int target = fdLimitTarget,
  }) {
    final current = limits();
    if (current == null) return null;
    // RLIM_INFINITY loads as a negative (max uint64) or max-int64 (Darwin)
    // — either means "unlimited", so the target itself is the wanted cap.
    final unlimited = current.hard < 0 || current.hard >= _rlimInfinitySentinel;
    final wanted = unlimited
        ? target
        : current.hard < target
        ? current.hard
        : target;
    if (_armed || current.soft >= wanted) return current;
    _armed = true;
    var applied = false;
    try {
      applied = setSoft(wanted, current.hard);
    } on Object {
      return current;
    }
    if (!applied) return current;
    return limits();
  }
}

final FdLimitRaise _fdLimitRaise = FdLimitRaise();

/// Sets the soft limit to [soft] (hard untouched) through libc
/// `setrlimit`; whether the syscall accepted it. Never throws.
bool _setSoftLimitFfi(int soft, int hard) {
  try {
    final libc = ffi.DynamicLibrary.process();
    final setrlimit = libc.lookupFunction<_RLimitOpC, _RLimitOpDart>(
      'setrlimit',
    );
    final rl = calloc<_RLimit>();
    try {
      rl.ref.rlimCur = soft;
      rl.ref.rlimMax = hard;
      return setrlimit(_rlimitNofile, rl) == 0;
    } finally {
      calloc.free(rl);
    }
  } on Object {
    return false;
  }
}

/// Raises the fd soft limit to `min(hard, [target])`, once per process
/// (armed across calls; a refusal arms too — see [FdLimitRaise]).
/// Returns the limits AFTER the attempt (the raised state on success, the
/// untouched state when already at/above the target or the syscall
/// refused); null when unsupported. Best-effort: never throws.
({int soft, int hard})? raiseFdLimitOnce({int target = fdLimitTarget}) =>
    _fdLimitRaise.apply(
      limits: fdLimits,
      setSoft: _setSoftLimitFfi,
      target: target,
    );

/// True when [error] is the spawn-time fd-table exhaustion (EMFILE 24 /
/// ENFILE 23, or the strerror text as a belt for platform variants) —
/// issue #2415: the bash tool must answer this as a typed, environmental
/// failure, not an uncaught `ProcessException`.
bool isFdExhaustion(Object error) {
  if (error is ProcessException) {
    // EMFILE (24) / ENFILE (23) — dart:io names the field `errorCode`.
    if (error.errorCode == 23 || error.errorCode == 24) return true;
  }
  return error.toString().contains('Too many open files');
}
