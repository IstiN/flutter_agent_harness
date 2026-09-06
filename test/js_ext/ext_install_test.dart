import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_catalog.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_install.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List zipOf(Map<String, String> files) {
  final archive = Archive();
  final names = files.keys.toList()..sort();
  for (final name in names) {
    final data = _bytes(files[name]!);
    archive.addFile(ArchiveFile(name, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _manifest = '{"name":"sample","kind":"cli-extension","version":"1.0.0"}';

http.Response _json(Object value) =>
    http.Response.bytes(_bytes(jsonEncode(value)), 200);

/// Fake GitHub: repo metadata, refs, raw manifest, codeload archive.
http.Client githubServer({
  String branch = 'main',
  String? sha = 'abc123',
  String manifest = _manifest,
  bool serveManifest = true,
  Uint8List? archive,
  int archiveStatus = 200,
  Map<String, dynamic>? repoJson,
}) {
  return MockClient((request) async {
    final url = request.url;
    if (url.host == 'api.github.com') {
      if (url.path == '/repos/o/r') {
        return _json(repoJson ?? {'default_branch': branch});
      }
      if (url.path == '/repos/o/r/git/refs/heads/$branch') {
        return _json({
          'object': {'sha': sha},
        });
      }
      return http.Response('not found', 404);
    }
    if (url.host == 'raw.githubusercontent.com') {
      if (serveManifest && url.path == '/o/r/$branch/manifest.json') {
        return http.Response.bytes(_bytes(manifest), 200);
      }
      return http.Response('not found', 404);
    }
    if (url.host == 'codeload.github.com') {
      if (archiveStatus != 200) return http.Response('boom', archiveStatus);
      return http.Response.bytes(
        archive ??
            zipOf({
              'repo-$branch/manifest.json': manifest,
              'repo-$branch/main.js': 'export default 1;',
            }),
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

const _userDir = '/home';
const _projectDir = '/proj';

(MemoryExecutionEnv, ExtensionStore) rig() {
  final env = MemoryExecutionEnv();
  return (
    env,
    ExtensionStore(env: env, projectDir: _projectDir, userDir: _userDir),
  );
}

void main() {
  group('planLocalInstall', () {
    test(
      'directory: manifest+main+extra text files, dotfiles skipped',
      () async {
        final (env, _) = rig();
        await env.writeFile('$_projectDir/ext/manifest.json', _manifest);
        await env.writeFile('$_projectDir/ext/main.js', 'console.log(1);');
        await env.writeFile('$_projectDir/ext/README.md', 'hi');
        await env.writeFile('$_projectDir/ext/.hidden.js', 'secret');
        await env.writeFile('$_projectDir/ext/sub/nested.js', 'nested();');

        final plan = await planLocalInstall('$_projectDir/ext', env);

        expect(plan.name, 'sample');
        expect(plan.manifest.name, 'sample');
        expect(plan.trustSource, ExtTrustSource.local);
        expect(plan.trustRef, '$_projectDir/ext');
        expect(
          plan.files.keys,
          containsAll([
            'manifest.json',
            'main.js',
            'README.md',
            'sub/nested.js',
          ]),
        );
        expect(plan.files.containsKey('.hidden.js'), isFalse);
      },
    );

    test('root-less zip extracts with no prefix', () async {
      final (env, _) = rig();
      await env.writeBinaryFile(
        '$_projectDir/ext.zip',
        zipOf({'manifest.json': _manifest, 'main.js': 'zip();'}),
      );

      final plan = await planLocalInstall('$_projectDir/ext.zip', env);

      expect(plan.name, 'sample');
      expect(plan.files['main.js'], 'zip();');
    });

    test('zip with a single root dir strips it', () async {
      final (env, _) = rig();
      await env.writeBinaryFile(
        '$_projectDir/ext.zip',
        zipOf({'sample/manifest.json': _manifest, 'sample/main.js': 'zip();'}),
      );

      final plan = await planLocalInstall('$_projectDir/ext.zip', env);

      expect(plan.files.keys.toSet(), {'manifest.json', 'main.js'});
    });

    test('missing path throws', () async {
      final (env, _) = rig();
      await expectLater(
        planLocalInstall('$_projectDir/nope', env),
        throwsA(isA<ExtInstallException>()),
      );
    });

    test('directory without main.js throws', () async {
      final (env, _) = rig();
      await env.writeFile('$_projectDir/ext/manifest.json', _manifest);
      await expectLater(
        planLocalInstall('$_projectDir/ext', env),
        throwsA(
          isA<ExtInstallException>().having(
            (e) => e.message,
            'message',
            contains('manifest.json and main.js'),
          ),
        ),
      );
    });

    test('zip-slip entry rejected and nothing written', () async {
      final (env, store) = rig();
      await env.writeBinaryFile(
        '$_projectDir/ext.zip',
        zipOf({'manifest.json': _manifest, 'x/../evil.js': 'evil();'}),
      );
      await expectLater(
        planLocalInstall('$_projectDir/ext.zip', env),
        throwsA(isA<ExtCatalogException>()),
      );
      expect((await store.list()).extensions, isEmpty);
    });
  });

  group('planGithubInstall', () {
    test('happy path: branch resolved, sha trusted, root stripped', () async {
      final plan = await planGithubInstall(
        'o/r',
        githubServer(
          archive: zipOf({
            'repo-main/manifest.json': _manifest,
            'repo-main/main.js': 'export default 1;',
            'repo-main/lib/util.js': 'u();',
          }),
        ),
      );

      expect(plan.name, 'sample');
      expect(plan.trustSource, ExtTrustSource.github);
      expect(plan.trustRef, 'o/r@abc123');
      expect(
        plan.files.keys,
        containsAll(['manifest.json', 'main.js', 'lib/util.js']),
      );
    });

    test('missing manifest => named exception', () async {
      await expectLater(
        planGithubInstall('o/r', githubServer(serveManifest: false)),
        throwsA(
          isA<ExtInstallException>().having(
            (e) => e.message,
            'message',
            contains('repo root must contain manifest.json+main.js'),
          ),
        ),
      );
    });

    test('no default_branch and unresolvable ref => HEAD fallback', () async {
      final plan = await planGithubInstall(
        'o/r',
        githubServer(repoJson: {}, sha: null, branch: 'HEAD'),
      );
      expect(plan.trustRef, 'o/r@HEAD');
      expect(plan.files['main.js'], 'export default 1;');
    });

    test('malformed owner/repo rejected', () async {
      await expectLater(
        planGithubInstall('just-a-name', githubServer()),
        throwsA(isA<ExtInstallException>()),
      );
    });
  });

  group('applyInstall', () {
    test('TOFU deny: null prompt writes nothing', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());

      final outcome = await applyInstall(plan, store);

      expect(outcome.installed, isFalse);
      expect(outcome.reason, 'trust required, nothing written');
      expect(await store.find('sample'), isNull);
    });

    test('TOFU prompt accepted => installed and trusted', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());

      ExtTrustRequest? seen;
      final outcome = await applyInstall(
        plan,
        store,
        prompt: (request) async {
          seen = request;
          return true;
        },
      );

      expect(outcome.installed, isTrue);
      expect(seen, isNotNull);
      expect(seen!.name, 'sample');
      expect(seen!.source, ExtTrustSource.github);
      expect(seen!.sourceRef, 'o/r@abc123');
      final installed = await store.find('sample');
      expect(installed, isNotNull);
      expect(installed!.trust, isNotNull);
      expect(installed.trust!.contentSha256, extContentHash(plan.files));
    });

    test('TOFU prompt declined => deny', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());
      final outcome = await applyInstall(
        plan,
        store,
        prompt: (_) async => false,
      );
      expect(outcome.installed, isFalse);
      expect(await store.find('sample'), isNull);
    });

    test('trustFlag grants TOFU without a prompt', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());
      var prompted = false;
      final outcome = await applyInstall(
        plan,
        store,
        trustFlag: true,
        prompt: (_) async {
          prompted = true;
          return false;
        },
      );
      expect(outcome.installed, isTrue);
      expect(prompted, isFalse);
    });

    test('same hash => up-to-date, nothing rewritten', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());
      await applyInstall(plan, store, trustFlag: true);

      var prompted = false;
      final outcome = await applyInstall(
        plan,
        store,
        prompt: (_) async {
          prompted = true;
          return true;
        },
      );

      expect(outcome.installed, isFalse);
      expect(outcome.reason, 'up-to-date');
      expect(prompted, isFalse);
    });

    test('hash-only change => silent re-grant, no prompt', () async {
      final (_, store) = rig();
      await applyInstall(
        await planGithubInstall('o/r', githubServer()),
        store,
        trustFlag: true,
      );
      final before = (await store.find('sample'))!.trust;

      var prompted = false;
      final updated = await planGithubInstall(
        'o/r',
        githubServer(
          archive: zipOf({
            'repo-main/manifest.json': _manifest,
            'repo-main/main.js': 'export default 2;',
          }),
        ),
      );
      final outcome = await applyInstall(
        updated,
        store,
        prompt: (_) async {
          prompted = true;
          return true;
        },
      );

      expect(outcome.installed, isTrue);
      expect(outcome.rePrompted, isFalse);
      expect(prompted, isFalse);
      final after = (await store.find('sample'))!.trust!;
      expect(after.contentSha256, extContentHash(updated.files));
      expect(after.contentSha256, isNot(before!.contentSha256));
      expect((await store.find('sample'))!.mainJs, 'export default 2;');
    });

    test(
      'capability diff => re-prompt; denial keeps the old install',
      () async {
        final (_, store) = rig();
        await applyInstall(
          await planGithubInstall('o/r', githubServer()),
          store,
          trustFlag: true,
        );
        final oldHash = (await store.find('sample'))!.trust!.contentSha256;

        final expandedManifest =
            '{"name":"sample","kind":"cli-extension","version":"2.0.0",'
            '"capabilities":{"tools":true}}';
        final plan = await planGithubInstall(
          'o/r',
          githubServer(
            manifest: expandedManifest,
            archive: zipOf({
              'repo-main/manifest.json': expandedManifest,
              'repo-main/main.js': 'export default 3;',
            }),
          ),
        );

        ExtTrustRequest? seen;
        var denied = await applyInstall(
          plan,
          store,
          prompt: (request) async {
            seen = request;
            return false;
          },
        );
        expect(denied.installed, isFalse);
        expect(seen, isNotNull);
        expect(seen!.previousCapabilities, isNotNull);

        // Old content + old trust untouched after the denial.
        final kept = (await store.find('sample'))!;
        expect(kept.mainJs, 'export default 1;');
        expect(kept.trust!.contentSha256, oldHash);

        final approved = await applyInstall(
          plan,
          store,
          prompt: (_) async => true,
        );
        expect(approved.installed, isTrue);
        expect(approved.rePrompted, isTrue);
        expect((await store.find('sample'))!.mainJs, 'export default 3;');
      },
    );

    test('trustFlag does not bypass an update re-prompt', () async {
      final (_, store) = rig();
      await applyInstall(
        await planGithubInstall('o/r', githubServer()),
        store,
        trustFlag: true,
      );

      final expandedManifest =
          '{"name":"sample","kind":"cli-extension","version":"2.0.0",'
          '"capabilities":{"network":true}}';
      final outcome = await applyInstall(
        await planGithubInstall(
          'o/r',
          githubServer(
            manifest: expandedManifest,
            archive: zipOf({
              'repo-main/manifest.json': expandedManifest,
              'repo-main/main.js': 'export default 4;',
            }),
          ),
        ),
        store,
        trustFlag: true,
      );
      expect(outcome.installed, isFalse);
      expect(outcome.reason, contains('capability change not approved'));
    });

    test('pinned hash mismatch rejects loudly, nothing written', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());
      await expectLater(
        applyInstall(plan, store, trustFlag: true, pinSha256: 'ff' * 32),
        throwsA(
          isA<ExtInstallException>().having(
            (e) => e.message,
            'message',
            contains('pinned hash mismatch'),
          ),
        ),
      );
      expect(await store.find('sample'), isNull);
    });

    test('correct pin installs', () async {
      final (_, store) = rig();
      final plan = await planGithubInstall('o/r', githubServer());
      final outcome = await applyInstall(
        plan,
        store,
        trustFlag: true,
        pinSha256: extContentHash(plan.files),
      );
      expect(outcome.installed, isTrue);
    });
  });

  group('planCatalogInstall', () {
    test('happy path: catalog entry downloaded and planned', () async {
      const id = 'crap-guard';
      final zip = zipOf({
        '$id/manifest.json':
            '{"name":"$id","kind":"cli-extension","version":"1.0.0"}',
        '$id/main.js': 'guard();',
      });
      final client = MockClient((request) async {
        final name = request.url.pathSegments.last;
        if (name == 'catalog.json') {
          return _json({
            'schemaVersion': 2,
            'extensions': [
              {
                'id': id,
                'version': '1.0.0',
                'kind': 'cli-extension',
                'zipFile': '$id-1.0.0.zip',
              },
            ],
          });
        }
        if (name == '$id-1.0.0.zip') {
          return http.Response.bytes(zip, 200);
        }
        return http.Response('not found', 404);
      });

      final plan = await planCatalogInstall(
        id,
        baseUrl: kExtCatalogBaseUrl,
        client: client,
      );

      expect(plan.name, id);
      expect(plan.trustSource, ExtTrustSource.catalog);
      expect(plan.trustRef, id);
      expect(plan.files['main.js'], 'guard();');
    });

    test('unknown catalog id throws', () async {
      await expectLater(
        planCatalogInstall(
          'nope',
          baseUrl: kExtCatalogBaseUrl,
          client: MockClient((request) async => _json({'extensions': []})),
        ),
        throwsA(
          isA<ExtInstallException>().having(
            (e) => e.message,
            'message',
            contains('no extension "nope"'),
          ),
        ),
      );
    });

    test('tampered zip => throw and nothing written', () async {
      const id = 'crap-guard';
      final zip = zipOf({
        '$id/manifest.json': '{"name":"$id"}',
        '$id/main.js': 'guard();',
      });
      final (_, store) = rig();
      final client = MockClient((request) async {
        final name = request.url.pathSegments.last;
        if (name == 'catalog.json') {
          return _json({
            'extensions': [
              {
                'id': id,
                'version': '1.0.0',
                'zipFile': '$id-1.0.0.zip',
                'zipSha256': '00' * 32,
              },
            ],
          });
        }
        if (name == '$id-1.0.0.zip') return http.Response.bytes(zip, 200);
        return http.Response('not found', 404);
      });

      await expectLater(
        planCatalogInstall(id, baseUrl: kExtCatalogBaseUrl, client: client),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('sha256 mismatch'),
          ),
        ),
      );
      expect((await store.list()).extensions, isEmpty);
    });
  });
}
