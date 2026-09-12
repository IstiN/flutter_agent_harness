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

    test('a corrupt snapshot restores to a clean FS and recovers', () async {
      final store = InMemoryFsSnapshotStore()..seed('{not json at all');
      final env = await _restoreEnv(store);
      expect((await env.listDir('/')).getOrThrow(), isEmpty);

      // Persistence keeps working afterwards and overwrites the bad data.
      (await env.writeFile('/after.txt', 'ok')).getOrThrow();
      await env.flush();
      final snapshot = jsonDecode(await store.load() ?? '') as Map;
      expect(snapshot['version'], PersistentWebExecutionEnv.snapshotVersion);
      final restored = await _restoreEnv(store);
      expect((await restored.readTextFile('/after.txt')).getOrThrow(), 'ok');
    });

    test('a snapshot with an unknown version is ignored', () async {
      final store = InMemoryFsSnapshotStore()
        ..seed(
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
        final store = InMemoryFsSnapshotStore()
          ..seed(
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
      'UT-parity: the atomic export is byte-identical to a quiescent '
      'async walk (issue #201)',
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
        final atomic = await store.load();
        expect(atomic, isNotNull);

        // Reference: the pre-fix async-walk encoding over the now-quiescent
        // tree. Byte-identical output proves the atomic path changed the
        // CONSISTENCY, not the FORMAT, of snapshots (AC5).
        final reloaded = await _restoreEnv(store);
        expect(await _legacyWalkSnapshot(reloaded), atomic);
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

final class _ThrowingLoadStore implements FsSnapshotStore {
  @override
  Future<String?> load() => throw StateError('storage blocked');

  @override
  Future<void> save(String snapshot) async {}
}
