import 'package:fa/services/media_models_store.dart';
import 'package:fa/ui/screens/media_slot_editor_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

    testWidgets('editor page saves an override and the row updates', (
      tester,
    ) async {
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotEditorPage), findsOneWidget);
      expect(find.text('Edit Image generation'), findsOneWidget);
      // No Clear button before an override exists.
      expect(find.text('Clear'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'gpt-image-1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://openrouter.ai/api/v1',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = store.overrideFor(MediaSlot.imageGeneration);
      expect(saved, isNotNull);
      expect(saved!.modelId, 'gpt-image-1');
      expect(saved.baseUrl, 'https://openrouter.ai/api/v1');
      expect(find.text('gpt-image-1 · openrouter.ai'), findsOneWidget);
      expect(find.text('Same as main connection'), findsNWidgets(5));
    });

    testWidgets('editor page saves via the endpoint model picker', (
      tester,
    ) async {
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _someModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      // The debounced fetch feeds the quick select.
      expect(find.byType(MediaSlotEditorPage), findsOneWidget);

      await tester.tap(find.widgetWithText(TextField, 'Model id'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('dall-e-3'));
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
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _someModels),
      );

      await tester.tap(find.text('Image generation'));
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
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();

      expect(
        find.text("This endpoint's models suggest support for:"),
        findsNothing,
      );
    });

    testWidgets('empty base URL falls back to the main connection default', (
      tester,
    ) async {
      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'tts-1',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // No service in this harness → the OpenAI default applies.
      expect(
        store.overrideFor(MediaSlot.audioTts)!.baseUrl,
        MediaModelsStore.defaultBaseUrl,
      );
    });

    testWidgets('clear restores the fallback summary', (tester) async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.imageGeneration, _override());
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      expect(find.text('gpt-image-1 · openrouter.ai'), findsOneWidget);

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      expect(find.text('Clear'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(store.overrideFor(MediaSlot.imageGeneration), isNull);
      expect(find.text('Same as main connection'), findsNWidgets(6));
    });

    testWidgets('apiKeyName collects a name, never a value', (tester) async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.transcription,
        _override(modelId: 'whisper-1', apiKeyName: 'OPENAI_API_KEY'),
      );
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      // The row summary shows model + host only, never the key name.
      expect(find.text('whisper-1 · openrouter.ai'), findsOneWidget);
      expect(find.textContaining('OPENAI_API_KEY'), findsNothing);

      await tester.tap(find.text('Transcription'));
      await tester.pumpAndSettle();
      final keyNameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'API key name (optional)'),
      );
      // The field holds the NAME (not obscured, not a secret value).
      expect(keyNameField.controller?.text, 'OPENAI_API_KEY');
      expect(keyNameField.obscureText, isFalse);

      await tester.enterText(
        find.widgetWithText(TextField, 'API key name (optional)'),
        'GROQ_API_KEY',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        store.overrideFor(MediaSlot.transcription)!.apiKeyName,
        'GROQ_API_KEY',
      );
    });
  });
}
