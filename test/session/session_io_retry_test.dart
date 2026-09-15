import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'flaky_session_fs.dart';

/// Issue #427: transient-ENOENT resilience for the JSONL session store.
/// A session-file open/append can momentarily fail on real hosts (macOS
/// Group Containers materialization, backup, AV scans); the storage rides
/// it out with a small capped-backoff retry, logs one `session_io_retry`
/// line per retry, and exhausts into a NAMED [SessionException] — never a
/// wedge, never a crash. Deterministic: a fake fs fails the first N calls.
void main() {
  const path = '/sessions/s.jsonl';

  /// Retry wiring with instant, recorded sleeps and a capturing logger —
  /// same cap semantics as production, zero wall-clock cost.
  ({SessionIoRetryConfig config, List<String> logs, List<Duration> delays})
  recordingRetry({int maxAttempts = 4}) {
    final logs = <String>[];
    final delays = <Duration>[];
    final config = SessionIoRetryConfig(
      policy: SessionIoRetryPolicy(
        maxAttempts: maxAttempts,
        initialBackoff: Duration.zero,
        multiplier: 1,
        maxTotalBackoff: const Duration(seconds: 2),
      ),
      logger: logs.add,
      delay: (d) async => delays.add(d),
    );
    return (config: config, logs: logs, delays: delays);
  }

  Future<JsonlSessionStorage> createStorage(
    FlakySessionFs fs, {
    SessionIoRetryConfig ioRetry = const SessionIoRetryConfig(),
  }) {
    return JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 's1',
      ioRetry: ioRetry,
    );
  }

  group('JsonlSessionStorage transient-ENOENT retry (issue #427)', () {
    test('appendEntry retries a transient ENOENT and lands the record',
        () async {
      final fs = FlakySessionFs();
      final retry = recordingRetry();
      final storage = await createStorage(fs, ioRetry: retry.config);
      fs.failNextAppends = 2;

      final record = MessageRecord(
        id: 'e1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('hello'),
      );
      await storage.appendEntry(record);

      // The record landed on disk exactly once, after the retries.
      final content = (await fs.readTextFile(path)).getOrThrow();
      final lines = content.trim().split('\n');
      expect(lines, hasLength(2));
      expect(jsonDecode(lines.last)['id'], 'e1');
      expect(fs.appendCalls, 3);
      expect(retry.delays, hasLength(2));
      // One `session_io_retry` line per retry, naming the op.
      expect(retry.logs, hasLength(2));
      expect(retry.logs[0], contains('session_io_retry'));
      expect(retry.logs[0], contains('op=append'));
      expect(retry.logs[0], contains('attempt=2/4'));
      expect(retry.logs[1], contains('attempt=3/4'));
      // The in-memory index sees the record too.
      expect(await storage.getEntry('e1'), same(record));
    });

    test('appendEntry exhaustion is a named SessionException and never '
        'poisons the store for later appends', () async {
      final fs = FlakySessionFs();
      final retry = recordingRetry(maxAttempts: 3);
      final storage = await createStorage(fs, ioRetry: retry.config);
      fs.failNextAppends = 99; // every attempt fails

      await expectLater(
        storage.appendEntry(
          MessageRecord(
            id: 'e1',
            parentId: null,
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('hello'),
          ),
        ),
        throwsA(
          isA<SessionException>()
              .having((e) => e.code, 'code', SessionErrorCode.notFound)
              .having(
                (e) => e.message,
                'message',
                contains('Failed to append session entry e1'),
              )
              .having((e) => e.cause, 'cause', isA<FileError>()),
        ),
      );
      // Capped: exactly maxAttempts attempts, then the named error —
      // no wedge, no crash.
      expect(fs.appendCalls, 3);
      expect(retry.logs, hasLength(2));
      expect(retry.logs.every((l) => l.contains('session_io_retry')), isTrue);

      // The failure does not wedge the file lock chain: a healthy append
      // right after still lands.
      fs.failNextAppends = 0;
      await storage.appendEntry(
        MessageRecord(
          id: 'e2',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('world'),
        ),
      );
      final content = (await fs.readTextFile(path)).getOrThrow();
      final lines = content.trim().split('\n');
      expect(lines, hasLength(2));
      expect(jsonDecode(lines.last)['id'], 'e2');
    });

    test('open retries a transient ENOENT during the full read', () async {
      final fs = FlakySessionFs();
      final retry = recordingRetry();
      final storage = await createStorage(fs);
      await storage.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hello'),
        ),
      );
      fs.failNextReads = 1;

      final reopened = await JsonlSessionStorage.open(
        fs,
        path,
        ioRetry: retry.config,
      );

      expect(await reopened.getEntry('e1'), isNotNull);
      expect(fs.readCalls, 2);
      expect(retry.logs, hasLength(1));
      expect(retry.logs.single, contains('op=open'));
      expect(retry.logs.single, contains('attempt=2/4'));
    });

    test('create retries a transient ENOENT on the header write', () async {
      final fs = FlakySessionFs();
      final retry = recordingRetry();
      fs.failNextWrites = 1;

      await JsonlSessionStorage.create(
        fs,
        path,
        cwd: '/work',
        sessionId: 's1',
        ioRetry: retry.config,
      );

      expect(fs.writeCalls, 2);
      expect(retry.logs, hasLength(1));
      expect(retry.logs.single, contains('op=create'));
      expect(retry.logs.single, contains('attempt=2/4'));
    });

    test('windowed appendEntry rides the same helper (app chat submit path)',
        () async {
      final fs = FlakySessionFs();
      final retry = recordingRetry();
      await JsonlSessionStorage.create(
        fs,
        path,
        cwd: '/work',
        sessionId: 's1',
      );
      final windowed = await WindowedSessionStorage.open(
        fs,
        path,
        ioRetry: retry.config,
      );
      fs.failNextAppends = 1;

      await windowed.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hello'),
        ),
      );

      expect(fs.appendCalls, 2);
      expect(retry.logs, hasLength(1));
      expect(retry.logs.single, contains('op=append'));
      final content = (await fs.readTextFile(path)).getOrThrow();
      expect(content.trim().split('\n'), hasLength(2));
    });
  });

  group('JsonlSessionRepo transient-ENOENT retry (issue #427)', () {
    test('open retries a transient ENOENT and returns the session',
        () async {
      final fs = FlakySessionFs();
      final retry = recordingRetry();
      final repo = JsonlSessionRepo(
        fs: fs,
        sessionsRoot: '/sessions',
        ioRetry: retry.config,
      );
      final created = await repo.create(
        const JsonlSessionCreateOptions(cwd: '/work', id: 's1'),
      );
      final metadata = await created.getMetadata();
      fs.failNextReads = 1;

      final opened = await repo.open(metadata);

      expect(opened.cachedId, 's1');
      expect(fs.readCalls, 2);
      expect(retry.logs.single, contains('op=open'));
    });
  });
}
