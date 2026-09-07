// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_api_client.dart' show GithubApiException;

/// The production OAuth web-flow callback (issue #35): GitHub redirects the
/// user's browser here after "Authorize", and the fa1.dev page displays the
/// one-time `code` for pasting back into the connect sheet. Register it as
/// the OAuth App's Authorization callback URL (desktop builds later add a
/// localhost callback — GitHub allows multiple URLs per app).
const String githubOauthWebRedirectUri = 'https://fa1.dev/oauth/callback';

/// Settings → Keys entry holding the user-registered OAuth App's client
/// secret. GitHub requires it for the web-flow token exchange (the device
/// flow needs no secret, which is why the device tab works without it).
const githubOauthClientSecretKeyName = 'github_oauth_client_secret';

/// Builds the github.com OAuth web-flow authorize URL: open it in an
/// external browser, GitHub redirects to [redirectUri] after "Authorize".
Uri buildGithubOauthAuthorizeUrl({
  required String clientId,
  String redirectUri = githubOauthWebRedirectUri,
  String? state,
  List<String> scopes = const ['public_repo'],
}) => Uri.https('github.com', '/login/oauth/authorize', {
  'client_id': clientId,
  'redirect_uri': redirectUri,
  if (scopes.isNotEmpty) 'scope': scopes.join(' '),
  if (state != null && state.isNotEmpty) 'state': state,
});

/// Exchanges an OAuth web-flow one-time `code` for an access token
/// (`POST https://github.com/login/oauth/access_token`, Accept:
/// application/json). [clientSecret] is required by GitHub for
/// user-registered OAuth Apps — take it from the
/// [githubOauthClientSecretKeyName] Keys entry.
///
/// Returns the access token; throws [GithubApiException] on any failure
/// (non-2xx, GitHub's `error` payload, or a missing token field).
Future<String> exchangeGithubOauthCode({
  required String clientId,
  required String code,
  String? clientSecret,
  String redirectUri = githubOauthWebRedirectUri,
  http.Client? httpClient,
}) async {
  final response = await (httpClient ?? http.Client()).post(
    Uri.parse('https://github.com/login/oauth/access_token'),
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'client_id': clientId,
      'code': code,
      if (clientSecret != null && clientSecret.isNotEmpty)
        'client_secret': clientSecret,
      'redirect_uri': redirectUri,
    }),
  );
  if (response.statusCode >= 400) {
    throw GithubApiException(response.statusCode, response.body);
  }
  Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on FormatException {
    throw GithubApiException(response.statusCode, response.body);
  }
  if (decoded is! Map) {
    throw GithubApiException(response.statusCode, response.body);
  }
  final error = decoded['error'];
  if (error != null) {
    throw GithubApiException(
      response.statusCode,
      (decoded['error_description'] ?? error).toString(),
    );
  }
  final token = decoded['access_token']?.toString();
  if (token == null || token.isEmpty) {
    throw GithubApiException(
      response.statusCode,
      'GitHub did not return an access token.',
    );
  }
  return token;
}

/// The OAuth web-flow steps the connect sheet uses, injectable so tests
/// script the exchange instead of talking to github.com.
class GithubOauthWebFlow {
  const GithubOauthWebFlow({this.exchange = exchangeGithubOauthCode});

  final Future<String> Function({
    required String clientId,
    required String code,
    String? clientSecret,
    String redirectUri,
  })
  exchange;
}
