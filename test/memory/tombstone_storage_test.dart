@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/memory/execution_env_kb_storage.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

/// UT-1 + AC2 for gh-1032: the project-scope storage adapter adopts the
/// flutter_agent_memory 0.2.3 tombstone capability — deletions rewrite the
/// entity file in place (conflict-free in git) instead of unlinking it, and
/// a tombstone file written by ANY tool on the shared store reads as absent.
void main() {
  group('ExecutionEnvKbStorage tombstones (flutter_agent_memory 0.2.3)', () {
    late MemoryExecutionEnv env;
    late ExecutionEnvKbStorage storage;

    setUp(() async {
      env = MemoryExecutionEnv(cwd: '/work');
      storage = ExecutionEnvKbStorage(env, '/.fah/memory');
      await storage.initialize();
      await env.writeFile(
        '/.fah/memory/note/n_0001_dead.md',
        '---\nid: n_0001_dead\n---\n# Entity: n_0001_dead\nlive note\n',
      );
      await env.writeFile(
        '/.fah/memory/note/n_0002_beef.md',
        '---\nid: n_0002_beef\n---\n# Entity: n_0002_beef\nkept note\n',
      );
    });

    test('the adapter is tombstone-capable (0.2.3)', () {
      expect(storage, isA<KbTombstoneCapable>());
    });

    test(
      'tombstoneEntity rewrites the file in place with the marker (AC1 seam)',
      () async {
        await storage.tombstoneEntity('note', 'n_0001_dead');
        final path = '/.fah/memory/note/n_0001_dead.md';
        // The file STAYS on disk — physical deletion is what produced the
        // git delete/modify conflicts this migration removes.
        expect((await env.exists(path)).valueOrNull, isTrue);
        final content = (await env.readTextFile(path)).valueOrNull!;
        expect(content, contains(FileKbStorage.tombstoneMarker));
      },
    );

    test('readEntity reports a tombstoned entity as absent', () async {
      await storage.tombstoneEntity('note', 'n_0001_dead');
      expect(await storage.readEntity('note', 'n_0001_dead'), isNull);
      // Unrelated entities keep reading normally.
      expect(await storage.readEntity('note', 'n_0002_beef'), isNotNull);
    });

    test(
      'readEntity filters a hand-written tombstone of foreign shape',
      () async {
        // Marker position/format is the library's contract; any file carrying
        // the marker line must read as absent.
        await env.writeFile(
          '/.fah/memory/note/n_0009_ff.md',
          '---\nid: n_0009_ff\ntombstone: true\n---\nbody\n',
        );
        expect(await storage.readEntity('note', 'n_0009_ff'), isNull);
      },
    );

    test(
      'listEntityIds still yields tombstoned ids (no silent id reuse)',
      () async {
        await storage.tombstoneEntity('note', 'n_0001_dead');
        expect(
          await storage.listEntityIds('note'),
          containsAll(['n_0001_dead', 'n_0002_beef']),
        );
      },
    );

    test(
      'purgeTombstones removes only tombstones and returns sorted ids',
      () async {
        await storage.tombstoneEntity('note', 'n_0002_beef');
        await storage.tombstoneEntity('answer', 'a_0001_ab');
        // Live note stays.
        final removed = await storage.purgeTombstones();
        expect(removed, ['a_0001_ab', 'n_0002_beef']);
        expect(
          (await env.exists('/.fah/memory/note/n_0002_beef.md')).valueOrNull,
          isFalse,
        );
        expect(
          (await env.exists('/.fah/memory/answer/a_0001_ab.md')).valueOrNull,
          isFalse,
        );
        expect(
          (await env.exists('/.fah/memory/note/n_0001_dead.md')).valueOrNull,
          isTrue,
        );
        // Idempotent: nothing left to purge.
        expect(await storage.purgeTombstones(), isEmpty);
      },
    );
  });

  group('cross-tool tombstone consistency (AC2)', () {
    late Directory temp;
    late ExecutionEnvKbStorage harnessStorage;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('fah_tombstone_ac2_');
      harnessStorage = ExecutionEnvKbStorage(
        LocalExecutionEnv(cwd: temp.path),
        temp.path,
      );
    });

    tearDown(() async {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('a store tombstoned by the library FileKbStorage reads as absent '
        'through the harness adapter', () async {
      const id = 'n_0001_cafe';
      await harnessStorage.writeEntity(
        'note',
        id,
        '---\nid: $id\n---\n# Entity: $id\nshared note\n',
      );
      expect(await harnessStorage.readEntity('note', id), isNotNull);

      // A CLI agent (or another tool) deletes through the library's file
      // backend: the tombstone content is what FileKbStorage writes (its
      // public static — simulated fixture on the shared store).
      await harnessStorage.writeEntity(
        'note',
        id,
        FileKbStorage.tombstoneContentFor(id, '2026-01-01T00:00:00.000Z'),
      );
      expect(await harnessStorage.readEntity('note', id), isNull);
      // And the raw file is still there (tombstone, not unlink).
      expect(
        FileKbStorage.isTombstoneContent(
          File('${temp.path}/note/$id.md').readAsStringSync(),
        ),
        isTrue,
      );
    });

    test('a harness tombstone carries the library marker format', () async {
      await harnessStorage.tombstoneEntity('note', 'n_0002_d00d');
      expect(
        FileKbStorage.isTombstoneContent(
          File('${temp.path}/note/n_0002_d00d.md').readAsStringSync(),
        ),
        isTrue,
      );
    });
  });
}
