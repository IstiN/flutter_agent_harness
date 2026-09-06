// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/github_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted GitHub API: a queue of (pathMatcher → responder).
final class _ScriptedGithub {
  _ScriptedGithub();

  final requests = <http.Request>[];
  final _responders = <_Responder>[];

  void on(String method, String path, Object responseBody, {int status = 200}) {
    _responders.add(_Responder(method, path, status, jsonEncode(responseBody)));
  }

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

void main() {
  group('GithubApiClient', () {
    test('createRepo 403 "not accessible by integration" gets the token hint', () async {
      final gh = _ScriptedGithub()
        ..on(
          'POST',
          '/user/repos',
          {
            'message': 'Resource not accessible by integration',
            'documentation_url':
                'https://docs.github.com/rest/users/users#create-a-user-repository',
          },
          status: 403,
        );
      final client = GithubApiClient(
        token: 'secret-token',
        httpClient: gh.client,
      );
      expect(
        () => client.createRepo(name: 'fa-widget-x'),
        throwsA(
          isA<GithubApiException>().having(
            (e) => e.message,
            'message',
            contains('classic PAT with the public_repo scope'),
          ),
        ),
      );
    });

    test('sends the bearer token only to api.github.com', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/user', {'login': 'octocat', 'avatar_url': 'a'});
      final client = GithubApiClient(
        token: 'secret-token',
        httpClient: gh.client,
      );
      final user = await client.getUser();
      expect(user.login, 'octocat');
      expect(user.avatarUrl, 'a');
      final request = gh.requests.single;
      expect(request.url.host, 'api.github.com');
      expect(request.headers['authorization'], 'Bearer secret-token');
      expect(request.url.scheme, 'https');
    });

    test('getRepo returns null on 404, throws on other errors', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/o/nope', {'message': 'Not Found'}, status: 404);
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      expect(await client.getRepo('o', 'nope'), isNull);

      final gh2 = _ScriptedGithub()
        ..on('GET', '/repos/o/r', {'message': 'Bad credentials'}, status: 401);
      final client2 = GithubApiClient(token: 't', httpClient: gh2.client);
      await expectLater(
        client2.getRepo('o', 'r'),
        throwsA(
          isA<GithubApiException>()
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });

    test(
      'createRepo defaults to PUBLIC (catalog submodules clone anonymously)',
      () async {
        final gh = _ScriptedGithub()
          ..on('POST', '/user/repos', {
            'full_name': 'octocat/fa-widget-x',
            'private': false,
            'default_branch': 'main',
          });
        final client = GithubApiClient(token: 't', httpClient: gh.client);
        final repo = await client.createRepo(
          name: 'fa-widget-x',
          description: 'Fa widget: x',
        );
        expect(repo.fullName, 'octocat/fa-widget-x');
        expect(repo.isPrivate, isFalse);
        final body =
            jsonDecode(gh.requests.single.body) as Map<String, dynamic>;
        expect(body['private'], isFalse);
        expect(body['name'], 'fa-widget-x');
      },
    );

    test('ensureFork reuses an existing fork, else forks and polls', () async {
      final gh = _ScriptedGithub()
        // First call: fork absent.
        ..on('GET', '/repos/octocat/fa_widgets', {
          'message': 'nope',
        }, status: 404)
        // Fork requested (202 flow answers 200/202 with the repo payload).
        ..on('POST', '/repos/IstiN/fa_widgets/forks', {
          'full_name': 'octocat/fa_widgets',
          'private': false,
          'default_branch': 'main',
        })
        // First poll still 404, second ready.
        ..on('GET', '/repos/octocat/fa_widgets', {
          'message': 'nope',
        }, status: 404)
        ..on('GET', '/repos/octocat/fa_widgets', {
          'full_name': 'octocat/fa_widgets',
          'private': false,
          'default_branch': 'main',
        });
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      var naps = 0;
      final fork = await client.ensureFork(
        owner: 'IstiN',
        repo: 'fa_widgets',
        asUser: 'octocat',
        sleep: (_) async => naps++,
      );
      expect(fork.fullName, 'octocat/fa_widgets');
      expect(naps, greaterThanOrEqualTo(1));
    });

    test('git data flow: blob → tree (gitlink) → commit → ref', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/o/r/git/ref/heads/main', {
          'object': {'sha': 'parent-sha'},
        })
        ..on('POST', '/repos/o/r/git/blobs', {'sha': 'blob-1'})
        ..on('POST', '/repos/o/r/git/trees', {'sha': 'tree-1'})
        ..on('POST', '/repos/o/r/git/commits', {'sha': 'commit-1'})
        ..on('PATCH', '/repos/o/r/git/refs/heads/main', {});
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      expect(await client.getHeadSha('o', 'r', 'main'), 'parent-sha');
      final blob = await client.createBlob('o', 'r', 'hello');
      expect(blob, 'blob-1');
      // The blob payload is base64.
      expect(
        jsonDecode(gh.requests[1].body)['content'],
        base64Encode(utf8.encode('hello')),
      );
      final tree = await client.createTree('o', 'r', [
        GithubTreeEntry.file('widgets/x/overlay.json', blob),
        GithubTreeEntry.submodule('vendor/external/x', 'ext-commit-sha'),
      ], baseTreeSha: 'parent-sha');
      expect(tree, 'tree-1');
      final treeBody = jsonDecode(gh.requests[2].body) as Map<String, dynamic>;
      final entries = treeBody['tree'] as List;
      expect(entries[0]['mode'], '100644');
      expect(entries[1]['mode'], '160000');
      expect(entries[1]['type'], 'commit');
      expect(entries[1]['sha'], 'ext-commit-sha');
      final commit = await client.createCommit(
        'o',
        'r',
        treeSha: tree,
        message: 'publish x',
        parentSha: 'parent-sha',
      );
      expect(commit, 'commit-1');
      await client.updateRef('o', 'r', 'main', commit);
      expect(jsonDecode(gh.requests.last.body)['sha'], 'commit-1');
    });

    test('getHeadSha returns null for an empty repo', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/o/r/git/ref/heads/main', {
          'message': 'Git Repository is empty.',
        }, status: 404);
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      expect(await client.getHeadSha('o', 'r', 'main'), isNull);
    });

    test('createBranch tolerates 422 (ref already exists)', () async {
      final gh = _ScriptedGithub()
        ..on('POST', '/repos/o/r/git/refs', {
          'message': 'Reference already exists',
        }, status: 422);
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      await client.createBranch('o', 'r', 'publish/x-1.0.0', 'sha');
    });

    test('createPull and findOpenPull dedupe', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls', [])
        ..on('POST', '/repos/IstiN/fa_widgets/pulls', {
          'number': 7,
          'url': 'https://api.github.com/x/7',
          'html_url': 'https://github.com/IstiN/fa_widgets/pull/7',
          'state': 'open',
          'title': 'Add widget x',
          'merged_at': null,
        });
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      expect(
        await client.findOpenPull('IstiN', 'fa_widgets', head: 'octocat:b'),
        isNull,
      );
      final pr = await client.createPull(
        owner: 'IstiN',
        repo: 'fa_widgets',
        head: 'octocat:publish/x-1.0.0',
        base: 'main',
        title: 'Add widget x',
        body: '...',
      );
      expect(pr.number, 7);
      expect(pr.merged, isFalse);
      // The head query is url-encoded in the request.
      expect(gh.requests.first.url.queryParameters['head'], 'octocat:b');
    });

    test('getPull marks merged PRs', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/repos/IstiN/fa_widgets/pulls/7', {
          'number': 7,
          'url': 'u',
          'html_url': 'h',
          'state': 'closed',
          'title': 't',
          'merged_at': '2026-09-06T00:00:00Z',
        });
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      final pr = await client.getPull('IstiN', 'fa_widgets', 7);
      expect(pr!.state, 'closed');
      expect(pr.merged, isTrue);
    });

    test(
      'listPullComments merges conversation + review, date-sorted',
      () async {
        final gh = _ScriptedGithub()
          ..on('GET', '/repos/o/r/issues/7/comments', [
            {
              'user': {'login': 'reviewer'},
              'body': 'please rename',
              'created_at': '2026-09-06T10:00:00Z',
            },
          ])
          ..on('GET', '/repos/o/r/pulls/7/comments', [
            {
              'user': {'login': 'reviewer'},
              'body': 'line note',
              'created_at': '2026-09-06T09:00:00Z',
            },
          ]);
        final client = GithubApiClient(token: 't', httpClient: gh.client);
        final comments = await client.listPullComments('o', 'r', 7);
        expect(comments, hasLength(2));
        expect(comments.first.isReview, isTrue); // 09:00 sorts before 10:00
        expect(comments.last.body, 'please rename');
      },
    );

    test('rate-limit responses are classified', () async {
      final gh = _ScriptedGithub()
        ..on('GET', '/user', {
          'message': 'API rate limit exceeded for x',
        }, status: 403);
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      await expectLater(
        client.getUser(),
        throwsA(
          isA<GithubApiException>().having(
            (e) => e.isRateLimited,
            'isRateLimited',
            isTrue,
          ),
        ),
      );
    });

    test('error bodies surface the server message and details', () async {
      final gh = _ScriptedGithub()
        ..on('POST', '/user/repos', {
          'message': 'Repository creation failed.',
          'errors': [
            {'message': 'name already exists on this account'},
          ],
        }, status: 422);
      final client = GithubApiClient(token: 't', httpClient: gh.client);
      await expectLater(
        client.createRepo(name: 'x'),
        throwsA(
          isA<GithubApiException>().having(
            (e) => e.toString(),
            'message',
            contains('name already exists'),
          ),
        ),
      );
    });
  });
}
