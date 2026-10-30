// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/gemma_leftover_cleanup.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [MemoryExecutionEnv] whose `remove` always fails (the read-only-volume
/// shape: delete errors must be recorded, never fatal).
final class _FailingRemoveEnv extends MemoryExecutionEnv {
  _FailingRemoveEnv({super.cwd});

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
    test('deletes .litertlm files and flutter_gemma dirs, keeps the rest',
        () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/gemma-4-E2B-it.litertlm', 'weights');
      await env.writeFile('${env.cwd}/keep-me.txt', 'user data');
      await env.writeFile(
        '${env.cwd}/nested/deeper/gemma-4-E4B-it.litertlm',
        'weights',
      );
      await env.writeFile('${env.cwd}/flutter_gemma/model.json', 'registry');
      await env.writeFile('${env.cwd}/other/x.litertlm.bak', 'not an artifact');

      final report = await cleanupGemmaLeftovers(env);

      expect(
        report.deleted.map((p) => p.split('/').last),
        containsAll(['gemma-4-E2B-it.litertlm', 'gemma-4-E4B-it.litertlm']),
      );
      expect(await env.exists('${env.cwd}/gemma-4-E2B-it.litertlm'), isFalse);
      expect(
        await env.exists('${env.cwd}/nested/deeper/gemma-4-E4B-it.litertlm'),
        isFalse,
      );
      // The plugin's storage dir is gone (its registry file with it).
      expect(await env.exists('${env.cwd}/flutter_gemma/model.json'), isFalse);
      // User files untouched.
      expect(await env.exists('${env.cwd}/keep-me.txt'), isTrue);
      // `.bak` is not a `.litertlm` suffix match.
      expect(await env.exists('${env.cwd}/other/x.litertlm.bak'), isTrue);
    });

    test('an empty sandbox cleans nothing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/chat/session.json', '{}');

      final report = await cleanupGemmaLeftovers(env);

      expect(report.isEmpty, isTrue);
      expect(report.deleted, isEmpty);
      expect(report.failed, isEmpty);
    });

    test('a failing delete is recorded, not fatal — the walk continues',
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
