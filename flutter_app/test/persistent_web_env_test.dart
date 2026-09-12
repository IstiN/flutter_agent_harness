// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
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
  FsSnapshotStore store, {
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

String b64(String text) => base64Encode(utf8.encode(text));

/// A stored envelope record in the CURRENT schema version.
Map<String, Object> envelope({
  int? version,
  List<String> dirs = const [],
  List<Map<String, String>> files = const [],
}) => {
  'version': version ?? PersistentWebExecutionEnv.snapshotVersion,
  'dirs': dirs,
  'files': files,
};

Map<String, dynamic> envelopeOf(
  Map<String, String> records,
  PersistentWebExecutionEnv env,
) => jsonDecode(records[PersistentWebExecutionEnv.storageKey]!)
    as Map<String, dynamic>;

List<String> envelopeFilePaths(
  Map<String, String> records,
  PersistentWebExecutionEnv env,
) => [
  for (final f in envelopeOf(records, env)['files'] as List)
    (f as Map)['path'] as String,
];

/// The session record key for [path].
String sessionKeyOf(String path) =>
    '${PersistentWebExecutionEnv.sessionKeyPrefix}$path';

void main() {
  group('PersistentWebExecutionEnv', () {
    test(
      'writes through the wrapper are readable through the same instance',
      () async {
        final env = await _restoreEnv(InMemoryFsSnapshotStore());
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
        final store = InMemoryFsSnapshotStore();
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
      final store = InMemoryFsSnapshotStore();
      final env = await _restoreEnv(store);
      (await env.writeFile('/gone.txt', 'x')).getOrThrow();
      await env.flush();
      (await env.remove('/gone.txt')).getOrThrow();
      await env.flush();

      final restored = await _restoreEnv(store);
      expect((await restored.exists('/gone.txt')).getOrThrow(), isFalse);
    });

    test('the debounced save fires without an explicit flush', () async {
      final store = InMemoryFsSnapshotStore();
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
      final store = InMemoryFsSnapshotStore();
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

    test(
      'IT-atomic-snapshot: a persist pass racing an install never '
      'persists a torn tree (issue #201)',
      () async {
        final store = InMemoryFsSnapshotStore();
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
      'UT-parity: the atomic export covers exactly the quiescent tree '
      '(issue #201, split across envelope + session records)',
      () async {
        final store = InMemoryFsSnapshotStore();
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

        // The stored envelope must NOT carry the session bytes (quota
        // isolation, issue #237) — those ride their own records.
        expect(
          envelopeFilePaths(store.records, env).where(
            (p) => p.startsWith('/sessions/'),
          ),
          isEmpty,
        );
        expect(store.records[sessionKeyOf('/sessions/s1.jsonl')], isNotNull);

        // Union of the envelope + session records == a quiescent async walk
        // over the same tree (the consistency contract of #201, unchanged
        // by the #237 split).
        final reloaded = await _restoreEnv(store);
        final legacy = await _legacyWalk(reloaded);
        final stored = <String, Uint8List>{
          for (final path in envelopeFilePaths(store.records, env))
            path: base64Decode(
              (envelopeOf(store.records, env)['files'] as List)
                  .map((f) => f as Map)
                  .firstWhere((f) => f['path'] == path)['data'] as String,
            ),
            for (final entry in store.records.entries)
              if (entry.key
                  .startsWith(PersistentWebExecutionEnv.sessionKeyPrefix))
                entry.key.substring(
                  PersistentWebExecutionEnv.sessionKeyPrefix.length,
                ): base64Decode(entry.value),
        };
        expect(stored.keys.toSet(), legacy.files.keys.toSet());
        for (final path in legacy.files.keys) {
          expect(stored[path], legacy.files[path], reason: path);
        }
        expect(
          (envelopeOf(store.records, env)['dirs'] as List).toSet(),
          legacy.dirs.toSet(),
        );
        reloaded.dispose();
      },
    );

    test(
      'IT-unload-flush: a mutation followed immediately by page unload '
      'persists (issue #201)',
      () async {
        final store = InMemoryFsSnapshotStore();
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

    group('issue #237 persistence vectors (per-session records)', () {
      test(
        'vector 2 — an unreadable envelope is backed up BEFORE any save '
        'overwrites it, then recovery proceeds',
        () async {
          final store = InMemoryFsSnapshotStore()
            ..seed({PersistentWebExecutionEnv.storageKey: '{not json at all'});
          final env = await _restoreEnv(store);
          expect((await env.listDir('/')).getOrThrow(), isEmpty);

          // Persistence keeps working afterwards and replaces the bad
          // envelope — but the raw bytes survive under the backup key.
          (await env.writeFile('/after.txt', 'ok')).getOrThrow();
          await env.flush();
          expect(
            store.records[PersistentWebExecutionEnv.backupKey],
            '{not json at all',
          );
          expect(envelopeOf(store.records, env)['version'], isNot(1));
          final restored = await _restoreEnv(store);
          expect(
            (await restored.readTextFile('/after.txt')).getOrThrow(),
            'ok',
          );
        },
      );

      test(
        'vector 2 — a newer-version envelope is backed up, and session '
        'records restore regardless of the envelope',
        () async {
          const sessionBody = '{"role":"user"}\n';
          final newer = jsonEncode(
            envelope(
              version: 999,
              files: [
                {'path': '/future.txt', 'data': b64('from the future')},
              ],
            ),
          );
          final store = InMemoryFsSnapshotStore()
            ..seed({
              PersistentWebExecutionEnv.storageKey: newer,
              sessionKeyOf('/sessions/s.jsonl'): b64(sessionBody),
            });
          final env = await _restoreEnv(store);
          // The unreadable envelope is NOT replayed...
          expect((await env.exists('/future.txt')).getOrThrow(), isFalse);
          // ...but session records are version-independent keys.
          expect(
            (await env.readTextFile('/sessions/s.jsonl')).getOrThrow(),
            sessionBody,
          );

          // A save must never clobber the backup.
          (await env.writeFile('/now.txt', 'x')).getOrThrow();
          await env.flush();
          expect(store.records[PersistentWebExecutionEnv.backupKey], newer);
        },
      );

      test(
        'vector 2 — a v1 envelope MIGRATES: sessions re-home into records, '
        'nothing is wiped',
        () async {
          const sessionBody = '{"v":1}\n';
          final v1 = jsonEncode(
            envelope(
              version: 1,
              dirs: ['/notes', '/sessions', '/sessions/--work--'],
              files: [
                {'path': '/notes/keep.txt', 'data': b64('keep')},
                {
                  'path': '/sessions/--work--/s1.jsonl',
                  'data': b64(sessionBody),
                },
              ],
            ),
          );
          final store = InMemoryFsSnapshotStore()
            ..seed({PersistentWebExecutionEnv.storageKey: v1});
          final env = await _restoreEnv(store);
          // The whole v1 tree replays.
          expect((await env.readTextFile('/notes/keep.txt')).getOrThrow(), 'keep');
          expect(
            (await env.readTextFile('/sessions/--work--/s1.jsonl'))
                .getOrThrow(),
            sessionBody,
          );

          // The next save re-homes the session into its own record and the
          // envelope forward — no data lost in the move.
          await env.flush();
          expect(envelopeOf(store.records, env)['version'], 2);
          expect(
            envelopeFilePaths(
              store.records,
              env,
            ).where((p) => p.startsWith('/sessions/')),
            isEmpty,
          );
          expect(
            store.records[sessionKeyOf('/sessions/--work--/s1.jsonl')],
            b64(sessionBody),
          );

          // And the migrated layout round-trips.
          final restored = await _restoreEnv(store);
          expect(
            (await restored.readTextFile('/sessions/--work--/s1.jsonl'))
                .getOrThrow(),
            sessionBody,
          );
        },
      );

      test(
        'vector 4 — session files ride per-file records OUTSIDE the '
        'envelope, so one oversized write cannot sink the rest',
        () async {
          final store = InMemoryFsSnapshotStore();
          final env = await _restoreEnv(store);
          (await env.writeFile('/notes/a.txt', 'a')).getOrThrow();
          (await env.writeFile(
            '/sessions/--w--/s1.jsonl',
            '{"one"}\n',
          )).getOrThrow();
          (await env.writeFile(
            '/sessions/--w--/s2.jsonl',
            '{"two"}\n',
          )).getOrThrow();
          await env.flush();

          expect(envelopeFilePaths(store.records, env), ['/notes/a.txt']);
          expect(
            store.records[sessionKeyOf('/sessions/--w--/s1.jsonl')],
            b64('{"one"}\n'),
          );
          expect(
            store.records[sessionKeyOf('/sessions/--w--/s2.jsonl')],
            b64('{"two"}\n'),
          );
        },
      );

      test(
        'vector 1 — deleting one session evicts ONLY its record; the rest '
        'stay byte-identical',
        () async {
          final store = InMemoryFsSnapshotStore();
          final env = await _restoreEnv(store);
          (await env.writeFile(
            '/sessions/--w--/s1.jsonl',
            '{"one"}\n',
          )).getOrThrow();
          (await env.writeFile(
            '/sessions/--w--/s2.jsonl',
            '{"two"}\n',
          )).getOrThrow();
          await env.flush();
          expect(
            store.records.keys
                .where((k) => k.startsWith(PersistentWebExecutionEnv.sessionKeyPrefix))
                .length,
            2,
          );
          final s2Before =
              store.records[sessionKeyOf('/sessions/--w--/s2.jsonl')];

          (await env.remove('/sessions/--w--/s1.jsonl')).getOrThrow();
          await env.flush();

          expect(
            store.records.keys
                .where((k) => k.startsWith(PersistentWebExecutionEnv.sessionKeyPrefix))
                .toList(),
            [sessionKeyOf('/sessions/--w--/s2.jsonl')],
          );
          expect(
            store.records[sessionKeyOf('/sessions/--w--/s2.jsonl')],
            s2Before,
          );
          expect(
            (await env.readTextFile('/sessions/--w--/s2.jsonl')).getOrThrow(),
            '{"two"}\n',
          );
        },
      );

      test(
        'vector 1 — repeated saves never drop live session keys',
        () async {
          final store = InMemoryFsSnapshotStore();
          final env = await _restoreEnv(store);
          (await env.writeFile(
            '/sessions/--w--/s1.jsonl',
            '{"live"}\n',
          )).getOrThrow();
          await env.flush();
          final live = store.records[sessionKeyOf('/sessions/--w--/s1.jsonl')];
          expect(live, isNotNull);

          for (var i = 0; i < 3; i++) {
            (await env.writeFile('/notes/n$i.txt', 'x')).getOrThrow();
            await env.flush();
            expect(
              store.records[sessionKeyOf('/sessions/--w--/s1.jsonl')],
              live,
            );
          }
        },
      );


      test(
        'vector 4 — an over-quota session fails ALONE: unrelated saves keep '
        'working and previously-saved sessions stay byte-identical',
        () async {
          final store = _QuotaStore(maxRecordBytes: 1000);
          final env = await _restoreEnv(store);
          (await env.writeFile(
            '/sessions/--w--/small.jsonl',
            '{"ok"}\n',
          )).getOrThrow();
          await env.flush();
          final smallBefore =
              store.records[sessionKeyOf('/sessions/--w--/small.jsonl')];
          expect(smallBefore, isNotNull);

          // A huge session lands alongside an ordinary file change.
          (await env.writeFile(
            '/sessions/--w--/huge.jsonl',
            'x' * 5000,
          )).getOrThrow();
          (await env.writeFile('/notes/regular.txt', 'still saves')).getOrThrow();
          await env.flush();

          // The envelope was still rewritten with the ordinary change and
          // never carries session bytes.
          expect(
            envelopeFilePaths(store.records, env),
            contains('/notes/regular.txt'),
          );
          expect(
            envelopeFilePaths(store.records, env).where(
              (p) => p.startsWith('/sessions/'),
            ),
            isEmpty,
          );
          // The small session record is untouched.
          expect(
            store.records[sessionKeyOf('/sessions/--w--/small.jsonl')],
            smallBefore,
          );
          // The huge one never landed, and the failure stays visible for
          // the next mutation or flush to retry.
          expect(
            store.records
                .containsKey(sessionKeyOf('/sessions/--w--/huge.jsonl')),
            isFalse,
          );
          expect(env.hasPendingChanges, isTrue);
          expect(store.failedSaves, greaterThan(0));
        },
      );

      test(
        'a torn session record is skipped alone; boot continues clean',
        () async {
          final store = InMemoryFsSnapshotStore()
            ..seed({
              PersistentWebExecutionEnv.storageKey: jsonEncode(
                envelope(
                  files: [
                    {'path': '/notes/a.txt', 'data': b64('a')},
                  ],
                ),
              ),
              sessionKeyOf('/sessions/x/broken.jsonl'): '!!! not base64 !!!',
            });
          final env = await _restoreEnv(store);
          expect((await env.readTextFile('/notes/a.txt')).getOrThrow(), 'a');
          expect(
            (await env.exists('/sessions/x/broken.jsonl')).getOrThrow(),
            isFalse,
          );
          (await env.writeFile('/after.txt', 'ok')).getOrThrow();
          expect((await env.readTextFile('/after.txt')).getOrThrow(), 'ok');
        },
      );

      test(
        'a foreign session-ish key is ignored (no path injection)',
        () async {
          final store = InMemoryFsSnapshotStore()
            ..seed({
              PersistentWebExecutionEnv.storageKey: jsonEncode(envelope()),
              '${PersistentWebExecutionEnv.sessionKeyPrefix}/evil.jsonl': b64(
                'nope',
              ),
            });
          final env = await _restoreEnv(store);
          expect((await env.exists('/evil.jsonl')).getOrThrow(), isFalse);
          // And it is not resurrected by a save either.
          (await env.writeFile('/x.txt', 'x')).getOrThrow();
          await env.flush();
          expect((await env.exists('/evil.jsonl')).getOrThrow(), isFalse);
        },
      );

      test(
        'IT — the #201 unload-flush path carries session data too',
        () async {
          final store = InMemoryFsSnapshotStore();
          final env = await _restoreEnv(
            store,
            persistDelay: const Duration(hours: 1),
          );
          (await env.writeFile(
            '/sessions/--w--/live.jsonl',
            '{"tail":true}\n',
          )).getOrThrow();
          expect(env.hasPendingChanges, isTrue);

          await env.onPageUnload();
          expect(env.hasPendingChanges, isFalse);
          env.dispose();

          final reloaded = await _restoreEnv(store);
          expect(
            (await reloaded.readTextFile('/sessions/--w--/live.jsonl'))
                .getOrThrow(),
            '{"tail":true}\n',
          );
          reloaded.dispose();
        },
      );

      test('flush awaits an in-flight save before returning', () async {
        final store = _GatedStore();
        final env = await _restoreEnv(
          store,
          persistDelay: const Duration(milliseconds: 20),
        );
        store.gateNext();
        (await env.writeFile('/a.txt', 'a')).getOrThrow();

        // Let the debounce fire into the gated store: a save is in flight.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(store.saveCalls, 1);
        expect(store.landedSaves, 0);

        // _dirty is already cleared by the in-flight loop, but flush must
        // still wait for the storage write to land.
        var flushDone = false;
        unawaited(env.flush().then((_) => flushDone = true));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(flushDone, isFalse, reason: 'flush returned before the '
            'in-flight save landed');

        store.release();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(flushDone, isTrue);
        expect(store.landedSaves, 1);
        env.dispose();
      });
    });
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

/// The pre-fix snapshot encoding (async `listDir`/`readBinaryFile` walk),
/// kept as the parity reference for UT-parity.
Future<({List<String> dirs, Map<String, Uint8List> files})> _legacyWalk(
  ExecutionEnv env,
) async {
  final dirs = <String>[];
  final files = <String, Uint8List>{};
  Future<void> walk(String dir) async {
    final entries = (await env.listDir(dir)).valueOrNull;
    if (entries == null) return;
    for (final entry in entries) {
      if (entry.kind == FileKind.directory) {
        dirs.add(entry.path);
        await walk(entry.path);
      } else {
        final bytes = (await env.readBinaryFile(entry.path)).valueOrNull;
        if (bytes != null) files[entry.path] = bytes;
      }
    }
  }

  await walk(env.cwd);
  return (dirs: dirs, files: files);
}

final class _ThrowingLoadStore implements FsSnapshotStore {
  @override
  Future<Map<String, String>> load() => throw StateError('storage blocked');

  @override
  Future<void> save(Map<String, String> records) async {}

  @override
  Future<void> remove(Iterable<String> keys) async {}
}

/// A storage with a per-record byte ceiling: a record over the quota fails
/// its save ALONE (the closest VM model of IndexedDB's quota behavior).
final class _QuotaStore implements FsSnapshotStore {
  _QuotaStore({required this.maxRecordBytes});

  final int maxRecordBytes;

  /// Test observability: the records as last written.
  Map<String, String> get records => Map.unmodifiable(_records);
  final Map<String, String> _records = {};

  /// How many saves hit the quota (test observability).
  int failedSaves = 0;

  @override
  Future<Map<String, String>> load() async => Map.of(_records);

  @override
  Future<void> save(Map<String, String> records) async {
    for (final record in records.entries) {
      if (record.value.length > maxRecordBytes) {
        failedSaves++;
        throw StateError('quota exceeded for ${record.key}');
      }
    }
    _records.addAll(records);
  }

  @override
  Future<void> remove(Iterable<String> keys) async {
    for (final key in keys) {
      _records.remove(key);
    }
  }
}

/// A storage whose next save blocks until [release] — models an IndexedDB
/// transaction that has not committed yet.
final class _GatedStore implements FsSnapshotStore {
  final Map<String, String> _records = {};
  Completer<void>? _gate;

  /// Saves started (test observability).
  int saveCalls = 0;

  /// Saves that actually landed in storage.
  int landedSaves = 0;

  /// Gates the NEXT save call.
  void gateNext() => _gate = Completer<void>();

  /// Lets the gated save land.
  void release() => _gate?.complete();

  @override
  Future<Map<String, String>> load() async => Map.of(_records);

  @override
  Future<void> save(Map<String, String> records) async {
    saveCalls++;
    final gate = _gate;
    if (gate != null) {
      _gate = null;
      await gate.future;
    }
    _records.addAll(records);
    landedSaves++;
  }

  @override
  Future<void> remove(Iterable<String> keys) async {
    for (final key in keys) {
      _records.remove(key);
    }
  }
}
