/// Web stub for `fd_limit_io.dart` (issue #2415 fd-limit handling).
///
/// `dart:ffi` does not compile on the web; `lib/io.dart` conditionally
/// exports this stub there. Web hosts have no process fd table to raise
/// and no spawn-time EMFILE to classify.
///
/// Mirrors the public surface of `fd_limit_io.dart` — keep in sync.
library;

/// The soft limit the CLI raises to (surface parity with the io variant).
const fdLimitTarget = 10240;

/// Web: no process fd limits — always null.
({int soft, int hard})? fdLimits() => null;

/// The raise decision (web parity): no limits to read, nothing to raise.
final class FdLimitRaise {
  /// Web: never armed — there is nothing to raise.
  bool get armed => false;

  /// Web: always null.
  ({int soft, int hard})? apply({
    required ({int soft, int hard})? Function() limits,
    required bool Function(int soft, int hard) setSoft,
    int target = fdLimitTarget,
  }) => null;
}

/// Web: nothing to raise — always null.
({int soft, int hard})? raiseFdLimitOnce({int target = fdLimitTarget}) => null;

/// Web: no spawn-time fd exhaustion to classify — always false.
bool isFdExhaustion(Object error) => false;
