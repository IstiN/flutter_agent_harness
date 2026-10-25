// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Issue #1848 coverage: [UnifiedModelPickerPage]'s manual-entry escape
/// (the typed id applied on the ACTIVE provider's endpoint with its
/// resolved key) and the `/models` fetch arms — the key resolution chain,
/// the saved-model fallbacks, and the per-model window/cap plumbing.
void main() {
  final applied = <FaChatModelConfig>[];

  setUp(applied.clear);

  /// Pumps the picker; [registry] may be null (the no-providers surface —
  /// the manual escape still applies there, keyless).
  Future<void> pumpPicker(
    WidgetTester tester, {
    ProviderRegistry? registry,
    required ModelsEndpointFetcher fetcher,
    FaStaticChatConnection? connection,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedModelPickerPage(
          connection:
              connection ??
              FaStaticChatConnection(
                providerKind: 'openai-completions',
                activeBaseUrl: 'https://acme.example/v1',
                modelId: 'acme-1',
              ),
          onApply: (config) async => applied.add(config),
          registry: registry,
          modelsFetcher: fetcher,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// An in-memory registry holding one 'Acme' entry (id returned for key
  /// remembering).
  Future<ProviderRegistry> registryWithAcme({
    String modelId = 'saved-1',
    String baseUrl = 'https://acme.example/v1',
  }) async {
    final registry = ProviderRegistry.inMemory();
    await registry.add(name: 'Acme', baseUrl: baseUrl, modelId: modelId);
    addTearDown(registry.dispose);
    return registry;
  }

  testWidgets('the manual escape applies the typed id with the active '
      'provider base-url-matched key', (tester) async {
    final registry = await registryWithAcme();
    registry.rememberKey(registry.providers.single.id, 'k-1');
    await pumpPicker(tester, registry: registry, fetcher: _listing);

    await tester.enterText(find.byType(TextField), 'totally-new-model');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use "totally-new-model"'));
    await tester.pumpAndSettle();

    expect(applied, hasLength(1));
    expect(applied.single.modelId, 'totally-new-model');
    expect(applied.single.baseUrl, 'https://acme.example/v1');
    expect(applied.single.apiKey, 'k-1');
  });

  testWidgets('the manual escape prefers the connection provider id when '
      'the surface carries one', (tester) async {
    final registry = await registryWithAcme();
    final id = registry.providers.single.id;
    registry.rememberKey(id, 'k-1');
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: _listing,
      connection: FaStaticChatConnection(
        providerKind: 'openai-completions',
        activeBaseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
        activeProviderId: id,
      ),
    );

    await tester.enterText(find.byType(TextField), 'typed-model');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use "typed-model"'));
    await tester.pumpAndSettle();

    expect(applied.single.modelId, 'typed-model');
    expect(applied.single.apiKey, 'k-1');
  });

  testWidgets('the manual escape without a registry applies keyless', (
    tester,
  ) async {
    await pumpPicker(tester, fetcher: _listing);

    await tester.enterText(find.byType(TextField), 'typed-model');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use "typed-model"'));
    await tester.pumpAndSettle();

    expect(applied, hasLength(1));
    expect(applied.single.modelId, 'typed-model');
    expect(applied.single.apiKey, '');
  });

  testWidgets('the registry session key rides into the fetch', (tester) async {
    final registry = await registryWithAcme();
    registry.rememberKey(registry.providers.single.id, 'k-1');
    final keysByBase = <String, String>{};
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: (baseUrl, {required apiKey}) async {
        keysByBase[baseUrl] = apiKey;
        return _listing(baseUrl, apiKey: apiKey);
      },
    );
    expect(keysByBase['https://acme.example/v1'], 'k-1');
  });

  testWidgets('a hosted preset entry resolves its named key through the '
      'host chain when no saved entry covers the endpoint', (tester) async {
    final registry = await registryWithAcme();
    FaUiHost.keyResolver = (name) =>
        name == "OPENROUTER_API_KEY" ? "hosted-key" : "";
    addTearDown(() => FaUiHost.keyResolver = null);
    final keysByBase = <String, String>{};
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: (baseUrl, {required apiKey}) async {
        keysByBase[baseUrl] = apiKey;
        return _listing(baseUrl, apiKey: apiKey);
      },
    );
    // The hosted OpenRouter endpoint was collected (its key resolves) and
    // fetched with the host-chain key; the plain entry stayed keyless.
    expect(keysByBase['https://openrouter.ai/api/v1'], 'hosted-key');
    expect(keysByBase['https://acme.example/v1'], '');
  });

  testWidgets('a saved Copilot entry whose session key is gone falls back '
      'to its entry-scoped token slot', (tester) async {
    final registry = await registryWithAcme(
      baseUrl: 'https://api.githubcopilot.com',
    );
    // No rememberKey: the session key is gone (the restart-without-
    // Keychain case) — the entry-scoped FA_KEY_COPILOT_<NAME> resolves.
    FaUiHost.keyResolver = (name) =>
        name == 'FA_KEY_COPILOT_ACME' ? 'copilot-token' : '';
    addTearDown(() => FaUiHost.keyResolver = null);
    final keysByBase = <String, String>{};
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: (baseUrl, {required apiKey}) async {
        keysByBase[baseUrl] = apiKey;
        return _listing(baseUrl, apiKey: apiKey);
      },
    );
    expect(keysByBase['https://api.githubcopilot.com'], 'copilot-token');
  });

  testWidgets('a listing without models falls back to the saved model', (
    tester,
  ) async {
    final registry = await registryWithAcme();
    registry.rememberKey(registry.providers.single.id, 'k-1');
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: (_, {required apiKey}) async =>
          (const <String>[], const <String, int>{}, const <String, int>{}),
    );
    // The active model is prepended; the provider's own saved-model row
    // is the tile carrying its id.
    await tester.tap(
      find.textContaining('saved-1', findRichText: true),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(applied, hasLength(1));
    expect(applied.single.modelId, 'saved-1');
    expect(applied.single.apiKey, 'k-1');
    // No persisted kind → the URL infers the plain wire shape.
    expect(applied.single.providerKind, 'openai-completions');
    expect(applied.single.contextWindow, fallbackContextWindow);
    expect(applied.single.maxTokens, fallbackMaxTokens);
  });

  testWidgets('a dead endpoint falls back to the saved model with the '
      'registry key and the persisted kind', (tester) async {
    final registry = ProviderRegistry.inMemory();
    addTearDown(registry.dispose);
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'saved-1',
      kind: 'dial',
    );
    registry.rememberKey(registry.providers.single.id, 'k-2');
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: (_, {required apiKey}) async => throw StateError('down'),
    );
    await tester.tap(
      find.textContaining('saved-1', findRichText: true),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(applied, hasLength(1));
    expect(applied.single.modelId, 'saved-1');
    expect(applied.single.apiKey, 'k-2');
    // The persisted identity wins: the dial wire shape rides through.
    expect(applied.single.providerKind, 'dial');
  });

  testWidgets('an empty listing with no saved model contributes no entry', (
    tester,
  ) async {
    final registry = await registryWithAcme(modelId: '');
    await pumpPicker(
      tester,
      registry: registry,
      fetcher: (_, {required apiKey}) async =>
          (const <String>[], const <String, int>{}, const <String, int>{}),
    );
    // The provider contributed nothing; the active model row (its label
    // resolves through the same registry) is the only model tile.
    expect(find.textContaining('saved-1', findRichText: true), findsNothing);
    expect(find.textContaining('acme-1', findRichText: true), findsOneWidget);
  });

  testWidgets('a reported per-model window applies; a missing cap takes '
      'the fallback', (tester) async {
    final registry = await registryWithAcme();
    await pumpPicker(tester, registry: registry, fetcher: _windowsCaps);

    await tester.tap(
      find.textContaining('m1', findRichText: true),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(applied.single.modelId, 'm1');
    expect(applied.single.contextWindow, 8000);
    expect(applied.single.maxTokens, fallbackMaxTokens);
  });

  testWidgets('a reported per-model cap applies; a missing window takes '
      'the fallback', (tester) async {
    final registry = await registryWithAcme();
    await pumpPicker(tester, registry: registry, fetcher: _windowsCaps);

    await tester.tap(
      find.textContaining('m2', findRichText: true),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(applied.single.modelId, 'm2');
    expect(applied.single.contextWindow, fallbackContextWindow);
    expect(applied.single.maxTokens, 4096);
  });
}

/// A two-model listing where m1 reports a window and m2 a cap.
Future<ModelsEndpointInfo> _windowsCaps(
  String baseUrl, {
  required String apiKey,
}) async => (const ['m1', 'm2'], const {'m1': 8000}, const {'m2': 4096});

/// A two-model listing (no windows, no caps).
Future<ModelsEndpointInfo> _listing(
  String baseUrl, {
  required String apiKey,
}) async => (const ['m1', 'm2'], const <String, int>{}, const <String, int>{});
