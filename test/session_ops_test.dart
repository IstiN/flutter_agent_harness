import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Unit coverage for the journal record shapes and the guard's
/// no-stores/one-store paths (issue #522).
void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/');
  });

  group('SessionOpRecord round-trip', () {
    test('toJson/fromJson survives every field', () {
      final record = SessionOpRecord(
        ts: DateTime.utc(2026, 9, 16, 21, 9, 3),
        kind: SessionOpKind.trash,
        path: '/sessions/--work--/a_b.jsonl',
        to: '/sessions/.trash/20260916T210903_a_b.jsonl',
        bytes: 424000,
        reason: 'incident',
        actor: const SessionOpsActor(
          pid: 85634,
          host: 'cli',
          sessionId: '01a0',
          tool: 'sessions_ui',
        ),
      );
      final decoded = SessionOpRecord.fromJson(record.toJson());
      expect(decoded!.kind, SessionOpKind.trash);
      expect(decoded.path, record.path);
      expect(decoded.to, record.to);
      expect(decoded.bytes, 424000);
      expect(decoded.reason, 'incident');
      expect(decoded.actor?.pid, 85634);
      expect(decoded.actor?.host, 'cli');
      expect(decoded.actor?.sessionId, '01a0');
      expect(decoded.actor?.tool, 'sessions_ui');
    });

    test('fromJson rejects torn/foreign lines (null, never throws)', () {
      expect(SessionOpRecord.fromJson({'op': 'trash'}), isNull);
      expect(
        SessionOpRecord.fromJson({'ts': 'nope', 'op': 'trash', 'path': 'x'}),
        isNull,
      );
      expect(
        SessionOpRecord.fromJson({
          'ts': '2026-09-16T21:09:03Z',
          'op': '???',
          'path': 'x',
        }),
        isNull,
      );
      expect(
        SessionOpRecord.fromJson({
          'ts': '2026-09-16T21:09:03Z',
          'op': 'purge',
          'path': 'x',
          'bytes': 'not-an-int',
          'actor': 'not-a-map',
        }),
        isNotNull,
      );
    });

    test('wire names round-trip for every kind', () {
      for (final kind in SessionOpKind.values) {
        expect(parseSessionOpKind(kind.wireName), kind);
      }
      expect(parseSessionOpKind('bogus'), isNull);
      expect(parseSessionOpKind(null), isNull);
    });

    test('actor withTool keeps identity, overrides the tool', () {
      const actor = SessionOpsActor(pid: 1, host: 'cli', tool: 'a');
      expect(actor.withTool('b').tool, 'b');
      expect(actor.withTool(null).tool, 'a');
      expect(actor.withTool('b').pid, 1);
    });
  });

  group('SessionOpsJournal', () {
    test('entries reads back only well-formed lines, oldest first', () async {
      final journal = SessionOpsJournal(fs: env, sessionsRoot: '/sessions');
      await env.createDir('/sessions');
      await env.writeFile(
        '/sessions/session_ops.journal',
        '{"ts":"2026-09-16T21:00:00Z","op":"trash","path":"a"}\n'
            'NOT JSON\n'
            '{"ts":"2026-09-16T21:01:00Z","op":"purge","path":"b"}\n',
      );
      final entries = await journal.entries();
      expect(entries.map((e) => e.kind), [
        SessionOpKind.trash,
        SessionOpKind.purge,
      ]);
    });

    test('entries on a missing journal is empty, never throws', () async {
      final journal = SessionOpsJournal(fs: env, sessionsRoot: '/sessions');
      expect(await journal.entries(), isEmpty);
    });

    test('record creates the journal under the root lazily', () async {
      final journal = SessionOpsJournal(fs: env, sessionsRoot: '/sessions');
      await journal.record(SessionOpKind.purge, path: 'x');
      final entries = await journal.entries();
      expect(entries, hasLength(1));
      expect(entries.single.kind, SessionOpKind.purge);
    });
  });

  group('PresenceLeaseSessionGuard', () {
    test('with no stores wired nothing is ever live', () async {
      final guard = PresenceLeaseSessionGuard();
      expect(await guard.liveOwnerOf(sessionId: 's', path: '/p.jsonl'), isNull);
    });

    test('with only a lease wired, presence is not consulted', () async {
      var now = DateTime.utc(2026, 9, 16, 21, 0);
      final lease = FileSessionLeaseStore(env: env, now: () => now);
      final guard = PresenceLeaseSessionGuard(lease: lease);
      expect(await guard.liveOwnerOf(sessionId: 's', path: '/p.jsonl'), isNull);
    });

    test('LiveSessionOwner renders a forensic label', () {
      expect(
        const LiveSessionOwner(
          source: 'presence',
          pid: 85634,
          host: 'cli',
        ).toString(),
        'presence pid 85634 (cli)',
      );
      expect(const LiveSessionOwner(source: 'lease').toString(), 'lease pid ?');
    });
  });
}
