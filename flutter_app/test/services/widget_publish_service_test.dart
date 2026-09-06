// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Scripted GitHub API: an ordered list of (method, path) → responder; the
/// first match is consumed, so repeated calls (blobs) script in order.
final class _ScriptedGithub {
  final requests = <http.Request>[];
  final _responders = <_Responder>[];

  void on(
    String method,
    String path,
    Object? responseBody, {
    int status = 200,
  }) {
    _responders.add(
      _Responder(
        method,
        path,
        status,
        responseBody == null ? '' : jsonEncode(responseBody),
      ),
    );
  }

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;

  Iterable<http.Request> where(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path);

  http.Client get client => MockClient((request) async {
    requests.add(request);
    for (var i = 0; i < _responders.length; i++) {
      final responder = _responders[i];
      if (request.method == responder.method &&
          request.url.path == responder.path) {
        _responders.removeAt(i);
        return http.Response(responder.body, responder.status);
      }
    }
    return http.Response(
      jsonEncode({
        'message': 'unscripted ${request.method} ${request.url.path}',
      }),
      500,
    );
  });
}

final class _Responder {
  _Responder(this.method, this.path, this.status, this.body);
  final String method;
  final String path;
  final int status;
  final String body;
}

Map<String, Object?> _repoJson(
  String fullName, {
  bool private = false,
  String? description,
}) => {
  'full_name': fullName,
  'private': private,
  'default_branch': 'main',
  'description': ?description,
};

Map<String, Object?> _pullJson(int number) => {
  'number': number,
  'url': 'https://api.github.com/repos/IstiN/fa_widgets/pulls/$number',
  'html_url': 'https://github.com/IstiN/fa_widgets/pull/$number',
  'state': 'open',
  'title': 'Add widget pomodoro 1.0.0',
};

Future<JsAppInfo> _seedWidget(
  MemoryExecutionEnv env, {
  String id = 'pomodoro',
  String version = '1.0.0',
  Map<String, Object?> manifestExtra = const {},
}) async {
  await env.writeFile(
    'apps/$id/manifest.json',
    jsonEncode({
      'id': id,
      'name': 'Pomodoro',
      'description': 'Focus timer',
      'version': version,
      'icon': '🍅',
      'tags': ['productivity'],
      'minRuntime': '1.0',
      ...manifestExtra,
    }),
  );
  await env.writeFile('apps/$id/widget.js', 'export function render() {}\n');
  await env.writeFile('apps/$id/icon.svg', '<svg/>\n');
  return JsAppInfo(
    id: id,
    name: 'Pomodoro',
    description: 'Focus timer',
    icon: '🍅',
    version: version,
    declaredPermissions: const AppPermissions(),
  );
}

Future<GithubAccountStore> _connectedAccount() async {
  final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
  await account.connect(token: 't', login: 'octocat');
  return account;
}

WidgetPublishService _service(
  MemoryExecutionEnv env,
  GithubAccountStore account,
  WidgetPublicationStore ledger,
  _ScriptedGithub gh,
) {
  return WidgetPublishService(
    env: env,
    account: account,
    ledger: ledger,
    clientFactory: (token) =>
        GithubApiClient(token: token, httpClient: gh.client),
    clock: () => DateTime.utc(2026, 2, 1, 12),
    sleep: (_) async {},
  );
}

/// Scripts the full fork → branch → PR step on `octocat/fa_widgets`
/// (fork absent: 404 → POST forks → poll → ready).
void _scriptForkAndPr(
  _ScriptedGithub gh, {
  required String widgetSha,
  bool forkExists = false,
  bool branchExists = false,
  Object? openPulls,
  int? prNumber,
}) {
  if (forkExists) {
    gh.on('GET', '/repos/octocat/fa_widgets', _repoJson('octocat/fa_widgets'));
  } else {
    gh.on('GET', '/repos/octocat/fa_widgets', {'message': 'nf'}, status: 404);
    gh.on('POST', '/repos/IstiN/fa_widgets/forks', {}, status: 202);
    gh.on('GET', '/repos/octocat/fa_widgets', _repoJson('octocat/fa_widgets'));
  }
  gh.on('GET', '/repos/octocat/fa_widgets/git/ref/heads/main', {
    'object': {'sha': 'forkbase'},
  });
  gh.on('POST', '/repos/octocat/fa_widgets/git/blobs', {'sha': 'ob1'});
  gh.on('POST', '/repos/octocat/fa_widgets/git/blobs', {'sha': 'ob2'});
  gh.on('POST', '/repos/octocat/fa_widgets/git/trees', {'sha': 'ptree'});
  gh.on('POST', '/repos/octocat/fa_widgets/git/commits', {'sha': 'pcommit'});
  gh.on(
    'POST',
    '/repos/octocat/fa_widgets/git/refs',
    branchExists ? {'message': 'Reference already exists'} : {},
    status: branchExists ? 422 : 201,
  );
  gh.on(
    'PATCH',
    '/repos/octocat/fa_widgets/git/refs/heads/publish/pomodoro-1.0.0',
    {},
  );
  gh.on('GET', '/repos/IstiN/fa_widgets/pulls', openPulls ?? const []);
  if (prNumber != null) {
    gh.on(
      'POST',
      '/repos/IstiN/fa_widgets/pulls',
      _pullJson(prNumber),
      status: 201,
    );
  }
}

void main() {
  group('WidgetPublicationStore', () {
    test('missing file loads empty; record persists immediately', () async {
      final env = MemoryExecutionEnv();
      final store = await WidgetPublicationStore.load(env);
      expect(store.publications, isEmpty);

      await store.record(
        WidgetPublication(
          widgetId: 'pomodoro',
          version: '1.0.0',
          repoFullName: 'octocat/fa-widget-pomodoro',
          repoCommit: 'abc',
          step: WidgetPublication.stepRepoPushed,
          submittedAt: DateTime.utc(2026, 2, 1),
        ),
      );
      final onDisk = (await env.readTextFile(
        WidgetPublicationStore.fileName,
      )).valueOrNull!;
      expect(jsonDecode(onDisk), {
        'version': 1,
        'items': [isA<Map<String, Object?>>()],
      });

      final reloaded = await WidgetPublicationStore.load(env);
      final p = reloaded.byWidgetId('pomodoro')!;
      expect(p.repoCommit, 'abc');
      expect(p.step, 'repo_pushed');
      expect(p.lastKnownState, 'open');
      expect(p.prNumber, isNull);
    });

    test('corrupt file loads empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(WidgetPublicationStore.fileName, '{not json');
      expect((await WidgetPublicationStore.load(env)).publications, isEmpty);
    });

    test('record upserts by widgetId and notifies', () async {
      final env = MemoryExecutionEnv();
      final store = await WidgetPublicationStore.load(env);
      var notifications = 0;
      store.addListener(() => notifications++);
      await store.record(
        WidgetPublication(
          widgetId: 'pomodoro',
          version: '1.0.0',
          repoFullName: 'octocat/fa-widget-pomodoro',
          repoCommit: 'abc',
          step: WidgetPublication.stepRepoPushed,
          submittedAt: DateTime.utc(2026, 2, 1),
        ),
      );
      await store.record(
        WidgetPublication(
          widgetId: 'pomodoro',
          version: '1.0.0',
          repoFullName: 'octocat/fa-widget-pomodoro',
          repoCommit: 'def',
          step: WidgetPublication.stepPrOpened,
          submittedAt: DateTime.utc(2026, 2, 1, 1),
          prNumber: 42,
          prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/42',
        ),
      );
      expect(notifications, 2);
      expect(store.publications, hasLength(1));
      final p = store.byWidgetId('pomodoro')!;
      expect(p.repoCommit, 'def');
      expect(p.step, 'pr_opened');
      expect(p.prNumber, 42);
    });

    test('publications are newest first', () async {
      final env = MemoryExecutionEnv();
      final store = await WidgetPublicationStore.load(env);
      for (final (id, day) in [('a', 1), ('b', 3), ('c', 2)]) {
        await store.record(
          WidgetPublication(
            widgetId: id,
            version: '1.0.0',
            repoFullName: 'o/r-$id',
            repoCommit: 'x',
            step: WidgetPublication.stepPrOpened,
            submittedAt: DateTime.utc(2026, 2, day),
          ),
        );
      }
      expect(store.publications.map((p) => p.widgetId).toList(), [
        'b',
        'c',
        'a',
      ]);
    });
  });

  group('WidgetPublishService.preflight', () {
    test('clean widget passes', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env);
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        _ScriptedGithub(),
      );
      expect(await service.preflight(app), isEmpty);
    });

    test('catches bad id + missing entry + oversized folder', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env, id: 'Bad_Id');
      await env.remove('apps/Bad_Id/widget.js');
      await env.writeBinaryFile(
        'apps/Bad_Id/big.bin',
        Uint8List(WidgetPublishService.maxFolderBytes + 1),
      );
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        _ScriptedGithub(),
      );
      final codes = (await service.preflight(app)).map((i) => i.code).toSet();
      expect(
        codes,
        containsAll(['id_invalid', 'entry_missing', 'folder_too_large']),
      );
    });

    test('catches manifest id mismatch and bad semver', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env, version: '1.0');
      // Manifest id deliberately different from the folder name.
      await env.writeFile(
        'apps/pomodoro/manifest.json',
        jsonEncode({'id': 'other', 'version': '1.0'}),
      );
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        _ScriptedGithub(),
      );
      final codes = (await service.preflight(app)).map((i) => i.code).toSet();
      expect(codes, containsAll(['manifest_id_mismatch', 'version_invalid']));
    });
  });

  group('WidgetPublishService.publish', () {
    test('throws when no GitHub account is connected', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env);
      final gh = _ScriptedGithub();
      final service = _service(
        env,
        GithubAccountStore(keys: SessionKeysStore.inMemory()),
        await WidgetPublicationStore.load(env),
        gh,
      );
      await expectLater(
        service.publish(app: app),
        throwsA(isA<GithubNotConnectedException>()),
      );
      expect(gh.requests, isEmpty);
    });

    test(
      'happy path: create repo → push sources → fork → PR, ledger records both steps',
      () async {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env);
        await env.writeFile('apps/pomodoro/storage.json', '{"secret": 1}');
        final gh = _ScriptedGithub()
          // Repo step: repo does not exist → create; empty → null head.
          ..on('GET', '/repos/octocat/fa-widget-pomodoro', {
            'message': 'nf',
          }, status: 404)
          ..on(
            'POST',
            '/user/repos',
            _repoJson('octocat/fa-widget-pomodoro'),
            status: 201,
          )
          ..on(
            'GET',
            '/repos/octocat/fa-widget-pomodoro/git/ref/heads/main',
            {'message': 'nf'},
            status: 404,
          )
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b1',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b2',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b3',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/trees', {
            'sha': 'tree1',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/commits', {
            'sha': 'commit1',
          })
          ..on(
            'PATCH',
            '/repos/octocat/fa-widget-pomodoro/git/refs/heads/main',
            {},
          );
        _scriptForkAndPr(gh, widgetSha: 'commit1', prNumber: 42);

        final ledger = await WidgetPublicationStore.load(env);
        final service = _service(env, await _connectedAccount(), ledger, gh);
        final result = await service.publish(app: app);

        expect(result.reusedPr, isFalse);
        final p = result.publication;
        expect(p.step, WidgetPublication.stepPrOpened);
        expect(p.repoFullName, 'octocat/fa-widget-pomodoro');
        expect(p.repoCommit, 'commit1');
        expect(p.prNumber, 42);
        expect(p.prHtmlUrl, 'https://github.com/IstiN/fa_widgets/pull/42');
        expect(p.lastKnownState, 'open');
        expect(p.submittedAt, DateTime.utc(2026, 2, 1, 12));
        expect(ledger.byWidgetId('pomodoro')!.prNumber, 42);

        // The repo is created PUBLIC with the provenance marker.
        final createBody = gh.bodyOf(gh.where('POST', '/user/repos').single);
        expect(createBody['private'], isFalse);
        expect(createBody['description'], contains('fa-widget:pomodoro'));

        // Exactly the sandbox widget files, storage.json excluded; blob
        // contents round-trip byte-for-byte.
        final blobs = gh
            .where('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs')
            .map(
              (r) =>
                  utf8.decode(base64Decode(gh.bodyOf(r)['content'] as String)),
            )
            .toList();
        expect(blobs, hasLength(3));
        expect(blobs, contains('<svg/>\n'));
        expect(blobs, contains('export function render() {}\n'));
        expect(blobs.any((c) => c.contains('secret')), isFalse);

        // Empty repo: tree without base, commit without parents.
        final treeBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/trees')
              .single,
        );
        expect(treeBody.containsKey('base_tree'), isFalse);
        final commitBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/commits')
              .single,
        );
        expect(commitBody['message'], 'Publish pomodoro 1.0.0');
        expect(commitBody.containsKey('parents'), isFalse);

        // Fork tree: gitlink pinned to the pushed commit + overlay + gitmodules.
        final prTree = gh.bodyOf(
          gh.where('POST', '/repos/octocat/fa_widgets/git/trees').single,
        );
        expect(prTree['base_tree'], 'forkbase');
        final entries = prTree['tree'] as List<dynamic>;
        final gitlink =
            entries.singleWhere(
                  (e) => (e as Map)['path'] == 'vendor/external/pomodoro',
                )
                as Map<String, dynamic>;
        expect(gitlink['mode'], '160000');
        expect(gitlink['sha'], 'commit1');

        // Overlay: source pin + manifest extras.
        final prBlobs = gh
            .where('POST', '/repos/octocat/fa_widgets/git/blobs')
            .map(
              (r) =>
                  utf8.decode(base64Decode(gh.bodyOf(r)['content'] as String)),
            )
            .toList();
        final overlay =
            jsonDecode(prBlobs.singleWhere((c) => c.contains('"source"')))
                as Map<String, dynamic>;
        expect(overlay['icon'], 'icon.svg');
        expect(overlay['author'], 'octocat');
        expect(overlay['tags'], ['productivity']);
        expect(overlay['minRuntime'], '1.0');
        expect(overlay['source'], {
          'repo': 'octocat/fa-widget-pomodoro',
          'commit': 'commit1',
        });
        final gitmodules = prBlobs.singleWhere((c) => c.contains('[submodule'));
        expect(gitmodules, contains('vendor/js_widget_runtime'));
        expect(gitmodules, contains('vendor/external/pomodoro'));

        // One PR, head = <login>:publish/<id>-<version>.
        final prBody = gh.bodyOf(
          gh.where('POST', '/repos/IstiN/fa_widgets/pulls').single,
        );
        expect(prBody['head'], 'octocat:publish/pomodoro-1.0.0');
        expect(prBody['base'], 'main');
        expect(prBody['title'], 'Add widget pomodoro 1.0.0');
        expect(prBody['body'], contains('commit1'));
      },
    );

    test(
      're-publish updates the repo and reuses the open PR (no duplicate)',
      () async {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env);
        final ledger = await WidgetPublicationStore.load(env);
        await ledger.record(
          WidgetPublication(
            widgetId: 'pomodoro',
            version: '1.0.0',
            repoFullName: 'octocat/fa-widget-pomodoro',
            repoCommit: 'oldcommit',
            step: WidgetPublication.stepPrOpened,
            submittedAt: DateTime.utc(2026, 1, 1),
            prNumber: 42,
            prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/42',
          ),
        );
        final gh = _ScriptedGithub()
          // Ledger-recorded repo → provenance holds without the marker.
          ..on(
            'GET',
            '/repos/octocat/fa-widget-pomodoro',
            _repoJson('octocat/fa-widget-pomodoro'),
          )
          ..on('GET', '/repos/octocat/fa-widget-pomodoro/git/ref/heads/main', {
            'object': {'sha': 'head1'},
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b1',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b2',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b3',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/trees', {
            'sha': 'tree2',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/commits', {
            'sha': 'commit2',
          })
          ..on(
            'PATCH',
            '/repos/octocat/fa-widget-pomodoro/git/refs/heads/main',
            {},
          );
        _scriptForkAndPr(
          gh,
          widgetSha: 'commit2',
          forkExists: true,
          branchExists: true, // 422 tolerated
          openPulls: [_pullJson(42)],
        );

        final service = _service(env, await _connectedAccount(), ledger, gh);
        final result = await service.publish(app: app);

        expect(result.reusedPr, isTrue);
        expect(result.publication.repoCommit, 'commit2');
        expect(result.publication.prNumber, 42);
        // No new repo, no new PR.
        expect(gh.where('POST', '/user/repos'), isEmpty);
        expect(gh.where('POST', '/repos/IstiN/fa_widgets/pulls'), isEmpty);
        // Update commit is based on the previous head.
        final treeBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/trees')
              .single,
        );
        expect(treeBody['base_tree'], 'head1');
        final commitBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/commits')
              .single,
        );
        expect(commitBody['parents'], ['head1']);
      },
    );

    test('private existing repo is rejected', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env);
      final gh = _ScriptedGithub()
        ..on(
          'GET',
          '/repos/octocat/fa-widget-pomodoro',
          _repoJson('octocat/fa-widget-pomodoro', private: true),
        );
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        gh,
      );
      await expectLater(
        service.publish(app: app),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('private'),
          ),
        ),
      );
      expect(gh.where('POST', '/user/repos'), isEmpty);
    });

    test(
      'foreign repo (no provenance marker, has commits) is rejected',
      () async {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env);
        final gh = _ScriptedGithub()
          ..on(
            'GET',
            '/repos/octocat/fa-widget-pomodoro',
            _repoJson('octocat/fa-widget-pomodoro', description: 'my project'),
          )
          ..on('GET', '/repos/octocat/fa-widget-pomodoro/git/ref/heads/main', {
            'object': {'sha': 'abc'},
          });
        final service = _service(
          env,
          await _connectedAccount(),
          await WidgetPublicationStore.load(env),
          gh,
        );
        await expectLater(
          service.publish(app: app),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('foreign'),
            ),
          ),
        );
        // Not a single write happened.
        expect(gh.requests.where((r) => r.method != 'GET'), isEmpty);
      },
    );

    test(
      'kill-resume: ledger step repo_pushed skips the repo step (E7)',
      () async {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env);
        final ledger = await WidgetPublicationStore.load(env);
        await ledger.record(
          WidgetPublication(
            widgetId: 'pomodoro',
            version: '1.0.0',
            repoFullName: 'octocat/fa-widget-pomodoro',
            repoCommit: 'deadbeef',
            step: WidgetPublication.stepRepoPushed,
            submittedAt: DateTime.utc(2026, 1, 31),
          ),
        );
        final gh = _ScriptedGithub();
        _scriptForkAndPr(
          gh,
          widgetSha: 'deadbeef',
          forkExists: true,
          prNumber: 7,
        );

        final service = _service(env, await _connectedAccount(), ledger, gh);
        final result = await service.publish(app: app);

        expect(result.publication.step, WidgetPublication.stepPrOpened);
        expect(result.publication.repoCommit, 'deadbeef');
        expect(result.publication.prNumber, 7);
        // The whole repo step was skipped: no repo read/create, no blobs,
        // no ref update on the widget repo.
        expect(gh.where('GET', '/repos/octocat/fa-widget-pomodoro'), isEmpty);
        expect(gh.where('POST', '/user/repos'), isEmpty);
        expect(
          gh.requests.where((r) => r.url.path.contains('fa-widget-pomodoro')),
          isEmpty,
        );
        // The gitlink still pins the commit recorded before the kill.
        final prTree = gh.bodyOf(
          gh.where('POST', '/repos/octocat/fa_widgets/git/trees').single,
        );
        final gitlink =
            (prTree['tree'] as List<dynamic>).singleWhere(
                  (e) => (e as Map)['path'] == 'vendor/external/pomodoro',
                )
                as Map<String, dynamic>;
        expect(gitlink['sha'], 'deadbeef');
      },
    );

    test('preflight failures abort before any network call', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env);
      await env.remove('apps/pomodoro/widget.js');
      final gh = _ScriptedGithub();
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        gh,
      );
      await expectLater(
        service.publish(app: app),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('entry_missing'),
          ),
        ),
      );
      expect(gh.requests, isEmpty);
    });
  });

  group('WidgetPublishService.refreshStatus', () {
    test('maps open / merged / 404 to ledger states', () async {
      final env = MemoryExecutionEnv();
      final ledger = await WidgetPublicationStore.load(env);
      final publication = await ledger.record(
        WidgetPublication(
          widgetId: 'pomodoro',
          version: '1.0.0',
          repoFullName: 'octocat/fa-widget-pomodoro',
          repoCommit: 'abc',
          step: WidgetPublication.stepPrOpened,
          submittedAt: DateTime.utc(2026, 2, 1),
          prNumber: 42,
        ),
      );

      // open → no change.
      final gh1 = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', _pullJson(42));
      final account = await _connectedAccount();
      await _service(env, account, ledger, gh1).refreshStatus(publication);
      expect(ledger.byWidgetId('pomodoro')!.lastKnownState, 'open');

      // closed + merged → 'merged'.
      final gh2 = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', {
          ..._pullJson(42),
          'state': 'closed',
          'merged_at': '2026-02-02T00:00:00Z',
        });
      await _service(env, account, ledger, gh2).refreshStatus(publication);
      expect(ledger.byWidgetId('pomodoro')!.lastKnownState, 'merged');

      // 404 → 'unknown'.
      final gh3 = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', {
          'message': 'nf',
        }, status: 404);
      await _service(env, account, ledger, gh3).refreshStatus(publication);
      expect(ledger.byWidgetId('pomodoro')!.lastKnownState, 'unknown');
    });
  });
}
