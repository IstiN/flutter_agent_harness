// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/github_oauth_web_flow.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/widgets/github_connect_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Scripted GitHub API (same pattern as
/// test/services/github_api_client_test.dart): a queue of path → response.
final class _ScriptedGithub {
  final _responders = <(String path, int status, String body)>[];

  void on(String path, Object responseBody, {int status = 200}) {
    _responders.add((path, status, jsonEncode(responseBody)));
  }

  http.Client get client => MockClient((request) async {
    for (var i = 0; i < _responders.length; i++) {
      final responder = _responders[i];
      if (request.url.path == responder.$1) {
        _responders.removeAt(i);
        return http.Response(responder.$3, responder.$2);
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

void main() {
  group('GithubConnectSheet (PAT)', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required GithubAccountStore account,
      required _ScriptedGithub github,
      void Function(bool?)? onResult,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showGithubConnectSheet(
                    context,
                    account: account,
                    clientFactory: (token) => GithubApiClient(
                      token: token,
                      httpClient: github.client,
                    ),
                    // Tests have no HTTP transport for the device flow: an
                    // empty client id disables the device tab.
                    deviceClientId: '',
                  );
                  onResult?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('happy path validates the token and connects the account', (
      tester,
    ) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      final github = _ScriptedGithub()
        ..on('/user', {'login': 'octocat', 'avatar_url': 'https://a/b.png'});
      bool? result;
      await pumpSheet(
        tester,
        account: account,
        github: github,
        onResult: (r) => result = r,
      );
      await openSheet(tester);

      expect(find.text('GitHub token with public_repo scope'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'ghp_test-token');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect GitHub'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(account.isConnected, isTrue);
      expect(account.token, 'ghp_test-token');
      expect(account.login, 'octocat');
      expect(account.avatarUrl, 'https://a/b.png');
      // The sheet popped.
      expect(find.byType(GithubConnectSheet), findsNothing);
    });

    testWidgets('server error shows the message inline and stays open', (
      tester,
    ) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      final github = _ScriptedGithub()
        ..on('/user', {'message': 'Bad credentials'}, status: 401);
      bool? result;
      await pumpSheet(
        tester,
        account: account,
        github: github,
        onResult: (r) => result = r,
      );
      await openSheet(tester);

      await tester.enterText(find.byType(TextField), 'ghp_expired');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect GitHub'));
      await tester.pumpAndSettle();

      expect(find.text('Bad credentials'), findsOneWidget);
      expect(account.isConnected, isFalse);
      expect(result, isNull);
      expect(find.byType(GithubConnectSheet), findsOneWidget);
    });

    testWidgets('hides the device-flow tab when no client id is configured', (
      tester,
    ) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      await pumpSheet(tester, account: account, github: _ScriptedGithub());
      await openSheet(tester);

      // FA_GITHUB_CLIENT_ID is empty in tests → no tab switcher at all.
      expect(find.text('Device code'), findsNothing);
      expect(find.text('Token'), findsNothing);
    });
  });

  group('GithubConnectSheet (Browser, OAuth web flow)', () {
    Future<void> pumpWebSheet(
      WidgetTester tester, {
      required GithubAccountStore account,
      required _ScriptedGithub github,
      required Future<String> Function({
        required String clientId,
        required String code,
        String? clientSecret,
        String redirectUri,
      })
      exchange,
      void Function(bool?)? onResult,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showGithubConnectSheet(
                    context,
                    account: account,
                    clientFactory: (token) => GithubApiClient(
                      token: token,
                      httpClient: github.client,
                    ),
                    // Only the Browser tab: an empty device id disables the
                    // device flow, the web id enables the OAuth web flow.
                    deviceClientId: '',
                    webClientId: 'test-web-client-id',
                    webFlow: GithubOauthWebFlow(exchange: exchange),
                  );
                  onResult?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Switch to the Browser tab.
      await tester.tap(find.text('Browser'));
      await tester.pumpAndSettle();
    }

    testWidgets('happy path exchanges the pasted code and connects', (
      tester,
    ) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      final github = _ScriptedGithub()
        ..on('/user', {'login': 'octocat', 'avatar_url': 'https://a/b.png'});
      final exchanges = <Map<String, String?>>[];
      bool? result;
      await pumpWebSheet(
        tester,
        account: account,
        github: github,
        onResult: (r) => result = r,
        exchange: ({required clientId, required code, clientSecret,
                    redirectUri = githubOauthWebRedirectUri}) async {
          exchanges.add({
            'clientId': clientId,
            'code': code,
            'clientSecret': clientSecret,
          });
          return 'tok_web_123';
        },
      );
      await openSheet(tester);

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'abcd-1234');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect GitHub'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(account.isConnected, isTrue);
      expect(account.token, 'tok_web_123');
      expect(account.login, 'octocat');
      // The exchange received our client id and the pasted code.
      expect(exchanges.single['clientId'], 'test-web-client-id');
      expect(exchanges.single['code'], 'abcd-1234');
      // No secret configured in Keys → exchanged without one.
      expect(exchanges.single['clientSecret'], isNull);
      // The sheet popped.
      expect(find.byType(GithubConnectSheet), findsNothing);
    });

    testWidgets('exchange error shows the message inline and stays open', (
      tester,
    ) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      bool? result;
      await pumpWebSheet(
        tester,
        account: account,
        github: _ScriptedGithub(),
        onResult: (r) => result = r,
        exchange: ({required clientId, required code, clientSecret,
                    redirectUri = githubOauthWebRedirectUri}) async {
          throw const GithubApiException(400, 'bad_verification_code');
        },
      );
      await openSheet(tester);

      await tester.enterText(find.byType(TextField), 'stale-code');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect GitHub'));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(find.text('bad_verification_code'), findsOneWidget);
      expect(find.byType(GithubConnectSheet), findsOneWidget);
    });

    testWidgets('hides the browser tab without an owned client id', (
      tester,
    ) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showGithubConnectSheet(
                  context,
                  account: account,
                  clientFactory: (_) => GithubApiClient(
                    token: 'tok',
                    httpClient: _ScriptedGithub().client,
                  ),
                  deviceClientId: '',
                  webClientId: '',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Browser'), findsNothing);
      expect(find.text('Token'), findsNothing);
    });
  });
}
