// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa_widgets_tool/src/validator.dart';
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
      'minRuntime': '1.0.0',
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
  String id = 'pomodoro',
  String version = '1.0.0',
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
    '/repos/octocat/fa_widgets/git/refs/heads/publish/$id-$version',
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
          ..on('GET', '/repos/octocat/fa-widget-pomodoro/git/ref/heads/main', {
            'message': 'Git Repository is empty.',
          }, status: 409)
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b1',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b4',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b2',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b4x',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b3',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b4x',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/trees', {
            'sha': 'tree1',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/commits', {
            'sha': 'commit1',
          })
          ..on('PUT', '/repos/octocat/fa-widget-pomodoro/contents/README.md', {
            'commit': {'sha': 'boot1'},
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
        expect(blobs, hasLength(4));
        expect(blobs, contains('<svg/>\n'));
        expect(blobs, contains('export function render() {}\n'));
        expect(blobs, contains(contains('# Fa Widget: Pomodoro')));
        expect(blobs.any((c) => c.contains('secret')), isFalse);

        // The widget tree is a full snapshot: README + widget sources,
        // no base_tree (so earlier garbage cannot survive a re-publish).
        final treeBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/trees')
              .single,
        );
        expect(treeBody.containsKey('base_tree'), isFalse);
        final treePaths = (treeBody['tree'] as List<dynamic>)
            .map((e) => (e as Map)['path'])
            .toList();
        expect(
          treePaths,
          containsAll(['README.md', 'manifest.json', 'widget.js', 'icon.svg']),
        );
        final commitBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/commits')
              .single,
        );
        expect(commitBody['message'], 'Publish pomodoro 1.0.0');
        expect(commitBody['parents'], ['boot1']);

        // AC1 (#232): the publish PR tree contains ONLY the overlay file —
        // no .gitmodules entry, no vendor/external/* gitlink.
        final prTree = gh.bodyOf(
          gh.where('POST', '/repos/octocat/fa_widgets/git/trees').single,
        );
        expect(prTree['base_tree'], 'forkbase');
        final entries = prTree['tree'] as List<dynamic>;
        final entryPaths = entries.map((e) => (e as Map)['path']).toList();
        expect(entryPaths, ['widgets/pomodoro/overlay.json']);
        expect(
          entries.any((e) => (e as Map)['mode'] == '160000'),
          isFalse,
          reason: 'no gitlink entries in the publish PR',
        );

        // Overlay: source pin + manifest extras — the ONLY fork blob.
        final prBlobRequests = gh
            .where('POST', '/repos/octocat/fa_widgets/git/blobs')
            .toList();
        expect(prBlobRequests, hasLength(1));
        final prBlobs = prBlobRequests
            .map(
              (r) =>
                  utf8.decode(base64Decode(gh.bodyOf(r)['content'] as String)),
            )
            .toList();
        expect(prBlobs.single.contains('[submodule'), isFalse);
        final overlay = jsonDecode(prBlobs.single) as Map<String, dynamic>;
        expect(overlay['icon'], 'icon.svg');
        expect(overlay['author'], 'octocat');
        expect(overlay['tags'], ['productivity']);
        // Issue #1045 AC2: the manifest's minRuntime rides through;
        // the floor stamp only fills a MISSING/empty value.
        expect(overlay['minRuntime'], '1.0.0');
        expect(overlay['source'], {
          'repo': 'octocat/fa-widget-pomodoro',
          'commit': 'commit1',
        });

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

    test('widgetRelativePath anchors on the widget folder name', () {
      JsAppInfo app(String id) => JsAppInfo(
        id: id,
        name: 'Pomodoro',
        description: 'Focus timer',
        icon: '🍅',
        version: '1.0.0',
        declaredPermissions: const AppPermissions(),
      );

      final pomodoro = app('pomodoro');
      // macOS shape: the walk reports host-absolute paths while app.dir is
      // sandbox-relative — the widget-root cut must still be right.
      expect(
        WidgetPublishService.widgetRelativePath(
          pomodoro,
          '/Users/u/proj/apps/pomodoro/manifest.json',
        ),
        'manifest.json',
      );
      // Sandbox-relative walk paths keep working.
      expect(
        WidgetPublishService.widgetRelativePath(
          pomodoro,
          'apps/pomodoro/deep/dir/widget.js',
        ),
        'deep/dir/widget.js',
      );
      // Outside the widget folder → never published.
      expect(
        WidgetPublishService.widgetRelativePath(
          pomodoro,
          '/Users/u/other/thing.json',
        ),
        isNull,
      );
      // The FIRST folder occurrence wins: a same-named directory nested
      // inside the widget stays nested instead of collapsing.
      expect(
        WidgetPublishService.widgetRelativePath(
          pomodoro,
          '/p/apps/pomodoro/sub/pomodoro/x.js',
        ),
        'sub/pomodoro/x.js',
      );
      // A different widget's files are outside this widget's folder.
      expect(
        WidgetPublishService.widgetRelativePath(
          app('clock'),
          '/Users/u/proj/apps/pomodoro/manifest.json',
        ),
        isNull,
      );
    });

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
            'sha': 'b4x',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b2',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b4x',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b3',
          })
          ..on('POST', '/repos/octocat/fa-widget-pomodoro/git/blobs', {
            'sha': 'b4x',
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
        // Update commit is based on the previous head, and the tree is a
        // full snapshot (no base_tree): the repo root stays exactly the
        // widget sources + README.
        final treeBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/trees')
              .single,
        );
        expect(treeBody.containsKey('base_tree'), isFalse);
        expect(
          (treeBody['tree'] as List<dynamic>).map((e) => (e as Map)['path']),
          contains('README.md'),
        );
        final commitBody = gh.bodyOf(
          gh
              .where('POST', '/repos/octocat/fa-widget-pomodoro/git/commits')
              .single,
        );
        expect(commitBody['parents'], ['head1']);
        // AC3 (#232): a republish touches ONLY the overlay — one fork tree
        // entry, no shared-file churn.
        final forkTree = gh.bodyOf(
          gh.where('POST', '/repos/octocat/fa_widgets/git/trees').single,
        );
        expect(
          (forkTree['tree'] as List<dynamic>).map((e) => (e as Map)['path']),
          ['widgets/pomodoro/overlay.json'],
        );
      },
    );

    test('AC2 (#232): two devices publish disjoint single-file PRs', () async {
      // Two independent devices (separate env + ledger), each past the
      // repo step, publish different widgets against one catalog fork.
      final gh = _ScriptedGithub();
      for (final (id, prNumber) in [('pomodoro', 11), ('timer', 12)]) {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env, id: id);
        final ledger = await WidgetPublicationStore.load(env);
        await ledger.record(
          WidgetPublication(
            widgetId: id,
            version: '1.0.0',
            repoFullName: 'octocat/fa-widget-$id',
            repoCommit: 'sha-$id',
            step: WidgetPublication.stepRepoPushed,
            submittedAt: DateTime.utc(2026, 1, 31),
          ),
        );
        _scriptForkAndPr(
          gh,
          widgetSha: 'sha-$id',
          id: id,
          forkExists: true,
          prNumber: prNumber,
        );
        final service = _service(env, await _connectedAccount(), ledger, gh);
        final result = await service.publish(app: app);
        expect(result.publication.prNumber, prNumber);
      }
      // Each PR tree touches exactly ONE file — its own overlay — so
      // parallel PRs can never conflict (no shared .gitmodules left).
      final trees = gh
          .where('POST', '/repos/octocat/fa_widgets/git/trees')
          .map(
            (r) => (gh.bodyOf(r)['tree'] as List<dynamic>)
                .map((e) => (e as Map)['path'] as String)
                .toSet(),
          )
          .toList();
      expect(trees, [
        {'widgets/pomodoro/overlay.json'},
        {'widgets/timer/overlay.json'},
      ]);
      expect(trees[0].intersection(trees[1]), isEmpty);
    });

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
        // The overlay source pin still points at the commit recorded
        // before the kill.
        final prTree = gh.bodyOf(
          gh.where('POST', '/repos/octocat/fa_widgets/git/trees').single,
        );
        final entryPaths = (prTree['tree'] as List<dynamic>)
            .map((e) => (e as Map)['path'])
            .toList();
        expect(entryPaths, ['widgets/pomodoro/overlay.json']);
        final overlay =
            jsonDecode(
                  utf8.decode(
                    base64Decode(
                      gh.bodyOf(
                            gh
                                .where(
                                  'POST',
                                  '/repos/octocat/fa_widgets/git/blobs',
                                )
                                .single,
                          )['content']
                          as String,
                    ),
                  ),
                )
                as Map<String, dynamic>;
        expect(overlay['source'], {
          'repo': 'octocat/fa-widget-pomodoro',
          'commit': 'deadbeef',
        });
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

    test('refresh snapshots reviewer comments into the ledger', () async {
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
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', _pullJson(42))
        ..on('GET', '/repos/IstiN/fa_widgets/issues/42/comments', [
          {
            'user': {'login': 'IstiN'},
            'body': 'Please bump the icon size.',
            'created_at': '2026-02-02T10:00:00Z',
          },
        ])
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42/comments', [
          {
            'user': {'login': 'IstiN'},
            'body': 'manifest.json line 3: semver ok',
            'created_at': '2026-02-02T09:00:00Z',
          },
        ]);
      await _service(
        env,
        await _connectedAccount(),
        ledger,
        gh,
      ).refreshStatus(publication);
      final comments = ledger.byWidgetId('pomodoro')!.comments;
      expect(comments, hasLength(2));
      // Conversation + review comments merge date-sorted, oldest first.
      expect(comments[0].body, 'manifest.json line 3: semver ok');
      expect(comments[0].isReview, isTrue);
      expect(comments[1].author, 'IstiN');
      expect(comments[1].body, 'Please bump the icon size.');
      expect(comments[1].isReview, isFalse);
      // Persisted for the next app start (kill-resume parity with state).
      final reloaded = await WidgetPublicationStore.load(env);
      expect(reloaded.byWidgetId('pomodoro')!.comments, hasLength(2));
      expect(
        reloaded.byWidgetId('pomodoro')!.comments[1].body,
        'Please bump the icon size.',
      );
    });

    test('comment fetch failure degrades to a state-only refresh', () async {
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
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', {
          ..._pullJson(42),
          'state': 'closed',
          'merged_at': '2026-02-02T00:00:00Z',
        })
        ..on('GET', '/repos/IstiN/fa_widgets/issues/42/comments', {
          'message': 'boom',
        }, status: 500)
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42/comments', {
          'message': 'boom',
        }, status: 500);
      await _service(
        env,
        await _connectedAccount(),
        ledger,
        gh,
      ).refreshStatus(publication);
      final stored = ledger.byWidgetId('pomodoro')!;
      expect(stored.lastKnownState, 'merged');
      expect(stored.comments, isEmpty);
    });

    test('comment snapshot is capped at the newest 50', () async {
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
      List<Map<String, Object?>> commentAt(int minute) => [
        {
          'user': {'login': 'IstiN'},
          'body': 'c$minute',
          'created_at':
              '2026-02-02T00:${minute.toString().padLeft(2, '0')}:00Z',
        },
      ];
      final issueComments = [for (var i = 0; i < 60; i++) ...commentAt(i)];
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', _pullJson(42))
        ..on('GET', '/repos/IstiN/fa_widgets/issues/42/comments', issueComments)
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42/comments', []);
      await _service(
        env,
        await _connectedAccount(),
        ledger,
        gh,
      ).refreshStatus(publication);
      final comments = ledger.byWidgetId('pomodoro')!.comments;
      expect(comments, hasLength(50));
      expect(comments.first.body, 'c10');
      expect(comments.last.body, 'c59');
    });

    test('an unchanged poll tick does not rewrite the ledger', () async {
      final env = MemoryExecutionEnv();
      final ledger = await WidgetPublicationStore.load(env);
      await ledger.record(
        WidgetPublication(
          widgetId: 'pomodoro',
          version: '1.0.0',
          repoFullName: 'octocat/fa-widget-pomodoro',
          repoCommit: 'abc',
          step: WidgetPublication.stepPrOpened,
          submittedAt: DateTime.utc(2026, 2, 1),
          prNumber: 42,
          lastKnownState: WidgetPublication.stateOpen,
          comments: [
            WidgetPublicationComment(
              author: 'IstiN',
              body: 'Looks good.',
              createdAt: DateTime.utc(2026, 2, 2, 9),
              isReview: false,
            ),
          ],
        ),
      );
      // The poller ticks every 5 minutes: a no-change tick must not
      // persist (no file rewrite, no listener spam).
      var records = 0;
      ledger.addListener(() => records++);
      // Scripted responders are one-shot: a fresh transport per tick.
      Map<String, Object?> comment(String body, String at) => {
        'user': {'login': 'IstiN'},
        'body': body,
        'created_at': at,
      };
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', _pullJson(42))
        ..on('GET', '/repos/IstiN/fa_widgets/issues/42/comments', [
          comment('Looks good.', '2026-02-02T09:00:00Z'),
        ])
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42/comments', []);
      final account = await _connectedAccount();
      final publication = ledger.byWidgetId('pomodoro')!;

      await _service(env, account, ledger, gh).refreshStatus(publication);
      expect(records, 0);

      // One new comment lands: exactly one persist.
      final gh2 = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', _pullJson(42))
        ..on('GET', '/repos/IstiN/fa_widgets/issues/42/comments', [
          comment('Looks good.', '2026-02-02T09:00:00Z'),
          comment('Merging after CI.', '2026-02-02T10:00:00Z'),
        ])
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/42/comments', []);
      await _service(env, account, ledger, gh2).refreshStatus(publication);
      expect(records, 1);
      expect(ledger.byWidgetId('pomodoro')!.comments, hasLength(2));
    });
  });

  // Issue #1045 regression pins: the on-device preflight must surface the
  // fa_widgets rule engine's VERBATIM errors (no swallowing), and the
  // stamped manifest must never leave minRuntime empty (the PR #8 killer).
  group('WidgetPublishService preflight engine parity (#1045)', () {
    test(
      'missing minRuntime never publishes empty - floor stamped (PR #8)',
      () async {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env);
        // Strip minRuntime entirely — the PR #8 failure shape. Seed again
        // without the key (the helper pins it) by overwriting the manifest.
        await env.writeFile(
          'apps/pomodoro/manifest.json',
          jsonEncode({
            'id': 'pomodoro',
            'name': 'Pomodoro',
            'description': 'Focus timer',
            'version': '1.0.0',
            'icon': '🍅',
            'tags': ['productivity'],
          }),
        );

        final service = _service(
          env,
          await _connectedAccount(),
          await WidgetPublicationStore.load(env),
          _ScriptedGithub(),
        );
        final issues = await service.preflight(app);
        // The floor satisfies the engine (AC2): the widget publishes with
        // minRuntime=0.4.79 instead of dying in CI with ERROR 2048.
        expect(issues.where((i) => i.message.contains('minRuntime')), isEmpty);
        expect(
          WidgetPublishService.stampedManifest(const {
            'minRuntime': null,
          })['minRuntime'],
          WidgetPublishService.catalogFloorRuntime,
        );
      },
    );

    test(
      'preflight errors are byte-identical to the engine (REG1 parity)',
      () async {
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env, version: 'not-semver');
        final service = _service(
          env,
          await _connectedAccount(),
          await WidgetPublicationStore.load(env),
          _ScriptedGithub(),
        );
        final issues = await service.preflight(app);
        final preflightMessages = issues.map((i) => i.message).toSet();

        // The same broken manifest straight through the engine (with the
        // service's minRuntime stamp, which the service also applies).
        final parent = await Directory.systemTemp.createTemp('parity');
        // The engine also enforces folder-name == id; mirror the app layout.
        final dir = Directory('${parent.path}/pomodoro')..createSync();
        final manifest = WidgetPublishService.stampedManifest(<String, Object?>{
          'id': 'pomodoro',
          'name': 'Pomodoro',
          'description': 'Focus timer',
          'version': 'not-semver',
          'minRuntime': '1.0.0',
          'icon': 'icon.svg',
        });
        await File(
          '${dir.path}/manifest.json',
        ).writeAsString(jsonEncode(manifest));
        await File('${dir.path}/widget.js').writeAsString('x');
        await File('${dir.path}/icon.svg').writeAsString('<svg/>');
        final engine = validateWidgetDirectory(dir);
        parent.deleteSync(recursive: true);

        expect(engine.errors, isNotEmpty);
        for (final error in engine.errors) {
          expect(
            preflightMessages,
            contains(error.message),
            reason: 'engine error must surface verbatim: ${error.message}',
          );
        }
      },
    );

    test('empty minRuntime is stamped to the catalog floor (AC2)', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(
        env,
        manifestExtra: const {'minRuntime': '  '},
      );
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        _ScriptedGithub(),
      );
      final issues = await service.preflight(app);
      // The floor satisfies the engine: preflight must NOT block on
      // minRuntime, and publish-time overlay carries the stamped value.
      expect(issues.where((i) => i.message.contains('minRuntime')), isEmpty);
      expect(
        WidgetPublishService.stampedManifest(const {})['minRuntime'],
        WidgetPublishService.catalogFloorRuntime,
      );
    });

    test('invalid minRuntime semver reported verbatim', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(
        env,
        manifestExtra: const {'minRuntime': '1.0'},
      );
      final service = _service(
        env,
        await _connectedAccount(),
        await WidgetPublicationStore.load(env),
        _ScriptedGithub(),
      );
      final issues = await service.preflight(app);
      expect(issues, isNotEmpty);
      expect(
        issues.any((i) => i.message.contains("minRuntime '1.0' must be")),
        isTrue,
      );
    });
  });

  // Issue #1045 review round-1: service-level pins for the CI-verdict
  // mapping (AC3) and the fire-and-forget ledger lifecycle (AC6/I4).
  group('WidgetPublishService CI verdict mapping (#1045)', () {
    WidgetPublication prPublication() => WidgetPublication(
      widgetId: 'pomodoro',
      version: '1.0.0',
      repoFullName: 'octocat/fa-widget-pomodoro',
      repoCommit: 'abc',
      step: WidgetPublication.stepPrOpened,
      submittedAt: DateTime.utc(2026, 2, 1),
      prNumber: 42,
    );

    Map<String, Object?> checkRun(
      int id, {
      String status = 'completed',
      String? conclusion = 'failure',
      String? htmlUrl,
    }) => {
      'id': id,
      'status': status,
      'conclusion': ?conclusion,
      'html_url':
          htmlUrl ??
          'https://github.com/IstiN/fa_widgets/actions/runs/9/job/$id',
    };

    Future<(MemoryExecutionEnv, WidgetPublicationStore, WidgetPublication)>
    seeded() async {
      final env = MemoryExecutionEnv();
      final ledger = await WidgetPublicationStore.load(env);
      final publication = await ledger.record(prPublication());
      return (env, ledger, publication);
    }

    _ScriptedGithub checksOn(String sha, Map<String, Object?> runs) =>
        _ScriptedGithub()
          ..on('GET', '/repos/IstiN/fa_widgets/pulls/42', {
            ..._pullJson(42),
            'head': {'sha': sha},
          })
          ..on('GET', '/repos/IstiN/fa_widgets/commits/$sha/check-runs', runs);

    test(
      'failed validate check → invalid with verbatim job-log errors',
      () async {
        final (env, ledger, publication) = await seeded();
        final gh =
            checksOn('deadbeef', {
              'total_count': 2,
              'check_runs': [
                checkRun(1, conclusion: 'success'),
                checkRun(
                  2,
                  conclusion: 'failure',
                  htmlUrl:
                      'https://github.com/IstiN/fa_widgets/actions/runs/99/job/2',
                ),
              ],
            })..on(
              'GET',
              '/repos/IstiN/fa_widgets/actions/jobs/2/logs',
              'ERROR 2048: external manifest: minRuntime must be a '
                  'non-empty string.\n',
            );

        final account = await _connectedAccount();
        final state = await _service(
          env,
          account,
          ledger,
          gh,
        ).refreshStatus(publication);

        expect(state, WidgetPublicationState.invalid);
        final stored = ledger.byWidgetId('pomodoro')!;
        expect(stored.validatorErrors, isNotEmpty);
        expect(
          stored.validatorErrors.join('\n'),
          contains('ERROR 2048: external manifest: minRuntime'),
        );
        expect(stored.runHtmlUrl, contains('actions/runs/99'));
      },
    );

    test('timed_out validate check counts as failed, not open', () async {
      final (env, ledger, publication) = await seeded();
      final gh = checksOn('deadbeef', {
        'total_count': 1,
        'check_runs': [checkRun(3, conclusion: 'timed_out')],
      })..on('GET', '/repos/IstiN/fa_widgets/actions/jobs/3/logs', '');

      final account = await _connectedAccount();
      final state = await _service(
        env,
        account,
        ledger,
        gh,
      ).refreshStatus(publication);
      expect(state, WidgetPublicationState.invalid);
    });

    test('pending checks → validating; green checks → open', () async {
      final (env, ledger, publication) = await seeded();
      final account = await _connectedAccount();

      final gh1 = checksOn('deadbeef', {
        'total_count': 1,
        'check_runs': [checkRun(4, status: 'in_progress', conclusion: null)],
      });
      expect(
        await _service(env, account, ledger, gh1).refreshStatus(publication),
        WidgetPublicationState.validating,
      );

      final gh2 = checksOn('deadbeef', {
        'total_count': 1,
        'check_runs': [checkRun(5, conclusion: 'success')],
      });
      expect(
        await _service(env, account, ledger, gh2).refreshStatus(publication),
        WidgetPublicationState.open,
      );
      expect(ledger.byWidgetId('pomodoro')!.lastKnownState, 'open');
    });
    test('non-ERROR crash log still surfaces verbatim CI lines', () async {
      // A `dart run` step that dies without an `error`-shaped line (Dart
      // compile crashes print `Error:`, an OOM kill prints nothing) must
      // not store an empty validatorErrors list — the ticket's headline
      // outcome is verbatim errors with no digging into CI (r2 review).
      final (env, ledger, publication) = await seeded();
      final account = await _connectedAccount();
      final gh =
          checksOn('deadbeef', {
            'total_count': 1,
            'check_runs': [checkRun(7, conclusion: 'failure')],
          })..on(
            'GET',
            '/repos/IstiN/fa_widgets/actions/jobs/7/logs',
            '2026-10-01T00:00:00.000Z Build flutter assemble\n'
                '2026-10-01T00:00:01.000Z Unhandled exception:\n'
                '2026-10-01T00:00:01.100Z OSError (code = -9, errno = 9)\n'
                '2026-10-01T00:00:02.000Z Process completed with exit code 255\n',
            status: 200,
          );
      final state = await _service(
        env,
        account,
        ledger,
        gh,
      ).refreshStatus(publication);
      expect(state, WidgetPublicationState.invalid);
      final stored = ledger.byWidgetId('pomodoro')!;
      expect(stored.validatorErrors, isNotEmpty);
      expect(
        stored.validatorErrors.join('\n'),
        contains('OSError (code = -9, errno = 9)'),
      );
    });
  });

  group('WidgetPublishService fire-and-forget lifecycle (#1045)', () {
    test('retry after a failed first publish recomputes the repo', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env);
      final account = await _connectedAccount();
      final ledger = await WidgetPublicationStore.load(env);

      // First attempt dies at the network boundary (nothing scripted).
      final ghFail = _ScriptedGithub();
      await expectLater(
        _service(env, account, ledger, ghFail).publish(app: app),
        throwsA(isA<GithubApiException>()),
      );
      final failed = ledger.byWidgetId('pomodoro')!;
      expect(failed.lastKnownState, WidgetPublication.stateFailed);
      expect(failed.repoFullName, isEmpty);

      // Retry must route the REAL repo path — the blocker was a retry
      // hitting GET /repos// from the empty optimistic record.
      final ghRetry = _ScriptedGithub()
        ..on('GET', '/repos/octocat/fa-widget-pomodoro', {
          'full_name': 'octocat/fa-widget-pomodoro',
          'private': false,
          'description': 'Fa widget: Pomodoro',
        });
      await expectLater(
        _service(env, account, ledger, ghRetry).publish(app: app),
        throwsA(isA<GithubApiException>()),
      );
      final paths = ghRetry.requests.map((r) => r.url.path).toList();
      expect(paths, contains('/repos/octocat/fa-widget-pomodoro'));
      expect(paths, everyElement(isNot(contains('//'))));
    });

    test('second startPublish while a flow is in flight fails fast', () async {
      final env = MemoryExecutionEnv();
      final app = await _seedWidget(env);
      final account = await _connectedAccount();
      final ledger = await WidgetPublicationStore.load(env);
      final service = _service(env, account, ledger, _ScriptedGithub());

      // The guard is claimed synchronously (before the first await), so
      // the second call trips it even before the first flow progresses.
      final first = service.startPublish(app: app);
      await expectLater(
        service.startPublish(app: app),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('publish_in_progress'),
          ),
        ),
      );
      final pending = await first;
      // The flow dies on the unscripted transport — swallow the expected
      // error so it is not an unhandled async failure.
      pending.flow.ignore();
    });

    test(
      'the in-flight guard is process-wide, not per service instance',
      () async {
        // Every publish entry point (launcher menu, account section, apps
        // panel) constructs its OWN WidgetPublishService — the guard must
        // live per widget, not per instance (issue #1045 review r2).
        final env = MemoryExecutionEnv();
        final app = await _seedWidget(env);
        final account = await _connectedAccount();
        final ledger = await WidgetPublicationStore.load(env);
        final first = _service(
          env,
          account,
          ledger,
          _ScriptedGithub(),
        ).startPublish(app: app);
        await expectLater(
          _service(
            env,
            account,
            ledger,
            _ScriptedGithub(),
          ).startPublish(app: app),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('publish_in_progress'),
            ),
          ),
        );
        final pending = await first;
        pending.flow.ignore();
      },
    );
  });
}
