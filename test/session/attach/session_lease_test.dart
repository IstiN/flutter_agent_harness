import 'dart:convert';
import 'dart:typed_data';

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
    env.setMtime(sidecar, base.millisecondsSinceEpoch - age.inMilliseconds);
  }

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    store = FileSessionLeaseStore(env: env, now: () => base);
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
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
    test(
      'free lease acquires and the sidecar carries the full shape',
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
          (await env.listDir(
            '/sessions',
          )).valueOrNull!.where((f) => f.path.endsWith('.tmp')),
          isEmpty,
        );
      },
    );

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
      expect((await store.inspect(sessionPath)).lease!.bootId, 'owner-boot');
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

  group('enforceable-backend failures refuse the drive (#2138)', () {
    Future<(FileSessionLeaseStore, String, _GateLeaseEnv)> rig(
      _GateLeaseEnv env,
    ) async {
      final store = FileSessionLeaseStore(env: env, now: () => base);
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final path = (await session.getMetadata()).path;
      return (store, path, env);
    }

    test('HOLE-2: a rename failure on an enforceable backend REFUSES the '
        'open — never drive unleased', () async {
      final (store, sessionPath, env) = await rig(
        _GateLeaseEnv()..failRenames = true,
      );
      final sidecar = store.sidecarPath(sessionPath);

      final result = await store.acquire(
        sessionFilePath: sessionPath,
        sessionId: 'sess-refuse',
        host: 'cli',
        bootId: 'mine',
        pid: 1000,
      );

      // Cannot prove the session is free → deny, not LeaseUnenforced.
      expect(result, isA<LeaseRefused>());
      expect((result as LeaseRefused).reason, LeaseRefuseReason.publishFailed);
      // No half-published sidecar, no tmp litter.
      expect((await env.readTextFile(sidecar)).valueOrNull, isNull);
      expect(
        (await env.listDir(
          '/sessions',
        )).valueOrNull!.where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test(
      'HOLE-3: a persistently unreadable verify REFUSES the open after '
      'bounded retries — the rename SUCCEEDED, only the read is broken',
      () async {
        final (store, sessionPath, _) = await rig(
          _GateLeaseEnv()..failingSidecarReads = 99,
        );

        final result = await store.acquire(
          sessionFilePath: sessionPath,
          sessionId: 'sess-verify',
          host: 'cli',
          bootId: 'mine',
          pid: 1000,
        );

        expect(result, isA<LeaseRefused>());
        expect((result as LeaseRefused).reason, LeaseRefuseReason.verifyFailed);
      },
    );

    test(
      'HOLE-3: a flaky verify read heals inside the bounded retry',
      () async {
        final (store, sessionPath, _) = await rig(
          // One failure feeds the initial inspect (read-side E4 fail-open),
          // one feeds the first verify read; the retry heals the rest.
          _GateLeaseEnv()..failingSidecarReads = 2,
        );

        final result = await store.acquire(
          sessionFilePath: sessionPath,
          sessionId: 'sess-flaky',
          host: 'cli',
          bootId: 'mine',
          pid: 1000,
        );

        expect(result, isA<LeaseAcquired>());
      },
    );
  });

  group('torn-write atomicity (#2262)', () {
    Future<(FileSessionLeaseStore, String, T)> rig<T extends _TornEnv>(
      T env,
    ) async {
      final store = FileSessionLeaseStore(env: env, now: () => base);
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final path = (await session.getMetadata()).path;
      return (store, path, env);
    }

    test('AC1: a second store inspecting DURING the heartbeat write window '
        'never fail-opens a live owner to free', () async {
      final (owner, sessionPath, torn) = await rig(_RenamableTornEnv());
      final watcher = FileSessionLeaseStore(env: torn, now: () => base);
      await owner.acquire(
        sessionFilePath: sessionPath,
        sessionId: 'sess-1',
        host: 'cli',
        bootId: 'owner-a',
        pid: 1000,
      );
      // The beat rewrites the sidecar every ~4s — a much larger reader
      // window than acquire. Pre-fix it truncate+writes the SIDECAR, so
      // the mid-write observer reads torn bytes and the watcher
      // fail-opens to free → dual ownership. Post-fix the beat goes
      // through a tmp; the sidecar is whole at every instant.
      final seen = <LeaseState>[];
      torn.onMidWrite = (_) async {
        seen.add((await watcher.inspect(sessionPath)).state);
      };
      expect(await owner.heartbeat(sessionPath, 'owner-a'), isTrue);
      expect(seen, isNotEmpty, reason: 'the mid-write hook must fire');
      expect(
        seen,
        everyElement(isNot(LeaseState.free)),
        reason: 'a torn read of a live owner must never report free',
      );
    });

    test('AC2: a concurrent reader sampling through 25 heartbeats never '
        'observes a partial sidecar (property)', () async {
      final (owner, sessionPath, torn) = await rig(_RenamableTornEnv());
      const bootId = 'owner-a';
      await owner.acquire(
        sessionFilePath: sessionPath,
        sessionId: 'sess-1',
        host: 'cli',
        bootId: bootId,
        pid: 1000,
      );
      final sidecar = owner.sidecarPath(sessionPath);
      // Sessions live at <root>/<encoded-cwd>/<file>: list the
      // sidecar's own directory, not the sessions root.
      final dir = sidecar.substring(0, sidecar.lastIndexOf('/'));
      // Park every write inside its tear window so the reader loop
      // samples mid-write.
      torn.onMidWrite = (_) =>
          Future<void>.delayed(const Duration(milliseconds: 2));
      final samples = <String>[];
      var reading = true;
      final reader = () async {
        while (reading) {
          final raw = (await torn.readTextFile(sidecar)).valueOrNull;
          if (raw != null) samples.add(raw);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }();
      for (var i = 0; i < 25; i++) {
        expect(await owner.heartbeat(sessionPath, bootId), isTrue);
      }
      reading = false;
      await reader;
      expect(samples, isNotEmpty, reason: 'the reader must have sampled');
      for (final raw in samples) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(decoded['bootId'], bootId);
      }
      expect(
        (await torn.listDir(
          dir,
        )).valueOrNull!.where((f) => f.name.endsWith('.tmp')),
        isEmpty,
        reason: 'a completed beat leaves no tmp behind',
      );
    });

    test('AC1: a torn READ (truncated bytes) retries within the bound '
        'instead of failing open to free', () async {
      final (store, sessionPath, torn) = await rig(_RenamableTornEnv());
      await store.acquire(
        sessionFilePath: sessionPath,
        sessionId: 'sess-1',
        host: 'cli',
        bootId: 'owner-a',
        pid: 1000,
      );
      torn.tornReads = 1; // next sidecar read returns half the bytes
      final found = await store.inspect(sessionPath);
      expect(found.state, LeaseState.live);
      expect(found.lease!.bootId, 'owner-a');
    });

    test('border: an orphan publish tmp of a DEAD publisher is swept on the '
        'next acquire; a fresh (in-flight) tmp survives', () async {
      final (store, sessionPath, env) = await rig(_RenamableTornEnv());
      final sidecar = store.sidecarPath(sessionPath);
      final dead = '$sidecar.deadboot.tmp';
      final fresh = '$sidecar.liveboot.tmp';
      await env.writeFile(dead, 'garbage');
      await env.writeFile(fresh, 'garbage');
      // Fixed clock: 20s ago is past staleAfter (dead publisher), now
      // is not (an in-flight acquirer's tmp).
      env.setMtime(
        dead,
        base.millisecondsSinceEpoch -
            const Duration(seconds: 20).inMilliseconds,
      );
      env.setMtime(fresh, base.millisecondsSinceEpoch);

      final result = await store.acquire(
        sessionFilePath: sessionPath,
        sessionId: 'sess-1',
        host: 'cli',
        bootId: 'mine',
        pid: 1000,
      );
      expect(result, isA<LeaseAcquired>());

      final dir = sidecar.substring(0, sidecar.lastIndexOf('/'));
      final names = (await env.listDir(dir)).valueOrNull!.map((f) => f.name);
      expect(names.where((n) => n.endsWith('.tmp')), {
        fresh.split('/').last,
      }, reason: 'only the dead publisher orphan is swept');
    });

    test('AC3: on a backend WITHOUT rename the heartbeat falls back to a '
        'single write + post-write verify (documented E5)', () async {
      final (store, sessionPath, plain) = await rig(_TornEnv());
      // No rename capability → acquire cannot enforce: no sidecar.
      expect(
        await store.acquire(
          sessionFilePath: sessionPath,
          sessionId: 'sess-1',
          host: 'cli',
          bootId: 'owner-a',
          pid: 1000,
        ),
        isA<LeaseUnenforced>(),
      );
      // A legacy/foreign publisher left our sidecar; the beat must land
      // and be verifiable on disk.
      await plain.writeFile(
        store.sidecarPath(sessionPath),
        const JsonEncoder.withIndent('  ').convert({
          'host': 'cli',
          'sessionId': 'sess-1',
          'pid': 1000,
          'bootId': 'owner-a',
          'heartbeatAt': base
              .subtract(const Duration(seconds: 3))
              .toIso8601String(),
          'acquiredAt': base.toIso8601String(),
        }),
      );
      expect(await store.heartbeat(sessionPath, 'owner-a'), isTrue);
      final json =
          jsonDecode(
                (await plain.readTextFile(
                  store.sidecarPath(sessionPath),
                )).valueOrNull!,
              )
              as Map<String, dynamic>;
      expect(json['heartbeatAt'], base.toIso8601String());
      // A foreign bootId never refreshes (E3) — unchanged.
      expect(await store.heartbeat(sessionPath, 'someone-else'), isFalse);
    });
  });
}

/// A renamable env with injected publish/verify failures: [failRenames]
/// breaks the atomic rename (hole-2 rig); [failingSidecarReads] makes the
/// next N sidecar READS fail (hole-3 rig — one is usually eaten by the
/// initial inspect, which stays read-side fail-open E4). Delegates to a
/// [MemoryExecutionEnv] and keeps the rename capability so the store
/// treats it as an ENFORCEABLE backend.
final class _GateLeaseEnv implements ExecutionEnv, RenamableFileSystem {
  _GateLeaseEnv() : _delegate = MemoryExecutionEnv(cwd: '/work');

  final MemoryExecutionEnv _delegate;
  bool failRenames = false;
  int failingSidecarReads = 0;

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    if (failRenames) {
      return Err(const FileError(FileErrorCode.unknown, 'rename exploded'));
    }
    return _delegate.renamePath(from, to);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    if (failingSidecarReads > 0 && path.endsWith('.owner.json')) {
      failingSidecarReads--;
      return Err(const FileError(FileErrorCode.unknown, 'sidecar read hiccup'));
    }
    return _delegate.readTextFile(path);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

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

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}

/// Delegates everything to a [MemoryExecutionEnv] while advertising NO
/// capability interfaces — the E5 (non-renamable, pure-web) backend
/// shape. Subclasses that mix in [_TornRename] become enforceable.
///
/// The #2262 rig: sidecar-family WRITES are observable mid-write
/// ([onMidWrite] fires between truncating the target and writing the
/// body — awaited, so an interleaved inspect runs inside the tear
/// window), and sidecar READS can return torn bytes ([tornReads] makes
/// the next N reads return half the file).
class _TornEnv implements ExecutionEnv {
  _TornEnv() : _delegate = MemoryExecutionEnv(cwd: '/work');

  final MemoryExecutionEnv _delegate;

  /// Fires inside the tear window of every sidecar-family write (the
  /// `.owner.json` file or its publish tmp). Awaited.
  Future<void> Function(String path)? onMidWrite;

  /// The next N sidecar READS return the first half of the file's bytes
  /// (a read caught mid-write). 0 = reads pass through.
  int tornReads = 0;

  /// Test-only mtime pin (the staleness clock), forwarded to the
  /// delegate's [MemoryExecutionEnv.setMtime].
  void setMtime(String path, int mtimeMs) => _delegate.setMtime(path, mtimeMs);

  static bool _isSidecarFamily(String path) => path.contains('.owner.json');

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    if (onMidWrite != null && _isSidecarFamily(path)) {
      await _delegate.writeFile(path, ''); // the torn state
      await onMidWrite!(path);
    }
    return _delegate.writeFile(path, content);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final raw = await _delegate.readTextFile(path);
    if (tornReads > 0 && _isSidecarFamily(path)) {
      tornReads--;
      final value = raw.valueOrNull;
      if (value != null && value.length > 1) {
        return Ok(value.substring(0, value.length ~/ 2));
      }
    }
    return raw;
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

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

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}

/// Atomic-rename capability over [_TornEnv]: mixing it in makes the
/// backend enforceable (the store probes `is RenamableFileSystem`).
mixin _TornRename on _TornEnv implements RenamableFileSystem {
  @override
  Future<Result<void, FileError>> renamePath(String from, String to) =>
      _delegate.renamePath(from, to);
}

final class _RenamableTornEnv extends _TornEnv with _TornRename {}
