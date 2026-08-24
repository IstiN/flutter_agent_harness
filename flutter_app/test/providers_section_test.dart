import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa_ui/fa_ui.dart' show AddProviderPresetPickerPage;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart'
    show MediaSlotModelPage, MediaSlotProviderPickerPage;

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

/// Sets the provider editor's model through the model selector its model
/// row opens (the editor itself has no model text field anymore).
Future<void> _setEditorModel(
  WidgetTester tester,
  String rowLabel,
  String modelId,
) async {
  await tester.tap(
    find.descendant(
      of: find.byType(ProviderEditorPage),
      matching: find.widgetWithText(InkWell, rowLabel),
    ),
  );
  await tester.pumpAndSettle();
  final page = find.byType(MediaSlotModelPage);
  expect(page, findsOneWidget);
  await tester.enterText(
    find.descendant(
      of: page,
      matching: find.widgetWithText(TextField, 'Model id'),
    ),
    modelId,
  );
  await tester.tap(
    find.descendant(
      of: page,
      matching: find.widgetWithText(FilledButton, 'Save'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ProvidersSection', () {
    testWidgets('lists the saved providers with no current-mark', (
      tester,
    ) async {
      // Hosted presets no longer render here (the provider-first setup
      // redesign): the section lists saved custom providers + Add provider.
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      expect(find.text('Providers'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('Add provider'), findsOneWidget);
      // No row is marked current — every row ends with a chevron.
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('add provider: the editor page persists via the registry', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      // 'Custom' is the LAST tile and may sit below the fold — scroll the
      // picker's own list to it first.
      await tester.scrollUntilVisible(
        find.text('Custom'),
        200,
        scrollable: find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
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
      await _pump(
        tester,
        ProvidersSection(registry: registry, modelsFetcher: _someModels),
      );

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

      await _setEditorModel(tester, 'Model id (optional)', 'acme-2');
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
  });

  group('DefaultChatModelSection flow', () {
    testWidgets('the unified picker lists the active model and applies a '
        'registry model', (tester) async {
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

      // The two-step provider → model flow (the same picker the role rows
      // open). The Acme entry carries the registry's remembered session key.
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'acme-1',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Back on the section; the service was reconfigured with the
      // provider's endpoint and session key, and the connection persisted.
      expect(service.modelId, 'acme-1');
      expect(service.activeBaseUrl, 'https://acme.example/v1');
      expect(find.text('acme-1 · Acme'), findsOneWidget);
      final connection = store.connection;
      expect(connection, isNotNull);
      expect(connection!.modelId, 'acme-1');
      expect(connection.baseUrl, 'https://acme.example/v1');
    });

    testWidgets('add provider from the picker returns to the picker', (
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
      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      // 'Custom' is the LAST tile and may sit below the fold — scroll the
      // picker's own list to it first.
      await tester.scrollUntilVisible(
        find.text('Custom'),
        200,
        scrollable: find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(_editorField('Name'), 'Local');
      await tester.enterText(
        _editorField('Base URL'),
        'http://localhost:8080/v1',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Back on the (two-step) picker with the saved provider listed.
      expect(find.byType(ProviderEditorPage), findsNothing);
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
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
