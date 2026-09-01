// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A fake [FaChatConnection] standing in for the host's agent service.
class _FakeConnection extends ChangeNotifier implements FaChatConnection {
  _FakeConnection();

  final String baseUrl = 'https://example.com';
  final String kind = 'test';
  String model = 'test-model';
  String? providerId;

  @override
  String get providerKind => kind;
  @override
  String get activeBaseUrl => baseUrl;
  @override
  String? get activeProviderId => providerId;
  @override
  String get modelId => model;
}

const _copilotBaseUrl = 'https://api.individual.githubcopilot.com';

/// A Copilot registry entry wired the way [runCopilotConnectFlow] does it
/// on the app side (the CLI contract: entry name + githubcopilot.com host).
Future<CustomProvider> _addCopilotEntry(ProviderRegistry registry) async {
  return registry.add(
    name: 'Copilot Work',
    baseUrl: _copilotBaseUrl,
    modelId: 'gpt-4.1',
  );
}

/// Pumps a home button that pushes [page] and captures its pop result.
///
/// [keysStore] wraps the NAVIGATOR (MaterialApp.builder), matching the
/// app's boot wiring — pushed routes resolve the scope like real pages do.
Future<void> _pumpWithOpener(
  WidgetTester tester,
  Widget page,
  void Function(Object?) onResult, {
  SessionKeysStore? keysStore,
}) {
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => SessionKeysScope(
        store: keysStore ?? SessionKeysStore.inMemory(),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              final result = await Navigator.of(
                context,
              ).push<Object?>(MaterialPageRoute(builder: (_) => page));
              onResult(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('copilot model dispatch', () {
    test('the picker dispatch hint maps copilot endpoints to the copilot '
        'dialect', () {
      expect(modelsDispatchHintFor(_copilotBaseUrl), 'copilot');
      expect(
        modelsDispatchHintFor('https://api.business.githubcopilot.com'),
        'copilot',
      );
      expect(modelsDispatchHintFor('https://ai-proxy.lab.epam.com'), 'dial');
      expect(modelsDispatchHintFor('https://api.openai.com/v1'), isNull);
    });

    testWidgets('the unified picker applies the copilot provider kind', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await _addCopilotEntry(registry);
      registry.rememberKey(provider.id, 'gho_session');
      FaChatModelConfig? applied;

      await _pumpWithOpener(
        tester,
        UnifiedModelPickerPage(
          connection: _FakeConnection(),
          onApply: (config) async => applied = config,
          registry: registry,
          modelsFetcher: (baseUrl, {required apiKey}) async => (
            const ['gpt-4.1'],
            const {'gpt-4.1': 128000},
            const <String, int>{},
          ),
        ),
        (_) {},
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The picker lists the entry's models (the fetch override proves the
      // request reached the picker with the entry's resolved key).
      expect(
        find.textContaining('gpt-4.1', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('gpt-4.1', findRichText: true));
      await tester.pumpAndSettle();

      // The picked model connects AS copilot — not openai-completions.
      expect(applied, isNotNull);
      expect(applied!.providerKind, 'copilot');
      expect(applied!.baseUrl, _copilotBaseUrl);
      expect(applied!.apiKey, 'gho_session');
    });
  });

  group('copilot entry key resolution', () {
    test('resolveProviderKey falls back to the entry-scoped slot', () async {
      final registry = ProviderRegistry.inMemory();
      final provider = await _addCopilotEntry(registry);

      // No key anywhere yet.
      expect(resolveProviderKey(provider, registry: registry), isEmpty);

      // The entry-scoped slot (FA_KEY_COPILOT_<NAME>, the CLI contract)
      // resolves when the registry session key is gone (restart).
      final keys = SessionKeysStore.inMemory({
        'FA_KEY_COPILOT_COPILOT_WORK': 'gho_entry',
      });
      expect(
        resolveProviderKey(provider, registry: registry, keysStore: keys),
        'gho_entry',
      );

      // The remembered registry key wins over the entry-scoped slot.
      registry.rememberKey(provider.id, 'gho_session');
      expect(
        resolveProviderKey(provider, registry: registry, keysStore: keys),
        'gho_session',
      );
    });

    testWidgets('the model page fetches copilot models with the '
        'entry-scoped key and saves the copilot kind', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await _addCopilotEntry(registry);
      // Deliberately NO rememberKey — the token only lives in the
      // entry-scoped slot, as after a restart without a Keychain.
      final keys = SessionKeysStore.inMemory({
        'FA_KEY_COPILOT_COPILOT_WORK': 'gho_entry',
      });

      String? fetchedUrl;
      String? fetchedKey;
      Object? result;
      await _pumpWithOpener(
        tester,
        MediaSlotModelPage(
          provider: provider,
          registry: registry,
          initialModel: 'gpt-4.1',
          modelsFetcher: (baseUrl, {required apiKey}) async {
            fetchedUrl = baseUrl;
            fetchedKey = apiKey;
            return (
              const ['gpt-4.1', 'claude-sonnet-4'],
              const <String, int>{},
              const <String, int>{},
            );
          },
        ),
        (r) => result = r,
        keysStore: keys,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The endpoint's real model list rendered.
      expect(fetchedUrl, _copilotBaseUrl);
      expect(fetchedKey, 'gho_entry');
      expect(find.text('claude-sonnet-4'), findsOneWidget);

      // Saving connects the role/chat flow AS copilot.
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final override = (result! as MediaSlotEditorResult).override!;
      expect(override.providerKind, 'copilot');
      expect(override.baseUrl, _copilotBaseUrl);
    });
  });

  group('core copilot dialect (what the pickers dispatch into)', () {
    test('a copilot baseUrl exchanges the GitHub token before /models — '
        'not the generic OpenAI probe', () async {
      final urls = <String>[];
      final authHeaders = <String, String?>{};
      final client = MockClient((request) async {
        urls.add(request.url.toString());
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode({
              'token': 'tid_1',
              'expires_at': 4102444800,
              'refresh_in': 1400,
            }),
            200,
          );
        }
        authHeaders['authorization'] = request.headers['authorization'];
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'gpt-4.1',
                'model_picker_enabled': true,
                'capabilities': {
                  'limits': {
                    'max_context_window_tokens': 128000,
                    'max_output_tokens': 16384,
                  },
                },
              },
              {'id': 'claude-sonnet-4', 'model_picker_enabled': true},
            ],
          }),
          200,
        );
      });

      // No provider hint — exactly how the pickers call the dispatch for a
      // custom-provider Copilot entry.
      final (ids, windows, caps) = await fetchModelsForEndpoint(
        _copilotBaseUrl,
        apiKey: 'gho_github',
        client: client,
      );

      // The exchange came first, /models rode the exchanged token.
      expect(urls, [copilotTokenExchangeUrl, '$_copilotBaseUrl/models']);
      expect(authHeaders['authorization'], 'Bearer tid_1');
      expect(ids, ['claude-sonnet-4', 'gpt-4.1']);
      expect(windows['gpt-4.1'], 128000);
      expect(caps['gpt-4.1'], 16384);
    });
  });
}
