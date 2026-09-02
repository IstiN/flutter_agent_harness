@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'fa_cube_headless_helper.dart';
import 'mock_llm_server.dart';

void main() {
  group('fa_cube headless integration', () {
    late Directory tempHome;
    late Directory workspace;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('fa_cube_test_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
      workspace = Directory.systemTemp.createTempSync('fa_cube_ws_');
    });

    tearDown(() {
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    });

    /// Runs one headless prompt against [server] with the temp HOME.
    Future<FaResult> runCube({
      required MockLlmServer server,
      required String prompt,
      String? cube,
      String? cubeConfig,
    }) {
      return runFaHeadless(
        workspace: workspace,
        baseUrl: server.baseUrl,
        prompt: prompt,
        cube: cube,
        cubeConfig: cubeConfig,
        env: {'HOME': tempHome.path},
      );
    }

    /// Writes a cube manifest into the workspace under `.fah/cubes/` and
    /// returns its name. [mounts] entries are full yaml flow-mapping bodies
    /// like `path: /etc, access: deny`.
    String writeCube(
      String name, {
      Iterable<String> allow = const [],
      Iterable<String> mounts = const [],
      String? networkAllowHost,
      String? cachePaths,
    }) {
      final sections = <String>[
        '  tools:',
        '    allow: [${allow.join(', ')}]',
        if (mounts.isNotEmpty)
          '  filesystem:\n'
              '    mounts:\n'
              '${mounts.map((m) => '      - {$m}').join('\n')}',
        if (networkAllowHost != null)
          '  network:\n'
              '    allow:\n'
              '      - {host: $networkAllowHost}',
        if (cachePaths != null)
          '  cache:\n'
              '    enabled: true\n'
              '    paths: [$cachePaths]',
      ];
      File('${workspace.path}/.fah/cubes/$name.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'apiVersion: fa/v1\n'
          'kind: Cube\n'
          'metadata:\n'
          '  name: $name\n'
          'spec:\n'
          '${sections.join('\n')}\n',
        );
      return name;
    }

    test('denied command: rm is refused with the fa_cube note', () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      final cube = writeCube('git-only', allow: ['git']);
      // Relative rm target: an absolute `rm -rf /` is force-escalated to an
      // approval prompt by the critical-pattern interceptor (above the cube
      // policy) even under yolo, so use a non-critical shape that still is
      // not on the allowlist.
      server.enqueueToolCall('bash', '{"command":"rm -rf ./build"}');
      server.enqueueText('done');

      final result = await runCube(
        server: server,
        prompt: 'clean the build dir',
        cube: cube,
      );

      expect(result.output, contains('fa_cube['));
      expect(result.output, contains("command 'rm' not in cube 'git-only'"));
      // The turn completes: the denial is a tool result, not a crash.
      expect(result.exitCode, 0);
    });

    test('allowed command: echo runs and output reaches the reply', () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      final cube = writeCube('echo-box', allow: ['echo']);
      server.enqueueToolCall('bash', '{"command":"echo fa-cube-ok"}');
      server.enqueueToolResultEcho();

      final result = await runCube(
        server: server,
        prompt: 'echo the marker',
        cube: cube,
      );

      // The reply echoes the tool RESULT text, so seeing the marker in the
      // assistant stdout proves the sandbox actually ran the command.
      expect(result.stdout, contains('fa-cube-ok'));
      expect(result.exitCode, 0);
    });

    test('fs guard: read of a denied path reports cube not-found', () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      final cube = writeCube('fs-guard', mounts: ['path: /etc, access: deny']);
      server.enqueueToolCall('read', '{"path":"/etc/hostname"}');
      server.enqueueToolResultEcho();

      final result = await runCube(
        server: server,
        prompt: 'read the host name',
        cube: cube,
      );

      expect(result.output, contains('fa_cube['));
      expect(
        result.output,
        contains('/etc/hostname does not exist in this cube'),
      );
      expect(result.exitCode, 0);
    });

    test('network denial: curl to a non-allowed host is refused', () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      final cube = writeCube(
        'net-guard',
        allow: ['curl'],
        networkAllowHost: 'api.github.com',
      );
      server.enqueueToolCall(
        'bash',
        '{"command":"curl https://evil.example.com/x"}',
      );
      server.enqueueToolResultEcho();

      final result = await runCube(
        server: server,
        prompt: 'fetch the url',
        cube: cube,
      );

      expect(result.output, contains('evil.example.com'));
      expect(result.output, contains("denied by cube 'net-guard'"));
      expect(result.exitCode, 0);
    });

    test('subshell: command inside the substitution is checked too', () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      final cube = writeCube('sub-guard', allow: ['echo']);
      server.enqueueToolCall('bash', '{"command":"echo \$(ssh host)"}');
      server.enqueueToolResultEcho();

      final result = await runCube(
        server: server,
        prompt: 'run the substitution',
        cube: cube,
      );

      expect(result.output, contains("'ssh'"));
      expect(result.output, contains('not in cube'));
      expect(result.exitCode, 0);
    });

    test('cache: run 1 snapshots the cache path, run 2 restores it', () async {
      final run1 = await MockLlmServer.start();
      addTearDown(run1.stop);
      final cube = writeCube(
        'cached',
        allow: ['echo', 'mkdir'],
        cachePaths: '/workspace/.cache',
      );
      run1.enqueueToolCall(
        'bash',
        '{"command":"mkdir -p .cache && echo v1 > .cache/artifact.txt"}',
      );
      run1.enqueueText('done');

      final first = await runCube(
        server: run1,
        prompt: 'seed cache',
        cube: cube,
      );
      expect(
        first.exitCode,
        0,
        reason: 'stdout: ${first.stdout}\nstderr: ${first.stderr}',
      );

      final cacheRoot = Directory('${workspace.path}/.fah/cube-cache');
      expect(
        cacheRoot.existsSync(),
        isTrue,
        reason: 'cache root written on exit',
      );
      final saved = cacheRoot.listSync().whereType<Directory>().single;
      expect(File('${saved.path}/manifest.json').existsSync(), isTrue);
      expect(
        File(
          '${saved.path}/cache/.cache/artifact.txt',
        ).readAsStringSync().trim(),
        'v1',
      );

      // Wipe the live `.cache` so run 2 can only see the artifact through a
      // boot-time cache restore (the second script never runs bash).
      Directory('${workspace.path}/.cache').deleteSync(recursive: true);

      final run2 = await MockLlmServer.start();
      addTearDown(run2.stop);
      run2.enqueueText('cache-restored');
      final second = await runCube(
        server: run2,
        prompt: 'check cache',
        cube: cube,
      );

      expect(
        second.exitCode,
        0,
        reason: 'stdout: ${second.stdout}\nstderr: ${second.stderr}',
      );
      final restored = File('${workspace.path}/.cache/artifact.txt');
      expect(restored.existsSync(), isTrue, reason: 'cache restored at boot');
      expect(restored.readAsStringSync().trim(), 'v1');
      expect(second.stdout, contains('cache-restored'));
    });

    test('missing cube name: clean file-not-found failure', () async {
      final result = await runFaHeadless(
        workspace: workspace,
        baseUrl: 'http://127.0.0.1:9/v1',
        prompt: 'anything',
        cube: 'no-such-cube',
        env: {'HOME': tempHome.path},
      );

      expect(result.stderr, contains('file not found'));
      expect(result.stderr, contains('no-such-cube.yaml'));
      expect(result.exitCode, 64);
    });

    test('explicit --cube-config path applies the manifest', () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      final manifest = File('${workspace.path}/custom-cube.yaml');
      manifest.writeAsStringSync('''
apiVersion: fa/v1
kind: Cube
metadata:
  name: custom
spec:
  tools:
    allow: [echo]
    deny: []
''');
      server.enqueueToolCall('bash', '{"command":"echo cube-config-ok"}');
      server.enqueueToolResultEcho();

      final result = await runCube(
        server: server,
        prompt: 'echo the marker',
        cubeConfig: manifest.path,
      );

      expect(result.stdout, contains('cube-config-ok'));
      expect(result.exitCode, 0);
    });
  });
}
