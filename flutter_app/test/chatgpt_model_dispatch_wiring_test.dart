// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

library;

/// Issue #771 app-level wiring: the provider editor's model quick-select
/// and the default-chat picker resolve EVERY dialect-bearing provider
/// kind through the one core dispatch (`fetchModelsForEndpoint`) — no
/// per-surface fetchers, no local special-casing. The ChatGPT (codex)
/// registry entry must list models both right after the OAuth flow
/// (codex wire 200) and after it goes stale (401 -> bundled catalog with
/// the provenance note).
///
/// Like copilot_model_picker_wiring_test.dart, this file stays free of
/// `fa/services/agent_service.dart`: the AgentService-level adapter is
/// covered by providers_section_test.dart once the flame dependency
/// drift is fixed.

import 'package:fa_ui/fa_ui.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A fake [FaChatConnection] capturing what the picker applies.
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

Future<String> _blob() => Future.value(
  const ChatGptOAuthCredentials(
    accessToken: 'at-1',
    refreshToken: 'rt-1',
    idToken: 'it-1',
    accountId: 'acc-1',
  ).encode(),
);

/// One registry entry per dialect-bearing kind with its distinct live
/// model id.
final _kindEntries =
    <String, ({String name, String baseUrl, String key, String id})>{
      'chatgpt-codex': (
        name: 'ChatGPT Codex',
        baseUrl: chatGptCodexBaseUrl,
        key: 'blob',
        id: 'gpt-5.6-sol',
      ),
      'dial': (
        name: 'DIAL',
        baseUrl: 'https://ai-proxy.lab.epam.com',
        key: 'dial-key',
        id: 'terra',
      ),
      'codemie': (
        name: 'CodeMie',
        baseUrl: 'https://org.example.com/code-assistant-api/v1',
        key: 'cookie',
        id: 'litellm-1',
      ),
      'copilot': (
        name: 'Copilot',
        baseUrl: 'https://api.individual.githubcopilot.com',
        key: 'gho_session',
        id: 'gpt-4.1',
      ),
    };

http.Client _liveRouter() => MockClient((request) async {
  final url = request.url.toString();
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

Future<ProviderRegistry> _registryWith(String kind, {String? baseUrl}) async {
  final registry = ProviderRegistry.inMemory();
  final entry = _kindEntries[kind]!;
  final provider = await registry.add(
    name: entry.name,
    baseUrl: baseUrl ?? entry.baseUrl,
    modelId: entry.id,
    // The connect flows persist the entry's identity — mirror that.
    kind: kind,
  );
  registry.rememberKey(
    provider.id,
    kind == 'chatgpt-codex' ? await _blob() : entry.key,
  );
  return registry;
}

Future<void> _pumpForm(
  WidgetTester tester,
  ProviderRegistry registry, {
  required Key key,
}) {
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          SessionKeysScope(store: SessionKeysStore.inMemory(), child: child!),
      home: KeyedSubtree(
        key: key,
        child: Scaffold(
          body: SingleChildScrollView(
            child: AgentSettingsForm(
              registry: registry,
              onConnect: (_) async {},
            ),
          ),
        ),
      ),
    ),
  );
}

/// Selects the provider row, waits out the fetch debounce, and opens the
/// model quick-select by typing a filter (RawAutocomplete shows options
/// for the typed text).
Future<void> _openQuickSelect(
  WidgetTester tester,
  String label,
  String id,
) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  final field = find.widgetWithText(TextField, 'Model id');
  expect(
    field,
    findsOneWidget,
    reason: 'label $label must show the model field',
  );
  await tester.ensureVisible(field.first);
  await tester.enterText(field.first, id.substring(0, 3).toLowerCase());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => setModelsDispatchClientForTesting(_liveRouter()));
  tearDown(() => setModelsDispatchClientForTesting(null));

  testWidgets(
    'AC1: a chatgpt-codex registry entry lists models in the provider '
    'editor — live codex wire, and bundled catalog when it 401s',
    (tester) async {
      // Variant 1: the codex /models answers 200 — the live list renders
      // and no fallback note shows.
      await _pumpForm(
        tester,
        await _registryWith('chatgpt-codex'),
        key: const ValueKey('live'),
      );
      await _openQuickSelect(tester, 'ChatGPT Codex', 'gpt-5.7-flask');
      expect(find.text('gpt-5.7-flask', findRichText: true), findsWidgets);
      expect(find.textContaining('bundled catalog'), findsNothing);

      // Variant 2: the same surface with the live wire 401ing — the
      // bundled catalog answers (never empty) with the note.
      setModelsDispatchClientForTesting(
        MockClient((request) async => http.Response('unauthorized', 401)),
      );
      await _pumpForm(
        tester,
        await _registryWith('chatgpt-codex'),
        key: const ValueKey('bundled'),
      );
      await _openQuickSelect(tester, 'ChatGPT Codex', 'gpt-5.6-sol');
      expect(find.text('gpt-5.6-sol', findRichText: true), findsWidgets);
      expect(find.textContaining('bundled catalog'), findsOneWidget);
    },
  );

  testWidgets('identity beats URL shape: the editor quick-select keeps a codex '
      'entry on the codex wire after its baseUrl was edited (issue #771 '
      'owner scenario)', (tester) async {
    // The proxied URL answers 401 — only the entry's persisted identity
    // selects the codex dialect, whose failure falls back to the bundled
    // catalog with the note. URL-shape matching would show NOTHING here
    // (the edited URL looks like a plain 404ing OpenAI endpoint).
    setModelsDispatchClientForTesting(
      MockClient((request) async => http.Response('unauthorized', 401)),
    );
    await _pumpForm(
      tester,
      await _registryWith(
        'chatgpt-codex',
        baseUrl: 'https://relay.example.net/codex-proxy',
      ),
      key: const ValueKey('edited'),
    );
    await _openQuickSelect(tester, 'ChatGPT Codex', 'gpt-5.6-sol');
    expect(find.text('gpt-5.6-sol', findRichText: true), findsWidgets);
    expect(find.textContaining('bundled catalog'), findsOneWidget);
  });

  testWidgets(
    'the editor quick-select routes every dialect kind through the one '
    'dispatch',
    (tester) async {
      var generation = 0;
      for (final kind in _kindEntries.keys) {
        if (kind == 'chatgpt-codex') continue; // covered by AC1 above
        await _pumpForm(
          tester,
          await _registryWith(kind),
          key: ValueKey('matrix-$kind-${generation++}'),
        );
        await _openQuickSelect(
          tester,
          _kindEntries[kind]!.name,
          _kindEntries[kind]!.id,
        );
        expect(
          find.text(_kindEntries[kind]!.id, findRichText: true),
          findsWidgets,
          reason: 'kind $kind must list through the dispatch',
        );
      }
    },
  );

  testWidgets('the default-chat picker lists the codex entry from the bundled '
      'catalog and connects as the codex kind', (tester) async {
    setModelsDispatchClientForTesting(
      MockClient((request) async => http.Response('unauthorized', 401)),
    );
    final registry = ProviderRegistry.inMemory();
    final entry = _kindEntries['chatgpt-codex']!;
    final provider = await registry.add(
      name: entry.name,
      baseUrl: entry.baseUrl,
      modelId: entry.id,
      kind: 'chatgpt-codex',
    );
    registry.rememberKey(provider.id, await _blob());
    final connection = _FakeConnection();

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            SessionKeysScope(store: SessionKeysStore.inMemory(), child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 800,
              child: DefaultChatModelSection(
                connection: connection,
                registry: registry,
                onApply: (config) async => connection.applied = config,
              ),
            ),
          ),
        ),
      ),
    );

    // The two-step flow: provider row -> model list.
    await tester.tap(find.text('test-model · example.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ChatGPT Codex'));
    await tester.pumpAndSettle();

    expect(find.text('gpt-5.6-sol', findRichText: true), findsWidgets);
    expect(find.textContaining('bundled catalog'), findsOneWidget);

    await tester.tap(find.text('gpt-5.6-sol', findRichText: true).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(connection.applied, isNotNull);
    expect(connection.applied!.providerKind, 'chatgpt-codex');
    expect(connection.applied!.modelId, 'gpt-5.6-sol');
    expect(connection.applied!.baseUrl, chatGptCodexBaseUrl);
  });
}
