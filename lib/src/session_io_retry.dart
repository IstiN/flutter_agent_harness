/// Transient-ENOENT resilience for the JSONL session store (issue #427,
/// relatives of the submit-death freeze family #355): on some hosts a
/// session-file open, create or append momentarily fails with a
/// not-found-shaped error even though the file exists — macOS Group
/// Containers materialization, Time Machine, AV scans, cloud-backed
/// stores revoking a placeholder mid-read. The record would be lost (a
/// submit dies) if the failure propagated immediately.
///
/// [retryTransientSessionFileIo] rides those failures out with a small,
/// hard-capped exponential backoff (total wait ≤
/// [SessionIoRetryPolicy.maxTotalBackoff], ~1.5s in the default policy —
/// a submit must never hang long), logs one `session_io_retry` line per
/// retry through an injectable logger (the CLI wires its `_logDiagnostic`
/// sink, which appends timestamped lines to `~/.fah/logs/fa.log`), and
/// on exhaustion simply returns the last [Err] — the call sites'
/// `_fsOrThrow` then surfaces it as a NAMED [SessionException]. No
/// wedge, no crash, no silent data loss beyond the original failure.
///
/// Pure Dart: the injected [FileSystem] is the only I/O surface (the
/// pure-Dart core rule — no `dart:io` outside `lib/io.dart`).
library;

import 'env/execution_env.dart';

/// Host diagnostic sink for retry lines. Hosts wire their existing
/// diagnostic log (the CLI's `_logDiagnostic` → `~/.fah/logs/fa.log`);
/// `null` keeps retries silent.
typedef SessionIoRetryLogger = void Function(String message);

/// The wall-clock sleep between retries. Injectable so tests observe the
/// backoff schedule without waiting for it.
Future<void> defaultSessionIoDelay(Duration delay) =>
    Future<void>.delayed(delay);

/// Capped exponential-backoff schedule for session-file retries.
final class SessionIoRetryPolicy {
  /// Creates a [SessionIoRetryPolicy].
  ///
  /// The defaults keep the whole retry window well under ~1.5s: attempts
  /// at t=0/50/250/1050ms — three retries for a transient ENOENT to
  /// clear, then a named failure.
  const SessionIoRetryPolicy({
    this.maxAttempts = defaultMaxAttempts,
    this.initialBackoff = const Duration(milliseconds: 50),
    this.multiplier = 4,
    this.maxTotalBackoff = const Duration(milliseconds: 1500),
  });

  /// Total attempts (initial try + retries) before giving up.
  static const int defaultMaxAttempts = 4;

  /// Total attempts, including the initial one.
  final int maxAttempts;

  /// The wait before the first retry; each later retry waits
  /// [multiplier] × the previous wait.
  final Duration initialBackoff;

  /// Growth factor between consecutive waits.
  final double multiplier;

  /// Hard budget for the accumulated wait: a retry whose computed wait
  /// would exceed the remaining budget is clamped to it, and once the
  /// budget is spent no further retry happens — regardless of
  /// [maxAttempts].
  final Duration maxTotalBackoff;
}

/// Retry wiring for one session store: the [policy] caps the window, the
/// [logger] receives one `session_io_retry` line per retry, and [delay]
/// replaces the wall-clock sleep (tests inject an instant recorder).
final class SessionIoRetryConfig {
  /// Creates a [SessionIoRetryConfig].
  const SessionIoRetryConfig({
    this.policy = const SessionIoRetryPolicy(),
    this.logger,
    this.delay = defaultSessionIoDelay,
  });

  /// The backoff schedule.
  final SessionIoRetryPolicy policy;

  /// One line per retry; `null` logs nothing.
  final SessionIoRetryLogger? logger;

  /// The sleep between retries.
  final Future<void> Function(Duration delay) delay;
}

/// Runs [operation] — one [FileSystem]-shaped call returning a
/// `Result` — retrying while it fails with a not-found-shaped
/// [FileError] (the transient-ENOENT shape; every other error code is
/// returned immediately). The last [Err] is returned as-is on
/// exhaustion, so the caller's `_fsOrThrow` names it
/// ([SessionErrorCode.notFound] via the existing mapping). Success and
/// non-retryable failures are indistinguishable from an un-wrapped call.
///
/// [op] names the operation in the log line (`open` / `create` /
/// `append`); [path] is the addressed session file.
Future<Result<T, FileError>> retryTransientSessionFileIo<T>(
  Future<Result<T, FileError>> Function() operation, {
  required String op,
  required String path,
  SessionIoRetryConfig config = const SessionIoRetryConfig(),
}) async {
  final policy = config.policy;
  var attempt = 0;
  var waited = Duration.zero;
  var backoff = policy.initialBackoff;
  while (true) {
    final result = await operation();
    attempt++;
    if (!result.isErr) return result;
    final error = result.errorOrNull!;
    if (error.code != FileErrorCode.notFound) return result;
    if (attempt >= policy.maxAttempts) return result;
    final remaining = policy.maxTotalBackoff - waited;
    if (remaining <= Duration.zero) return result;
    if (backoff > remaining) backoff = remaining;
    waited += backoff;
    final retryIn = backoff;
    backoff *= policy.multiplier;
    // One line per retry: the next attempt's number, the wait, the file,
    // and the underlying error — post-mortem greps start at
    // `session_io_retry`.
    config.logger?.call(
      'session_io_retry op=$op attempt=${attempt + 1}/${policy.maxAttempts} '
      'path=$path waitMs=${retryIn.inMilliseconds} error=${error.message}',
    );
    await config.delay(retryIn);
  }
}
