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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

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

/// A scripted github.com device flow (issue #229): the grant endpoint
/// always answers, the poll endpoint plays [pollScript] (a Response is
/// served, an Exception is thrown — the iOS -1005 transient case).
final class _ScriptedDeviceFlow {
  _ScriptedDeviceFlow({this.expiresIn = 900, List<Object> pollScript = const []})
    : pollScript = List.of(pollScript);

  final int expiresIn;
  final List<Object> pollScript;
  var grantRequests = 0;
  var pollRequests = 0;

  http.Client get client => MockClient((request) async {
    if (request.url.path == '/login/device/code') {
      grantRequests++;
      return http.Response(
        jsonEncode({
          'device_code': 'dev-code-1',
          'user_code': 'C1BF-2420',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': expiresIn,
          'interval': 5,
        }),
        200,
      );
    }
    if (request.url.path == '/login/oauth/access_token') {
      pollRequests++;
      final next = pollScript.isEmpty
          ? http.Response(jsonEncode({'error': 'authorization_pending'}), 200)
          : pollScript.removeAt(0);
      if (next is Exception) throw next;
      return next as http.Response;
    }
    return http.Response('unscripted ${request.url}', 500);
  });
}

/// Records every url_launcher call (url_launcher_platform_interface is a
/// dev dependency exactly for this seam — same pattern as
/// test/golden/github_publish_golden_test.dart).
final class _RecordingUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return true;
  }
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

  group('GithubConnectSheet (Device flow, issue #229)', () {
    late _RecordingUrlLauncher launcher;

    // flutter_test has no clipboard mock — an unanswered
    // Clipboard.setData/getData future never completes (the methods ride
    // SystemChannels.platform), so the group installs an in-memory
    // handler (same pattern as test/chat_composer_test.dart).
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? clipText;

    setUp(() {
      launcher = _RecordingUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
      clipText = null;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (
        call,
      ) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipText = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return <String, Object?>{'text': clipText};
        }
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> pumpDeviceSheet(
      WidgetTester tester, {
      required GithubAccountStore account,
      required _ScriptedGithub github,
      required _ScriptedDeviceFlow deviceFlow,
      void Function(bool?)? onResult,
    }) async {
      await tester.pumpWidget(
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
                    deviceClientId: 'Iv1.test',
                    httpClient: deviceFlow.client,
                  );
                  onResult?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // Sheet animation + the auto-starting grant request (the device
      // pane animates a spinner forever — never pumpAndSettle here).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }

    // AC4: starting the device flow must NOT auto-launch the browser
    // (copy-first UX); the manual open button still launches the
    // verification URI and the copy button still copies the code.
    testWidgets(
      'no auto-launch; manual open button launches, copy button copies',
      (tester) async {
        final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
        // expires_in 6 < the 6s first poll wait: the flow ends with the
        // expired error without a single poll request (no pending timer).
        final deviceFlow = _ScriptedDeviceFlow(expiresIn: 6);
        await pumpDeviceSheet(
          tester,
          account: account,
          github: _ScriptedGithub(),
          deviceFlow: deviceFlow,
        );

        // The code is up and NO browser launch happened on its own.
        expect(find.text('C1BF-2420'), findsOneWidget);
        expect(launcher.launched, isEmpty);

        await tester.tap(find.text('Copy code'));
        await tester.pump();
        expect(clipText, 'C1BF-2420');
        expect(launcher.launched, isEmpty);

        await tester.tap(find.text('Open github.com/login/device'));
        await tester.pump();
        expect(launcher.launched, ['https://github.com/login/device']);

        // Let the flow reach its expired end (6s first wait >= budget).
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expect(find.textContaining('expired'), findsOneWidget);
        expect(deviceFlow.pollRequests, 0);
      },
    );

    // AC6: an injected transient failure (-1005-style) renders a status
    // line ("retrying…"), never the raw exception, and the flow keeps
    // polling to success.
    testWidgets('a transient poll failure shows a retry status, then '
        'the flow completes and connects', (tester) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      final github = _ScriptedGithub()
        ..on('/user', {'login': 'octocat', 'avatar_url': 'https://a/b.png'});
      final deviceFlow = _ScriptedDeviceFlow(
        pollScript: [
          Exception(
            'NSErrorClientException: The network connection was lost. '
            '[domain=NSURLErrorDomain, code=-1005]',
          ),
          http.Response(
            jsonEncode({'error': 'authorization_pending'}),
            200,
          ),
          http.Response(jsonEncode({'access_token': 'gho_device'}), 200),
        ],
      );
      bool? result;
      await pumpDeviceSheet(
        tester,
        account: account,
        github: github,
        deviceFlow: deviceFlow,
        onResult: (r) => result = r,
      );

      // Poll 1 throws transiently → a retry STATUS, no raw exception.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.textContaining('retrying'), findsOneWidget);
      expect(find.textContaining('-1005'), findsNothing);
      expect(find.textContaining('network connection was lost'), findsNothing);

      // Poll 2 pending, poll 3 success → the sheet connects and pops.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(result, isTrue);
      expect(account.isConnected, isTrue);
      expect(account.token, 'gho_device');
      expect(account.login, 'octocat');
    });

    // AC5: backgrounding suspends the poll (no requests while paused);
    // resuming continues with the SAME grant — no restart, no error.
    testWidgets('the poll suspends while paused and resumes with the '
        'same grant', (tester) async {
      final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
      final github = _ScriptedGithub()
        ..on('/user', {'login': 'octocat', 'avatar_url': 'https://a/b.png'});
      final deviceFlow = _ScriptedDeviceFlow(
        pollScript: [
          http.Response(
            jsonEncode({'error': 'authorization_pending'}),
            200,
          ),
          http.Response(
            jsonEncode({'error': 'authorization_pending'}),
            200,
          ),
          http.Response(jsonEncode({'access_token': 'gho_resumed'}), 200),
        ],
      );
      bool? result;
      await pumpDeviceSheet(
        tester,
        account: account,
        github: github,
        deviceFlow: deviceFlow,
        onResult: (r) => result = r,
      );

      // Poll 1 (pending).
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(deviceFlow.pollRequests, 1);

      // Background (the framework enforces the full transition chain
      // resumed → inactive → hidden → paused): time flies by, but no
      // poll request fires.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(deviceFlow.pollRequests, 1);

      // Foreground: the SAME grant keeps polling — no new grant request.
      // The delay already elapsed during the pause, so poll 2 fires at
      // once.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(deviceFlow.grantRequests, 1);
      expect(deviceFlow.pollRequests, 2);

      // Poll 3 succeeds → connect + pop.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(result, isTrue);
      expect(account.token, 'gho_resumed');
    });
  });
}
