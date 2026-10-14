// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/app_storage.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// gh-1614 — one app-storage namespace: listing and reading resolve
/// `apps/<id>/` through the shared [AppStorage] resolver, so an app the
/// Apps tab lists is an app it can start (or it renders the explicit
/// "stored files missing" state naming the root — never a raw
/// `StateError: app entry not found`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppsStore> storeWith(ExecutionEnv env) async =>
      AppsStore(env, readAsset: (path) async => '');

  group('gh-1614 I2/I3: listed ⇒ bootable (AppsStore.listApps)', () {
    test('a listed app whose entry is missing renders the missing-files '
        'state naming the root and the exact path', () async {
      final env = MemoryExecutionEnv();
      // The torn web-snapshot / cross-host shape: manifest restored, the
      // entry never persisted (the original "2048 Мини 🎲" report).
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048 Мини 🎲'}),
      );
      final apps = await (await storeWith(env)).listApps();

      expect(apps, hasLength(1));
      final app = apps.single;
      expect(app.error, isNotNull);
      expect(app.error, contains('apps/2048/'), reason: 'names the root');
      expect(app.error, contains('apps/2048/widget.js'));
    });

    test('a fully stored app lists clean — present and startable', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048 Мини 🎲'}),
      );
      await env.writeFile('apps/2048/widget.js', 'jsr.render(null);');
      final apps = await (await storeWith(env)).listApps();

      expect(apps, hasLength(1));
      expect(apps.single.error, isNull);
    });

    test('a multi-app scan keeps every state distinct (2+ items)', () async {
      final env = MemoryExecutionEnv();
      // healthy: manifest + entry
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048'}),
      );
      await env.writeFile('apps/2048/widget.js', 'jsr.render(null);');
      // torn: manifest restored, entry lost
      await env.writeFile(
        'apps/todo/manifest.json',
        jsonEncode({'id': 'todo', 'name': 'Todo'}),
      );
      // half-created: an empty dir (healer's domain) — never listed
      await env.createDir('apps/ghost');

      final apps = await (await storeWith(env)).listApps();
      final byId = {for (final app in apps) app.id: app};

      expect(byId['2048']!.error, isNull);
      expect(byId['todo']!.error, contains('apps/todo/widget.js'));
      expect(byId.containsKey('ghost'), isFalse);
    });

    test('the entry returning heals the tile on the next scan', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048'}),
      );
      final store = await storeWith(env);
      expect((await store.listApps()).single.error, isNotNull);

      // The auto-update healer (or the agent) restores the entry.
      await env.writeFile('apps/2048/widget.js', 'jsr.render(null);');
      expect((await store.listApps()).single.error, isNull);
    });

    test('REG-1: the store probes the exact path the boot path checks',
        () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048'}),
      );
      final apps = await (await storeWith(env)).listApps();

      // The listing's missing-files state names the very path the boot
      // resolver probes — one root, one path shape (gh-1614 I1).
      expect(apps.single.error, contains(AppStorage.entryPath('2048')));
      final reader = JsAppEngine.appWidgetFileReaderForTest(
        env: env,
        dir: 'apps/2048',
        entryFile: 'widget.js',
      );
      expect(await reader.exists(AppStorage.entryPath('2048')), isFalse);
      expect(await reader.exists(AppStorage.manifestPath('2048')), isTrue);
    });
  });

  group('gh-1614 AC4: traversal ids rejected at list and read', () {
    test('a hostile directory name is never listed', () async {
      final env = _HostileListEnv(MemoryExecutionEnv());
      await env.inner.writeFile(
        'apps/ok/manifest.json',
        jsonEncode({'id': 'ok', 'name': 'Ok'}),
      );
      await env.inner.writeFile('apps/ok/widget.js', 'jsr.render(null);');

      final apps = await (await storeWith(env)).listApps();
      expect(apps.map((a) => a.id), ['ok']);
    });

    test('an app id that cannot live in the namespace fails assembly '
        'with ArgumentError, never a namespace escape', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/ok/widget.js',
        'jsr.render({type: "text", data: "never"});',
      );
      await expectLater(
        JsAppEngine.assembleEntryJsForTest(
          env: env,
          dir: 'apps/../evil',
          entryFile: 'widget.js',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('../evil'),
          ),
        ),
      );
    });

    test('the reader answers escaping paths as missing files', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/ok/widget.js', 'entry');
      await env.writeFile('secret.json', '{"top":"secret"}');
      await env.writeFile('apps/secret.json', '{"app":"secret"}');

      final reader = JsAppEngine.appWidgetFileReaderForTest(
        env: env,
        dir: 'apps/ok',
        entryFile: 'widget.js',
      );
      expect(await reader.readString('apps/ok/../../secret.json'), isNull);
      expect(await reader.readString('/secret.json'), isNull);
      expect(await reader.readString('apps/ok/..%2Fsecret.json'), isNull);
      expect(await reader.exists('../secret.json'), isFalse);
      expect(await reader.exists(r'C:\abs\path.js'), isFalse);
    });
  });

  group('gh-1614 AC1/I3: honest boot failures (entry assembly)', () {
    test('missing entry (manifest present) names the root and the path',
        () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048'}),
      );
      await expectLater(
        JsAppEngine.assembleEntryJsForTest(
          env: env,
          dir: 'apps/2048',
          entryFile: 'widget.js',
        ),
        throwsA(
          isA<StateError>()
              .having(
                (e) => e.message,
                'message',
                allOf([
                  contains('app entry not found'),
                  contains('apps/2048/'),
                  contains('apps/2048/widget.js'),
                ]),
              )
              .having(
                (e) => e.message,
                'manifest is present — only the entry is named missing',
                isNot(contains('manifest.json')),
              ),
        ),
      );
    });

    test('a missing dir names every missing file', () async {
      final env = MemoryExecutionEnv();
      await expectLater(
        JsAppEngine.assembleEntryJsForTest(
          env: env,
          dir: 'apps/vanished',
          entryFile: 'widget.js',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('app entry not found'),
              contains('apps/vanished/'),
              contains('apps/vanished/manifest.json'),
              contains('apps/vanished/widget.js'),
            ]),
          ),
        ),
      );
    });

    test('a listed app whose files vanished after listing still fails '
        'honestly (E1: no crash, no stale boot)', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({'id': '2048', 'name': '2048'}),
      );
      await env.writeFile('apps/2048/widget.js', 'jsr.render(null);');
      final apps = await (await storeWith(env)).listApps();
      expect(apps.single.error, isNull);

      // Deleted while its card is open (E1).
      await env.remove('apps/2048/widget.js');
      await expectLater(
        JsAppEngine.assembleEntryJsForTest(
          env: env,
          dir: apps.single.dir,
          entryFile: 'widget.js',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('apps/2048/widget.js'),
          ),
        ),
      );
    });

    test('AC1: a web-shaped MemoryExecutionEnv boots a stored app through '
        'the same entry-assembly path start() runs', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/2048/manifest.json',
        jsonEncode({
          'id': '2048',
          'name': '2048 Мини 🎲',
          'files': ['engine.js', 'widget.js'],
        }),
      );
      await env.writeFile('apps/2048/engine.js', 'var boot = "engine";');
      await env.writeFile(
        'apps/2048/widget.js',
        'jsr.render({type: "text", data: boot});',
      );

      // start() runs exactly this assembly (JsAppEngine._assembleEntryJs).
      final js = await JsAppEngine.assembleEntryJsForTest(
        env: env,
        dir: AppStorage.appDir('2048'),
        entryFile: 'widget.js',
      );
      expect(js, contains('engine'));
      expect(js, contains('jsr.render'));

      // …and the listing that produced the boot was clean.
      final apps = await (await storeWith(env)).listApps();
      expect(apps.single.error, isNull);
    });
  });
}

/// [ExecutionEnv] whose `apps/` listing carries hostile directory names —
/// the crafted-state shape for the gh-1614 AC4 list-side rejection (a
/// divergent legacy root, or storage arriving from another host). Delegates
/// to an in-memory env; unexpected calls fail loudly.
class _HostileListEnv implements ExecutionEnv {
  _HostileListEnv(this.inner);

  final MemoryExecutionEnv inner;

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final result = await inner.listDir(path);
    if (result.isErr) return result;
    const hostile = [
      FileInfo(
        name: '../evil',
        path: 'apps/../evil',
        kind: FileKind.directory,
        size: 0,
        mtimeMs: 0,
      ),
      FileInfo(
        name: 'Party-Time',
        path: 'apps/Party-Time',
        kind: FileKind.directory,
        size: 0,
        mtimeMs: 0,
      ),
      FileInfo(
        name: '/abs',
        path: 'apps//abs',
        kind: FileKind.directory,
        size: 0,
        mtimeMs: 0,
      ),
    ];
    return Ok([...result.valueOrNull ?? const <FileInfo>[], ...hostile]);
  }

  @override
  Future<Result<bool, FileError>> exists(String path) => inner.exists(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      inner.readTextFile(path);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      inner.writeFile(path, content);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected env call: $invocation');
}
