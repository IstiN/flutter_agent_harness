// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:http/http.dart' as http;

/// The connected GitHub user profile (subset the app needs).
final class GithubUser {
  const GithubUser({required this.login, this.avatarUrl});

  factory GithubUser.fromJson(Map<String, dynamic> json) => GithubUser(
    login: (json['login'] ?? '').toString(),
    avatarUrl: json['avatar_url']?.toString(),
  );

  final String login;
  final String? avatarUrl;
}

/// A GitHub repository (subset).
final class GithubRepo {
  const GithubRepo({
    required this.fullName,
    required this.isPrivate,
    required this.defaultBranch,
    this.description,
  });

  factory GithubRepo.fromJson(Map<String, dynamic> json) => GithubRepo(
    fullName: (json['full_name'] ?? '').toString(),
    isPrivate: json['private'] == true,
    defaultBranch: (json['default_branch'] ?? 'main').toString(),
    description: json['description']?.toString(),
  );

  final String fullName;
  final bool isPrivate;
  final String defaultBranch;
  final String? description;
}

/// A pull request (subset).
final class GithubPull {
  const GithubPull({
    required this.number,
    required this.url,
    required this.htmlUrl,
    required this.state,
    required this.merged,
    required this.title,
  });

  factory GithubPull.fromJson(Map<String, dynamic> json) => GithubPull(
    number: (json['number'] as num).toInt(),
    url: (json['url'] ?? '').toString(),
    htmlUrl: (json['html_url'] ?? '').toString(),
    state: (json['state'] ?? 'open').toString(),
    merged: json['merged_at'] != null || json['merged'] == true,
    title: (json['title'] ?? '').toString(),
  );

  final int number;
  final String url;
  final String htmlUrl;

  /// `open` | `closed`; [merged] distinguishes a published merge from a
  /// rejected close.
  final String state;
  final bool merged;
  final String title;
}

/// One PR conversation entry (issue comment or review comment, unified).
final class GithubComment {
  const GithubComment({
    required this.author,
    required this.body,
    required this.createdAt,
    required this.isReview,
  });

  final String author;
  final String body;
  final DateTime createdAt;

  /// True for line-level review comments, false for conversation comments.
  final bool isReview;
}

/// One entry of a git tree: a file blob, or a submodule gitlink (mode
/// `160000`, [sha] = the pinned commit of the submodule repo).
final class GithubTreeEntry {
  const GithubTreeEntry({required this.path, required this.mode, this.sha});

  /// File blob entry.
  factory GithubTreeEntry.file(String path, String blobSha) =>
      GithubTreeEntry(path: path, mode: '100644', sha: blobSha);

  /// Submodule gitlink entry; [commitSha] is the pinned commit of the
  /// external repository (its URL lives in the `.gitmodules` blob).
  factory GithubTreeEntry.submodule(String path, String commitSha) =>
      GithubTreeEntry(path: path, mode: '160000', sha: commitSha);

  final String path;
  final String mode;
  final String? sha;

  Map<String, Object?> toJson() => {
    'path': path,
    'mode': mode,
    'type': mode == '160000' ? 'commit' : 'blob',
    if (sha != null) 'sha': sha,
  };
}

/// A non-2xx GitHub API response, with the status and the server's message.
final class GithubApiException implements Exception {
  const GithubApiException(this.statusCode, this.message, {this.errors});

  final int statusCode;
  final String message;
  final List<String>? errors;

  bool get isUnauthorized => statusCode == 401;
  bool get isNotFound => statusCode == 404;

  /// 403 with a rate-limit body — status polling backs off to the reset.
  bool get isRateLimited =>
      statusCode == 403 && message.toLowerCase().contains('rate limit');

  /// 403 "Resource not accessible by integration" — the token cannot act
  /// on this resource at all. Typical for fine-grained PATs (especially
  /// scoped to "Only select repositories": a repo that does not exist yet
  /// can never be in the selection) or tokens without the Administration
  /// repo permission — repository creation needs it.
  bool get isForbiddenIntegration =>
      statusCode == 403 &&
      message.toLowerCase().contains('resource not accessible by integration');

  /// The actionable fix for [isForbiddenIntegration], appended to the
  /// server message by the write paths ([createRepo], [ensureFork],
  /// [createPull]).
  static const tokenPermissionHint =
      'The connected GitHub token lacks permission for this. Use a classic '
      'PAT with the public_repo scope, or a fine-grained PAT with "All '
      'repositories" + Administration (read/write) + Contents (read/write).';

  /// Rethrows [error] with [tokenPermissionHint] appended when it is a
  /// forbidden-integration failure; otherwise rethrows unchanged.
  static Never rethrowWithPermissionHint(GithubApiException error) {
    if (error.isForbiddenIntegration) {
      throw GithubApiException(
        error.statusCode,
        '${error.message}. $tokenPermissionHint',
        errors: error.errors,
      );
    }
    throw error;
  }

  /// Validation failed (422) — e.g. fork already exists, ref exists.
  bool get isValidation => statusCode == 422;

  @override
  String toString() {
    final suffix = (errors == null || errors!.isEmpty)
        ? ''
        : ' (${errors!.join('; ')})';
    return 'GitHub API $statusCode: $message$suffix';
  }
}

/// Pure-Dart GitHub REST v3 client for the widget-publishing flow
/// (issue #35). No `gh` CLI — works in the App-Store sandbox; every method
/// takes an injectable [http.Client] at construction so tests script the
/// API with `MockClient`.
///
/// The token goes ONLY to `https://api.github.com` (literal host check is
/// unnecessary — the base URI is a constant), via `Authorization: Bearer`.
/// All mutating calls target the caller's OWN repositories or their fork —
/// the catalog repo is written exclusively through pull requests.
class GithubApiClient {
  GithubApiClient({required this._token, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static const baseUrl = 'https://api.github.com';

  /// The catalog repository every widget PR targets.
  static const catalogOwner = 'IstiN';
  static const catalogRepo = 'fa_widgets';

  final String _token;
  final http.Client _http;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  // --- account -------------------------------------------------------------

  /// `GET /user` — the connected account (login + avatar).
  Future<GithubUser> getUser() async {
    final json = await _request('GET', '/user');
    return GithubUser.fromJson(json as Map<String, dynamic>);
  }

  // --- repositories --------------------------------------------------------

  /// `GET /repos/<owner>/<name>`; null when the repo does not exist.
  Future<GithubRepo?> getRepo(String owner, String name) async {
    try {
      final json = await _request('GET', '/repos/$owner/$name');
      return GithubRepo.fromJson(json as Map<String, dynamic>);
    } on GithubApiException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// `POST /user/repos` — creates a repo under the connected account.
  /// Widget repos are PUBLIC ([private] defaults false): the catalog CI
  /// clones external submodules anonymously.
  Future<GithubRepo> createRepo({
    required String name,
    String? description,
    bool private = false,
  }) async {
    final Map<String, dynamic> json;
    try {
      json =
          await _request(
                'POST',
                '/user/repos',
                body: {
                  'name': name,
                  'private': private,
                  'description': ?description,
                  'auto_init': false,
                },
              )
              as Map<String, dynamic>;
    } on GithubApiException catch (error) {
      // Creating a repo is exactly what fine-grained PATs without the
      // Administration permission (or scoped to select repositories)
      // cannot do — surface the token fix immediately.
      throw GithubApiException.rethrowWithPermissionHint(error);
    }
    return GithubRepo.fromJson(json);
  }

  /// Forks `<owner>/<repo>` into the connected account (`POST /forks`) and
  /// waits for the fork to become usable (GitHub forks asynchronously).
  /// An existing fork is returned as-is. [asUser] is the connected login.
  Future<GithubRepo> ensureFork({
    required String owner,
    required String repo,
    required String asUser,
    Future<void> Function(Duration)? sleep,
  }) async {
    final existing = await getRepo(asUser, repo);
    if (existing != null) return existing;
    await _request('POST', '/repos/$owner/$repo/forks'); // 202 Accepted
    final nap = sleep ?? Future<void>.delayed;
    for (var i = 0; i < 20; i++) {
      await nap(const Duration(milliseconds: 1500));
      final ready = await getRepo(asUser, repo);
      if (ready != null) return ready;
    }
    throw const GithubApiException(
      408,
      'the fork is still being created — try again in a few seconds',
    );
  }

  // --- git data ------------------------------------------------------------

  /// The head commit sha of [branch] in `<owner>/<repo>`; null when the
  /// repo is empty (no commits yet).
  Future<String?> getHeadSha(String owner, String repo, String branch) async {
    try {
      final json =
          await _request('GET', '/repos/$owner/$repo/git/ref/heads/$branch')
              as Map<String, dynamic>;
      final object = json['object'];
      return object is Map ? object['sha']?.toString() : null;
    } on GithubApiException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// `POST /git/blobs` — one file's content; returns the blob sha.
  Future<String> createBlob(String owner, String repo, String content) async {
    final json =
        await _request(
              'POST',
              '/repos/$owner/$repo/git/blobs',
              body: {
                'content': base64Encode(utf8.encode(content)),
                'encoding': 'base64',
              },
            )
            as Map<String, dynamic>;
    return (json['sha'] as String);
  }

  /// `POST /git/trees` — entries relative to [baseTreeSha] (null = a fresh
  /// root tree, used for the first commit of an empty repo).
  Future<String> createTree(
    String owner,
    String repo,
    List<GithubTreeEntry> entries, {
    String? baseTreeSha,
  }) async {
    final json =
        await _request(
              'POST',
              '/repos/$owner/$repo/git/trees',
              body: {
                'base_tree': ?baseTreeSha,
                'tree': [for (final entry in entries) entry.toJson()],
              },
            )
            as Map<String, dynamic>;
    return json['sha'] as String;
  }

  /// `POST /git/commits`.
  Future<String> createCommit(
    String owner,
    String repo, {
    required String treeSha,
    required String message,
    String? parentSha,
  }) async {
    final json =
        await _request(
              'POST',
              '/repos/$owner/$repo/git/commits',
              body: {
                'tree': treeSha,
                'message': message,
                'parents': ?(parentSha == null ? null : [parentSha]),
              },
            )
            as Map<String, dynamic>;
    return json['sha'] as String;
  }

  /// Creates `refs/heads/<branch>`; 422 (already exists) is fine — the
  /// follow-up [updateRef] moves it.
  Future<void> createBranch(
    String owner,
    String repo,
    String branch,
    String sha,
  ) async {
    try {
      await _request(
        'POST',
        '/repos/$owner/$repo/git/refs',
        body: {'ref': 'refs/heads/$branch', 'sha': sha},
      );
    } on GithubApiException catch (error) {
      if (!error.isValidation) rethrow;
    }
  }

  /// `PATCH /git/refs/heads/<branch>` — fast-forward (or force) the branch
  /// to [sha].
  Future<void> updateRef(
    String owner,
    String repo,
    String branch,
    String sha,
  ) async {
    await _request(
      'PATCH',
      '/repos/$owner/$repo/git/refs/heads/$branch',
      body: {'sha': sha, 'force': true},
    );
  }

  // --- pull requests -------------------------------------------------------

  /// `POST /repos/<owner>/<repo>/pulls` — [head] is `<login>:<branch>` for
  /// the cross-fork PR; 422 when an identical open PR exists.
  Future<GithubPull> createPull({
    required String owner,
    required String repo,
    required String head,
    required String base,
    required String title,
    required String body,
  }) async {
    final Map<String, dynamic> json;
    try {
      json =
          await _request(
                'POST',
                '/repos/$owner/$repo/pulls',
                body: {'head': head, 'base': base, 'title': title, 'body': body},
              )
              as Map<String, dynamic>;
    } on GithubApiException catch (error) {
      throw GithubApiException.rethrowWithPermissionHint(error);
    }
    return GithubPull.fromJson(json);
  }

  /// `GET /repos/<owner>/<repo>/pulls/<number>`; null when gone.
  Future<GithubPull?> getPull(String owner, String repo, int number) async {
    try {
      final json =
          await _request('GET', '/repos/$owner/$repo/pulls/$number')
              as Map<String, dynamic>;
      return GithubPull.fromJson(json);
    } on GithubApiException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// The open PR for a head branch, if any — re-publish dedupes on this.
  Future<GithubPull?> findOpenPull(
    String owner,
    String repo, {
    required String head,
  }) async {
    final json =
        await _request(
              'GET',
              '/repos/$owner/$repo/pulls?state=open&head=${Uri.encodeComponent(head)}',
            )
            as List<dynamic>;
    if (json.isEmpty) return null;
    return GithubPull.fromJson(json.first as Map<String, dynamic>);
  }

  /// Conversation + review comments of a PR, merged and date-sorted.
  Future<List<GithubComment>> listPullComments(
    String owner,
    String repo,
    int number,
  ) async {
    final issueComments =
        await _request('GET', '/repos/$owner/$repo/issues/$number/comments')
            as List<dynamic>;
    final reviewComments =
        await _request('GET', '/repos/$owner/$repo/pulls/$number/comments')
            as List<dynamic>;
    final all = <GithubComment>[
      for (final raw in issueComments)
        _comment(raw as Map<String, dynamic>, isReview: false),
      for (final raw in reviewComments)
        _comment(raw as Map<String, dynamic>, isReview: true),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all;
  }

  GithubComment _comment(Map<String, dynamic> json, {required bool isReview}) {
    final user = json['user'];
    return GithubComment(
      author: user is Map ? (user['login'] ?? '?').toString() : '?',
      body: (json['body'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      isReview: isReview,
    );
  }

  // --- transport -----------------------------------------------------------

  Future<Object?> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final request = http.Request(method, uri)..headers.addAll(_headers);
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _http.send(request);
    final response = await http.Response.fromStream(streamed);
    final text = response.body;
    if (response.statusCode >= 400) {
      String message = text;
      List<String>? errors;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          message = (decoded['message'] ?? message).toString();
          final raw = decoded['errors'];
          if (raw is List) {
            errors = [
              for (final e in raw)
                e is Map ? (e['message'] ?? e['code'] ?? e).toString() : '$e',
            ];
          }
        }
      } on FormatException {
        // Non-JSON error body (proxy pages etc.) — keep the raw text.
      }
      throw GithubApiException(response.statusCode, message, errors: errors);
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }
}
