import 'package:fa_ui/fa_ui.dart';
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

    testWidgets('the flow saves an override and fires the host hooks', (
      tester,
    ) async {
      final store = MediaModelsStore.inMemory();
      final opened = <String>[];
      final saved = <String>[];
      await _pump(
        tester,
        MediaModelsSection(
          store: store,
          mainBaseUrl: 'https://api.test/v1',
          modelsFetcher: _noModels,
          onSlotEditorOpened: opened.add,
          onSlotOverrideSaved: saved.add,
        ),
      );

      // Media slots list connected providers only — give OpenRouter a key.
      FaUiHost.keyResolver =
          (name) => name == 'OPENROUTER_API_KEY' ? 'sk-or' : '';
      addTearDown(() => FaUiHost.keyResolver = null);

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      expect(opened, [MediaSlot.imageGeneration]);
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      expect(find.text('Edit Image generation'), findsOneWidget);
      // The mainBaseUrl host rides under the main-connection row.
      expect(find.text('api.test'), findsOneWidget);

      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'gpt-image-1',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final override = store.overrideFor(MediaSlot.imageGeneration);
      expect(override, isNotNull);
      expect(override!.modelId, 'gpt-image-1');
      expect(override.baseUrl, 'https://openrouter.ai/api/v1');
      expect(override.apiKeyName, 'OPENROUTER_API_KEY');
      expect(saved, [MediaSlot.imageGeneration]);
      expect(find.text('gpt-image-1 · OpenRouter'), findsOneWidget);
    });

    testWidgets('the Gemini preset saves its URL and key name', (tester) async {
      FaUiHost.keyResolver =
          (name) => name == 'GEMINI_API_KEY' ? 'sk-gemini' : '';
      addTearDown(() => FaUiHost.keyResolver = null);

      final store = MediaModelsStore.inMemory();
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Gemini'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'gemini-2.5-flash-preview-tts',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final override = store.overrideFor(MediaSlot.audioTts)!;
      expect(
        override.baseUrl,
        'https://generativelanguage.googleapis.com/v1beta',
      );
      expect(override.modelId, 'gemini-2.5-flash-preview-tts');
      expect(override.apiKeyName, 'GEMINI_API_KEY');
      expect(
        find.text('gemini-2.5-flash-preview-tts · Google Gemini'),
        findsOneWidget,
      );
    });

    testWidgets('the main connection row clears the override', (tester) async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.imageGeneration,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'gpt-image-1',
        ),
      );
      await _pump(
        tester,
        MediaModelsSection(store: store, modelsFetcher: _noModels),
      );

      expect(find.text('gpt-image-1 · OpenRouter'), findsOneWidget);

      await tester.tap(find.text('Image generation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main connection'));
      await tester.pumpAndSettle();

      expect(store.overrideFor(MediaSlot.imageGeneration), isNull);
      expect(find.text('Same as main connection'), findsNWidgets(6));
    });
  });
}
