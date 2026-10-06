// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa_llm/fa_llm.dart' show CopilotAccountType;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Widget tests run without the platform channel engine: an unanswered
  // `fah/keychain` invoke would hang the flows forever. Default to
  // "Keychain absent" so the saved-keys fallback runs; the keychain-first
  // test registers its own capture handler.
  const keychainChannel = MethodChannel('fah/keychain');
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keychainChannel, (call) async {
          return call.method == 'isAvailable' ? false : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keychainChannel, null);
  });

  testWidgets('connectCodeMie lands the org as a custom entry with the '
      'session cookie and a picked model', (tester) async {
    final registry = ProviderRegistry.inMemory();
    var modelsFetched = 0;
    final sso = FaUiSso(
      registry: registry,
      codeMieSsoFn: (orgUrl, onStatus) async {
        expect(orgUrl, defaultCodeMieBaseUrl);
        return const CodeMieSsoCredentials(
          cookies: {'codemie_access_token': 'jwt123'},
          apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
          expiresAt: 9999999999999,
        );
      },
      fetchCodeMieModelsFn: (apiBase, cookie) async {
        modelsFetched++;
        expect(cookie, 'codemie_access_token=jwt123');
        return ['qwen-coder', 'gpt-4o'];
      },
    );
    final connected = await _run(
      tester,
      (context) => sso.connectCodeMie(context),
      thenTap: find.text('qwen-coder'),
    );
    expect(connected, isTrue);
    expect(modelsFetched, 1);
    expect(registry.providers, hasLength(1));
    final provider = registry.providers.single;
    expect(provider.name, 'codemie.lab.epam.com');
    expect(
      provider.baseUrl,
      'https://codemie.lab.epam.com/code-assistant-api/v1',
    );
    expect(provider.modelId, 'qwen-coder');
    expect(registry.keyFor(provider.id), 'codemie_access_token=jwt123');
  });

  testWidgets('connectCodeMie re-auth refreshes an existing same-endpoint '
      'entry in place without a model pick', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final existing = await registry.add(
      name: 'my-org',
      baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
      modelId: 'old-model',
    );
    registry.rememberKey(existing.id, 'stale-cookie');
    var modelFetches = 0;
    final sso = FaUiSso(
      registry: registry,
      codeMieSsoFn: (orgUrl, onStatus) async => const CodeMieSsoCredentials(
        cookies: {'codemie_access_token': 'fresh'},
        apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
        expiresAt: 9999999999999,
      ),
      fetchCodeMieModelsFn: (apiBase, cookie) async {
        modelFetches++;
        return const [];
      },
    );
    final connected = await _run(
      tester,
      (context) => sso.connectCodeMie(context),
    );
    expect(connected, isTrue);
    expect(modelFetches, 0);
    expect(registry.providers, hasLength(1));
    expect(registry.providers.single.id, existing.id);
    expect(registry.providers.single.name, 'my-org');
    expect(registry.providers.single.modelId, 'old-model');
    expect(registry.keyFor(existing.id), 'codemie_access_token=fresh');
  });

  testWidgets('connectCodeMie with an unwired platform reports the snack '
      'and adds nothing', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final sso = FaUiSso(
      registry: registry,
      codeMieSsoFn: (orgUrl, onStatus) =>
          throw UnsupportedError('no local servers'),
    );
    final connected = await _run(
      tester,
      (context) => sso.connectCodeMie(context),
    );
    expect(connected, isFalse);
    expect(registry.providers, isEmpty);
    expect(
      find.text('CodeMie sign-in is not available on this platform.'),
      findsOneWidget,
    );
  });

  testWidgets('connectCodeMie with a cancelled sign-in adds nothing', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    final sso = FaUiSso(
      registry: registry,
      codeMieSsoFn: (orgUrl, onStatus) async => null,
    );
    final connected = await _run(
      tester,
      (context) => sso.connectCodeMie(context),
    );
    expect(connected, isFalse);
    expect(registry.providers, isEmpty);
  });

  testWidgets('connectChatGpt lands a chatgpt-codex entry named after the '
      'account email with the encoded credential blob', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final credentials = ChatGptOAuthCredentials(
      accessToken: 'at',
      refreshToken: 'rt',
      idToken: _idToken('dev@acme.com'),
    );
    final sso = FaUiSso(
      registry: registry,
      chatGptOAuthFn: (onStatus) async => credentials,
    );
    final connected = await _run(
      tester,
      (context) => sso.connectChatGpt(context),
    );
    expect(connected, isTrue);
    expect(registry.providers, hasLength(1));
    final provider = registry.providers.single;
    expect(provider.name, 'dev@acme.com');
    expect(provider.baseUrl, chatGptCodexBaseUrl);
    expect(provider.kind, 'chatgpt-codex');
    expect(provider.modelId, chatGptCodexDefaultModel);
    expect(registry.keyFor(provider.id), credentials.encode());
  });

  testWidgets('connectChatGpt persists the entry-scoped key slot '
      'keychain-first', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final persisted = <String, String>{};
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fah/keychain'),
      (call) async {
        switch (call.method) {
          case 'isAvailable':
            return true;
          case 'set':
            final args = call.arguments as Map<Object?, Object?>;
            persisted[args['name'] as String] = args['value'] as String;
            return true;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('fah/keychain'),
        null,
      ),
    );
    final credentials = ChatGptOAuthCredentials(
      accessToken: 'at',
      refreshToken: 'rt',
      idToken: _idToken('dev@acme.com'),
    );
    final sso = FaUiSso(
      registry: registry,
      chatGptOAuthFn: (onStatus) async => credentials,
    );
    final connected = await _run(
      tester,
      (context) => sso.connectChatGpt(context),
    );
    expect(connected, isTrue);
    final keyName = CustomProviderRegistry.keyNameFor(
      chatGptCodexBaseUrl,
      providerName: 'dev@acme.com',
    );
    expect(persisted[keyName], credentials.encode());
  });

  testWidgets('connectAiin lands the registered key under the account '
      'email with a picked model', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final sso = FaUiSso(
      registry: registry,
      aiinConnectFn: (onStatus) async => const AiinConnectResult(
        apiKey: AiinApiKey(
          raw: 'sk-aiin-xyz',
          id: '42',
          prefix: 'sk-aiin',
          createdAt: '2026-10-06',
        ),
        tokens: AiinOAuthTokens(
          accessToken: 'a',
          refreshToken: 'r',
          tokenType: 'Bearer',
          expiresIn: 3600,
          refreshExpiresIn: 7200,
        ),
        email: 'u@aiin.by',
      ),
      modelsFetcher: (baseUrl, {required apiKey}) async {
        expect(baseUrl, '$aiinApiBaseUrl/v1');
        expect(apiKey, 'sk-aiin-xyz');
        return (['glm-4'], <String, int>{}, <String, int>{});
      },
    );
    final connected = await _run(
      tester,
      (context) => sso.connectAiin(context),
      thenTap: find.text('glm-4'),
    );
    expect(connected, isTrue);
    expect(registry.providers, hasLength(1));
    final provider = registry.providers.single;
    expect(provider.name, 'u@aiin.by');
    expect(provider.baseUrl, '$aiinApiBaseUrl/v1');
    expect(provider.modelId, 'glm-4');
    expect(registry.keyFor(provider.id), 'sk-aiin-xyz');
  });

  test('landCopilotConnect adds a copilot entry with the entry-scoped '
      'token slot', () async {
    final registry = ProviderRegistry.inMemory();
    final sessionKeys = SessionKeysStore.inMemory();
    final provider = await FaUiSso.landCopilotConnect(
      registry,
      const CopilotConnectResult(
        githubToken: 'gho_token',
        login: 'octo',
        entryName: 'copilot-octo',
        accountType: CopilotAccountType.business,
        modelId: 'gpt-5',
      ),
      sessionKeys: sessionKeys,
    );
    expect(provider, isNotNull);
    expect(provider!.name, 'copilot-octo');
    expect(provider.baseUrl, 'https://api.business.githubcopilot.com');
    expect(provider.kind, 'copilot');
    expect(provider.modelId, 'gpt-5');
    expect(registry.keyFor(provider.id), 'gho_token');
    // No Keychain under `flutter test` — the saved-keys store is the
    // portable fallback and must carry the entry-scoped slot.
    expect(
      sessionKeys.valueOf(
        CustomProviderRegistry.copilotEntryKeyName('copilot-octo'),
      ),
      'gho_token',
    );
  });

  test(
    'landCopilotConnect re-auth refreshes the matched entry in place',
    () async {
      final registry = ProviderRegistry.inMemory();
      final existing = await registry.add(
        name: 'copilot-octo',
        baseUrl: 'https://api.business.githubcopilot.com',
        modelId: 'gpt-5',
        kind: 'copilot',
      );
      registry.rememberKey(existing.id, 'old');
      final provider = await FaUiSso.landCopilotConnect(
        registry,
        const CopilotConnectResult(
          githubToken: 'new',
          login: 'octo',
          entryName: 'copilot-octo',
          accountType: CopilotAccountType.business,
          modelId: 'gpt-5',
        ),
      );
      expect(provider!.id, existing.id);
      expect(registry.providers, hasLength(1));
      expect(registry.keyFor(existing.id), 'new');
    },
  );

  test('landCopilotConnect without a model lands nothing', () async {
    final registry = ProviderRegistry.inMemory();
    final provider = await FaUiSso.landCopilotConnect(
      registry,
      const CopilotConnectResult(
        githubToken: 'gho_token',
        login: 'octo',
        entryName: 'copilot-octo',
        accountType: CopilotAccountType.individual,
        modelId: '',
      ),
    );
    expect(provider, isNull);
    expect(registry.providers, isEmpty);
  });
}

/// Runs [flow] from a live context under a MaterialApp (snacks and pushed
/// pages resolve), optionally tapping [thenTap] on the pushed pick page.
Future<bool> _run(
  WidgetTester tester,
  Future<bool> Function(BuildContext) flow, {
  Finder? thenTap,
}) async {
  var result = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => result = await flow(context),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  if (thenTap != null) {
    await tester.tap(thenTap);
    await tester.pumpAndSettle();
  }
  return result;
}

/// A minimal JWT carrying an `email` claim (the identity seed for the
/// ChatGPT/AIIN entry names).
String _idToken(String email) {
  String part(Map<String, Object> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'email': email})}.sig';
}
