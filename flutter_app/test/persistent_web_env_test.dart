// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/sandbox/fs_persistence.dart';
import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/persistent_web_env.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the web wiring in `env_factory_stub.dart`: a MemoryShell-backed
/// MemoryExecutionEnv wrapped for persistence.
Future<PersistentWebExecutionEnv> _restoreEnv(
  FsRecordStore store, {
  Duration persistDelay = const Duration(milliseconds: 800),
}) {
  final shell = MemoryShell();
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  return PersistentWebExecutionEnv.restore(
    env,
    store,
    persistDelay: persistDelay,
  );
}

void main() {
  group('PersistentWebExecutionEnv', () {
    test(
      'writes through the wrapper are readable through the same instance',
      () async {
        final env = await _restoreEnv(InMemoryFsRecordStore());
        (await env.writeFile('/notes/hello.txt', 'hi there')).getOrThrow();
        (await env.writeBinaryFile(
          '/bin.dat',
          Uint8List.fromList([0, 1, 2, 255]),
        )).getOrThrow();

        expect(
          (await env.readTextFile('/notes/hello.txt')).getOrThrow(),
          'hi there',
        );
        expect((await env.readBinaryFile('/bin.dat')).getOrThrow(), [
          0,
          1,
          2,
          255,
        ]);
        expect((await env.listDir('/notes')).getOrThrow().map((e) => e.name), [
          'hello.txt',
        ]);
      },
    );

    test(
      'mutations persist and restore into a fresh env (round-trip)',
      () async {
        final store = InMemoryFsRecordStore();
        final env = await _restoreEnv(store);
        (await env.writeFile('/dir/a.txt', 'hello')).getOrThrow();
        (await env.appendFile('/dir/a.txt', ' world')).getOrThrow();
        (await env.writeBinaryFile(
          '/dir/blob.bin',
          Uint8List.fromList([9, 8, 7]),
        )).getOrThrow();
        (await env.createDir('/empty')).getOrThrow();
        // Same FS as the agent's: sessions live there too and persist.
        (await env.writeFile(
          '/sessions/s1.jsonl',
          '{"role":"user"}\n',
        )).getOrThrow();
        await env.flush();
        expect(store.saveCount, greaterThan(0));

        final restored = await _restoreEnv(store);
        expect(
          (await restored.readTextFile('/dir/a.txt')).getOrThrow(),
          'hello world',
        );
        expect((await restored.readBinaryFile('/dir/blob.bin')).getOrThrow(), [
          9,
          8,
          7,
        ]);
        expect(
          (await restored.readTextFile('/sessions/s1.jsonl')).getOrThrow(),
          '{"role":"user"}\n',
        );
        expect((await restored.exists('/empty')).getOrThrow(), isTrue);
        expect(
          (await restored.listDir('/dir')).getOrThrow().map((e) => e.name),
          ['a.txt', 'blob.bin'],
        );
      },
    );

    test('remove persists', () async {
      final store = InMemoryFsRecordStore();
      final env = await _restoreEnv(store);
      (await env.writeFile('/gone.txt', 'x')).getOrThrow();
      await env.flush();
      (await env.remove('/gone.txt')).getOrThrow();
      await env.flush();

      final restored = await _restoreEnv(store);
      expect((await restored.exists('/gone.txt')).getOrThrow(), isFalse);
    });

    test('the debounced save fires without an explicit flush', () async {
      final store = InMemoryFsRecordStore();
      final env = await _restoreEnv(
        store,
        persistDelay: const Duration(milliseconds: 20),
      );
      (await env.writeFile('/auto.txt', 'auto')).getOrThrow();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(store.saveCount, greaterThan(0));

      final restored = await _restoreEnv(store);
      expect((await restored.readTextFile('/auto.txt')).getOrThrow(), 'auto');
    });

    test('shell commands mark the FS dirty (exec persistence hook)', () async {
      final store = InMemoryFsRecordStore();
      final env = await _restoreEnv(store);
      final result = await env.exec("printf 'from shell' > /via_shell.txt");
      expect(result.isOk, isTrue, reason: result.errorOrNull.toString());
      await env.flush();

      final restored = await _restoreEnv(store);
      expect(
        (await restored.readTextFile('/via_shell.txt')).getOrThrow(),
        'from shell',
      );
    });

    test('a corrupt snapshot restores to a clean FS and recovers', () async {
      final store = InMemoryFsRecordStore()..seed(PersistentWebExecutionEnv.storageKey, '{not json at all');
      final env = await _restoreEnv(store);
      expect((await env.listDir('/')).getOrThrow(), isEmpty);

      // Persistence keeps working afterwards and overwrites the bad data.
      (await env.writeFile('/after.txt', 'ok')).getOrThrow();
      await env.flush();
      final snapshot = jsonDecode(
          (await store.loadAll())[PersistentWebExecutionEnv.storageKey] ??
              '',
        ) as Map;
      expect(snapshot['version'], PersistentWebExecutionEnv.snapshotVersion);
      final restored = await _restoreEnv(store);
      expect((await restored.readTextFile('/after.txt')).getOrThrow(), 'ok');
    });

    test('a snapshot with an unknown version is ignored', () async {
      final store = InMemoryFsRecordStore()
        ..seed(
          PersistentWebExecutionEnv.storageKey,
          jsonEncode({
            'version': 999,
            'dirs': <String>[],
            'files': [
              {'path': '/old.txt', 'data': base64Encode(utf8.encode('old'))},
            ],
          }),
        );
      final env = await _restoreEnv(store);
      expect((await env.exists('/old.txt')).getOrThrow(), isFalse);
    });

    test(
      'a structurally valid but semantically corrupt snapshot is ignored',
      () async {
        final store = InMemoryFsRecordStore()
          ..seed(
            PersistentWebExecutionEnv.storageKey,
            jsonEncode({
              'version': PersistentWebExecutionEnv.snapshotVersion,
              'dirs': ['/x'],
              'files': [
                {'path': '/x/bad.txt', 'data': '!!! not base64 !!!'},
              ],
            }),
          );
        final env = await _restoreEnv(store);
        // Nothing was replayed (validation happens before any write), and the
        // env is fully usable.
        expect((await env.exists('/x/bad.txt')).getOrThrow(), isFalse);
        (await env.writeFile('/fine.txt', 'y')).getOrThrow();
        expect((await env.readTextFile('/fine.txt')).getOrThrow(), 'y');
      },
    );

    test(
      'IT-atomic-snapshot: a persist pass racing an install never '
      'persists a torn tree (issue #201)',
      () async {
        final store = InMemoryFsRecordStore();
        final env = await PersistentWebExecutionEnv.restore(
          _MidInstallEnv(),
          store,
        );
        // Install begins: manifest in, widget.js about to land...
        (await env.writeFile(
          '/apps/calculator/manifest.json',
          '{"id":"calculator"}',
        )).getOrThrow();
        // ...the debounced persist pass runs while the install is
        // mid-flight (the harness lands widget.js mid-pass).
        await env.flush();
        // The panel unloads before another pass could complete.
        env.dispose();

        // Reload: restore replays the persisted snapshot.
        final reloaded = await _restoreEnv(store);
        // The tile renders (manifest present)...
        expect(
          (await reloaded.exists('/apps/calculator/manifest.json'))
              .getOrThrow(),
          isTrue,
        );
        // ...and the launch must NOT hit the torn state:
        // FileError(notFound, /apps/calculator/widget.js).
        final launch = await reloaded.readTextFile(
          '/apps/calculator/widget.js',
        );
        expect(
          launch.valueOrNull,
          _MidInstallEnv.widgetJs,
          reason: 'torn snapshot persisted: ${launch.errorOrNull}',
        );
        reloaded.dispose();
      },
    );

    test(
      'UT-parity: the atomic export is byte-identical to a quiescent '
      'async walk (issue #201)',
      () async {
        final store = InMemoryFsRecordStore();
        final env = await _restoreEnv(store);
        // Golden fixture tree: nested dirs, an empty dir, binary content,
        // and a sessions log (the expensive real-world payload).
        (await env.writeFile('/apps/calc/manifest.json', '{"id":"calc"}'))
            .getOrThrow();
        (await env.writeFile('/apps/calc/widget.js', 'code')).getOrThrow();
        (await env.writeBinaryFile(
          '/apps/calc/icon.bin',
          Uint8List.fromList([0, 1, 254, 255]),
        )).getOrThrow();
        (await env.createDir('/apps/calc/assets/empty')).getOrThrow();
        (await env.writeFile('/notes/todo.txt', 'one\ntwo')).getOrThrow();
        (await env.writeFile(
          '/sessions/s1.jsonl',
          '{"role":"user"}\n',
        )).getOrThrow();
        await env.flush();
        env.dispose();

        // Reference: the pre-fix async-walk encoding over the now-quiescent
        // tree, compared against the MERGED persisted view (envelope files
        // plus per-session records, issue #237). Identical output proves
        // the atomic path changed the CONSISTENCY, not the CONTENT, of
        // snapshots (AC5): session bytes moved out of the envelope into
        // their own records, nothing else.
        final reloaded = await _restoreEnv(store);
        expect(
          _canonical(await _mergedStoredSnapshot(store)),
          _canonical(await _legacyWalkSnapshot(reloaded)),
        );
        reloaded.dispose();
      },
    );

    test(
      'IT-unload-flush: a mutation followed immediately by page unload '
      'persists (issue #201)',
      () async {
        final store = InMemoryFsRecordStore();
        // A debounce the test never lets fire: only the unload hook may save.
        final env = await _restoreEnv(
          store,
          persistDelay: const Duration(hours: 1),
        );
        (await env.writeFile('/apps/calculator/widget.js', 'code'))
            .getOrThrow();
        expect(env.hasPendingChanges, isTrue);

        // Simulated beforeunload / visibilitychange(hidden): the web
        // bootstrap's bindUnloadFlush calls exactly this.
        await env.onPageUnload();
        expect(env.hasPendingChanges, isFalse);
        expect(store.saveCount, greaterThan(0));
        env.dispose();

        final reloaded = await _restoreEnv(store);
        expect(
          (await reloaded.readTextFile('/apps/calculator/widget.js'))
              .getOrThrow(),
          'code',
        );
        reloaded.dispose();
      },
    );

    test('a store that throws on load starts clean', () async {
      final store = _ThrowingLoadStore();
      final env = await _restoreEnv(store);
      expect((await env.listDir('/')).getOrThrow(), isEmpty);
      (await env.writeFile('/still.txt', 'works')).getOrThrow();
      expect((await env.readTextFile('/still.txt')).getOrThrow(), 'works');
    });
  });

  // Issue #237 — pins for the #228 session-loss vectors in the IndexedDB
  // twin, over an in-memory record store (mirroring #236's FakeChrome
  // pins):
  //
  //   vector 1 (eviction):  deleting one session must remove ONLY its
  //                         record; a save must never drop live session
  //                         records.
  //   vector 2 (version wipe): a v1 envelope migrates; an unreadable/newer
  //                         envelope is backed up under sandbox.bak BEFORE
  //                         any save can overwrite it, and session records
  //                         (version-independent keys) still restore.
  //   vector 3 (torn/unload): rides the #201 fix — a session mutation
  //                         flushed by onPageUnload must actually persist
  //                         the session; session writes also persist
  //                         EAGERLY (mobile browsers may never fire
  //                         beforeunload).
  //   vector 4 (one-record quota): sessions live as per-file records
  //                         outside the monolith envelope, so one oversized
  //                         session fails alone; unrelated saves keep
  //                         working and previously-saved sessions stay
  //                         byte-identical.
  group('version safety (vector 2 — never wipe on version mismatch)', () {
    test(
      'a v1 envelope migrates: sessions and files restore, then persist '
      'as v2 with sessions OUTSIDE the envelope',
      () async {
        final store = InMemoryFsRecordStore()
          ..seed(
            PersistentWebExecutionEnv.storageKey,
            _v1Envelope(
              dirs: ['/notes'],
              files: {
                '/sessions/s1.jsonl': '{"v":1}\n{"role":"user"}\n',
                '/notes/a.txt': 'alpha',
              },
            ),
          );

        final env = await _restoreEnv(store);
        expect(
          (await env.readTextFile('/sessions/s1.jsonl')).getOrThrow(),
          '{"v":1}\n{"role":"user"}\n',
        );
        expect((await env.readTextFile('/notes/a.txt')).getOrThrow(), 'alpha');

        (await env.writeFile('/b.txt', 'beta')).getOrThrow();
        await env.flush();

        final stored = await store.loadAll();
        final envelope = _envelopeOf(stored);
        expect(envelope['version'], PersistentWebExecutionEnv.snapshotVersion);
        // The session migrated out of the envelope into its own record.
        expect(
          _envelopeFilePaths(stored),
          isNot(contains('/sessions/s1.jsonl')),
        );
        expect(
          _envelopeFilePaths(stored),
          containsAll(['/notes/a.txt', '/b.txt']),
        );
        expect(
          stored['${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/s1.jsonl'],
          _b64('{"v":1}\n{"role":"user"}\n'),
        );
        env.dispose();
      },
    );

    test(
      'a NEWER-version envelope is backed up, never wiped; session '
      'records still restore',
      () async {
        final futureEnvelope = jsonEncode({
          'version': PersistentWebExecutionEnv.snapshotVersion + 1,
          'dirs': <String>[],
          'files': <Object>[],
          'futureField': 'must-not-be-destroyed',
        });
        final store = InMemoryFsRecordStore()
          ..seed(PersistentWebExecutionEnv.storageKey, futureEnvelope)
          ..seed(
            '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/s1.jsonl',
            _b64('HISTORY'),
          );

        final env = await _restoreEnv(store);
        // Version-independent session records survive the envelope bump.
        expect(
          (await env.readTextFile('/sessions/s1.jsonl')).getOrThrow(),
          'HISTORY',
        );
        // The unreadable envelope is preserved under the backup key.
        expect(
          (await store.loadAll())[PersistentWebExecutionEnv.backupKey],
          futureEnvelope,
        );

        // A subsequent save may replace the envelope — but the backup stays.
        (await env.writeFile('/x.txt', 'x')).getOrThrow();
        await env.flush();
        final after = await store.loadAll();
        expect(after[PersistentWebExecutionEnv.backupKey], futureEnvelope);
        expect(
          _envelopeOf(after)['version'],
          PersistentWebExecutionEnv.snapshotVersion,
        );
        env.dispose();
      },
    );

    test(
      'a corrupt envelope is backed up and boot still restores session '
      'records',
      () async {
        final store = InMemoryFsRecordStore()
          ..seed(PersistentWebExecutionEnv.storageKey, '{not json at all')
          ..seed(
            '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/old.jsonl',
            _b64('OLD'),
          );

        final env = await _restoreEnv(store);
        expect(
          (await env.readTextFile('/sessions/old.jsonl')).getOrThrow(),
          'OLD',
        );
        expect(
          (await store.loadAll())[PersistentWebExecutionEnv.backupKey],
          '{not json at all',
        );
        env.dispose();
      },
    );
  });

  group('session writes and unload (vector 3 — rides the #201 fix)', () {
    test(
      'a session mutation flushed by onPageUnload persists the session '
      'record (sessions are included in the #201 unload path)',
      () async {
        final store = InMemoryFsRecordStore();
        // A debounce the test never lets fire: only the unload hook may save.
        final env = await _restoreEnv(
          store,
          persistDelay: const Duration(hours: 1),
        );
        (await env.writeFile('/sessions/s1.jsonl', '{"turn":1}\n'))
            .getOrThrow();

        await env.onPageUnload();

        final stored = await store.loadAll();
        expect(
          stored,
          contains(
            '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/s1.jsonl',
          ),
        );
        env.dispose();

        final reloaded = await _restoreEnv(store);
        expect(
          (await reloaded.readTextFile('/sessions/s1.jsonl')).getOrThrow(),
          '{"turn":1}\n',
        );
        reloaded.dispose();
      },
    );

    test(
      'a session write survives a reload WITHOUT a flush or unload hook '
      '(eager persist)',
      () async {
        final store = InMemoryFsRecordStore();
        final env = await _restoreEnv(store);
        (await env.writeFile('/sessions/s1.jsonl', '{"turn":1}\n'))
            .getOrThrow();
        // NO flush, NO unload: the page dies inside the 800 ms debounce
        // window (mobile browsers may never fire beforeunload).
        await _settle();

        final reincarnated = await _restoreEnv(store);
        expect(
          (await reincarnated.readTextFile('/sessions/s1.jsonl')).getOrThrow(),
          '{"turn":1}\n',
        );
        env.dispose();
      },
    );

    test('rapid session appends each reach storage without a flush', () async {
      final store = InMemoryFsRecordStore();
      final env = await _restoreEnv(store);
      (await env.appendFile('/sessions/s1.jsonl', 'a\n')).getOrThrow();
      (await env.appendFile('/sessions/s1.jsonl', 'b\n')).getOrThrow();
      (await env.appendFile('/sessions/s1.jsonl', 'c\n')).getOrThrow();
      await _settle();

      final reincarnated = await _restoreEnv(store);
      expect(
        (await reincarnated.readTextFile('/sessions/s1.jsonl')).getOrThrow(),
        'a\nb\nc\n',
      );
      env.dispose();
    });

    test('non-session files keep the debounce (documented tradeoff)', () async {
      final store = InMemoryFsRecordStore();
      final env = await _restoreEnv(store);
      (await env.writeFile('/scratch.txt', 'temp')).getOrThrow();
      await _settle();
      expect(
        await store.loadAll(),
        isNot(contains(PersistentWebExecutionEnv.storageKey)),
      );
      await env.flush();
      expect(
        await store.loadAll(),
        contains(PersistentWebExecutionEnv.storageKey),
      );
      env.dispose();
    });
  });

  group('per-session storage records (vector 1 eviction / vector 4 '
      'monolith)', () {
    test('sessions live outside the monolith envelope', () async {
      final store = InMemoryFsRecordStore();
      final env = await _restoreEnv(store);
      (await env.writeFile('/sessions/s1.jsonl', 'S' * 2000)).getOrThrow();
      (await env.writeFile('/app/data.txt', 'app-bytes')).getOrThrow();
      await env.flush();

      final stored = await store.loadAll();
      expect(
        stored.keys,
        containsAll([
          PersistentWebExecutionEnv.storageKey,
          '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/s1.jsonl',
        ]),
      );
      // The envelope carries neither the session path nor its bytes.
      expect(_envelopeFilePaths(stored), ['/app/data.txt']);
      expect(
        stored[PersistentWebExecutionEnv.storageKey]!,
        isNot(contains(_b64('S' * 2000))),
      );
      env.dispose();
    });

    test('appending to one session rewrites ONLY that record', () async {
      final store = _RecordingStore(InMemoryFsRecordStore());
      final env = await _restoreEnv(store);
      (await env.writeFile('/sessions/aaa.jsonl', 'one\n')).getOrThrow();
      (await env.writeFile('/sessions/bbb.jsonl', 'two\n')).getOrThrow();
      (await env.writeFile('/note.txt', 'n')).getOrThrow();
      await env.flush();

      store.changedKeys.clear();
      (await env.appendFile('/sessions/aaa.jsonl', 'more\n')).getOrThrow();
      await _settle();

      expect(store.changedKeys, {
        '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/aaa.jsonl',
      });
      env.dispose();
    });

    test(
      'deleting a session removes only its record; live records are '
      'never evicted by a save',
      () async {
        final store = InMemoryFsRecordStore();
        final env = await _restoreEnv(store);
        (await env.writeFile('/sessions/aaa.jsonl', 'one\n')).getOrThrow();
        (await env.writeFile('/sessions/bbb.jsonl', 'two\n')).getOrThrow();
        await env.flush();
        expect(
          await store.loadAll(),
          contains(
            '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/aaa.jsonl',
          ),
        );

        (await env.remove('/sessions/aaa.jsonl')).getOrThrow();
        await env.flush();

        final stored = await store.loadAll();
        expect(
          stored,
          isNot(
            contains(
              '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/aaa.jsonl',
            ),
          ),
        );
        expect(
          stored['${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/bbb.jsonl'],
          _b64('two\n'),
        );
        expect(stored, contains(PersistentWebExecutionEnv.storageKey));
        env.dispose();
      },
    );
  });

  group('quota isolation (vector 4 — one oversized session fails alone)', () {
    test(
      'an over-quota session does not block unrelated saves and leaves '
      'previously-saved sessions byte-identical',
      () async {
        const aaaKey =
            '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/aaa.jsonl';
        final store = InMemoryFsRecordStore(quotaBytes: 4000);

        final env = await _restoreEnv(store);
        (await env.writeFile('/sessions/aaa.jsonl', 'A' * 400)).getOrThrow();
        await env.flush();
        final savedA = (await store.loadAll())[aaaKey];
        expect(savedA, isNotNull);

        // The oversized session can never fit: its record write fails, the
        // env stays dirty (surfaced, retried), but nothing else breaks.
        (await env.writeFile('/sessions/big.jsonl', 'B' * 10000))
            .getOrThrow();
        await env.flush();
        expect(env.hasPendingChanges, isTrue);

        // Unrelated saves keep working: the envelope no longer carries
        // session bytes, so it still fits.
        (await env.writeFile('/note.txt', 'tiny')).getOrThrow();
        await env.flush();

        final stored = await store.loadAll();
        // Vector 1/4: the previously-saved session was never dropped or
        // rewritten by the failing saves.
        expect(stored[aaaKey], savedA);
        expect(_envelopeFilePaths(stored), contains('/note.txt'));
        // Session-local damage: only the oversized record is missing.
        expect(
          stored,
          isNot(
            contains(
              '${PersistentWebExecutionEnv.sessionKeyPrefix}/sessions/big.jsonl',
            ),
          ),
        );

        // After a restart: everything that fit survived.
        final reincarnated = await _restoreEnv(store);
        expect(
          (await reincarnated.readTextFile('/sessions/aaa.jsonl'))
              .getOrThrow(),
          'A' * 400,
        );
        expect(
          (await reincarnated.readTextFile('/note.txt')).getOrThrow(),
          'tiny',
        );
        expect(
          (await reincarnated.exists('/sessions/big.jsonl')).getOrThrow(),
          isFalse,
        );
        env.dispose();
      },
    );
  });
}

/// Simulates an install racing the persist pass (issue #201): the
/// `widget.js` write lands while the pass is reading the app directory —
/// the classic torn-snapshot interleave (manifest captured, widget.js lost).
///
/// Forwards everything to an inner [MemoryExecutionEnv] (the core envs are
/// `final` and cannot be subclassed). The interleave fires at whichever
/// seam the implementation under test reads through: the pre-fix async
/// walk ([listDir], torn snapshot — see the RED commit) or the fixed
/// synchronous [exportSnapshot] (no yield points, so the "concurrent"
/// write can only land entirely before or entirely after the copy — the
/// exported tree is never torn).
final class _MidInstallEnv implements ExecutionEnv, FsSnapshotExporter {
  _MidInstallEnv();

  static const widgetJs = 'widget-code';

  final MemoryExecutionEnv _inner = MemoryExecutionEnv(cwd: '/');
  bool _widgetPending = true;

  void _landWidgetJs() {
    if (!_widgetPending) return;
    _widgetPending = false;
    // Direct write on the delegate (like the install loop landing mid-pass).
    _inner.writeFile('/apps/calculator/widget.js', widgetJs);
  }

  // Interleave point of the OLD asynchronous walk (listDir + readBinaryFile
  // per entry, event-loop yields between every step).
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final result = await _inner.listDir(path);
    if (path == '/apps/calculator') _landWidgetJs();
    return result;
  }

  // Interleave point of the NEW atomic export: the write lands fully BEFORE
  // the synchronous copy starts — a sync pass can only observe the tree on
  // one side of a concurrent write, never straddle it.
  @override
  MemoryFsSnapshot exportSnapshot() {
    _landWidgetJs();
    return _inner.exportSnapshot();
  }

  @override
  String get cwd => _inner.cwd;
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _inner.exec(command, options: options);
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);
  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);
  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);
  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _inner.writeFile(path, content);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _inner.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _inner.appendFile(path, content);
  @override
  Future<Result<void, FileError>> createDir(String path, {bool recursive = true}) =>
      _inner.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);
}

/// The pre-fix `_snapshot` implementation (async `listDir`/`readBinaryFile`
/// walk), kept as the parity reference for UT-parity.
Future<String> _legacyWalkSnapshot(ExecutionEnv env) async {
  final dirs = <String>[];
  final files = <Map<String, String>>[];
  Future<void> walk(String dir) async {
    final entries = (await env.listDir(dir)).valueOrNull;
    if (entries == null) return;
    for (final entry in entries) {
      if (entry.kind == FileKind.directory) {
        dirs.add(entry.path);
        await walk(entry.path);
      } else {
        final bytes = (await env.readBinaryFile(entry.path)).valueOrNull;
        if (bytes != null) {
          files.add({'path': entry.path, 'data': base64Encode(bytes)});
        }
      }
    }
  }

  await walk(env.cwd);
  return jsonEncode({
    'version': PersistentWebExecutionEnv.snapshotVersion,
    'dirs': dirs,
    'files': files,
  });
}

final class _ThrowingLoadStore implements FsRecordStore {
  @override
  Future<Map<String, String>> loadAll() => throw StateError('storage blocked');

  @override
  Future<void> save(String key, String value) async {}

  @override
  Future<void> remove(List<String> keys) async {}
}

/// Normalizes a snapshot JSON string (dirs sorted, files sorted by path)
/// so the merged persisted view and the legacy async walk can be compared
/// independent of traversal order.
String _canonical(String snapshotJson) {
  final decoded = jsonDecode(snapshotJson) as Map<String, dynamic>;
  final dirs = [for (final d in decoded['dirs'] as List) d as String]
    ..sort();
  final files = [
    for (final f in decoded['files'] as List) f as Map<String, dynamic>,
  ]..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
  return jsonEncode({
    'version': decoded['version'],
    'dirs': dirs,
    'files': files,
  });
}

/// Reassembles the full-tree snapshot from the stored records: the
/// envelope (non-session files) plus one record per session file
/// (issue #237).
Future<String> _mergedStoredSnapshot(InMemoryFsRecordStore store) async {
  final all = await store.loadAll();
  final envelope =
      jsonDecode(all[PersistentWebExecutionEnv.storageKey]!)
          as Map<String, dynamic>;
  final files = [...envelope['files'] as List];
  for (final entry in all.entries) {
    if (!entry.key.startsWith(PersistentWebExecutionEnv.sessionKeyPrefix)) {
      continue;
    }
    files.add({
      'path': entry.key.substring(
        PersistentWebExecutionEnv.sessionKeyPrefix.length,
      ),
      'data': entry.value,
    });
  }
  return jsonEncode({
    'version': envelope['version'],
    'dirs': envelope['dirs'],
    'files': files,
  });
}

/// Drains the microtask queue plus a few macrotask turns so fire-and-forget
/// persists (eager session saves, no fake timers involved) can settle
/// WITHOUT calling flush — flush would mask the loss vector being pinned.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

String _b64(String text) => base64Encode(utf8.encode(text));

/// The v1 (pre-#237) snapshot envelope: sessions inline, whole tree under
/// one record — the shape existing users have stored in IndexedDB.
String _v1Envelope({
  Map<String, String> files = const {},
  List<String> dirs = const [],
}) => jsonEncode({
  'version': 1,
  'dirs': dirs,
  'files': [
    for (final e in files.entries)
      {'path': e.key, 'data': _b64(e.value)},
  ],
});

Map<String, dynamic> _envelopeOf(Map<String, String> stored) =>
    jsonDecode(stored[PersistentWebExecutionEnv.storageKey]!)
        as Map<String, dynamic>;

List<String> _envelopeFilePaths(Map<String, String> stored) => [
  for (final f in _envelopeOf(stored)['files'] as List)
    (f as Map)['path'] as String,
];

/// An [FsRecordStore] wrapper that records which keys a save actually
/// CHANGED (like FakeChrome's onChanged in the #236 pins): writing a
/// record whose value is already stored is not a change.
final class _RecordingStore implements FsRecordStore {
  _RecordingStore(this._inner);

  final InMemoryFsRecordStore _inner;
  final Set<String> changedKeys = {};

  @override
  Future<Map<String, String>> loadAll() => _inner.loadAll();

  @override
  Future<void> save(String key, String value) async {
    final before = await _inner.loadAll();
    await _inner.save(key, value);
    if (before[key] != value) changedKeys.add(key);
  }

  @override
  Future<void> remove(List<String> keys) async {
    final before = await _inner.loadAll();
    await _inner.remove(keys);
    for (final key in keys) {
      if (before.containsKey(key)) changedKeys.add(key);
    }
  }
}
