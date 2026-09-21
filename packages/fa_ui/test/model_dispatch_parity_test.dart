// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #771: one model-list dispatch for every surface. The fa_ui
/// pickers (media-slot model page, unified default-chat picker) must
/// resolve EVERY dialect-bearing provider kind through the core
/// `fetchModelsForEndpoint` dispatch, with identity-driven hints beating
/// URL-shape guessing and a truthful bundled-catalog provenance note when
/// the live fetch fails.
library;

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

/// The requests the dispatch made during the current test.
List<String> seenUrls = [];

/// Routes every registered dialect's wire to a canned answer: one live
/// model per kind, each distinct so the assertions prove WHICH wire was
/// spoken.
http.Client _dispatchRouter() => MockClient((request) async {
  final url = request.url.toString();
  seenUrls.add(url);
  if (url == '$chatGptCodexBaseUrl/models') {
    return http.Response(
      '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.7-flask"}]}',
      200,
    );
  }
  if (url == 'https://ai-proxy.lab.epam.com/openai/models') {
    return http.Response('{"data":[{"id":"terra"}]}', 200);
  }
  if (url.contains('/llm_models')) {
    return http.Response('[{"id":"litellm-1"}]', 200);
  }
  if (request.url.host == 'api.github.com') {
    return http.Response('{"token":"tid=x","expires_at":9999999999}', 200);
  }
  if (request.url.host.endsWith('githubcopilot.com')) {
    return http.Response(
      '{"data":[{"id":"gpt-4.1","model_picker_enabled":true,'
      '"capabilities":{"supports":{"tool_calls":true}}}]}',
      200,
    );
  }
  return http.Response('not found', 404);
});

/// One registry entry per dialect-bearing kind, keyed the way each
/// provider's connect flow saves it. DIAL uses a real DIAL host — the
/// hint (and thus the dialect) keys off the identity-bearing host.
final _kindEntries =
    <String, ({String name, String baseUrl, String key, String id, String wire})>{
  'chatgpt-codex': (
    name: 'ChatGPT Codex',
    baseUrl: chatGptCodexBaseUrl,
    key: 'blob',
    id: 'gpt-5.6-sol',
    wire: '$chatGptCodexBaseUrl/models',
  ),
  'dial': (
    name: 'DIAL',
    baseUrl: 'https://ai-proxy.lab.epam.com',
    key: 'dial-key',
    id: 'terra',
    wire: 'https://ai-proxy.lab.epam.com/openai/models',
  ),
  'codemie': (
    name: 'CodeMie',
    baseUrl: 'https://org.example.com/code-assistant-api/v1',
    key: 'cookie',
    id: 'litellm-1',
    wire: 'https://org.example.com/code-assistant-api/v1/llm_models',
  ),
  'copilot': (
    name: 'Copilot',
    baseUrl: 'https://api.individual.githubcopilot.com',
    key: 'gho_session',
    id: 'gpt-4.1',
    wire: 'api.individual.githubcopilot.com/models',
  ),
};

Future<CustomProvider> _addEntry(ProviderRegistry registry, String kind) async {
  final entry = _kindEntries[kind]!;
  final provider = await registry.add(
    name: entry.name,
    baseUrl: entry.baseUrl,
    modelId: entry.id,
  );
  registry.rememberKey(provider.id, entry.key);
  return provider;
}

/// Pumps [page] as the home with a [SessionKeysScope], matching how real
/// host pages resolve their scoped stores. [key] must differ between
/// pumps of the same page type so elements rebuild fresh.
Future<void> _pumpPage(WidgetTester tester, Widget page, Key key) {
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          SessionKeysScope(store: SessionKeysStore.inMemory(), child: child!),
      home: KeyedSubtree(key: key, child: Scaffold(body: page)),
    ),
  );
}

void main() {
  setUp(() {
    seenUrls = [];
    setModelsDispatchClientForTesting(_dispatchRouter());
  });
  tearDown(() => setModelsDispatchClientForTesting(null));

  test(
    'the dispatch hint maps the Codex backend by identity, not URL shape',
    () {
      expect(modelsDispatchHintFor(chatGptCodexBaseUrl), 'chatgpt-codex');
      // A plain OpenAI-shaped URL stays null (the generic dialect).
      expect(modelsDispatchHintFor('https://api.openai.com/v1'), isNull);
    },
  );

  testWidgets(
    'the media-slot model page routes every dialect kind through the '
    'dispatch',
    (tester) async {
      var generation = 0;
      for (final kind in _kindEntries.keys) {
        seenUrls.clear();
        final registry = ProviderRegistry.inMemory();
        final provider = await _addEntry(registry, kind);
        final entry = _kindEntries[kind]!;

        await _pumpPage(
          tester,
          MediaSlotModelPage(
            provider: provider,
            registry: registry,
            initialModel: '',
          ),
          ValueKey('media-$kind-${generation++}'),
        );
        await tester.pumpAndSettle();

        // The page spoke ONLY the kind's own wire (one dispatch call, no
        // local re-fetch), and the live model rendered.
        expect(
          seenUrls.where((url) => url.contains(_kindUrlProbe(entry.wire))),
          isNotEmpty,
          reason: 'kind $kind must hit ${entry.wire}',
        );
        // Exactly one dispatch call — copilot's dialect is two-leg
        // (GitHub token exchange, then the models API).
        expect(
          seenUrls.length,
          kind == 'copilot' ? 2 : 1,
          reason: 'kind $kind: no extra fetches beyond the dialect wire',
        );
        expect(
          find.text(entry.id, findRichText: true),
          findsWidgets,
          reason: 'kind $kind must list ${entry.id} through the dispatch',
        );
      }
    },
  );

  testWidgets(
    'the media-slot page shows the bundled-catalog note when the live '
    'codex fetch fails',
    (tester) async {
      setModelsDispatchClientForTesting(
        MockClient((request) async => http.Response('unauthorized', 401)),
      );
      final registry = ProviderRegistry.inMemory();
      final provider = await _addEntry(registry, 'chatgpt-codex');

      await _pumpPage(
        tester,
        MediaSlotModelPage(
          provider: provider,
          registry: registry,
          initialModel: '',
        ),
        const ValueKey('media-bundled'),
      );
      await tester.pumpAndSettle();

      // The bundled catalog answered (never-empty), and the page says so.
      expect(find.text('gpt-5.6-sol', findRichText: true), findsWidgets);
      expect(find.textContaining('bundled catalog'), findsOneWidget);
    },
  );

  testWidgets(
    'the unified picker routes dialect entries through the dispatch',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      for (final kind in _kindEntries.keys) {
        await _addEntry(registry, kind);
      }
      FaChatModelConfig? applied;

      await _pumpPage(
        tester,
        SizedBox(
          width: 800,
          height: 1200,
          child: UnifiedModelPickerPage(
            connection: _FakeConnection(),
            onApply: (config) async => applied = config,
            registry: registry,
          ),
        ),
        const ValueKey('unified'),
      );
      await tester.pumpAndSettle();

      // Every dialect entry fetched through its own wire.
      for (final kind in _kindEntries.keys) {
        final wire = _kindUrlProbe(_kindEntries[kind]!.wire);
        expect(
          seenUrls.where((url) => url.contains(wire)),
          isNotEmpty,
          reason: 'kind $kind must fetch $wire via the dispatch',
        );
      }
    },
  );
}

/// Copilot speaks two hosts (token exchange, then the models API) — probe
/// by host; every other dialect by its full request path.
String _kindUrlProbe(String wire) =>
    wire.contains('/models') && wire.contains('githubcopilot.com')
    ? 'githubcopilot.com'
    : wire;
