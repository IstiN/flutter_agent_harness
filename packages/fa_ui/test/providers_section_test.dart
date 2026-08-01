// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A mutable [FaChatConnection] fake standing in for the host's agent
/// service: [apply] mimics a reconfigure (and records the applied config).
class _FakeConnection extends ChangeNotifier implements FaChatConnection {
  _FakeConnection({this.baseUrl = 'https://example.com', this.kind = 'test'});

  String baseUrl;
  String kind;
  String model = 'test-model';
  FaChatModelConfig? applied;

  @override
  String get providerKind => kind;
  @override
  String get activeBaseUrl => baseUrl;
  @override
  String get modelId => model;

  Future<void> apply(FaChatModelConfig config) async {
    applied = config;
    kind = config.providerKind;
    baseUrl = config.baseUrl;
    model = config.modelId;
    notifyListeners();
  }
}

/// A `/models` fetch reporting two chat models (the quick-select path).
Future<ModelsEndpointInfo> _someModels(
  String baseUrl, {
  required String apiKey,
}) async =>
    (const ['acme-1', 'acme-2'], const <String, int>{}, const <String, int>{});

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

/// A TextField inside the full-screen provider editor page.
Finder _editorField(String label) {
  return find.descendant(
    of: find.byType(ProviderEditorPage),
    matching: find.widgetWithText(TextField, label),
  );
}

void main() {
  group('ProvidersSection', () {
    testWidgets('lists the hosted presets and marks the current provider', (
      tester,
    ) async {
      final connection = _FakeConnection(
        baseUrl: 'https://openrouter.ai/api/v1',
        kind: 'openai-completions',
      );
      await _pump(tester, ProvidersSection(service: connection));

      expect(find.text('Providers'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('Add provider'), findsOneWidget);
      // Exactly one row is marked current — the OpenRouter preset.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('add provider: the editor page persists via the registry', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(_editorField('Name'), 'Acme');
      await tester.enterText(
        _editorField('Base URL'),
        'https://acme.example/v1',
      );
      await tester.enterText(
        _editorField('API key (optional)'),
        'sk-acme-session',
      );
      // The model id is optional — a provider may have no model yet.
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers, hasLength(1));
      final provider = registry.providers.single;
      expect(provider.name, 'Acme');
      expect(provider.baseUrl, 'https://acme.example/v1');
      expect(provider.modelId, isEmpty);
      expect(registry.keyFor(provider.id), 'sk-acme-session');
      // Back on the section, the new provider is listed.
      expect(find.text('Acme'), findsOneWidget);
    });

    testWidgets('edit provider: write-only key keeps the stored key when '
        'left empty', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-acme-kept');
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      // The existing key is never shown (write-only)…
      final keyField = tester.widget<TextField>(
        _editorField('API key (optional)'),
      );
      expect(keyField.controller!.text, isEmpty);
      expect(keyField.obscureText, isTrue);
      // …and the helper says an empty field keeps it.
      expect(
        find.textContaining('leave the field empty to keep it'),
        findsOneWidget,
      );

      await tester.enterText(_editorField('Model id (optional)'), 'acme-2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers.single.modelId, 'acme-2');
      expect(registry.keyFor(provider.id), 'sk-acme-kept');
    });

    testWidgets('edit provider: delete goes through the editor page', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Acme?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(registry.providers, isEmpty);
      expect(find.text('Acme'), findsNothing);
    });

    testWidgets('preset editor: name/URL are read-only, the model and key '
        'save', (tester) async {
      final keysStore = SessionKeysStore.inMemory();
      final registry = ProviderRegistry.inMemory();
      await _pump(
        tester,
        SessionKeysScope(
          store: keysStore,
          child: ProvidersSection(registry: registry),
        ),
      );

      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      expect(tester.widget<TextField>(_editorField('Name')).enabled, isFalse);
      expect(
        tester.widget<TextField>(_editorField('Base URL')).enabled,
        isFalse,
      );
      // The model field is editable (TextField.enabled is nullable — null
      // means the default, enabled) and prefilled with the preset default.
      final modelField = tester.widget<TextField>(_editorField('Model id'));
      expect(modelField.enabled ?? true, isTrue);
      expect(modelField.controller!.text, 'openai/gpt-4o-mini');

      await tester.enterText(_editorField('Model id'), 'anthropic/claude');
      await tester.enterText(_editorField('API key (optional)'), 'sk-or-new');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(keysStore.valueOf('OPENROUTER_API_KEY'), 'sk-or-new');
      expect(
        registry.presetModelOverride(ProviderPreset.openrouter.name),
        'anthropic/claude',
      );
    });

    testWidgets('preset editor: a saved override prefills the model, saving '
        'the built-in default clears it', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.setPresetModelOverride(
        ProviderPreset.openrouter.name,
        'anthropic/claude',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_editorField('Model id')).controller!.text,
        'anthropic/claude',
      );

      await tester.enterText(
        _editorField('Model id'),
        ProviderPreset.openrouter.defaultModel,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        registry.presetModelOverride(ProviderPreset.openrouter.name),
        isNull,
      );
    });

    testWidgets('a host key resolver feeds the preset editor note', (
      tester,
    ) async {
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-from-host' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final registry = ProviderRegistry.inMemory();
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      // The host-resolved key counts as saved: the keep-note shows.
      expect(
        find.textContaining('leave the field empty to keep it'),
        findsOneWidget,
      );
    });
  });

  group('DefaultChatModelSection flow', () {
    testWidgets('pick provider → pick model → onApply runs with the config', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-acme');
      final connection = _FakeConnection();
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          registry: registry,
          modelsFetcher: _someModels,
        ),
      );

      // The row summarizes the active provider + model.
      expect(find.text('test-model · example.com'), findsOneWidget);
      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      expect(find.byType(DefaultModelProviderPickerPage), findsOneWidget);
      expect(find.text('Choose provider'), findsOneWidget);

      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      expect(find.byType(DefaultModelPickerPage), findsOneWidget);
      expect(find.text('Choose model'), findsOneWidget);
      // The provider's model prefills the field…
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Model id'))
            .controller!
            .text,
        'acme-1',
      );

      // …and the /models quick select offers the endpoint's models (clear
      // the prefill first — the typed text filters the options).
      await tester.enterText(find.widgetWithText(TextField, 'Model id'), '');
      await tester.tap(find.widgetWithText(TextField, 'Model id'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('acme-2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Back on the section; onApply ran with the provider's endpoint and
      // session key, and the summary follows the connection.
      expect(find.byType(DefaultModelPickerPage), findsNothing);
      expect(connection.applied, isNotNull);
      expect(connection.applied!.providerKind, 'openai-completions');
      expect(connection.applied!.modelId, 'acme-2');
      expect(connection.applied!.baseUrl, 'https://acme.example/v1');
      expect(connection.applied!.apiKey, 'sk-acme');
      expect(find.text('acme-2 · Acme'), findsOneWidget);
    });

    testWidgets('add provider from the picker returns to picking', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final connection = _FakeConnection();
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          registry: registry,
        ),
      );

      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(_editorField('Name'), 'Local');
      await tester.enterText(
        _editorField('Base URL'),
        'http://localhost:8080/v1',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Back on the picker, the new provider is listed and pickable.
      expect(find.byType(DefaultModelProviderPickerPage), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
    });

    testWidgets('a hosted provider applies with its saved key', (tester) async {
      final keysStore = SessionKeysStore.inMemory({
        'OLLAMA_API_KEY': 'sk-ollama',
      });
      final connection = _FakeConnection();
      // The scope wraps the app, so pushed pages see it.
      await tester.pumpWidget(
        SessionKeysScope(
          store: keysStore,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DefaultChatModelSection(
                  connection: connection,
                  onApply: connection.apply,
                  modelsFetcher: _someModels,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      // The preset's default model is prefilled; apply directly.
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(connection.model, 'gpt-oss:120b');
      expect(connection.baseUrl, 'https://ollama.com/v1');
      expect(connection.applied!.apiKey, 'sk-ollama');
      expect(find.text('gpt-oss:120b · Ollama'), findsOneWidget);
    });

    testWidgets('a hosted provider without a key fails validation', (
      tester,
    ) async {
      final connection = _FakeConnection();
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
        ),
      );

      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pump();

      expect(find.text('API key is required'), findsOneWidget);
      // Still on the model page — nothing was applied.
      expect(find.byType(DefaultModelPickerPage), findsOneWidget);
      expect(connection.model, 'test-model');
    });

    testWidgets('on-device routes render and their page unwinds the flow', (
      tester,
    ) async {
      final connection = _FakeConnection(kind: 'webllm');
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          providerKindLabels: const {'webllm': 'On-device (WebLLM)'},
          onDeviceProviders: [
            FaOnDeviceRoute(
              label: 'On-device (WebLLM)',
              pageBuilder: (context, apply) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    await apply(
                      const FaChatModelConfig(
                        providerKind: 'webllm',
                        modelId: 'local-model',
                        baseUrl: '',
                        apiKey: '',
                      ),
                    );
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                  child: const Text('connect local'),
                ),
              ),
            ),
          ],
        ),
      );

      // The kind label stands in for the (endpoint-less) provider summary.
      expect(find.text('test-model · On-device (WebLLM)'), findsOneWidget);
      await tester.tap(find.text('test-model · On-device (WebLLM)'));
      await tester.pumpAndSettle();
      expect(find.text('On-device (WebLLM)'), findsOneWidget);

      await tester.tap(find.text('On-device (WebLLM)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('connect local'));
      await tester.pumpAndSettle();

      // The page popped true: the whole flow unwound and onApply ran.
      expect(find.byType(DefaultModelProviderPickerPage), findsNothing);
      expect(connection.applied!.providerKind, 'webllm');
      expect(connection.model, 'local-model');
    });
  });
}
