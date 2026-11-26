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
/// lookup fails (never throws — callers are best-effort boot paths).
({int soft, int hard})? fdLimits() {
  if (Platform.isWindows) return null;
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

bool _raisedOnce = false;

/// Raises the fd soft limit to `min(hard, [target])`, once per process.
/// Returns the limits AFTER the attempt (the raised state on success, the
/// untouched state when already at/above the target or the syscall
/// refused); null when unsupported. Best-effort: never throws.
({int soft, int hard})? raiseFdLimitOnce({int target = fdLimitTarget}) {
  final limits = fdLimits();
  if (limits == null) return null;
  final hard = limits.hard < 0 || limits.hard >= _rlimInfinitySentinel
      ? target
      : limits.hard;
  final wanted = hard < target ? hard : target;
  if (_raisedOnce || limits.soft >= wanted) return limits;
  _raisedOnce = true;
  try {
    final libc = ffi.DynamicLibrary.process();
    final setrlimit = libc.lookupFunction<_RLimitOpC, _RLimitOpDart>(
      'setrlimit',
    );
    final rl = calloc<_RLimit>();
    try {
      rl.ref.rlimCur = wanted;
      rl.ref.rlimMax = limits.hard;
      if (setrlimit(_rlimitNofile, rl) != 0) return limits;
    } finally {
      calloc.free(rl);
    }
  } on Object {
    return limits;
  }
  return fdLimits();
}

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
