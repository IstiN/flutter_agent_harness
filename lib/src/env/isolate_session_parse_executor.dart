/// `dart:isolate`-backed [SessionParseExecutor] (issue #199): each bounded
/// batch parses inside `Isolate.run`, so the calling (UI) isolate never
/// decodes session JSON. Exported only from `lib/io.dart` — web has no
/// isolates and keeps the inline batched path.
///
/// Deviation from the issue's "long-lived pool of 2" open question, pinned:
/// `Isolate.run` forks from the isolate group (sub-ms spawn), so per-batch
/// spawning amortizes the same way with zero worker-lifecycle code and no
/// request/cancel protocol; caller-side bounds (16-way listing, sequential
/// open batches) cap concurrency (E4: the VM sizes isolate groups to the
/// cores available).
library;

import 'dart:isolate';

import 'session_parse_executor.dart';

/// Parses every batch in a fresh short-lived isolate.
final class IsolateSessionParseExecutor implements SessionParseExecutor {
  const IsolateSessionParseExecutor();

  @override
  Future<SessionParseResult> parse(SessionParseBatch batch) {
    return Isolate.run(() => parseSessionEntryLinesSync(batch));
  }
}
