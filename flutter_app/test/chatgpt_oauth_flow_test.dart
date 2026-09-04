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
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
/// canned OAuth result (no browser, no callback server).
Future<(Future<bool>, _RecordingService, ProviderRegistry)> _launch(
  WidgetTester tester, {
  ProviderRegistry? registry,
  SessionKeysStore? keys,
  required ChatGptOAuthCredentials credentials,
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
                platformSupportedFn: () => true,
                chatGptOAuthFlowFn: () async => credentials,
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
}
