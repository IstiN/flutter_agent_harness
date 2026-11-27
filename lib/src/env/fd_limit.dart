/// Raise the process's open-file soft limit at startup (gh-2415).
///
/// The macOS launchd default soft limit is 256 descriptors; a long-lived
/// orchestrator (directory watchers, keep-alive sockets, one pipe pair per
/// bash call, adopted jobs) sits near it at rest and hits `EMFILE` on
/// every spike — the bash tool died with `ProcessException: Too many open
/// files` and the receipt writer lost writes. The hard limit is normally
/// unlimited, so the soft limit is the only thing in the way.
///
/// Pure decision core: [FdLimitRaiser] plans and applies the raise over an
/// injected [FdLimitBackend] exactly once per process; the VM backend
/// (`getrlimit`/`setrlimit` through dart:ffi) lives in `fd_limit_io.dart`
/// and web/Windows hosts get the stub — `lib/` stays pure Dart.
library;

/// The soft limit the raise targets — the `ulimit -n 10240` the team runs
/// with; enough for concurrent subagents each spawning hook processes.
const int fdLimitTarget = 10240;

/// One `getrlimit(RLIMIT_NOFILE)` reading. [hard] below 0 = unlimited
/// (`RLIM_INFINITY`, which the 64-bit `rlim_t` reports as all-ones).
typedef FdLimits = ({int soft, int hard});

/// The platform seam: reads the current limits and sets a new soft limit.
/// Implementations never throw — a failure answers false / null — so the
/// raise is strictly best-effort.
abstract interface class FdLimitBackend {
  /// The current limits, or null when the platform cannot report them.
  FdLimits? getLimits();

  /// Sets the soft limit to [soft] (the hard limit is never lowered).
  /// Whether `setrlimit` accepted it.
  bool setSoftLimit(int soft);
}

/// What one [FdLimitRaiser.apply] did.
enum FdLimitOutcome {
  /// `setrlimit` raised the soft limit.
  raised,

  /// Nothing to do: the soft limit already meets the target.
  alreadySufficient,

  /// The platform has no `getrlimit` (web, Windows) or the hard limit
  /// leaves nothing to raise (hard ≤ soft).
  unsupported,

  /// `setrlimit` refused (a sandboxed or hardened host).
  refused,
}

/// One-shot soft-limit raise, pure over [backend].
///
/// Exactly ONCE per instance (a process calls [apply] from `main()`; a
/// second call — or any call after a refusal — is a no-op answering
/// null, so a `--version` boot never pays the syscall twice and a
/// sandboxed host is not retried on every command). [target] is capped at
/// the hard limit; a hard limit at or below the current soft limit means
/// nothing can be raised.
final class FdLimitRaiser {
  FdLimitRaiser({required this.backend, this.target = fdLimitTarget});

  /// Null on platforms without `RLIMIT_NOFILE` semantics (web, Windows).
  final FdLimitBackend? backend;

  /// The soft limit to reach, capped at the hard limit.
  final int target;

  var _applied = false;

  /// Whether [apply] already ran (whatever it decided).
  bool get applied => _applied;

  /// The raise plan for [limits]: the soft limit to set, or null when
  /// nothing should change. Pure — the unit tests pin every branch.
  int? planFor(FdLimits limits) {
    if (limits.soft >= target) return null; // already sufficient
    final cap = limits.hard < 0
        ? target
        : (limits.hard < target ? limits.hard : target);
    if (cap <= limits.soft) return null; // hard limit leaves no room
    return cap;
  }

  /// Applies the raise once. Null when this instance already ran or the
  /// platform has no backend.
  FdLimitOutcome? apply() {
    if (_applied) return null;
    _applied = true;
    final b = backend;
    final current = b?.getLimits();
    if (b == null || current == null) return FdLimitOutcome.unsupported;
    final planned = planFor(current);
    if (planned == null) {
      // Two different "nothing to set": already there vs. a hard limit
      // that leaves no room (the host cannot help us).
      return current.soft >= target
          ? FdLimitOutcome.alreadySufficient
          : FdLimitOutcome.unsupported;
    }
    return b.setSoftLimit(planned)
        ? FdLimitOutcome.raised
        : FdLimitOutcome.refused;
  }
}
