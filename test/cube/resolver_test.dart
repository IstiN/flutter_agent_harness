/// Tests for `CubeResolver`: name lookup under `<cwd>/.fah/cubes/`,
/// explicit paths, `~` expansion, clean errors for missing/invalid files,
/// and `null` when nothing is requested.
library;

import 'package:flutter_agent_harness/src/cube/runtime/cube_resolver.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';

const _validCube = '''
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
spec:
  tools:
    allow: [curl]
''';

void main() {
  Future<MemoryExecutionEnv> envWith(String path, String content) async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final write = await env.writeFile(path, content);
    assert(write is Ok, 'test setup failed writing $path');
    return env;
  }

  group('CubeResolver.resolve', () {
    test('resolves by name from <cwd>/.fah/cubes/<name>.yaml', () async {
      final env = await envWith('/work/.fah/cubes/web.yaml', _validCube);
      final spec = await CubeResolver.resolve(env: env, name: 'web');
      expect(spec, isNotNull);
      expect(spec!.name, 'web-scraper');
      expect(spec.tools.permits('curl'), isTrue);
    });

    test('resolves by explicit path (highest precedence)', () async {
      final env = await envWith('/cubes/custom.yaml', _validCube);
      final spec = await CubeResolver.resolve(
        env: env,
        path: '/cubes/custom.yaml',
      );
      expect(spec, isNotNull);
      expect(spec!.name, 'web-scraper');
    });

    test('prefers explicit path over name', () async {
      final env = await envWith('/cubes/custom.yaml', _validCube);
      final spec = await CubeResolver.resolve(
        env: env,
        path: '/cubes/custom.yaml',
        name: 'does-not-exist',
      );
      expect(spec!.name, 'web-scraper');
    });

    test('expands a leading ~ with homeDir', () async {
      final env = await envWith('/home/dev/cube.yaml', _validCube);
      final spec = await CubeResolver.resolve(
        env: env,
        path: '~/cube.yaml',
        homeDir: '/home/dev',
      );
      expect(spec!.name, 'web-scraper');
    });

    test('throws a clean ConfigException for a missing file', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      expect(
        () => CubeResolver.resolve(env: env, name: 'missing'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            'cube: file not found: /work/.fah/cubes/missing.yaml',
          ),
        ),
      );
    });

    test('throws a clean ConfigException for a missing explicit path', () {
      final env = MemoryExecutionEnv(cwd: '/work');
      expect(
        () => CubeResolver.resolve(env: env, path: '/nope/cube.yaml'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('file not found: /nope/cube.yaml'),
          ),
        ),
      );
    });

    test('returns null when nothing is requested', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      expect(await CubeResolver.resolve(env: env), isNull);
    });

    test('rejects invalid yaml with ConfigException', () async {
      final env = await envWith('/work/.fah/cubes/bad.yaml', 'a: [unclosed');
      expect(
        () => CubeResolver.resolve(env: env, name: 'bad'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('invalid yaml'),
          ),
        ),
      );
    });

    test('rejects a schema violation from the parsed document', () async {
      final env = await envWith('/work/.fah/cubes/wrong.yaml', '''
apiVersion: fa/v1
kind: Cube
metadata: {name: Bad_Name}
''');
      expect(
        () => CubeResolver.resolve(env: env, name: 'wrong'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('metadata.name'),
          ),
        ),
      );
    });

    test('~ path without homeDir fails loudly', () {
      final env = MemoryExecutionEnv(cwd: '/work');
      expect(
        () => CubeResolver.resolve(env: env, path: '~/cube.yaml'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
