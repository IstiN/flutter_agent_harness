import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #522 — a live session file can never silently vanish:
///
/// * every destructive op on a session file is journaled into a per-root
///   `session_ops.journal` (who: pid/session/tool, what: path, when),
/// * deleting a live-registered session (presence heartbeat / ownership
///   lease) is REFUSED with a named error — stale check via heartbeat
///   expiry only,
/// * deletes move the file into `<root>/.trash/<timestamp>_<name>`
///   (never unlink) until an explicit TTL purge.
void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;
  late SessionOpsJournal journal;

  Future<SessionMetadata> createSession({
    String? id,
    List<String> extraLines = const [],
  }) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', id: id),
    );
    final metadata = await session.getMetadata();
    if (extraLines.isNotEmpty) {
      await env.appendFile(metadata.path, extraLines.join('\n'));
      await env.appendFile(metadata.path, '\n');
    }
    return metadata;
  }

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/');
    repo = JsonlSessionRepo(
      fs: env,
      sessionsRoot: '/sessions',
      actor: () =>
          const SessionOpsActor(pid: 1111, host: 'cli', sessionId: 'own'),
    );
    journal = SessionOpsJournal(fs: env, sessionsRoot: '/sessions');
  });

  group('SessionOpsJournal (AC1: journaled deletes)', () {
    test('delete writes a trash record naming pid + session + tool', () async {
      final metadata = await createSession(extraLines: ['{"type":"msg"}']);
      await repo.delete(metadata, tool: 'sessions_ui');

      final entries = await journal.entries();
      expect(entries, hasLength(1));
      final record = entries.single;
      expect(record.kind, SessionOpKind.trash);
      expect(record.path, metadata.path);
      expect(record.to, contains('/sessions/.trash/'));
      expect(record.to, endsWith('.jsonl'));
      expect(record.bytes, greaterThan(0));
      expect(record.actor?.pid, 1111);
      expect(record.actor?.host, 'cli');
      expect(record.actor?.sessionId, 'own');
      expect(record.actor?.tool, 'sessions_ui');
      expect(record.ts.year, greaterThanOrEqualTo(2026));
    });

    test('cleanupEmptySessions journals every trashed file', () async {
      await createSession(id: 'empty-1'); // header only
      await createSession(id: 'full-1', extraLines: ['{"type":"msg"}']);

      final removed = await repo.cleanupEmptySessions();
      expect(removed, 1);

      final entries = await journal.entries();
      expect(
        entries.map((e) => e.kind),
        everyElement(SessionOpKind.cleanupTrash),
      );
      expect(entries, hasLength(1));
      expect(entries.single.path, contains('empty-1'));
    });

    test('journal write failure never breaks the delete', () async {
      final metadata = await createSession();
      // A journal whose root cannot be created still deletes fine.
      final brokenJournal = SessionOpsJournal(
        fs: _FailingAppendFs(env),
        sessionsRoot: '/sessions',
      );
      await brokenJournal.record(SessionOpKind.trash, path: metadata.path);
      await repo.delete(metadata);
      expect(await env.exists(metadata.path).then((r) => r.valueOrNull), false);
    });
  });

  group('trash, never unlink (AC3)', () {
    test('delete moves the file into .trash/<timestamp>_<name>', () async {
      final metadata = await createSession(extraLines: ['{"record":"body"}']);
      final before = await env.readTextFile(metadata.path);

      await repo.delete(metadata);

      expect(
        await env.exists(metadata.path).then((r) => r.valueOrNull),
        isFalse,
        reason: 'the original path must be vacated',
      );
      final trashDir = await env
          .joinPath(['/sessions', '.trash'])
          .then((r) => r.valueOrNull as String);
      final trashed = (await env.listDir(trashDir).then((r) => r.valueOrNull))
          ?.where((f) => f.kind == FileKind.file)
          .toList();
      expect(trashed, hasLength(1));
      expect(trashed!.single.name, endsWith('.jsonl'));
      expect(
        trashed.single.name,
        contains(metadata.id),
        reason: 'trash names keep the original file name',
      );
      final moved = await env.readTextFile(trashed.single.path);
      expect(moved.valueOrNull, before.valueOrNull);
    });

    test('trashed sessions do not resurrect in list()', () async {
      final metadata = await createSession(extraLines: ['{"type":"msg"}']);
      await repo.delete(metadata);
      expect(await repo.list(), isEmpty);
    });

    test('purgeExpiredTrash removes only entries older than the ttl', () async {
      final metadata = await createSession(extraLines: ['{"type":"msg"}']);
      await repo.delete(metadata);

      // Nothing purged inside the ttl.
      expect(await repo.purgeExpiredTrash(), 0);

      final trashDir = await env
          .joinPath(['/sessions', '.trash'])
          .then((r) => r.valueOrNull as String);
      final trashed = (await env.listDir(trashDir).then((r) => r.valueOrNull))!
          .where((f) => f.kind == FileKind.file)
          .first;
      env.setMtime(
        trashed.path,
        DateTime.now()
            .subtract(const Duration(days: 31))
            .millisecondsSinceEpoch,
      );

      expect(await repo.purgeExpiredTrash(), 1);
      expect(
        await env
            .listDir(trashDir)
            .then((r) => r.valueOrNull?.where((f) => f.kind == FileKind.file)),
        isEmpty,
      );
      final entries = await journal.entries();
      expect(entries.last.kind, SessionOpKind.purge);
      expect(entries.last.path, trashed.path);
    });

    test('a non-renamable filesystem still lands the file in trash', () async {
      final plainRepo = JsonlSessionRepo(
        fs: _NonRenamableFs(env),
        sessionsRoot: '/sessions',
      );
      final metadata = await createSession(extraLines: ['{"type":"msg"}']);
      final before = await env.readTextFile(metadata.path);

      await plainRepo.delete(metadata);

      expect(
        await env.exists(metadata.path).then((r) => r.valueOrNull),
        isFalse,
      );
      final trashDir = await env
          .joinPath(['/sessions', '.trash'])
          .then((r) => r.valueOrNull as String);
      final trashed = (await env.listDir(trashDir).then((r) => r.valueOrNull))!
          .where((f) => f.kind == FileKind.file)
          .single;
      expect(
        (await env.readTextFile(trashed.path)).valueOrNull,
        before.valueOrNull,
      );
    });
  });

  group('live-session guard (AC2)', () {
    test(
      'a live presence registration refuses the delete, named error',
      () async {
        var now = DateTime.utc(2026, 9, 16, 21, 0);
        final presence = FileSessionPresenceStore(
          env: env,
          root: '/sessions',
          now: () => now,
        );
        final guarded = JsonlSessionRepo(
          fs: env,
          sessionsRoot: '/sessions',
          guard: PresenceLeaseSessionGuard(presence: presence),
          actor: () => const SessionOpsActor(pid: 1111, host: 'cli'),
        );
        final metadata = await createSession(extraLines: ['{"type":"msg"}']);
        await presence.register(metadata.id, pid: 4242, host: 'fa');

        await expectLater(
          guarded.delete(metadata),
          throwsA(
            isA<SessionException>()
                .having((e) => e.code, 'code', SessionErrorCode.sessionLive)
                .having((e) => e.message, 'message', contains('4242')),
          ),
        );
        // The file survived.
        expect(
          await env.exists(metadata.path).then((r) => r.valueOrNull),
          isTrue,
        );
        // The refusal is journaled — the audit trail for the incident.
        final entries = await journal.entries();
        expect(entries.last.kind, SessionOpKind.refusedLive);
        expect(entries.last.path, metadata.path);
        expect(entries.last.reason, contains('4242'));
      },
    );

    test('an expired heartbeat (dead process) allows the delete', () async {
      var now = DateTime.utc(2026, 9, 16, 21, 0);
      final presence = FileSessionPresenceStore(
        env: env,
        root: '/sessions',
        now: () => now,
      );
      final guarded = JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
        guard: PresenceLeaseSessionGuard(presence: presence),
      );
      final metadata = await createSession(extraLines: ['{"type":"msg"}']);
      await presence.register(metadata.id, pid: 4242);

      // Stale-check via heartbeat expiry only: 20s silence = dead.
      now = now.add(const Duration(seconds: 20));

      await guarded.delete(metadata);
      expect(
        await env.exists(metadata.path).then((r) => r.valueOrNull),
        isFalse,
      );
      final entries = await journal.entries();
      expect(entries.last.kind, SessionOpKind.trash);
    });

    test(
      'the live owner itself (same pid) may delete its own session',
      () async {
        final presence = _FakePresence({
          'sess-1': const SessionPresence(
            sessionId: 'sess-1',
            startedAt: '',
            touchedAt: '',
            pid: 1111,
            host: 'cli',
          ),
        });
        final guarded = JsonlSessionRepo(
          fs: env,
          sessionsRoot: '/sessions',
          guard: PresenceLeaseSessionGuard(presence: presence),
          actor: () => const SessionOpsActor(pid: 1111, host: 'cli'),
        );
        final metadata = await createSession(
          id: 'sess-1',
          extraLines: ['{"type":"msg"}'],
        );

        await guarded.delete(metadata);
        expect(
          await env.exists(metadata.path).then((r) => r.valueOrNull),
          isFalse,
        );
      },
    );

    test('a live ownership lease refuses, an expired one allows', () async {
      var now = DateTime.utc(2026, 9, 16, 21, 0);
      final lease = FileSessionLeaseStore(env: env, now: () => now);
      final guarded = JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
        guard: PresenceLeaseSessionGuard(lease: lease),
        actor: () => const SessionOpsActor(pid: 1111, host: 'cli'),
      );
      final metadata = await createSession(extraLines: ['{"type":"msg"}']);
      final acquired = await lease.acquire(
        sessionFilePath: metadata.path,
        sessionId: metadata.id,
        host: 'app',
        bootId: 'boot-1',
        pid: 4242,
      );
      expect(acquired, isA<LeaseAcquired>());
      // mtime pins liveness in the memory fs (age 0 = a live owner).
      env.setMtime(
        lease.sidecarPath(metadata.path),
        now.millisecondsSinceEpoch,
      );

      await expectLater(
        guarded.delete(metadata),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.sessionLive,
          ),
        ),
      );
      expect(
        await env.exists(metadata.path).then((r) => r.valueOrNull),
        isTrue,
      );

      // Owner died: the sidecar heartbeat expired.
      now = now.add(const Duration(seconds: 20));
      await guarded.delete(metadata);
      expect(
        await env.exists(metadata.path).then((r) => r.valueOrNull),
        isFalse,
      );
    });

    test(
      'cleanupEmptySessions skips a live-registered empty session',
      () async {
        final presence = _FakePresence({
          'live-empty': const SessionPresence(
            sessionId: 'live-empty',
            startedAt: '',
            touchedAt: '',
            pid: 4242,
          ),
        });
        final guarded = JsonlSessionRepo(
          fs: env,
          sessionsRoot: '/sessions',
          guard: PresenceLeaseSessionGuard(presence: presence),
        );
        final metadata = await createSession(id: 'live-empty');

        expect(await guarded.cleanupEmptySessions(), 0);
        expect(
          await env.exists(metadata.path).then((r) => r.valueOrNull),
          isTrue,
        );
        final entries = await journal.entries();
        expect(entries.last.kind, SessionOpKind.refusedLive);
      },
    );
  });
}

/// Presence double: whatever [live] holds is a fresh registration.
final class _FakePresence implements SessionPresenceStore {
  _FakePresence(this.live);

  final Map<String, SessionPresence> live;

  @override
  Future<Map<String, SessionPresence>> list() async => live;

  @override
  Future<void> register(String sessionId, {int? pid, String? host}) async {}

  @override
  Future<void> touch(String sessionId) async {}

  @override
  Future<void> unregister(String sessionId) async {}
}

/// Delegates every [FileSystem] member to [delegate] except [appendFile],
/// which always fails — journal writes die, the delete must not.
final class _FailingAppendFs extends _FsOverlay {
  _FailingAppendFs(super.delegate);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    return Future.value(
      Err(FileError(FileErrorCode.unknown, 'append refused', path: path)),
    );
  }
}

/// A [FileSystem] that is deliberately NOT a [RenamableFileSystem]: the
/// trash move must degrade to copy+remove, never to unlink-without-trace.
///
/// Implements the plain interface over the delegate env; the inherited
/// rename capability is hidden because this class is only a [FileSystem].
final class _NonRenamableFs extends _FsOverlay {
  _NonRenamableFs(super.delegate);
}

/// Explicit per-member [FileSystem] delegation (noSuchMethod forwarding
/// does not exist in stable Dart).
base class _FsOverlay implements FileSystem {
  _FsOverlay(this._delegate);

  final FileSystem _delegate;

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);
}
