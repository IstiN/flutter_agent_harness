// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/leftover_model_cleanup.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// An [ExecutionEnv] whose `remove` always fails (the read-only-volume
/// shape: delete errors must be recorded, never fatal). Everything else
/// forwards to the in-memory inner env; unimplemented members can never be
/// reached by the cleanup module (it only walks/removes).
final class _FailingRemoveEnv implements ExecutionEnv {
  _FailingRemoveEnv(this._inner);

  final ExecutionEnv _inner;

  @override
  String get cwd => _inner.cwd;

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    return Err(
      FileError(FileErrorCode.unknown, 'read-only volume', path: path),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The in-memory OPFS/web storage fake for the web cleanup path.
final class _FakeWebArtifactStore implements GemmaWebArtifactStore {
  _FakeWebArtifactStore(this._names);

  final List<GemmaArtifactEntry> _names;
  final List<String> removed = [];
  Object? throwOnRemove;

  @override
  Future<List<GemmaArtifactEntry>> listRoot() async => _names;

  @override
  Future<void> remove(String name, {bool directory = false}) async {
    if (throwOnRemove != null) {
      throw throwOnRemove!;
    }
    removed.add(name);
  }
}

void main() {
  group('cleanupGemmaLeftovers (IO walk)', () {
    test(
      'deletes .litertlm files and flutter_gemma dirs, keeps the rest',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeFile('${env.cwd}/gemma-4-E2B-it.litertlm', 'weights');
        await env.writeFile('${env.cwd}/keep-me.txt', 'user data');
        await env.writeFile(
          '${env.cwd}/nested/deeper/gemma-4-E4B-it.litertlm',
          'weights',
        );
        await env.writeFile('${env.cwd}/flutter_gemma/model.json', 'registry');
        await env.writeFile(
          '${env.cwd}/other/x.litertlm.bak',
          'not an artifact',
        );

        final report = await cleanupGemmaLeftovers(env);

        expect(
          report.deleted.map((p) => p.split('/').last),
          containsAll(['gemma-4-E2B-it.litertlm', 'gemma-4-E4B-it.litertlm']),
        );
        expect(
          (await env.exists('${env.cwd}/gemma-4-E2B-it.litertlm')).valueOrNull,
          isFalse,
        );
        expect(
          (await env.exists(
            '${env.cwd}/nested/deeper/gemma-4-E4B-it.litertlm',
          )).valueOrNull,
          isFalse,
        );
        // The plugin's storage dir is gone (its registry file with it).
        expect(
          (await env.exists('${env.cwd}/flutter_gemma/model.json')).valueOrNull,
          isFalse,
        );
        // User files untouched.
        expect(
          (await env.exists('${env.cwd}/keep-me.txt')).valueOrNull,
          isTrue,
        );
        // `.bak` is not a `.litertlm` suffix match.
        expect(
          (await env.exists('${env.cwd}/other/x.litertlm.bak')).valueOrNull,
          isTrue,
        );
      },
    );

    test('an empty sandbox cleans nothing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/chat/session.json', '{}');

      final report = await cleanupGemmaLeftovers(env);

      expect(report.isEmpty, isTrue);
      expect(report.deleted, isEmpty);
      expect(report.failed, isEmpty);
    });

    test(
      'a failing delete is recorded, not fatal — the walk continues',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeFile('${env.cwd}/a.litertlm', 'weights');
        await env.writeFile('${env.cwd}/sub/b.litertlm', 'weights');

        // A remove() that errors for everything: the report names both
        // artifacts under `failed` and the call still completes.
        final report = await cleanupGemmaLeftovers(_FailingRemoveEnv(env));

        expect(report.failed.length, 2);
        expect(report.deleted, isEmpty);
        // Non-artifact cleanup state is untouched either way.
        expect(report.isEmpty, isFalse);
      },
    );
  });

  group('cleanupGemmaLeftovers (mounted project env — gh-2004 review)', () {
    // The desktop boot env with a mounted project folder: cwd == '/project'
    // maps onto the user-selected HOST folder, while the app container
    // (where the flutter_gemma plugin actually stored) stays the delegate
    // env's cwd. The cleanup must walk ONLY the app-owned container —
    // the user's real project content must survive every boot.
    test(
      'a mounted user project survives; the app container is cleaned',
      () async {
        final container = MemoryExecutionEnv(cwd: '/container');
        final mount = ProjectMountEnv(container)..mountedRoot = '/host-project';

        // User's real project content under the mounted root — including
        // shapes the fragment/exact match would kill if the walk ever
        // reached the host folder (vendored checkout, notes folder, a
        // fixture bundle).
        await container.writeFile(
          '/host-project/third_party/flutter_gemma/lib/main.dart',
          'vendored checkout',
        );
        await container.writeFile(
          '/host-project/docs/flutter_gemma_notes/readme.md',
          'notes',
        );
        await container.writeFile('/host-project/sample.litertlm', 'fixture');
        // Plugin leftovers where the plugin actually stored: the app
        // container.
        await container.writeFile(
          '/container/flutter_gemma/model.json',
          'registry',
        );
        await container.writeFile(
          '/container/gemma-4-E2B-it.litertlm',
          'weights',
        );

        final report = await cleanupGemmaLeftovers(mount);

        // The plugin's storage inside the app container is gone.
        expect(
          (await container.exists(
            '/container/flutter_gemma/model.json',
          )).valueOrNull,
          isFalse,
        );
        expect(
          (await container.exists(
            '/container/gemma-4-E2B-it.litertlm',
          )).valueOrNull,
          isFalse,
        );
        expect(report.deleted, isNotEmpty);
        // Every deleted path lives inside the app container — nothing under
        // the mounted host folder was touched.
        for (final path in report.deleted) {
          expect(path, startsWith('/container/'));
        }
        // The user's project content survives, byte-for-byte present.
        expect(
          (await container.exists(
            '/host-project/third_party/flutter_gemma/lib/main.dart',
          )).valueOrNull,
          isTrue,
        );
        expect(
          (await container.exists(
            '/host-project/docs/flutter_gemma_notes/readme.md',
          )).valueOrNull,
          isTrue,
        );
        expect(
          (await container.exists('/host-project/sample.litertlm')).valueOrNull,
          isTrue,
        );
      },
    );

    test(
      'decorator wrappers (secrets/session vars) still find the container',
      () async {
        final container = MemoryExecutionEnv(cwd: '/container');
        final mount = ProjectMountEnv(container)..mountedRoot = '/host-project';
        final env = SecretsExecutionEnv(mount, {'API_KEY': 'k'});
        await container.writeFile('/host-project/keep.txt', 'user data');
        await container.writeFile('/container/x.litertlm', 'weights');

        await cleanupGemmaLeftovers(env);

        expect(
          (await container.exists('/container/x.litertlm')).valueOrNull,
          isFalse,
        );
        expect(
          (await container.exists('/host-project/keep.txt')).valueOrNull,
          isTrue,
        );
      },
    );

    test('an unresolvable /project cwd is never walked', () async {
      // Pathological shape: an env whose app-owned cwd still IS the mount
      // segment (unwrapping hit an unknown decorator). The cleanup must
      // refuse to walk rather than touch anything — a no-op report.
      final env = MemoryExecutionEnv(cwd: '/project');
      await env.writeFile('/project/user-data.txt', 'irreplaceable');

      final report = await cleanupGemmaLeftovers(env);

      expect(report.isEmpty, isTrue);
      expect((await env.exists('/project/user-data.txt')).valueOrNull, isTrue);
    });

    test('only the plugin\'s exact storage dir name matches', () async {
      // Inside the app container a dir merely CONTAINING the fragment is
      // not the plugin's storage — `flutter_gemma` was the exact name the
      // plugin created; anything else (notes, forks) must survive.
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/flutter_gemma/model.json', 'registry');
      await env.writeFile('${env.cwd}/flutter_gemma_notes/readme.md', 'notes');
      await env.writeFile(
        '${env.cwd}/third_party/flutter_gemma/model.json',
        'fork',
      );

      await cleanupGemmaLeftovers(env);

      expect(
        (await env.exists('${env.cwd}/flutter_gemma/model.json')).valueOrNull,
        isFalse,
      );
      expect(
        (await env.exists(
          '${env.cwd}/flutter_gemma_notes/readme.md',
        )).valueOrNull,
        isTrue,
      );
      expect(
        (await env.exists(
          '${env.cwd}/third_party/flutter_gemma/model.json',
        )).valueOrNull,
        isTrue,
      );
    });
  });

  group('cleanupGemmaLeftovers (web store)', () {
    test('deletes root .litertlm entries and flutter_gemma dirs', () async {
      final store = _FakeWebArtifactStore([
        const GemmaArtifactEntry(
          name: 'gemma-4-E2B-it-web.litertlm',
          directory: false,
        ),
        const GemmaArtifactEntry(name: 'flutter_gemma', directory: true),
        const GemmaArtifactEntry(name: 'session.json', directory: false),
      ]);

      final report = await cleanupGemmaLeftovers(
        MemoryExecutionEnv(),
        isWeb: true,
        webStore: store,
      );

      expect(report.deleted, hasLength(2));
      expect(store.removed, containsAll(['gemma-4-E2B-it-web.litertlm']));
      expect(store.removed, isNot(contains('session.json')));
    });

    test('a root dir merely containing the vendor name survives', () async {
      final store = _FakeWebArtifactStore([
        const GemmaArtifactEntry(name: 'flutter_gemma_foo', directory: true),
      ]);

      final report = await cleanupGemmaLeftovers(
        MemoryExecutionEnv(),
        isWeb: true,
        webStore: store,
      );

      expect(report.isEmpty, isTrue);
      expect(store.removed, isEmpty);
    });

    test('a failing web delete is recorded, not fatal', () async {
      final store = _FakeWebArtifactStore([
        const GemmaArtifactEntry(
          name: 'gemma-4-E2B-it-web.litertlm',
          directory: false,
        ),
      ]);
      store.throwOnRemove = StateError('quota exceeded');

      final report = await cleanupGemmaLeftovers(
        MemoryExecutionEnv(),
        isWeb: true,
        webStore: store,
      );

      expect(report.failed, hasLength(1));
      expect(report.deleted, isEmpty);
    });
  });
}
