// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/chatgpt_oauth_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test',
  baseUrl: 'https://example.com',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessageEventStream _noopStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) => AssistantMessageEventStream();

/// A service recording [reconfigure] calls (nothing else is exercised).
final class _RecordingService extends AgentService {
  _RecordingService(ExecutionEnv env)
    : super(
        agent: Agent(
          model: _testModel,
          systemPrompt: 'You are Fa.',
          streamFunction: _noopStream,
          toolRegistry: ToolRegistry(const []),
        ),
        env: env,
        sessionsRoot: '/sessions',
      );

  AgentConfig? reconfigured;

  @override
  Future<void> reconfigure(AgentConfig config) async {
    reconfigured = config;
  }
}

/// A minimal id_token JWT whose payload carries [claims] (the flow reads
/// the account email from it).
String _idToken(Map<String, Object?> claims) {
  String segment(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json)));
  return '${segment({'alg': 'none'})}.${segment(claims)}.sig';
}

ChatGptOAuthCredentials _credentials(String email) => ChatGptOAuthCredentials(
  accessToken: 'at-1',
  refreshToken: 'rt-1',
  idToken: _idToken({'email': email, 'chatgpt_account_id': 'acc-1'}),
);

/// Pumps a 'go' button that launches the flow with in-memory stores and a
/// canned OAuth result (no browser, no callback server). The [iosFn] /
/// [pushWebView] / [exchangeFn] seams switch the flow onto its iOS WebView
/// hop (the injected flowFn must then stay unused).
Future<(Future<bool>, _RecordingService, ProviderRegistry)> _launch(
  WidgetTester tester, {
  ProviderRegistry? registry,
  SessionKeysStore? keys,
  ChatGptOAuthCredentials? credentials,
  bool platformSupported = true,
  Future<ChatGptOAuthCredentials?> Function()? flowFn,
  bool Function()? iosFn,
  ChatGptCodeExchange? exchangeFn,
  Future<String?> Function(BuildContext, Uri, String)? pushWebView,
}) async {
  final resolvedRegistry = registry ?? ProviderRegistry.inMemory();
  final service = _RecordingService(MemoryExecutionEnv());
  Future<bool>? done;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              done = runChatGptOAuthFlow(
                context: context,
                registry: resolvedRegistry,
                service: service,
                lastConnectionStore: LastConnectionStore.inMemory(),
                sessionKeysStore: keys ?? SessionKeysStore.inMemory(),
                platformSupportedFn: () => platformSupported,
                chatGptOAuthFlowFn: iosFn != null
                    ? null
                    : flowFn ?? () async => credentials,
                iosFn: iosFn,
                exchangeFn: exchangeFn,
                pushWebView: pushWebView,
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return (done!, service, resolvedRegistry);
}

void main() {
  // Issue #329: Android now counts as a KeychainStore surface, so the
  // flow probes the fah/keychain channel. Under FakeAsync an unmocked
  // channel reply never arrives and the flow future never completes.
  // These tests own the saved-keys fallback contract (no secure backend),
  // so answer the probe accordingly — same pattern as
  // copilot_connect_flow_test.dart.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), (
          call,
        ) async {
          return switch (call.method) {
            'isAvailable' => false,
            'readAll' => <String, String>{},
            'set' || 'delete' => false,
            _ => null,
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), null);
  });

  test('chatgptEntryKeyName matches the CLI sanitizer', () {
    // Byte-identical with CustomProviderRegistry.keyNameFor(
    // chatGptCodexBaseUrl, providerName: entryName).
    expect(
      chatgptEntryKeyName('alice@example.com'),
      'FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM',
    );
    expect(chatgptEntryKeyName('Acme 2'), 'FA_KEY_CHATGPT_COM_ACME_2');
    expect(chatgptEntryKeyName('_-x-_'), 'FA_KEY_CHATGPT_COM_X');
    // A name equal to the host must not double the suffix.
    expect(chatgptEntryKeyName('chatgpt.com'), 'FA_KEY_CHATGPT_COM');
  });

  testWidgets('a completed flow saves an email-named entry with an '
      'entry-scoped key', (tester) async {
    final keys = SessionKeysStore.inMemory();
    final (done, service, registry) = await _launch(
      tester,
      keys: keys,
      credentials: _credentials('alice@example.com'),
    );
    expect(await done, isTrue);

    final entry = registry.providers.single;
    expect(entry.name, 'alice@example.com');
    expect(entry.baseUrl, chatGptCodexBaseUrl);
    // The stored value is the full credentials blob (refresh-able), not the
    // bare access token.
    expect(
      registry.keyFor(entry.id),
      _credentials('alice@example.com').encode(),
    );
    expect(
      keys.valueOf('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM'),
      _credentials('alice@example.com').encode(),
    );
    expect(service.reconfigured, isNotNull);
    expect(service.reconfigured!.providerKind, 'chatgpt-codex');
    expect(service.reconfigured!.baseUrl, chatGptCodexBaseUrl);
    expect(service.reconfigured!.modelId, chatGptCodexDefaultModel);
  });

  testWidgets('re-auth (same account) matches by name + baseUrl and keeps '
      'the model', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final keys = SessionKeysStore.inMemory();
    final existing = await registry.add(
      name: 'alice@example.com',
      baseUrl: chatGptCodexBaseUrl,
      modelId: 'my-pick',
    );
    registry.rememberKey(existing.id, 'stale');
    await keys.set('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM', 'stale');

    final (done, service, _) = await _launch(
      tester,
      registry: registry,
      keys: keys,
      credentials: _credentials('alice@example.com'),
    );
    expect(await done, isTrue);

    // Still one entry, same id, refreshed key, KEPT model choice.
    expect(registry.providers.length, 1);
    expect(registry.providers.single.id, existing.id);
    expect(registry.providers.single.modelId, 'my-pick');
    expect(
      registry.keyFor(existing.id),
      _credentials('alice@example.com').encode(),
    );
    expect(
      keys.valueOf('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM'),
      _credentials('alice@example.com').encode(),
    );
    expect(service.reconfigured!.modelId, 'my-pick');
  });

  testWidgets('a second account lands in its own entry without touching '
      'the first', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final keys = SessionKeysStore.inMemory();
    final alice = await registry.add(
      name: 'alice@example.com',
      baseUrl: chatGptCodexBaseUrl,
      modelId: 'my-pick',
    );
    registry.rememberKey(alice.id, 'alice-key');
    await keys.set('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM', 'alice-key');

    final (done, _, _) = await _launch(
      tester,
      registry: registry,
      keys: keys,
      credentials: _credentials('bob@example.com'),
    );
    expect(await done, isTrue);

    // The old baseUrl-only match would have overwritten alice's entry —
    // name + baseUrl matching keeps both accounts side by side.
    expect(registry.providers, hasLength(2));
    final bob = registry.providers.singleWhere(
      (p) => p.name == 'bob@example.com',
    );
    expect(bob.baseUrl, chatGptCodexBaseUrl);
    expect(registry.keyFor(alice.id), 'alice-key');
    expect(keys.valueOf('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM'), 'alice-key');
    expect(
      keys.valueOf('FA_KEY_CHATGPT_COM_BOB_EXAMPLE_COM'),
      _credentials('bob@example.com').encode(),
    );
  });

  testWidgets('an id_token without an email falls back to ChatGPT and '
      'de-duplicates', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final keys = SessionKeysStore.inMemory();
    final first = await registry.add(
      name: 'ChatGPT',
      baseUrl: chatGptCodexBaseUrl,
      modelId: chatGptCodexDefaultModel,
    );

    final (done, _, _) = await _launch(
      tester,
      registry: registry,
      keys: keys,
      credentials: ChatGptOAuthCredentials(
        accessToken: 'at-2',
        refreshToken: 'rt-2',
        idToken: _idToken({'sub': 'no-email-here'}),
      ),
    );
    expect(await done, isTrue);

    expect(registry.providers, hasLength(2));
    final second = registry.providers
        .map((p) => p.name)
        .where((name) => name != first.name)
        .single;
    expect(second, 'ChatGPT-2');
  });

  testWidgets('an unsupported surface refuses with a snackbar', (tester) async {
    final (done, service, registry) = await _launch(
      tester,
      credentials: _credentials('alice@example.com'),
      platformSupported: false,
    );
    expect(await done, isFalse);
    expect(registry.providers, isEmpty);
    expect(service.reconfigured, isNull);
    expect(
      find.text(
        'ChatGPT sign-in ships on macOS and iOS. '
        'Use OpenAI with an API key on this platform.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a cancelled OAuth (null credentials) refuses silently', (
    tester,
  ) async {
    final (done, service, registry) = await _launch(
      tester,
      flowFn: () async => null,
    );
    expect(await done, isFalse);
    expect(registry.providers, isEmpty);
    expect(service.reconfigured, isNull);
  });

  testWidgets('a Keychain-backed surface persists entry-scoped without '
      'touching saved-keys', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), (
          call,
        ) async {
          return switch (call.method) {
            'isAvailable' => true,
            'set' => true,
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fah/keychain'), null);
    });
    final keys = SessionKeysStore.inMemory();
    final (done, _, registry) = await _launch(
      tester,
      keys: keys,
      credentials: _credentials('alice@example.com'),
    );
    expect(await done, isTrue);
    expect(
      registry.keyFor(registry.providers.single.id),
      _credentials('alice@example.com').encode(),
    );
    expect(keys.valueOf('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM'), isNull);
  });

  group('the iOS WebView hop (issue #773)', () {
    // The loopback redirect the webview intercepts; the port is never bound.
    const redirectUri = 'http://localhost:1455/auth/callback';

    testWidgets('an iOS-shaped run lands the same entry, key slot and '
        'service reconfigure as the macOS flow', (tester) async {
      Uri? authorizeUrl;
      final keys = SessionKeysStore.inMemory();
      final (done, service, registry) = await _launch(
        tester,
        keys: keys,
        iosFn: () => true,
        pushWebView: (context, url, state) async {
          authorizeUrl = url;
          return 'code-1';
        },
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String codeVerifier,
            }) async {
              expect(code, 'code-1');
              expect(redirectUri, 'http://localhost:1455/auth/callback');
              return _credentials('alice@example.com');
            },
      );
      expect(await done, isTrue);

      // The SAME assertions the macOS flow tests make (shared tail).
      final entry = registry.providers.single;
      expect(entry.name, 'alice@example.com');
      expect(entry.baseUrl, chatGptCodexBaseUrl);
      expect(
        registry.keyFor(entry.id),
        _credentials('alice@example.com').encode(),
      );
      expect(
        keys.valueOf('FA_KEY_CHATGPT_COM_ALICE_EXAMPLE_COM'),
        _credentials('alice@example.com').encode(),
      );
      expect(service.reconfigured, isNotNull);
      expect(service.reconfigured!.providerKind, 'chatgpt-codex');
      expect(service.reconfigured!.baseUrl, chatGptCodexBaseUrl);
      expect(authorizeUrl, isNotNull);
    });

    testWidgets('the authorize URL is the harness PKCE request with a '
        'loopback redirect', (tester) async {
      Uri? authorizeUrl;
      String? expectedState;
      await _launch(
        tester,
        iosFn: () => true,
        pushWebView: (context, url, state) async {
          authorizeUrl = url;
          expectedState = state;
          return null; // cancel right away — the URL asserts carry the test
        },
      );

      expect(authorizeUrl!.host, 'auth.openai.com');
      expect(authorizeUrl!.path, '/oauth/authorize');
      final query = authorizeUrl!.queryParameters;
      expect(query['response_type'], 'code');
      expect(query['client_id'], chatGptOAuthClientId);
      expect(query['redirect_uri'], redirectUri);
      expect(query['code_challenge_method'], 'S256');
      expect(query['state'], expectedState);
      // A real S256 challenge: unpadded base64url of a SHA-256 digest.
      expect(query['code_challenge'], hasLength(43));
      expect(query['code_challenge'], isNot(contains('=')));
    });

    testWidgets('the intercepted code completes the real token exchange '
        'over a MockClient', (tester) async {
      Uri? authorizeUrl;
      http.Request? tokenRequest;
      final keys = SessionKeysStore.inMemory();
      final (done, service, registry) = await _launch(
        tester,
        keys: keys,
        iosFn: () => true,
        pushWebView: (context, url, state) async {
          authorizeUrl = url;
          return 'code-1';
        },
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String codeVerifier,
            }) => exchangeChatGptAuthorizationCode(
              code: code,
              redirectUri: redirectUri,
              codeVerifier: codeVerifier,
              client: MockClient((request) async {
                tokenRequest = request;
                return http.Response(
                  jsonEncode({
                    'access_token': 'at-1',
                    'refresh_token': 'rt-1',
                    'id_token': _idToken({
                      'email': 'alice@example.com',
                      'chatgpt_account_id': 'acc-1',
                    }),
                    'expires_in': 3600,
                  }),
                  200,
                );
              }),
            ),
      );
      expect(await done, isTrue);

      // The exchange posts the intercepted code to the token endpoint with
      // the SAME loopback redirect and the verifier matching the challenge
      // the authorize URL carried.
      expect(
        tokenRequest!.url.toString(),
        'https://auth.openai.com/oauth/token',
      );
      final body = Uri(query: tokenRequest!.body).queryParameters;
      expect(body['grant_type'], 'authorization_code');
      expect(body['code'], 'code-1');
      expect(body['redirect_uri'], redirectUri);
      expect(body['client_id'], chatGptOAuthClientId);
      expect(
        authorizeUrl!.queryParameters['code_challenge'],
        generateChatGptPkceChallenge(body['code_verifier']!),
      );

      // The exchanged credentials flow into the shared save tail.
      expect(registry.providers.single.name, 'alice@example.com');
      expect(service.reconfigured, isNotNull);
    });

    testWidgets('a cancelled WebView hop saves nothing', (tester) async {
      final (done, service, registry) = await _launch(
        tester,
        iosFn: () => true,
        pushWebView: (context, url, state) async => null,
      );
      expect(await done, isFalse);
      expect(registry.providers, isEmpty);
      expect(service.reconfigured, isNull);
      expect(find.textContaining('token exchange'), findsNothing);
    });

    testWidgets('an exchange failure surfaces a named error and saves '
        'nothing', (tester) async {
      final (done, service, registry) = await _launch(
        tester,
        iosFn: () => true,
        pushWebView: (context, url, state) async => 'code-1',
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String codeVerifier,
            }) async =>
                throw const ConfigException('authorization code expired (400)'),
      );
      await done;
      await tester.pump(); // let the snackbar animate in

      expect(registry.providers, isEmpty);
      expect(service.reconfigured, isNull);
      expect(
        find.textContaining('ChatGPT sign-in failed at the token exchange'),
        findsOneWidget,
      );
      expect(find.textContaining('authorization code expired'), findsOneWidget);
    });
  });
}
