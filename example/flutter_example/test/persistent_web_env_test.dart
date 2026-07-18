// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_example/fs_persistence.dart';
import 'package:flutter_agent_example/memory_shell.dart';
import 'package:flutter_agent_example/persistent_web_env.dart';
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

    test('a store that throws on load starts clean', () async {
      final store = _ThrowingLoadStore();
      final env = await _restoreEnv(store);
      expect((await env.listDir('/')).getOrThrow(), isEmpty);
      (await env.writeFile('/still.txt', 'works')).getOrThrow();
      expect((await env.readTextFile('/still.txt')).getOrThrow(), 'works');
    });
  });
}

final class _ThrowingLoadStore implements FsSnapshotStore {
  @override
  Future<String?> load() => throw StateError('storage blocked');

  @override
  Future<void> save(String snapshot) async {}
}
