import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/media_slot_picker_page.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa_ui/fa_ui.dart' show FaVoicePresetPicker;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `/models` fetch reporting image and vision models.
Future<ModelsEndpointInfo> _someModels(
  String baseUrl, {
  required String apiKey,
}) async => (
  const ['gpt-image-1', 'dall-e-3', 'gpt-4o'],
  const <String, int>{},
  const <String, int>{},
);

/// Pumps a home button that pushes [page] and captures its pop result.
Future<void> _pumpWithOpener(
  WidgetTester tester,
  Widget page,
  void Function(MediaSlotEditorResult?) onResult,
) {
  return tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              final result = await Navigator.of(context)
                  .push<MediaSlotEditorResult>(
                    MaterialPageRoute(builder: (_) => page),
                  );
              onResult(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('MediaSlotProviderPickerPage', () {
    testWidgets('renders the main connection, presets, custom providers and '
        'the add row; the override provider is checked', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpWithOpener(
        tester,
        MediaSlotProviderPickerPage(
          slot: MediaSlot.imageGeneration,
          title: 'Edit Image generation',
          mainBaseUrl: 'https://openrouter.ai/api/v1',
          initial: const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://acme.example/v1',
            modelId: 'acme-img',
          ),
          registry: registry,
          modelsFetcher: _someModels,
        ),
        (_) {},
      );
      await _open(tester);

      expect(find.text('Edit Image generation'), findsOneWidget);
      expect(find.text('Main connection'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('Add provider'), findsOneWidget);
      expect(find.text('acme.example'), findsOneWidget);
      // Exactly one row is checked — the override's provider.
      expect(find.byIcon(Icons.check), findsOneWidget);
      final checkedTile = tester.widget<ListTile>(
        find.ancestor(
          of: find.byIcon(Icons.check),
          matching: find.byType(ListTile),
        ),
      );
      expect((checkedTile.title as Text).data, 'Acme');
    });

    testWidgets('connectedOnly hides hosted presets whose key does not '
        'resolve (the agent-role flow)', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpWithOpener(
        tester,
        MediaSlotProviderPickerPage(
          slot: null, // the generic provider→model role flow
          title: 'Quick model',
          mainBaseUrl: 'https://openrouter.ai/api/v1',
          registry: registry,
          modelsFetcher: _someModels,
          connectedOnly: true,
        ),
        (_) {},
      );
      await _open(tester);

      // No keys configured in the test environment: hosted presets hide,
      // the main connection + saved custom providers stay.
      expect(find.text('Main connection'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('OpenRouter'), findsNothing);
      expect(find.text('Ollama'), findsNothing);
      expect(find.text('Add provider'), findsOneWidget);
    });

    testWidgets('the main connection row pops a clear result', (tester) async {
      MediaSlotEditorResult? result;
      var popped = false;
      await _pumpWithOpener(
        tester,
        const MediaSlotProviderPickerPage(
          slot: MediaSlot.imageGeneration,
          title: 'Edit Image generation',
        ),
        (value) {
          popped = true;
          result = value;
        },
      );
      await _open(tester);

      await tester.tap(find.text('Main connection'));
      await tester.pumpAndSettle();

      expect(popped, isTrue);
      expect(result, isNotNull);
      expect(result!.cleared, isTrue);
      expect(result!.override, isNull);
    });

    testWidgets('add provider continues straight to its model page', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await _pumpWithOpener(
        tester,
        MediaSlotProviderPickerPage(
          slot: MediaSlot.imageGeneration,
          title: 'Edit Image generation',
          registry: registry,
          modelsFetcher: _someModels,
        ),
        (_) {},
      );
      await _open(tester);

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Acme');
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://acme.example/v1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id (optional)'),
        'acme-img',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // The provider was added and its model page opened (prefilled with
      // the provider's model).
      expect(registry.providers, hasLength(1));
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Model id'))
            .controller!
            .text,
        'acme-img',
      );
    });

    testWidgets('a saved model-page result unwinds the whole flow', (
      tester,
    ) async {
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        MediaSlotProviderPickerPage(
          slot: MediaSlot.imageGeneration,
          title: 'Edit Image generation',
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'gpt-image-1',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Both pages popped; the section's push resolves with the save.
      expect(find.byType(MediaSlotProviderPickerPage), findsNothing);
      expect(result, isNotNull);
      expect(result!.cleared, isFalse);
      expect(result!.override!.modelId, 'gpt-image-1');
    });
  });

  group('MediaSlotModelPage', () {
    testWidgets('the /models fetch feeds the quick select', (tester) async {
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.imageGeneration,
          provider: ProviderPreset.openrouter,
          modelsFetcher: _someModels,
        ),
        (_) {},
      );
      await _open(tester);
      // The post-frame fetch completes during settle.
      expect(find.byType(MediaSlotModelPage), findsOneWidget);

      await tester.tap(find.widgetWithText(TextField, 'Model id'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('dall-e-3'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Model id'))
            .controller!
            .text,
        'dall-e-3',
      );
    });

    testWidgets('a hosted preset save maps to its well-known key name', (
      tester,
    ) async {
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.audioTts,
          provider: ProviderPreset.ollamaCloud,
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'tts-1',
      );
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final override = result!.override!;
      expect(override.providerKind, 'openai-completions');
      expect(override.baseUrl, 'https://ollama.com/v1');
      expect(override.modelId, 'tts-1');
      expect(override.apiKeyName, 'OLLAMA_API_KEY');
    });

    testWidgets('a custom provider save maps to the host-scoped key name', (
      tester,
    ) async {
      const provider = CustomProvider(
        id: 'p1',
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-img',
      );
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.imageGeneration,
          provider: provider,
          initialModel: 'acme-img',
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      // The provider header + prefilled model; save directly.
      expect(find.text('Acme'), findsWidgets);
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final override = result!.override!;
      expect(override.baseUrl, 'https://acme.example/v1');
      expect(override.modelId, 'acme-img');
      expect(override.apiKeyName, 'FA_KEY_ACME_EXAMPLE');
    });

    testWidgets('an empty model id fails validation', (tester) async {
      var popped = false;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.imageGeneration,
          provider: ProviderPreset.openrouter,
          initialModel: '',
          modelsFetcher: _someModels,
        ),
        (_) => popped = true,
      );
      await _open(tester);

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Model id is required'), findsOneWidget);
      expect(popped, isFalse);
    });

    testWidgets('the voice field renders only for the TTS slot, prefilled, '
        'and rides into the saved override', (tester) async {
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.audioTts,
          provider: ProviderPreset.openrouter,
          // No presets match this model — the free-text field stays.
          initialModel: 'acme-voice-1',
          initialVoice: 'af_heart',
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      final voiceField = find.widgetWithText(TextField, 'Voice (optional)');
      expect(voiceField, findsOneWidget);
      expect(tester.widget<TextField>(voiceField).controller!.text, 'af_heart');

      await tester.enterText(voiceField, 'nova');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result!.override!.modelId, 'acme-voice-1');
      expect(result!.override!.voice, 'nova');
    });

    testWidgets('a Gemini TTS model swaps the voice field for the preset '
        'picker and saves the picked voice', (tester) async {
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.audioTts,
          provider: ProviderPreset.openrouter,
          initialModel: 'gemini-2.5-flash-preview-tts',
          initialVoice: 'Kore',
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      // The picker shows the saved voice (with its trait and a preview
      // button); the free-text field is gone.
      expect(find.byType(FaVoicePresetPicker), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Voice (optional)'), findsNothing);
      expect(find.text('Kore — Firm'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Puck — Upbeat').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result!.override!.modelId, 'gemini-2.5-flash-preview-tts');
      expect(result!.override!.voice, 'Puck');
    });

    testWidgets('a saved voice unknown to the presets is kept as-is', (
      tester,
    ) async {
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.audioTts,
          provider: ProviderPreset.openrouter,
          initialModel: 'tts-1',
          initialVoice: 'my-custom-voice',
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      // tts-1 matches the OpenAI presets; the saved voice is none of them
      // but still renders (and saves) unchanged.
      expect(find.byType(FaVoicePresetPicker), findsOneWidget);
      expect(find.text('my-custom-voice'), findsOneWidget);

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result!.override!.voice, 'my-custom-voice');
    });

    testWidgets('no voice field outside the TTS slot', (tester) async {
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.imageGeneration,
          provider: ProviderPreset.openrouter,
          modelsFetcher: _someModels,
        ),
        (_) {},
      );
      await _open(tester);

      expect(find.widgetWithText(TextField, 'Voice (optional)'), findsNothing);
    });

    testWidgets('an empty voice field saves no voice', (tester) async {
      MediaSlotEditorResult? result;
      await _pumpWithOpener(
        tester,
        const MediaSlotModelPage(
          slot: MediaSlot.audioTts,
          provider: ProviderPreset.openrouter,
          initialModel: 'tts-1',
          modelsFetcher: _someModels,
        ),
        (value) => result = value,
      );
      await _open(tester);

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result!.override!.voice, isNull);
    });
  });
}
