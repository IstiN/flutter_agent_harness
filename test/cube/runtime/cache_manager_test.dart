import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

CubeSpec spec({
  List<String> paths = const ['/workspace/.cache'],
  bool enabled = true,
  bool restore = true,
  Duration? ttl,
  Set<String> tools = const {'git'},
  int? diskBytes,
  String workspace = '/workspace',
}) => CubeSpec(
  name: 'test-cube',
  tools: CubeToolPolicy(allow: tools),
  filesystem: CubeFsPolicy(workspace: workspace),
  resources: CubeResourceLimits(diskBytes: diskBytes),
  cache: CubeCachePolicy(
    enabled: enabled,
    paths: paths,
    restore: restore,
    ttl: ttl,
  ),
);

/// Seeds `<cwd>/.cache/blob.txt` in the memory env.
Future<void> seedCache(ExecutionEnv env, {String content = 'payload'}) =>
    env.writeFile('/work/.cache/blob.txt', content);

void main() {
  group('CubeCacheManager', () {
    test('the key is stable per spec and changes with it', () {
      final env = MemoryExecutionEnv(cwd: '/work');
      final key = CubeCacheManager(env, spec()).cacheKey;
      expect(key, CubeCacheManager(env, spec()).cacheKey);
      expect(
        CubeCacheManager(env, spec(tools: {'git', 'curl'})).cacheKey,
        isNot(key),
      );
      expect(key, hasLength(10));
    });

    test('cacheRoot lives under the env cwd', () {
      final env = MemoryExecutionEnv(cwd: '/work');
      final manager = CubeCacheManager(env, spec());
      expect(manager.cacheRoot, startsWith('/work/.fah/cube-cache/'));
      expect(manager.cacheRoot.endsWith(manager.cacheKey), isTrue);
    });

    test('cold save creates the manifest and mirrored files', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final manager = CubeCacheManager(env, spec());
      await manager.save();

      final manifest = jsonDecode(
        (await env.readTextFile(
          '${manager.cacheRoot}/manifest.json',
        )).getOrThrow(),
      );
      expect(manifest['key'], manager.cacheKey);
      expect(manifest['name'], 'test-cube');
      expect(manifest['paths'], ['/workspace/.cache']);
      expect(
        (await env.readTextFile(
          '${manager.cacheRoot}/cache/.cache/blob.txt',
        )).getOrThrow(),
        'payload',
      );
    });

    test('restore copies the cached tree back into place', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final manager = CubeCacheManager(env, spec());
      await manager.save();

      // A fresh sandbox: the live cache path is gone.
      await env.remove('/work/.cache', recursive: true, force: true);
      expect((await env.exists('/work/.cache/blob.txt')).getOrThrow(), isFalse);

      await manager.restoreIfNeeded();
      expect(
        (await env.readTextFile('/work/.cache/blob.txt')).getOrThrow(),
        'payload',
      );
    });

    test('an expired ttl clears the entry and restores nothing', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final manager = CubeCacheManager(
        env,
        spec(ttl: const Duration(hours: 1)),
      );
      await manager.save();
      // Backdate the manifest beyond the ttl.
      final manifestPath = '${manager.cacheRoot}/manifest.json';
      final manifest =
          jsonDecode((await env.readTextFile(manifestPath)).getOrThrow())
              as Map<String, Object?>;
      manifest['createdAtMs'] =
          DateTime.now().millisecondsSinceEpoch - 2 * 3600 * 1000;
      await env.writeFile(manifestPath, jsonEncode(manifest));

      await env.remove('/work/.cache', recursive: true, force: true);
      await manager.restoreIfNeeded();

      expect((await env.exists(manifestPath)).getOrThrow(), isFalse);
      expect((await env.exists('/work/.cache/blob.txt')).getOrThrow(), isFalse);
    });

    test('restore:false skips the restore but keeps saving', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final manager = CubeCacheManager(env, spec(restore: false));
      await manager.save();
      expect(
        (await env.exists(
          '${manager.cacheRoot}/cache/.cache/blob.txt',
        )).getOrThrow(),
        isTrue,
      );

      await env.remove('/work/.cache', recursive: true, force: true);
      await manager.restoreIfNeeded();
      expect((await env.exists('/work/.cache/blob.txt')).getOrThrow(), isFalse);
    });

    test('a cache path outside the workspace mirrors by basename', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.m2/settings.xml', 'm2');
      final manager = CubeCacheManager(
        env,
        spec(paths: ['/workspace/.cache', '/etc/.m2']),
      );
      await manager.save();
      expect(
        (await env.exists(
          '${manager.cacheRoot}/cache/.m2/settings.xml',
        )).getOrThrow(),
        isTrue,
      );
      await env.remove('/work/.m2', recursive: true, force: true);
      await manager.restoreIfNeeded();
      expect(
        (await env.readTextFile('/work/.m2/settings.xml')).getOrThrow(),
        'm2',
      );
    });

    test('a custom spec workspace mirrors positionally onto the cwd', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.gradle/cache.bin', 'gradle');
      final manager = CubeCacheManager(
        env,
        spec(paths: ['/cube/.gradle'], workspace: '/cube'),
      );
      await manager.save();
      expect(
        (await env.readTextFile(
          '${manager.cacheRoot}/cache/.gradle/cache.bin',
        )).getOrThrow(),
        'gradle',
      );
      await env.remove('/work/.gradle', recursive: true, force: true);
      await manager.restoreIfNeeded();
      expect(
        (await env.readTextFile('/work/.gradle/cache.bin')).getOrThrow(),
        'gradle',
      );
    });

    test('a changed spec forks a separate cache root', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final first = CubeCacheManager(env, spec());
      await first.save();
      final second = CubeCacheManager(env, spec(tools: {'git', 'curl'}));
      await second.save();
      expect(second.cacheKey, isNot(first.cacheKey));
      expect(
        (await env.exists('${first.cacheRoot}/manifest.json')).getOrThrow(),
        isTrue,
      );
    });

    test('save prunes oldest siblings down to the disk bound', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      // Two fat old entries, oldest first.
      final old1 = '${env.cwd}/.fah/cube-cache/aaaaaaaaaa';
      final old2 = '${env.cwd}/.fah/cube-cache/bbbbbbbbbb';
      await env.writeFile('$old1/cache/big.txt', 'x' * 800);
      await env.writeFile('$old2/cache/big.txt', 'x' * 800);

      final manager = CubeCacheManager(env, spec(diskBytes: 1000));
      await manager.save();

      expect((await env.exists(old1)).getOrThrow(), isFalse);
      expect((await env.exists(old2)).getOrThrow(), isTrue);
      // The entry just saved is never pruned.
      expect(
        (await env.exists('${manager.cacheRoot}/manifest.json')).getOrThrow(),
        isTrue,
      );
    });

    test('clear removes the whole cache root', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final manager = CubeCacheManager(env, spec());
      await manager.save();
      expect((await env.exists(manager.cacheRoot)).getOrThrow(), isTrue);
      await manager.clear();
      expect((await env.exists(manager.cacheRoot)).getOrThrow(), isFalse);
    });

    test('a disabled cache policy is a full no-op', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await seedCache(env);
      final manager = CubeCacheManager(env, spec(enabled: false));
      await manager.save();
      await manager.restoreIfNeeded();
      expect((await env.exists('/work/.fah')).getOrThrow(), isFalse);
    });
  });
}
