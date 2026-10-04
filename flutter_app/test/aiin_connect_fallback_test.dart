// The AIIN connect flow's failure state and re-auth contract (gh-1044:
// the owner ruled SSO is the only path — no key-paste fallback). Android
// is the default test target and runs the mobile branch (issue #976).
//
// - a null `aiinConnectFn` result is a VISIBLE error — never the paste
//   sheet (gh-1044 AC4);
// - re-auth mode refreshes the existing entry through a SUCCESSFUL SSO
//   round-trip (same id/name/model, fresh key).
import 'package:fa/services/aiin_connect_flow.dart';
import 'package:flutter/foundation.dart';
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

  testWidgets('a sign-in that does not complete is a visible error — '
      'never the paste sheet (gh-1044 AC4, the owner SSO-only ruling)', (
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
      // The sign-in did not complete (cancelled/failed to start).
      aiinConnectFn: () async => null,
    );

    // The visible failure state — and NO key-paste dialog (SSO only).
    await tester.pumpAndSettle();
    expect(
      find.textContaining('AIIN sign-in did not complete'),
      findsOneWidget,
    );
    expect(find.text('AIIN API key'), findsNothing);
    expect(find.text('Open the AIIN cabinet'), findsNothing);
    expect(done, completion(false));

    // Nothing was saved.
    expect(registry.providers, isEmpty);
    await tester.pump(const Duration(seconds: 8)); // expire the snacks
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('re-auth mode refreshes the existing entry through a '
      'successful SSO round-trip — instead of adding one', (tester) async {
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
      // An honest SSO round-trip completes and hands back the fresh key.
      aiinConnectFn: () async => _fakeConnectResult(),
      reauthenticateFor: existing,
    );

    // Re-auth keeps the entry's name and model — no model picker, no
    // sheet: the fresh key lands straight on the existing entry.
    await tester.pumpAndSettle();
    expect(find.text('AIIN model'), findsNothing);

    expect(done, completion(true));
    // Still exactly one entry, same id/name/model; the key is refreshed.
    expect(registry.providers.length, 1);
    expect(registry.providers.first.id, existing.id);
    expect(registry.providers.first.modelId, 'moonshotai/kimi-k2');
    expect(registry.keyFor(existing.id), 'sk-aiin-fake-key-0000000001');
  });
}

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
