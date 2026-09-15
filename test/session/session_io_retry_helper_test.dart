import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/session_io_retry.dart';
import 'package:test/test.dart';

void main() {
  group('retryTransientSessionFileIo', () {
    test('retries a transient ENOENT until the operation succeeds', () async {
      final logs = <String>[];
      final delays = <Duration>[];
      var calls = 0;
      final result = await retryTransientSessionFileIo<String>(
        () async {
          calls++;
          if (calls <= 2) {
            return Err(
              FileError(
                FileErrorCode.notFound,
                'transient ENOENT (simulated)',
                path: '/s.jsonl',
              ),
            );
          }
          return const Ok('content');
        },
        op: 'open',
        path: '/s.jsonl',
        config: SessionIoRetryConfig(
          logger: logs.add,
          delay: (d) async => delays.add(d),
        ),
      );

      expect(result.getOrThrow(), 'content');
      expect(calls, 3);
      // Default policy: 50ms then 200ms — exponential, far under the cap.
      expect(delays, [
        const Duration(milliseconds: 50),
        const Duration(milliseconds: 200),
      ]);
      // One `session_io_retry` line per retry, naming op, the upcoming
      // attempt, the path, and the underlying error.
      expect(logs, hasLength(2));
      expect(logs[0], contains('session_io_retry'));
      expect(logs[0], contains('op=open'));
      expect(logs[0], contains('attempt=2/4'));
      expect(logs[0], contains('path=/s.jsonl'));
      expect(logs[0], contains('transient ENOENT'));
      expect(logs[1], contains('attempt=3/4'));
    });

    test('a non-ENOENT failure is returned immediately (never retried)',
        () async {
      final logs = <String>[];
      final delays = <Duration>[];
      var calls = 0;
      final result = await retryTransientSessionFileIo<String>(
        () async {
          calls++;
          return const Err(
            FileError(
              FileErrorCode.permissionDenied,
              'permission denied',
              path: '/s.jsonl',
            ),
          );
        },
        op: 'append',
        path: '/s.jsonl',
        config: SessionIoRetryConfig(
          logger: logs.add,
          delay: (d) async => delays.add(d),
        ),
      );

      expect(calls, 1);
      expect(delays, isEmpty);
      expect(logs, isEmpty);
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, FileErrorCode.permissionDenied);
    });

    test('exhausting the cap returns the last error inside the total-wait '
        'budget (no wedge)', () async {
      final logs = <String>[];
      final delays = <Duration>[];
      const policy = SessionIoRetryPolicy(
        maxAttempts: 3,
        initialBackoff: Duration(milliseconds: 10),
        multiplier: 2,
        maxTotalBackoff: Duration(milliseconds: 25),
      );
      var calls = 0;
      final result = await retryTransientSessionFileIo<String>(
        () async {
          calls++;
          return Err(
            FileError(
              FileErrorCode.notFound,
              'transient ENOENT (simulated)',
              path: '/s.jsonl',
            ),
          );
        },
        op: 'append',
        path: '/s.jsonl',
        config: SessionIoRetryConfig(
          policy: policy,
          logger: logs.add,
          delay: (d) async => delays.add(d),
        ),
      );

      // Capped at maxAttempts — the caller fails with the last error
      // instead of hanging.
      expect(calls, 3);
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, FileErrorCode.notFound);
      // Backoff is clamped to the total-wait budget: 10ms, then the
      // remaining 15ms of the 25ms cap.
      expect(delays, [
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 15),
      ]);
      // One line per retry (2 retries), never one per attempt.
      expect(logs, hasLength(2));
      expect(logs[0], contains('attempt=2/3'));
      expect(logs[1], contains('attempt=3/3'));
    });
  });
}
