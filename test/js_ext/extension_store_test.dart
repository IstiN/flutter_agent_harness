import 'dart:convert';

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:test/test.dart';

const _projectDir = '/proj';
const _userDir = '/home/u';

TrustRecord _trust(String sha) => TrustRecord(
  source: ExtTrustSource.local,
  sourceRef: '/tmp/somewhere',
  contentSha256: sha,
  capabilities: const {'tools': true},
  grantedAt: DateTime.utc(2026, 1, 1),
);

Map<String, String> _files({
  String name = 'hello-ext',
  String capabilities = '"tools": true',
}) => {
  'manifest.json': jsonEncode({
    'name': name,
    'version': '0.1.0',
    'capabilities': jsonDecode('{$capabilities}'),
  }),
  'main.js': 'jsr.ext.registerTool({});',
  'lib/extra.txt': 'hi',
};

void main() {
  late MemoryExecutionEnv env;
  late ExtensionStore store;

  setUp(() {
    env = MemoryExecutionEnv(cwd: _projectDir);
    store = ExtensionStore(
      env: env,
      projectDir: _projectDir,
      userDir: _userDir,
    );
  });

  group('write + list round-trip', () {
    test('writes files, trust.json, and reads them back', () async {
      await store.write('hello-ext', files: _files(), trust: _trust('abc123'));
      final result = await store.list();
      expect(result.problems, isEmpty);
      expect(result.extensions, hasLength(1));
      final ext = result.extensions.single;
      expect(ext.name, 'hello-ext');
      expect(ext.scope, ExtStoreScope.project);
      expect(ext.dir, '$_projectDir/.fah/js-ext/hello-ext');
      expect(ext.manifest.kind, ExtKind.widget);
      expect(ext.manifest.capabilities.tools, isTrue);
      expect(ext.mainJs, 'jsr.ext.registerTool({});');
      expect(ext.trust, isNotNull);
      expect(ext.trust!.contentSha256, 'abc123');
      expect(ext.trust!.source, ExtTrustSource.local);
    });

    test('list skips dirs without a manifest silently', () async {
      await env.writeFile('$_projectDir/.fah/js-ext/README.md', 'not an ext');
      await env.createDir('$_projectDir/.fah/js-ext/empty-dir');
      final result = await store.list();
      expect(result.extensions, isEmpty);
      expect(result.problems, isEmpty);
    });

    test('list of an empty store works', () async {
      final result = await store.list();
      expect(result.extensions, isEmpty);
      expect(result.problems, isEmpty);
    });
  });

  group('shadowing', () {
    test('project shadows user by name; find agrees', () async {
      await store.write(
        'dup',
        files: _files(name: 'dup'),
        trust: _trust('p1'),
      );
      final userRoot = '$_userDir/.fah/js-ext/dup';
      await env.writeFile(
        '$userRoot/manifest.json',
        jsonEncode({'name': 'dup', 'version': '9.9.9'}),
      );
      await env.writeFile('$userRoot/main.js', '// user main');

      final result = await store.list();
      expect(result.extensions, hasLength(1));
      expect(result.extensions.single.scope, ExtStoreScope.project);
      expect(result.extensions.single.manifest.version, '0.1.0');

      final found = await store.find('dup');
      expect(found, isNotNull);
      expect(found!.scope, ExtStoreScope.project);
    });

    test('user entry is used when project has none', () async {
      final userRoot = '$_userDir/.fah/js-ext/only-user';
      await env.writeFile(
        '$userRoot/manifest.json',
        jsonEncode({'name': 'only-user', 'version': '2.0.0'}),
      );
      await env.writeFile('$userRoot/main.js', '// user');
      final result = await store.list();
      expect(result.extensions.single.scope, ExtStoreScope.user);
    });
  });

  group('invalid extension dirs', () {
    test('invalid manifest skipped into problems', () async {
      final root = '$_projectDir/.fah/js-ext/broken';
      await env.writeFile(
        '$root/manifest.json',
        jsonEncode({'name': 'Bad_Name', 'version': ''}),
      );
      await env.writeFile('$root/main.js', '// x');
      final result = await store.list();
      expect(result.extensions, isEmpty);
      expect(result.problems['broken'], contains('invalid manifest.json'));
      expect(result.problems['broken'], contains('invalid name'));
      expect(result.problems['broken'], contains('version must be non-empty'));
    });

    test('unparseable manifest skipped into problems', () async {
      final root = '$_projectDir/.fah/js-ext/garbage';
      await env.writeFile('$root/manifest.json', '{nope');
      await env.writeFile('$root/main.js', '// x');
      final result = await store.list();
      expect(result.problems['garbage'], contains('invalid manifest.json'));
    });

    test('manifest without main.js skipped into problems', () async {
      final root = '$_projectDir/.fah/js-ext/no-main';
      await env.writeFile(
        '$root/manifest.json',
        jsonEncode({'name': 'no-main', 'version': '1.0.0'}),
      );
      final result = await store.list();
      expect(result.problems['no-main'], 'missing main.js');
    });
  });

  group('platform filter', () {
    test('forPlatform keeps only supporting extensions', () async {
      final files = _files(name: 'mac-only');
      files['manifest.json'] = jsonEncode({
        'name': 'mac-only',
        'version': '1.0.0',
        'platforms': ['macos'],
      });
      await store.write('mac-only', files: files, trust: _trust('m1'));
      await store.write(
        'all',
        files: _files(name: 'all'),
        trust: _trust('a1'),
      );

      expect((await store.list()).extensions, hasLength(2));
      expect(
        (await store.list(
          forPlatform: ExtPlatformTag.cli,
        )).extensions.single.name,
        'all',
      );
      expect(
        (await store.list(
          forPlatform: ExtPlatformTag.macos,
        )).extensions.map((e) => e.name),
        unorderedEquals(['mac-only', 'all']),
      );
    });
  });

  group('trust', () {
    test('trust.json absent => trust null (untrusted)', () async {
      final root = '$_projectDir/.fah/js-ext/no-trust';
      await env.writeFile(
        '$root/manifest.json',
        jsonEncode({'name': 'no-trust', 'version': '1.0.0'}),
      );
      await env.writeFile('$root/main.js', '// x');
      final ext = await store.find('no-trust');
      expect(ext, isNotNull);
      expect(ext!.trust, isNull);
    });

    test('corrupt trust.json => untrusted, not a crash', () async {
      final root = '$_projectDir/.fah/js-ext/bad-trust';
      await env.writeFile(
        '$root/manifest.json',
        jsonEncode({'name': 'bad-trust', 'version': '1.0.0'}),
      );
      await env.writeFile('$root/main.js', '// x');
      await env.writeFile('$root/trust.json', 'not json');
      final ext = await store.find('bad-trust');
      expect(ext!.trust, isNull);
    });

    test('setTrust writes and updates the record', () async {
      await store.write(
        'upd',
        files: _files(name: 'upd'),
        trust: _trust('v1'),
      );
      await store.setTrust(
        'upd',
        TrustRecord(
          source: ExtTrustSource.bundled,
          sourceRef: 'bundled',
          contentSha256: 'v2',
          capabilities: const {},
          grantedAt: DateTime.utc(2026, 2, 2),
        ),
      );
      final ext = await store.find('upd');
      expect(ext!.trust!.contentSha256, 'v2');
      expect(ext.trust!.source, ExtTrustSource.bundled);
    });

    test('setTrust on missing extension throws', () async {
      await expectLater(store.setTrust('ghost', _trust('x')), throwsStateError);
    });
  });

  group('remove', () {
    test('deletes the directory; missing is silent', () async {
      await store.write(
        'gone',
        files: _files(name: 'gone'),
        trust: _trust('g'),
      );
      await store.remove('gone');
      expect(await store.find('gone'), isNull);
      expect((await store.list()).extensions, isEmpty);
      await store.remove('never-existed');
      await store.remove('never-existed'); // idempotent
    });

    test('removes user-scope copy when no project copy exists', () async {
      final userRoot = '$_userDir/.fah/js-ext/user-only';
      await env.writeFile(
        '$userRoot/manifest.json',
        jsonEncode({'name': 'user-only', 'version': '1.0.0'}),
      );
      await env.writeFile('$userRoot/main.js', '// x');
      await store.remove('user-only');
      expect(await store.find('user-only'), isNull);
    });
  });

  group('write validation', () {
    test('requires manifest.json and main.js', () async {
      await expectLater(
        store.write('x', files: {'main.js': '//'}, trust: _trust('h')),
        throwsArgumentError,
      );
      await expectLater(
        store.write('x', files: {'manifest.json': '{}'}, trust: _trust('h')),
        throwsArgumentError,
      );
    });

    test('rejects invalid manifest content', () async {
      await expectLater(
        store.write('x', files: _files(), trust: _trust('h')),
        completes,
      );
      final bad = _files();
      bad['manifest.json'] = jsonEncode({'name': 'NO CAPS', 'version': '1'});
      await expectLater(
        store.write('y', files: bad, trust: _trust('h')),
        throwsA(isA<ExtManifestException>()),
      );
    });

    test('rejects path escapes', () async {
      final bad = _files()..['../escape.txt'] = 'nope';
      await expectLater(
        store.write('z', files: bad, trust: _trust('h')),
        throwsArgumentError,
      );
    });
  });

  group('extContentHash', () {
    test('pinned fixture digest', () {
      expect(
        extContentHash({
          'main.js': 'console.log(1);\n',
          'manifest.json': '{"name":"hi"}',
        }),
        '5ecfe44d36a4d3d73ca24709830bc8ad9f3c4346a0dace55e303905b27265a07',
      );
    });

    test('sorts paths before hashing', () {
      final a = extContentHash({'main.js': 'x', 'manifest.json': 'y'});
      final b = extContentHash({'manifest.json': 'y', 'main.js': 'x'});
      expect(a, b);
    });

    test('order-sensitive: different content => different hash', () {
      final single = extContentHash({'a.txt': 'b'});
      expect(single, isNot(extContentHash({'a.txt': 'c'})));
    });
  });
}
