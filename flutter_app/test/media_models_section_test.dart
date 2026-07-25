import 'package:fa/services/media_models_store.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

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
      await _pump(tester, MediaModelsSection(store: store));

      expect(find.text('Media models'), findsOneWidget);
      expect(find.text('Image generation'), findsOneWidget);
      expect(find.text('Text-to-speech'), findsOneWidget);
      expect(find.text('Music generation'), findsOneWidget);
      expect(find.text('Video generation'), findsOneWidget);
      expect(find.text('Vision (image reading)'), findsOneWidget);
      expect(find.text('Transcription'), findsOneWidget);
      expect(find.text('Same as main connection'), findsNWidgets(6));
    });

    testWidgets('editor saves an override and the row updates', (tester) async {
      final store = MediaModelsStore.inMemory();
      await _pump(tester, MediaModelsSection(store: store));

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotEditorDialog), findsOneWidget);
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

    testWidgets('empty base URL falls back to the main connection default', (
      tester,
    ) async {
      final store = MediaModelsStore.inMemory();
      await _pump(tester, MediaModelsSection(store: store));

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
      await _pump(tester, MediaModelsSection(store: store));

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
      await _pump(tester, MediaModelsSection(store: store));

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
