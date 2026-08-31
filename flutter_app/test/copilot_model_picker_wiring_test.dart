// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

library;

/// App-level wiring test for Copilot model listing: the fetcher the app
/// injects into the pickers (see ProvidersSection.modelsFetcher /
/// providerModelFetcher) reaches a Copilot registry entry with its GitHub
/// token, the fetched models render, and the applied connection is the
/// copilot kind (not openai-completions, which would 401 the raw GitHub
/// token against the Copilot API).
///
/// Deliberately free of `fa/services/agent_service.dart` (and everything
/// downstream of it): that import chain drags in js_widget_runtime ->
/// flame -> flame_3d, which currently fails to compile against the pinned
/// Flutter SDK (pre-existing, unrelated to Copilot). The AgentService-level
/// adapter lives in providers_section_test.dart and covers the same flow
/// once the dependency drift is fixed.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake [FaChatConnection] capturing what the picker applies — the same
/// shape the app's AgentService reconfigure would receive.
class _FakeConnection extends ChangeNotifier implements FaChatConnection {
  _FakeConnection();

  final String baseUrl = 'https://example.com';
  final String kind = 'test';
  String model = 'test-model';
  String? providerId;
  FaChatModelConfig? applied;

  @override
  String get providerKind => kind;
  @override
  String get activeBaseUrl => baseUrl;
  @override
  String? get activeProviderId => providerId;
  @override
  String get modelId => model;
}

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, inner) =>
          SessionKeysScope(store: SessionKeysStore.inMemory(), child: inner!),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  testWidgets('a Copilot entry lists real models via the app fetcher and '
      'applies the copilot kind', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final provider = await registry.add(
      name: 'Copilot Work',
      baseUrl: 'https://api.individual.githubcopilot.com',
      modelId: 'gpt-4.1',
    );
    registry.rememberKey(provider.id, 'gho_session');
    final connection = _FakeConnection();

    final fetchedUrls = <String>[];
    final fetchedKeys = <String>[];
    await _pump(
      tester,
      DefaultChatModelSection(
        connection: connection,
        registry: registry,
        // The app's fetcher wiring (ProvidersSection forwards exactly this
        // shape into every picker).
        modelsFetcher: (baseUrl, {required apiKey}) async {
          fetchedUrls.add(baseUrl);
          fetchedKeys.add(apiKey);
          return (
            const ['gpt-4.1', 'claude-sonnet-4'],
            const <String, int>{},
            const <String, int>{},
          );
        },
        onApply: (config) async => connection.applied = config,
      ),
    );

    // The two-step flow: provider row -> model page.
    await tester.tap(find.text('test-model · example.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copilot Work'));
    await tester.pumpAndSettle();

    // The fetcher reached the Copilot endpoint with the entry's GitHub
    // token, and the fetched (real) models render.
    expect(fetchedUrls.single, 'https://api.individual.githubcopilot.com');
    expect(fetchedKeys.single, 'gho_session');
    expect(find.text('claude-sonnet-4'), findsOneWidget);

    await tester.tap(find.text('claude-sonnet-4'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The applied connection is the copilot kind with the entry's key.
    expect(connection.applied, isNotNull);
    expect(connection.applied!.providerKind, 'copilot');
    expect(connection.applied!.modelId, 'claude-sonnet-4');
    expect(
      connection.applied!.baseUrl,
      'https://api.individual.githubcopilot.com',
    );
    expect(connection.applied!.apiKey, 'gho_session');
  });

  testWidgets('a Copilot media-slot save keeps the OpenAI media contract '
      'while the role flow saves the copilot kind', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final provider = await registry.add(
      name: 'Copilot Work',
      baseUrl: 'https://api.business.githubcopilot.com',
      modelId: 'gpt-4.1',
    );
    registry.rememberKey(provider.id, 'gho_session');

    for (final (slot, expectedKind) in [
      (MediaSlot.imageGeneration, 'openai-completions'),
      (null, 'copilot'),
    ]) {
      MediaSlotEditorResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  result = await Navigator.of(context)
                      .push<MediaSlotEditorResult>(
                        MaterialPageRoute(
                          builder: (_) => MediaSlotModelPage(
                            slot: slot,
                            provider: provider,
                            registry: registry,
                            initialModel: 'gpt-4.1',
                          ),
                        ),
                      );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(result!.override!.providerKind, expectedKind);
      expect(result!.override!.baseUrl, provider.baseUrl);
    }
  });
}
