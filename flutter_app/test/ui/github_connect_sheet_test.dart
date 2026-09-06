// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
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
}
