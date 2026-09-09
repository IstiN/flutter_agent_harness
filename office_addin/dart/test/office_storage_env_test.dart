// OfficeStorageEnv (office_storage_env.dart): snapshot round trip, corrupt
// snapshot → clean fs, version mismatch ignored, debounced persist via
// flush, save failures swallowed, and the shell-less exec note. Issue #89.
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:test/test.dart';

import '../src/office_storage_env.dart';

void main() {
  final store = <String, String>{};
  String? read(String key) => store[key];
  void write(String key, String value) => store[key] = value;

  group('snapshot round trip', () {
    test('mutations survive a fresh restore', () async {
      store.clear();
      final env = OfficeStorageEnv(read: read, write: write);
      await env.createDir('/notes');
      await env.writeFile('/notes/a.txt', 'hello');
      await env.writeFile('/root.bin', 'bytes');
      await env.flush();
      expect(store, contains('faOfficeFs'));

      final restored = OfficeStorageEnv(read: read, write: write);
      expect((await restored.exists('/notes/a.txt')).valueOrNull, isTrue);
      expect(
        (await restored.readTextFile('/notes/a.txt')).valueOrNull,
        'hello',
      );
      expect((await restored.readBinaryFile('/root.bin')).valueOrNull, [
        0x62,
        0x79,
        0x74,
        0x65,
        0x73,
      ]);
      expect(
        (await restored.listDir('/')).valueOrNull?.map((e) => e.path),
        containsAll(['/notes', '/root.bin']),
      );
      expect(
        (await restored.listDir('/notes')).valueOrNull?.map((e) => e.path),
        contains('/notes/a.txt'),
      );
      restored.dispose();
      env.dispose();
    });

    test(
      'debounced mutation only persists on flush (or after the window)',
      () async {
        store.clear();
        final env = OfficeStorageEnv(read: read, write: write);
        await env.writeFile('/x.txt', 'x');
        expect(store['faOfficeFs'], isNull, reason: 'debounce has not fired');
        await env.flush();
        expect(store['faOfficeFs'], isNotNull);
        env.dispose();
      },
    );
  });

  group('corrupt snapshot', () {
    test('malformed JSON yields a clean fs, never a crash', () async {
      store.clear();
      store['faOfficeFs'] = '{"version": 1, "dirs": [not json';
      final env = OfficeStorageEnv(read: read, write: write);
      expect((await env.exists('/notes')).valueOrNull, isFalse);
      expect((await env.listDir('/')).isOk, isTrue);
      env.dispose();
    });

    test('wrong schema shape yields a clean fs', () async {
      store.clear();
      store['faOfficeFs'] = '{"version": 1, "dirs": "not-a-list", "files": 42}';
      final env = OfficeStorageEnv(read: read, write: write);
      expect((await env.listDir('/')).isOk, isTrue);
      expect((await env.exists('/anything')).valueOrNull, isFalse);
      env.dispose();
    });

    test('different snapshot version is ignored', () async {
      store.clear();
      store['faOfficeFs'] = '{"version": 999, "dirs": ["/stale"], "files": []}';
      final env = OfficeStorageEnv(read: read, write: write);
      expect((await env.exists('/stale')).valueOrNull, isFalse);
      env.dispose();
    });

    test('a failing read closure yields a clean fs', () async {
      final env = OfficeStorageEnv(
        read: (key) => throw StateError('storage blocked'),
        write: write,
      );
      expect((await env.listDir('/')).isOk, isTrue);
      env.dispose();
    });
  });

  group('save failures', () {
    test('a throwing write closure never breaks the sandbox', () async {
      store.clear();
      var fail = true;
      final env = OfficeStorageEnv(
        read: read,
        write: (key, value) {
          if (fail) throw StateError('quota exceeded');
          store[key] = value;
        },
      );
      await env.writeFile('/a.txt', 'a');
      await env.flush(); // must complete despite the failure
      expect((await env.readTextFile('/a.txt')).valueOrNull, 'a');

      fail = false; // next mutation retries and succeeds
      await env.appendFile('/a.txt', 'b');
      await env.flush();
      expect((await env.readTextFile('/a.txt')).valueOrNull, 'ab');
      expect(store['faOfficeFs'], isNotNull);
      env.dispose();
    });
  });

  group('exec', () {
    test('answers the clean taskpane note, never a crash', () async {
      final env = OfficeStorageEnv(read: read, write: write);
      final result = await env.exec('ls -la');
      expect(result.isErr, isTrue);
      final error = result.errorOrNull!;
      expect(error.code, ExecutionErrorCode.shellUnavailable);
      expect(error.message, contains('Office taskpane'));
      env.dispose();
    });
  });
}
