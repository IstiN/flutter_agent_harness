// The AIIN connect flow's paste-key fallback: when the automatic sign-in
// does not complete (the mobile sign-in cancelled or failed to start), the
// flow must still complete — cabinet key paste → model pick → provider
// saved. Android is the default test target and runs the mobile branch
// (issue #976); a null `aiinConnectFn` result triggers the fallback.
import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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

  testWidgets('the AIIN model picker filters the fetched model list', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    BuildContext? flowContext;
    Future<bool>? done;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Builder(
              builder: (context) {
                flowContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    done = runAiinConnectFlow(
      context: flowContext!,
      registry: registry,
      service: null,
      lastConnectionStore: LastConnectionStore.inMemory(),
      aiinConnectFn: () async => _fakeConnectResult(),
      aiinModelsFetcher: (baseUrl, {required apiKey}) async => [
        'moonshotai/kimi-k2',
        'deepseek-ai/deepseek-v3',
        'qwen/qwen-72b',
        'meta-llama/llama-3-70b',
      ],
    );

    // Sign-in succeeded → the model picker shows the full list and count.
    await tester.pumpAndSettle();

    // The picker shows the full list and the live count.
    expect(find.text('4 models'), findsOneWidget);
    expect(find.text('moonshotai/kimi-k2'), findsOneWidget);

    // Typing filters the list and updates the count.
    final filterField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Filter models…',
    );
    await tester.enterText(filterField, 'kimi');
    await tester.pump();
    expect(find.text('1 of 4'), findsOneWidget);
    expect(find.text('moonshotai/kimi-k2'), findsOneWidget);
    expect(find.text('deepseek-ai/deepseek-v3'), findsNothing);

    // Picking the filtered model completes the connect.
    await tester.tap(find.text('moonshotai/kimi-k2'));
    final completed = await done;
    expect(completed, isTrue);
    expect(registry.providers.single.modelId, 'moonshotai/kimi-k2');
  });

  testWidgets('AIIN connect falls back to the paste-key dialog when the '
      'service blocks the redirect, and completes the connect', (tester) async {
    final registry = ProviderRegistry.inMemory();
    BuildContext? flowContext;
    Future<bool>? done;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Builder(
              builder: (context) {
                flowContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    done = runAiinConnectFlow(
      context: flowContext!,
      registry: registry,
      service: null,
      lastConnectionStore: LastConnectionStore.inMemory(),
      // The sign-in did not complete (cancelled/failed) → paste-key path.
      aiinConnectFn: () async => null,
    );

    // The paste-key dialog appears (initiate was rejected).
    await tester.pumpAndSettle();
    expect(find.text('AIIN API key'), findsOneWidget);
    expect(find.text('Open the AIIN cabinet'), findsOneWidget);

    // An invalid key keeps Connect disabled.
    await tester.enterText(find.byType(TextField), 'not-a-key');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))
          .onPressed,
      isNull,
    );

    // A valid key enables Connect.
    await tester.enterText(find.byType(TextField), 'sk-aiin-test-1234567890');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // The model picker opens (no models fetched) — use the manual entry.
    expect(find.text('AIIN model'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'kimi-k2');
    await tester.tap(find.text('Use'));
    final completed = await done;
    expect(completed, isTrue);

    // The provider was saved under the AIIN endpoint with the pasted key.
    expect(registry.providers, hasLength(1));
    final provider = registry.providers.single;
    expect(provider.baseUrl, 'https://api.aiin.by/v1');
    expect(provider.modelId, 'kimi-k2');
    expect(provider.name, startsWith('AIIN'));
    expect(registry.keyFor(provider.id), 'sk-aiin-test-1234567890');
  });

  testWidgets('re-auth mode refreshes the existing entry instead of adding '
      'one', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final existing = await registry.add(
      name: 'user@aiin.by',
      baseUrl: aiinDefaultChatBaseUrl,
      modelId: 'moonshotai/kimi-k2',
    );
    registry.rememberKey(existing.id, 'sk-aiin-old-key-000000000');
    BuildContext? flowContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Builder(
              builder: (context) {
                flowContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    final done = runAiinConnectFlow(
      context: flowContext!,
      registry: registry,
      service: null,
      lastConnectionStore: LastConnectionStore.inMemory(),
      // Sign-in failed → paste-key dialog → paste the fresh key.
      aiinConnectFn: () async => null,
      reauthenticateFor: existing,
    );

    // Timeout → paste-key dialog → paste the fresh key.
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sk-aiin-new-9999999999');
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(done, completion(true));
    // Still exactly one entry, same id/name/model; the key is refreshed.
    expect(registry.providers.length, 1);
    expect(registry.providers.first.id, existing.id);
    expect(registry.providers.first.modelId, 'moonshotai/kimi-k2');
    expect(registry.keyFor(existing.id), 'sk-aiin-new-9999999999');
  });
}

/// A fake automatic sign-in result driving the model-pick tail without the
/// network (the same contract `aiin_web_auth_test` runs against).
AiinConnectResult _fakeConnectResult() => AiinConnectResult(
      apiKey: const AiinApiKey(
        raw: 'sk-aiin-fake-key-0000000001',
        id: 'key-1',
        prefix: 'sk-aiin-fake',
        createdAt: '2026-09-26T00:00:00Z',
      ),
      tokens: const AiinOAuthTokens(
        accessToken: 'jwt-a',
        refreshToken: 'jwt-b',
        tokenType: 'Bearer',
        expiresIn: 3600,
        refreshExpiresIn: 86400,
      ),
      email: null,
    );
