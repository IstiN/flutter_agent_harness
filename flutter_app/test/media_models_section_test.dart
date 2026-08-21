import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/media_slot_picker_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa_ui/fa_ui.dart' show FaVoicePresetPicker;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart' show FaUiHost;

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

/// A `/models` fetch that reports no models (the manual-entry path).
Future<ModelsEndpointInfo> _noModels(
  String baseUrl, {
  required String apiKey,
}) async => (const <String>[], const <String, int>{}, const <String, int>{});

/// A `/models` fetch reporting image, TTS and vision models (the picker and
/// capability-hints path).
Future<ModelsEndpointInfo> _someModels(
  String baseUrl, {
  required String apiKey,
}) async => (
  const ['gpt-image-1', 'dall-e-3', 'tts-1', 'gpt-4o'],
  const <String, int>{},
  const <String, int>{},
);

MediaSlotOverride _override({
  String baseUrl = 'https://openrouter.ai/api/v1',
  String modelId = 'gpt-image-1',
  String? apiKeyName,
}) => MediaSlotOverride(
  providerKind: 'openai-completions',
  baseUrl: baseUrl,
  modelId: modelId,
  apiKeyName: apiKeyName,
);

void main() {
  group('MediaModelsSection', () {
    testWidgets('hides when no store is available', (tester) async {
      await _pump(tester, const MediaModelsSection());
      expect(find.text('Media models'), findsNothing);
    });

    testWidgets('rows render the fallback summary without overrides', (
      tester,
    ) async {
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      expect(find.text('Media models'), findsOneWidget);
      expect(find.text('Image generation'), findsOneWidget);
      expect(find.text('Text-to-speech'), findsOneWidget);
      expect(find.text('Music generation'), findsOneWidget);
      expect(find.text('Video generation'), findsOneWidget);
      expect(find.text('Vision (image reading)'), findsOneWidget);
      expect(find.text('Transcription'), findsOneWidget);
      expect(find.text('Same as main connection'), findsNWidgets(6));
    });

    testWidgets('the flow saves an override and the row updates', (
      tester,
    ) async {
      // The picker lists connected providers only — key up OpenRouter.
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-test' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      expect(find.text('Edit Image generation'), findsOneWidget);
      // No override yet → the main connection row is checked.
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'gpt-image-1',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = store.overrideFor(MediaSlot.imageGeneration);
      expect(saved, isNotNull);
      expect(saved!.modelId, 'gpt-image-1');
      // The provider's resolved URL is what gets stored…
      expect(saved.baseUrl, 'https://openrouter.ai/api/v1');
      // …with the hosted preset's well-known key NAME (never a value).
      expect(saved.apiKeyName, 'OPENROUTER_API_KEY');
      // …but the row summarizes with the provider name, never the URL.
      expect(find.text('gpt-image-1 · OpenRouter'), findsOneWidget);
      expect(find.text('Same as main connection'), findsNWidgets(5));
    });

    testWidgets('a custom provider is picked by name and saved as its URL', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-img',
      );
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(
          store: store,
          registry: registry,
          modelsFetcher: _noModels,
        ),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      // The custom provider's own model prefills the field.
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Model id'))
            .controller!
            .text,
        'acme-img',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = store.overrideFor(MediaSlot.imageGeneration)!;
      expect(saved.baseUrl, 'https://acme.example/v1');
      expect(saved.modelId, 'acme-img');
      // Custom providers store their host-scoped key name.
      expect(saved.apiKeyName, 'FA_KEY_ACME_EXAMPLE');
      expect(find.text('acme-img · Acme'), findsOneWidget);
    });

    testWidgets('the model page picks from the endpoint model list', (
      tester,
    ) async {
      // The picker lists connected providers only — key up OpenRouter.
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-test' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _someModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);

      // The preset's default model prefills — clear it so the typed text
      // does not filter the quick select.
      await tester.enterText(find.widgetWithText(TextField, 'Model id'), '');
      await tester.tap(find.widgetWithText(TextField, 'Model id'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('dall-e-3'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = store.overrideFor(MediaSlot.imageGeneration);
      expect(saved, isNotNull);
      expect(saved!.modelId, 'dall-e-3');
    });

    testWidgets('capability hints reflect the endpoint model metadata', (
      tester,
    ) async {
      // The picker lists connected providers only — key up OpenRouter.
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-test' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _someModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();

      // gpt-image-1/dall-e-3 → image, tts-1 → TTS, gpt-4o → vision.
      expect(
        find.text("This endpoint's models suggest support for:"),
        findsOneWidget,
      );
      expect(find.text('Text-to-speech'), findsOneWidget);
      expect(find.text('Vision (image reading)'), findsOneWidget);
      expect(find.text('Music generation'), findsNothing);
    });

    testWidgets('no capability hints when the endpoint has no /models', (
      tester,
    ) async {
      // The picker lists connected providers only — key up OpenRouter.
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-test' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();

      expect(
        find.text("This endpoint's models suggest support for:"),
        findsNothing,
      );
    });

    testWidgets('the main connection row clears the override', (tester) async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.imageGeneration, _override());
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      expect(find.text('gpt-image-1 · OpenRouter'), findsOneWidget);

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      // The override's provider is checked, not the main connection row.
      await tester.tap(find.text('Main connection'));
      await tester.pumpAndSettle();

      expect(store.overrideFor(MediaSlot.imageGeneration), isNull);
      expect(find.text('Same as main connection'), findsNWidgets(6));
    });

    testWidgets('the row summary shows model + provider name, never the key '
        'name', (tester) async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.transcription,
        _override(modelId: 'whisper-1', apiKeyName: 'OPENAI_API_KEY'),
      );
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      expect(find.text('whisper-1 · OpenRouter'), findsOneWidget);
      expect(find.textContaining('OPENAI_API_KEY'), findsNothing);
    });

    testWidgets('the TTS flow edits the voice and the override keeps it', (
      tester,
    ) async {
      // The picker lists connected providers only — key up OpenRouter.
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-test' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'tts-1',
          voice: 'af_heart',
        ),
      );
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);

      // tts-1 matches the OpenAI voice presets, so the voice control is the
      // preset picker, prefilled from the current override.
      expect(find.byType(FaVoicePresetPicker), findsOneWidget);
      expect(find.text('af_heart'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('nova').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = store.overrideFor(MediaSlot.audioTts)!;
      expect(saved.modelId, 'tts-1');
      expect(saved.voice, 'nova');
    });

    testWidgets('non-TTS slots render no voice field', (tester) async {
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-test' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();

      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Voice (optional)'), findsNothing);
    });
  });
}
