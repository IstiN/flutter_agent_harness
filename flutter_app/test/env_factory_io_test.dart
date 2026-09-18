import 'dart:io';

import 'package:fa/sandbox/env_factory_io.dart' as app_env;
import 'package:fa/sandbox/persistent_web_env.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/project_mount_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  group('SandboxedExecutionEnv', () {
    late Directory hostRoot;
    late app_env.SandboxedExecutionEnv env;

    setUp(() {
      hostRoot = Directory.systemTemp.createTempSync('fah_sandbox_test_');
      env = app_env.SandboxedExecutionEnv(
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

      // The session file lands under an encoded-cwd directory inside the
      // sandbox host directory…
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

  group('createPlatformEnv builders (issue #568)', () {
    late Directory appSupport;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      appSupport = Directory.systemTemp.createTempSync('fah_app_support_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(appSupport);
    });

    tearDown(() {
      if (appSupport.existsSync()) appSupport.deleteSync(recursive: true);
    });

    test(
      'createDesktopEnv builds the env on the app-support directory',
      () async {
        final env = await app_env.createDesktopEnv();
        expect(env.cwd, appSupport.path);
        expect(env, isA<LocalExecutionEnv>());
      },
    );

    test(
      'applyStoredMount exposes a granted bookmark as the mounted root',
      () async {
        final (mountEnv, stored) = await _mountWithStoredMount();
        app_env.applyStoredMount(mountEnv, stored, granted: true);
        expect(mountEnv.mountedRoot, '/proj');
        expect(mountEnv.mountUnavailable, isNull);
      },
    );

    test('applyStoredMount surfaces a refused bookmark as stale', () async {
      final (mountEnv, stored) = await _mountWithStoredMount();
      app_env.applyStoredMount(mountEnv, stored, granted: false);
      expect(mountEnv.mountedRoot, isNull);
      expect(mountEnv.mountUnavailable, '/proj');
    });
    test(
      'mountedDesktopEnv without a stored mount is a plain wrapper',
      () async {
        final baseEnv = LocalExecutionEnv(
          cwd: Directory.systemTemp.createTempSync('fah_base_').path,
        );
        addTearDown(() => Directory(baseEnv.cwd).deleteSync(recursive: true));
        final env = await app_env.mountedDesktopEnv(baseEnv) as ProjectMountEnv;
        expect(env.mountedRoot, isNull);
        expect(env.mountUnavailable, isNull);
        expect(env.cwd, baseEnv.cwd);
      },
    );
  });

  group('createMobileSandboxEnv fallback (issue #640)', () {
    late Directory appSupport;
    late Directory documents;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      appSupport = Directory.systemTemp.createTempSync('fah_app_support_');
      documents = Directory.systemTemp.createTempSync('fah_documents_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(
        appSupport,
        documents,
      );
      AppLog.reset();
    });

    tearDown(() {
      AppLog.reset();
      for (final dir in [appSupport, documents]) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    });

    test('a failing WasiSandboxShell.load falls back to MemoryShell', () async {
      final env = await app_env.createMobileSandboxEnv(
        loadShell: () async => throw StateError('PanicException: python.wasm'),
      );
      expect(env, isA<PersistentWebExecutionEnv>());
      // The fallback shell answers basic commands in memory.
      final r = await env.exec('echo ok');
      expect(r.valueOrNull!.exitCode, 0);
      expect(r.valueOrNull!.stdout, contains('ok'));
    });
    test('the fallback logs an informational warning line', () async {
      await app_env.createMobileSandboxEnv(
        loadShell: () async => throw StateError('PanicException: python.wasm'),
      );
      final log = AppLog.dump();
      expect(log, contains('falling back to MemoryShell'));
      expect(log, contains('PanicException'));
    });
  });
}

/// Builds a mount env with a persisted mount via the public save/load API.
Future<(ProjectMountEnv, ProjectMountStore)> _mountWithStoredMount() async {
  final baseEnv = LocalExecutionEnv(
    cwd: Directory.systemTemp.createTempSync('fah_base_').path,
  );
  addTearDown(() => Directory(baseEnv.cwd).deleteSync(recursive: true));
  await ProjectMountStore.save(
    baseEnv,
    path: '/proj',
    bookmark: 'bm',
    scoped: true,
  );
  final stored = (await ProjectMountStore.load(baseEnv))!;
  return (ProjectMountEnv(baseEnv), stored);
}

/// Platform-interface fake: the path_provider method channel is gated by
/// the host platform, the interface is not.
final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._appSupport, [this._documents]);

  final Directory _appSupport;
  final Directory? _documents;

  @override
  Future<String?> getApplicationSupportPath() async => _appSupport.path;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      _documents?.path ?? _appSupport.path;
}
