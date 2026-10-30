// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/copilot_connect_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa_llm/fa_llm.dart';
import 'package:fa_ui/fa_ui.dart' show CopilotConnectCallbacks;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

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
  Future<void> reconfigure(
    AgentConfig config, {
    bool fromProviderAddFlow = false,
  }) async {
    reconfigured = config;
  }
}

CopilotConnectCallbacks _fixedCallbacks() => CopilotConnectCallbacks(
  requestDeviceCode: () async => const CopilotDeviceCode(
    deviceCode: 'dev123',
    userCode: 'ABCD-1234',
    verificationUri: 'https://github.com/login/device',
    expiresIn: 900,
    interval: Duration(seconds: 5),
  ),
  pollAccessToken: (_) async => 'gho_token',
  fetchLogin: (_) async => 'octocat',
  fetchModels: (_, _) async => const ['gpt-4.1', 'claude-sonnet-5'],
);

/// Pumps a 'go' button that launches the flow with in-memory stores; the
/// sheet's fake callbacks resolve immediately, so tapping 'Connect Copilot'
/// finishes it. Returns the flow future and the recording service.
Future<(Future<bool>, _RecordingService)> _launch(WidgetTester tester) async {
  final registry = ProviderRegistry.inMemory();
  final service = _RecordingService(MemoryExecutionEnv());
  Future<bool>? done;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              done = runCopilotConnectFlow(
                context: context,
                registry: registry,
                service: service,
                lastConnectionStore: LastConnectionStore.inMemory(),
                sessionKeysStore: SessionKeysStore.inMemory(),
                callbacks: _fixedCallbacks(),
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
  await tester.tap(find.text('Sign in with GitHub'));
  await tester.pumpAndSettle();
  return (done!, service);
}

void main() {
  // Android counts as a KeychainStore surface now (issue #329) and tests
  // default to the android target — with no native channel behind it the
  // unhandled platform message never completes and hangs the FakeAsync
  // zone. Answer like the pre-#329 gate did: no secure store.
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

  test('copilotEntryKeyName sanitizes entry names like the CLI', () {
    expect(
      CustomProviderRegistry.copilotEntryKeyName('copilot-octocat'),
      'FA_KEY_COPILOT_COPILOT_OCTOCAT',
    );
    expect(
      CustomProviderRegistry.copilotEntryKeyName('copilot.alice-smith'),
      'FA_KEY_COPILOT_COPILOT_ALICE_SMITH',
    );
    expect(
      CustomProviderRegistry.copilotEntryKeyName('Acme 2'),
      'FA_KEY_COPILOT_ACME_2',
    );
    expect(
      CustomProviderRegistry.copilotEntryKeyName('_-x-_'),
      'FA_KEY_COPILOT_X',
    );
  });

  testWidgets('a completed flow reconfigures the service as copilot', (
    tester,
  ) async {
    final (done, service) = await _launch(tester);
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    // The sheet's model step (first fetched id preselected) finishes it.
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);

    expect(service.reconfigured, isNotNull);
    expect(service.reconfigured!.providerKind, 'copilot');
    expect(service.reconfigured!.modelId, 'gpt-4.1');
    expect(service.reconfigured!.baseUrl, 'https://api.githubcopilot.com');
    expect(service.reconfigured!.apiKey, 'gho_token');
  });

  testWidgets('the connect result persists an entry-scoped token and a '
      'copilot entry', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final keys = SessionKeysStore.inMemory();
    final last = LastConnectionStore.inMemory();
    final service = _RecordingService(MemoryExecutionEnv());
    Future<bool>? done;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                done = runCopilotConnectFlow(
                  context: context,
                  registry: registry,
                  service: service,
                  lastConnectionStore: last,
                  sessionKeysStore: keys,
                  callbacks: _fixedCallbacks(),
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
    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    // The sheet's model step (first fetched id preselected) finishes it.
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);

    final entry = registry.providers.single;
    expect(entry.name, 'copilot-octocat');
    expect(entry.baseUrl, 'https://api.githubcopilot.com');
    expect(registry.keyFor(entry.id), 'gho_token');
    expect(keys.valueOf('FA_KEY_COPILOT_COPILOT_OCTOCAT'), 'gho_token');
    expect(last.connection!.providerKind, 'copilot');
    expect(last.connection!.baseUrl, 'https://api.githubcopilot.com');
  });

  testWidgets('re-auth updates only the matching entry and keeps its model', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    final existing = await registry.add(
      name: 'copilot-octocat',
      baseUrl: 'https://api.githubcopilot.com',
      modelId: 'my-pick',
    );
    registry.rememberKey(existing.id, 'gho_old');

    final service = _RecordingService(MemoryExecutionEnv());
    Future<bool>? done;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                done = runCopilotConnectFlow(
                  context: context,
                  registry: registry,
                  service: service,
                  lastConnectionStore: LastConnectionStore.inMemory(),
                  sessionKeysStore: SessionKeysStore.inMemory(),
                  callbacks: _fixedCallbacks(),
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
    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    // The sheet's model step (first fetched id preselected) finishes it.
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);

    // Still one entry, same id, refreshed key, kept model.
    expect(registry.providers.length, 1);
    expect(registry.providers.single.id, existing.id);
    expect(registry.providers.single.modelId, 'my-pick');
    expect(registry.keyFor(existing.id), 'gho_token');
    expect(service.reconfigured!.modelId, 'my-pick');
  });

  testWidgets('dismissing the sheet reports false and stores nothing', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    final service = _RecordingService(MemoryExecutionEnv());
    Future<bool>? done;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                done = runCopilotConnectFlow(
                  context: context,
                  registry: registry,
                  service: service,
                  lastConnectionStore: LastConnectionStore.inMemory(),
                  sessionKeysStore: SessionKeysStore.inMemory(),
                  callbacks: _fixedCallbacks(),
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

    // Tap the modal barrier above the sheet.
    await tester.tapAt(const Offset(20, 60));
    await tester.pumpAndSettle();

    expect(await done, isFalse);
    expect(registry.providers, isEmpty);
    expect(service.reconfigured, isNull);
  });

  group('default report callback (gh-1990)', () {
    tearDown(() {
      setModelsDispatchClientForTesting(null);
    });

    test('a healthy answer lists models with no reason', () async {
      final client = http_testing.MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            '{"token":"[REDACTED:credential]","expires_at":9999999999}',
            200,
          );
        }
        return http.Response(
          '{"data":[{"id":"gpt-4.1","model_picker_enabled":true,'
          '"supported_endpoints":["/chat/completions"]}]}',
          200,
        );
      });
      setModelsDispatchClientForTesting(client);
      final callback = defaultCopilotCallbacks().fetchModelsReport;

      final (ids, reason) = await callback!(
        'gho_dead',
        'https://api.githubcopilot.com',
      );

      expect(ids, ['gpt-4.1']);
      expect(reason, isNull);
    });

    test(
      'an empty answer names the exchange branch with the remedies',
      () async {
        final client = http_testing.MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response('{"message":"Bad credentials"}', 401);
          }
          return http.Response('{"message":"no"}', 401);
        });
        setModelsDispatchClientForTesting(client);
        final callback = defaultCopilotCallbacks().fetchModelsReport;

        // A classic ghp_ PAT retries PAT-direct (also 401 here) — the
        // combined reason names both paths and hints at the remedies.
        final (ids, reason) = await callback!(
          'ghp_deadbeef',
          'https://api.githubcopilot.com',
        );

        expect(ids, isEmpty);
        expect(reason, contains('exchange path:'));
        expect(reason, contains('pat-direct path:'));
        expect(reason, contains('OAuth device flow'));
      },
    );
  });
}
