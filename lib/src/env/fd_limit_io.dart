/// The VM [FdLimitBackend] (gh-2415): `getrlimit`/`setrlimit(RLIMIT_NOFILE)`
/// through `dart:ffi` against the process's own libc — macOS and 64-bit
/// Linux only, the two POSIX hosts the CLI ships for where the launchd /
/// systemd soft default (256 / 1024) is the exhaustion driver. Every
/// failure degrades to null / false: the raise is best-effort and never
/// takes a boot down. Platform glue only — exported from `lib/io.dart`
/// behind the web stub.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// The constructor params keep their public names (get/set) while the
// fields stay private — same shape as scheduled_receipts.dart.
// ignore_for_file: prefer_initializing_formals

import 'fd_limit.dart';

/// `struct rlimit { rlim_t rlim_cur; rlim_t rlim_max; }` — `rlim_t` is
/// `unsigned long`, 64-bit on both supported hosts.
final class _Rlimit extends Struct {
  @Uint64()
  external int cur;
  @Uint64()
  external int max;
}

typedef _GetrlimitC = Int32 Function(Int32 resource, Pointer<_Rlimit> rlim);
typedef _GetrlimitDart = int Function(int resource, Pointer<_Rlimit> rlim);
typedef _SetrlimitC = Int32 Function(Int32 resource, Pointer<_Rlimit> rlim);
typedef _SetrlimitDart = int Function(int resource, Pointer<_Rlimit> rlim);

/// `RLIMIT_NOFILE`: 8 on Darwin, 7 on generic Linux (x86_64 / aarch64).
int get _rlimitNofile => Platform.isMacOS ? 8 : 7;

/// The backend over this process's libc, or null when the host has no
/// POSIX rlimit (Windows, a non Darwin/Linux POSIX with other constants),
/// the ABI is not 64-bit, or the symbols are missing.
FdLimitBackend? systemFdLimitBackend() {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  if (sizeOf<IntPtr>() != 8) return null;
  try {
    final lib = DynamicLibrary.process();
    final getrlimit = lib.lookupFunction<_GetrlimitC, _GetrlimitDart>(
      'getrlimit',
    );
    final setrlimit = lib.lookupFunction<_SetrlimitC, _SetrlimitDart>(
      'setrlimit',
    );
    final resource = _rlimitNofile;
    return _FfiFdLimitBackend(
      get: (out) => getrlimit(resource, out) == 0,
      set: (rlim) => setrlimit(resource, rlim) == 0,
    );
  } on Object {
    return null;
  }
}

final class _FfiFdLimitBackend implements FdLimitBackend {
  _FfiFdLimitBackend({
    required bool Function(Pointer<_Rlimit>) get,
    required bool Function(Pointer<_Rlimit>) set,
  }) : _get = get,
       _set = set;

  final bool Function(Pointer<_Rlimit>) _get;
  final bool Function(Pointer<_Rlimit>) _set;

  @override
  FdLimits? getLimits() {
    final out = calloc<_Rlimit>();
    try {
      if (!_get(out)) return null;
      // RLIM_INFINITY arrives as all-ones: Dart's signed 64-bit int reads
      // it as -1 — the backend contract's "unlimited".
      return (soft: out.ref.cur, hard: out.ref.max);
    } finally {
      calloc.free(out);
    }
  }

  @override
  bool setSoftLimit(int soft) {
    final current = getLimits();
    if (current == null) return false;
    final rlim = calloc<_Rlimit>();
    try {
      rlim.ref.cur = soft;
      rlim.ref.max = current.hard;
      return _set(rlim);
    } finally {
      calloc.free(rlim);
    }
  }
}

FdLimitRaiser? _raiser;

/// Raises this process's `RLIMIT_NOFILE` soft limit to
/// min(hard, [fdLimitTarget]) — exactly once per process (the second call
/// is a no-op answering null). Null when the host has no backend.
FdLimitOutcome? raiseFdLimitOnce() =>
    (_raiser ??= FdLimitRaiser(backend: systemFdLimitBackend())).apply();
