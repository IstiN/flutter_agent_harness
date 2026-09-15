@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

import '../session/flaky_session_fs.dart';

/// Issue #427: the task-resume child-session open (`TaskExecutor
/// ._resumeSession` → `jsonlChildSessionOpener`, the host wiring in
/// `child_session_io.dart`) rides the same capped transient-ENOENT retry
/// as every other JSONL session open — a resumed child's transcript file
/// that briefly disappears mid-open is retried, logged, and only then
/// fails as a named error.
void main() {
  const path = '/sessions/child.jsonl';

  test('the child-session opener retries a transient ENOENT and opens',
      () async {
    final fs = FlakySessionFs();
    final logs = <String>[];
    final delays = <Duration>[];
    final config = SessionIoRetryConfig(
      policy: SessionIoRetryPolicy(
        initialBackoff: Duration.zero,
        multiplier: 1,
        maxTotalBackoff: const Duration(seconds: 2),
      ),
      logger: logs.add,
      delay: (d) async => delays.add(d),
    );
    await JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 'child-1',
    );
    fs.failNextReads = 1;

    final session = await jsonlChildSessionOpener(fs, ioRetry: config)(path);

    expect(session.cachedId, 'child-1');
    expect(fs.readCalls, 2);
    expect(delays, hasLength(1));
    expect(logs.single, contains('session_io_retry'));
    expect(logs.single, contains('op=open'));
    expect(logs.single, contains('path=$path'));
  });

  test('the child-session opener exhausts the cap into a named '
      'SessionException (resume refuses, never wedges)', () async {
    final fs = FlakySessionFs();
    final logs = <String>[];
    final config = SessionIoRetryConfig(
      policy: SessionIoRetryPolicy(
        maxAttempts: 3,
        initialBackoff: Duration.zero,
        multiplier: 1,
        maxTotalBackoff: const Duration(seconds: 2),
      ),
      logger: logs.add,
      delay: (_) async {},
    );
    await JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 'child-1',
    );
    fs.failNextReads = 99;

    await expectLater(
      jsonlChildSessionOpener(fs, ioRetry: config)(path),
      throwsA(
        isA<SessionException>().having(
          (e) => e.cause,
          'cause',
          isA<FileError>().having(
            (f) => f.code,
            'code',
            FileErrorCode.notFound,
          ),
        ),
      ),
    );
    expect(fs.readCalls, 3);
    expect(logs, hasLength(2));
    expect(logs.every((l) => l.contains('session_io_retry')), isTrue);
  });
}
