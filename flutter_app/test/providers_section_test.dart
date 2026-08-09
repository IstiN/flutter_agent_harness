import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa_ui/fa_ui.dart' show ProviderPreset;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentService _fakeService({
  String baseUrl = 'https://example.com',
  String provider = 'test',
}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: provider,
        baseUrl: baseUrl,
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('hi'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
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
      final service = _fakeService(
        baseUrl: 'https://openrouter.ai/api/v1',
        provider: 'openai-completions',
      );
      await service.initialize();
      await _pump(tester, ProvidersSection(service: service));

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
      expect(
        modelField.controller!.text,
        ProviderPreset.openrouter.defaultModel,
      );

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
  });

  group('DefaultChatModelSection flow', () {
    testWidgets('pick provider → pick model → the service is reconfigured', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final store = await LastConnectionStore.load(env);
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-acme');
      final service = _fakeService();
      await service.initialize();
      await _pump(
        tester,
        DefaultChatModelSection(
          service: service,
          registry: registry,
          lastConnectionStore: store,
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

      // Back on the section; the service was reconfigured with the
      // provider's endpoint and session key, and the connection persisted.
      expect(find.byType(DefaultModelPickerPage), findsNothing);
      expect(service.modelId, 'acme-2');
      expect(service.activeBaseUrl, 'https://acme.example/v1');
      expect(find.text('acme-2 · Acme'), findsOneWidget);
      final connection = store.connection;
      expect(connection, isNotNull);
      expect(connection!.modelId, 'acme-2');
      expect(connection.baseUrl, 'https://acme.example/v1');
    });

    testWidgets('add provider from the picker returns to picking', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final service = _fakeService();
      await service.initialize();
      await _pump(
        tester,
        DefaultChatModelSection(service: service, registry: registry),
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
      final service = _fakeService();
      await service.initialize();
      // The scope wraps the app (like main.dart), so pushed pages see it.
      await tester.pumpWidget(
        SessionKeysScope(
          store: keysStore,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DefaultChatModelSection(
                  service: service,
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

      expect(service.modelId, 'gpt-oss:120b');
      expect(service.activeBaseUrl, 'https://ollama.com/v1');
      expect(find.text('gpt-oss:120b · Ollama'), findsOneWidget);
    });

    testWidgets('a saved preset-model override prefills the model page', (
      tester,
    ) async {
      final keysStore = SessionKeysStore.inMemory({
        'OLLAMA_API_KEY': 'sk-ollama',
      });
      final registry = ProviderRegistry.inMemory();
      await registry.setPresetModelOverride(
        ProviderPreset.ollamaCloud.name,
        'qwen3:32b',
      );
      final service = _fakeService();
      await service.initialize();
      await tester.pumpWidget(
        SessionKeysScope(
          store: keysStore,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DefaultChatModelSection(
                  service: service,
                  registry: registry,
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
      // The override wins over the preset's built-in default.
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Model id'))
            .controller!
            .text,
        'qwen3:32b',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(service.modelId, 'qwen3:32b');
      expect(service.activeBaseUrl, 'https://ollama.com/v1');
    });

    testWidgets('a hosted provider without a key fails validation', (
      tester,
    ) async {
      final service = _fakeService();
      await service.initialize();
      await _pump(tester, DefaultChatModelSection(service: service));

      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pump();

      expect(find.text('API key is required'), findsOneWidget);
      // Still on the model page — nothing was applied.
      expect(find.byType(DefaultModelPickerPage), findsOneWidget);
      expect(service.modelId, 'test-model');
    });
  });

  group('MediaModelsSection provider summary', () {
    testWidgets('an override summarizes with the provider name', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.imageGeneration,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://acme.example/v1',
          modelId: 'acme-img',
        ),
      );
      await _pump(tester, MediaModelsSection(store: store, registry: registry));

      expect(find.text('acme-img · Acme'), findsOneWidget);
      expect(find.textContaining('acme.example'), findsNothing);
    });
  });
}
