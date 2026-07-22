import 'dart:io';

import 'package:fa/env_factory_io.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SandboxedExecutionEnv', () {
    late Directory hostRoot;
    late SandboxedExecutionEnv env;

    setUp(() {
      hostRoot = Directory.systemTemp.createTempSync('fah_sandbox_test_');
      env = SandboxedExecutionEnv(
        LocalExecutionEnv(cwd: hostRoot.path),
        hostRoot.path,
      );
    });

    tearDown(() {
      if (hostRoot.existsSync()) {
        hostRoot.deleteSync(recursive: true);
      }
    });

    test(
      'maps sandbox-absolute paths into the host sandbox directory',
      () async {
        (await env.writeFile('/notes/a.txt', 'hello')).getOrThrow();
        expect(
          File('${hostRoot.path}/notes/a.txt').readAsStringSync(),
          'hello',
        );
      },
    );

    test('resolves relative paths against the host cwd', () async {
      (await env.writeFile('b.txt', 'rel')).getOrThrow();
      expect(File('${hostRoot.path}/b.txt').readAsStringSync(), 'rel');

      // The file browser navigates with paths relative to env.cwd.
      final entries = (await env.listDir('.')).getOrThrow();
      expect(entries.map((e) => e.name), contains('b.txt'));
    });

    test('does not re-map paths built from env.cwd', () async {
      // env.cwd is a host path; appending to it and passing the result back
      // through the env must not apply the sandbox prefix a second time.
      final hostPath = '${env.cwd}/sessions/x.jsonl';
      (await env.writeFile(hostPath, 'data')).getOrThrow();
      expect(File(hostPath).readAsStringSync(), 'data');
      expect(
        Directory('${hostRoot.path}${hostRoot.path}').existsSync(),
        isFalse,
      );
    });

    test('absolutePath is idempotent for cwd-derived paths', () async {
      final once = (await env.absolutePath('${env.cwd}/sessions')).getOrThrow();
      expect(once, '${hostRoot.path}/sessions');
      final twice = (await env.absolutePath(once)).getOrThrow();
      expect(twice, once);
    });

    test('JsonlSessionRepo stores sessions under <sandbox>/sessions', () async {
      // Mirrors AgentService._withEnv, which builds the repo with
      // sessionsRoot = '${env.cwd}/sessions'.
      final repo = JsonlSessionRepo(
        fs: env,
        sessionsRoot: '${env.cwd}/sessions',
      );
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: 'test-provider'),
      );
      await session.appendMessage(
        UserMessage(
          content: [TextContent(text: 'hi')],
          timestamp: DateTime.now(),
        ),
      );

      // The session file lands directly under the sandbox host directory…
      final sessionsDir = Directory('${hostRoot.path}/sessions');
      expect(sessionsDir.existsSync(), isTrue);
      final jsonlFiles = sessionsDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList();
      expect(jsonlFiles, hasLength(1));
      expect(jsonlFiles.single.readAsStringSync(), contains('hi'));

      // …and NOT in a nested '<sandbox>/<host-path>/sessions' directory:
      // the sandbox root must contain nothing but the sessions directory.
      expect(hostRoot.listSync().map((e) => e.path), [
        '${hostRoot.path}/sessions',
      ]);
      expect(
        Directory('${hostRoot.path}${hostRoot.path}').existsSync(),
        isFalse,
      );
    });

    test('listDir FileInfo paths round-trip through the env', () async {
      (await env.writeFile('/dir/c.txt', 'roundtrip')).getOrThrow();
      final entries = (await env.listDir('/dir')).getOrThrow();
      final info = entries.singleWhere((e) => e.name == 'c.txt');
      // FileInfo.path is host-space; feeding it back must read the same file.
      expect((await env.readTextFile(info.path)).getOrThrow(), 'roundtrip');
    });
  });
}
