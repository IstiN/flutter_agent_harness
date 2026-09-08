// Pins the `session_new` archive step (session_reset.dart): the live
// transcript is copied to a sibling archive before the live path is
// re-created, a never-materialised session archives as a clean no-op, and
// a failed copy THROWS instead of letting the reset destroy the only copy.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../src/session_reset.dart';

void main() {
  test('archives the live transcript to /session-<id>.jsonl', () async {
    final fs = MemoryFileSystem(cwd: '/')
      ..writeFile('/session.jsonl', '{"a":1}\n{"a":2}\n');
    final archive = await archiveLiveSession(
      fs: fs,
      sessionPath: '/session.jsonl',
      sessionId: 'abc',
    );
    expect(archive, '/session-abc.jsonl');
    expect(
      (await fs.readTextFile('/session-abc.jsonl')).valueOrNull,
      '{"a":1}\n{"a":2}\n',
    );
    // The live file is untouched — the caller re-creates it only after a
    // successful archive.
    expect(
      (await fs.readTextFile('/session.jsonl')).valueOrNull,
      '{"a":1}\n{"a":2}\n',
    );
  });

  test(
    'no live file (lazy session) → clean no-op returning the path',
    () async {
      final fs = MemoryFileSystem(cwd: '/');
      final archive = await archiveLiveSession(
        fs: fs,
        sessionPath: '/session.jsonl',
        sessionId: 'abc',
      );
      expect(archive, '/session-abc.jsonl');
      expect((await fs.exists('/session-abc.jsonl')).valueOrNull, isFalse);
    },
  );

  test('empty session id throws — nothing to archive from', () async {
    final fs = MemoryFileSystem(cwd: '/');
    await expectLater(
      archiveLiveSession(fs: fs, sessionPath: '/session.jsonl', sessionId: ''),
      throwsStateError,
    );
  });

  test('a failed archive write throws instead of enabling data loss', () async {
    // A read failure surfaces as unreadable; a write failure surfaces as
    // Err. Either way the helper must throw so the caller aborts the
    // reset before re-creating the live file.
    final fs = MemoryFileSystem(cwd: '/')
      ..writeFile('/session.jsonl', '{"a":1}\n');
    // Corrupt the read path: a directory where the file should be makes
    // readTextFile fail on the memory fs.
    fs.createDir('/session.jsonl');
    await expectLater(
      archiveLiveSession(
        fs: fs,
        sessionPath: '/session.jsonl',
        sessionId: 'abc',
      ),
      throwsA(anything),
    );
    // No half archive appeared.
    expect((await fs.exists('/session-abc.jsonl')).valueOrNull, isFalse);
  });

  test(
    'restoreArchivedSession copies the archive onto the live path',
    () async {
      final fs = MemoryFileSystem(cwd: '/')
        ..writeFile('/session-old.jsonl', '{"id":"old"}\n{"r":1}\n')
        ..writeFile('/session.jsonl', '{"id":"live"}\n');
      await restoreArchivedSession(
        fs: fs,
        sessionPath: '/session.jsonl',
        archivePath: '/session-old.jsonl',
      );
      expect(
        (await fs.readTextFile('/session.jsonl')).valueOrNull,
        '{"id":"old"}\n{"r":1}\n',
      );
    },
  );

  test('restoreArchivedSession: missing archive throws', () async {
    final fs = MemoryFileSystem(cwd: '/');
    await expectLater(
      restoreArchivedSession(
        fs: fs,
        sessionPath: '/session.jsonl',
        archivePath: '/session-ghost.jsonl',
      ),
      throwsStateError,
    );
  });
}
