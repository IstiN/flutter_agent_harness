import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The `_owner.json` session-ownership lease (issue #428, AC1 + AC7 +
/// E3/E4/E5): acquire → heartbeat → stale expiry → fresh acquire;
/// graceful release → immediate re-acquire; a live lease is NEVER
/// seized — the opener becomes a viewer.
void main() {
  late MemoryExecutionEnv env;
  late FileSessionLeaseStore store;
  late String sessionPath;

  // Fixed clock: leases stamp `2026-09-15T10:00:00Z`.
  final base = DateTime.utc(2026, 9, 15, 10);

  Future<void> seedLease({
    String host = 'cli',
    String pid = '999',
    String bootId = 'owner-boot',
    Duration age = Duration.zero,
    String? corrupt,
    Map<String, dynamic>? extra,
  }) async {
    final sidecar = store.sidecarPath(sessionPath);
    if (corrupt != null) {
      await env.writeFile(sidecar, corrupt);
    } else {
      await env.writeFile(
        sidecar,
        const JsonEncoder.withIndent('  ').convert({
          'host': host,
          'sessionId': 'sess-1',
          'pid': 999,
          'bootId': bootId,
          'heartbeatAt': base.toIso8601String(),
          'acquiredAt': base.toIso8601String(),
          ...?extra,
        }),
      );
    }
    // mtime pins liveness: age=0 is a live owner, >15s is a dead one.
    env.setMtime(
      sidecar,
      base.millisecondsSinceEpoch - age.inMilliseconds,
    );
  }

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    store = FileSessionLeaseStore(env: env, now: () => base);
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work'),
    );
    sessionPath = (await session.getMetadata()).path;
  });


  Future<LeaseAcquire> attempt({
    String bootId = 'mine',
    int pid = 1000,
    String host = 'cli',
  }) => store.acquire(
    sessionFilePath: sessionPath,
    sessionId: 'sess-1',
    host: host,
    bootId: bootId,
    pid: pid,
  );

  group('lease lifecycle (AC1)', () {
    test('free lease acquires and the sidecar carries the full shape',
        () async {
      final result = await attempt(bootId: 'mine', pid: 1000);
      expect(result, isA<LeaseAcquired>());
      final sidecar = store.sidecarPath(sessionPath);
      final json =
          jsonDecode((await env.readTextFile(sidecar)).valueOrNull!)
              as Map<String, dynamic>;
      expect(json['host'], 'cli');
      expect(json['sessionId'], 'sess-1');
      expect(json['pid'], 1000);
      expect(json['bootId'], 'mine');
      expect(json['acquiredAt'], base.toIso8601String());
      expect(json['heartbeatAt'], base.toIso8601String());
      // No temp files survive a publish.
      expect(
        (await env.listDir('/sessions')).valueOrNull!
            .where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('heartbeat refreshes liveness only for the owner (E3)', () async {
      await attempt(bootId: 'mine');
      expect(await store.heartbeat(sessionPath, 'mine'), isTrue);
      // A recycled PID with a different bootId never refreshes.
      expect(await store.heartbeat(sessionPath, 'someone-else'), isFalse);
    });

    test('graceful release frees the lease for immediate re-acquire', () async {
      await attempt(bootId: 'mine');
      await store.release(sessionPath, 'mine');
      expect((await store.inspect(sessionPath)).state, LeaseState.free);
      final again = await attempt(bootId: 'next');
      expect(again, isA<LeaseAcquired>());
    });

    test('release refuses to delete a foreign lease', () async {
      await seedLease(bootId: 'owner-boot');
      await store.release(sessionPath, 'mine');
      expect((await store.inspect(sessionPath)).state, LeaseState.live);
    });
  });

  group('live lease is never seized (AC3/AC7)', () {
    test('acquire over a live lease blocks as viewer', () async {
      await seedLease();
      final result = await attempt(bootId: 'mine');
      expect(result, isA<LeaseBlocked>());
      final blocked = result as LeaseBlocked;
      expect(blocked.lease.pid, 999);
      expect(blocked.lease.bootId, 'owner-boot');
      // The owner's sidecar is untouched.
      expect(
        (await store.inspect(sessionPath)).lease!.bootId,
        'owner-boot',
      );
    });

    test('property: no interleaving beats a fresh heartbeat (AC7)', () async {
      // Across interleavings of the two hosts' clocks: as long as the
      // owner's sidecar is fresher than the staleness window, a second
      // host NEVER acquires; past the window it always does.
      final liveDeltas = [
        const Duration(seconds: 0),
        const Duration(seconds: 5),
        const Duration(seconds: 14),
      ];
      final deadDeltas = [
        const Duration(seconds: 15),
        const Duration(seconds: 16),
        const Duration(seconds: 60),
        const Duration(days: 3),
      ];
      for (final delta in liveDeltas) {
        await seedLease(age: delta);
        expect(
          await attempt(bootId: 'challenger-$delta'),
          isA<LeaseBlocked>(),
          reason: 'delta $delta is inside the window — viewer',
        );
        await env.remove(store.sidecarPath(sessionPath), force: true);
      }
      for (final delta in deadDeltas) {
        await seedLease(age: delta);
        expect(
          await attempt(bootId: 'challenger-$delta'),
          isA<LeaseAcquired>(),
          reason: 'delta $delta is past the window — free to acquire',
        );
        await env.remove(store.sidecarPath(sessionPath), force: true);
      }
    });

    test('expiry frees the lease and names the dead owner', () async {
      await seedLease(age: const Duration(seconds: 20));
      final inspect = await store.inspect(sessionPath);
      expect(inspect.state, LeaseState.expired);
      expect(inspect.lease!.host, 'cli');
      expect(inspect.lease!.pid, 999);
      final result = await attempt(bootId: 'next');
      expect(result, isA<LeaseAcquired>());
    });
  });

  group('corrupt and foreign sidecars (E4)', () {
    test('a corrupt sidecar is no lease', () async {
      await seedLease(corrupt: '{not json');
      expect((await store.inspect(sessionPath)).state, LeaseState.free);
      expect(await attempt(), isA<LeaseAcquired>());
    });

    test('a non-object sidecar is no lease', () async {
      await seedLease(corrupt: '["array"]');
      expect((await store.inspect(sessionPath)).state, LeaseState.free);
    });

    test('strict parse: missing required fields throw', () {
      expect(
        () => SessionLease.fromJson({
          'host': 'cli',
          'sessionId': 's',
          'bootId': 'b',
          'heartbeatAt': 'x',
          'acquiredAt': 'y',
          // pid missing
        }),
        throwsFormatException,
      );
    });

    test('unknown fields are tolerated with a note', () {
      final lease = SessionLease.fromJson({
        'host': 'cli',
        'sessionId': 's',
        'pid': 1,
        'bootId': 'b',
        'heartbeatAt': 'x',
        'acquiredAt': 'y',
        'futureField': 42,
      });
      expect(lease.unknownFieldNotes, ['unknown lease field "futureField"']);
    });
  });

  group('banner text (AC9)', () {
    test('live banner matches the exact contract wording', () {
      final lease = SessionLease(
        host: 'cli',
        sessionId: 's',
        pid: 85634,
        bootId: 'b',
        // 14:32 in an arbitrary fixed local zone — toLocal round-trips.
        heartbeatAt: DateTime(2026, 9, 15, 14, 32).toUtc().toIso8601String(),
        acquiredAt: DateTime(2026, 9, 15, 14, 32).toUtc().toIso8601String(),
      );
      expect(
        viewerBannerText(lease, stale: false),
        'Driven by fa CLI (pid 85634) since 14:32 — you are viewing. '
        'Your messages are delivered to the live agent.',
      );
    });

    test('stale banner offers the reopen, never a takeover', () {
      final lease = SessionLease(
        host: 'macos',
        sessionId: 's',
        pid: 42,
        bootId: 'b',
        heartbeatAt: DateTime(2026, 9, 15, 9).toUtc().toIso8601String(),
        acquiredAt: DateTime(2026, 9, 15, 9).toUtc().toIso8601String(),
      );
      final text = viewerBannerText(lease, stale: true);
      expect(text, startsWith('Driven by Fa.app (pid 42) since 09:00'));
      expect(text, contains('reopen'));
      expect(text, isNot(contains('take over')));
    });

    test('host labels', () {
      expect(leaseOwnerLabel('cli'), 'fa CLI');
      expect(leaseOwnerLabel('macos'), 'Fa.app');
      expect(leaseOwnerLabel('ios'), 'Fa.app');
      expect(leaseOwnerLabel('extension'), 'Fa extension');
    });
  });
}
