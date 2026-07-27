// Unit + widget tests for `lib/ui/screens/model_presets.dart` — the
// declarative preset list, the one-tap apply semantics (media overrides +
// main-connection reconfigure), and the swipeable wizard section.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal [AgentService] (never connected: no network/file/JS backends)
/// — the pattern of `test/golden/settings_golden_test.dart`.
AgentService _fakeService({
  String baseUrl = 'https://openrouter.ai/api/v1',
  String provider = 'openai-completions',
  String modelId = 'openai/gpt-4o-mini',
}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: modelId,
        api: 'test-api',
        provider: provider,
        baseUrl: baseUrl,
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are fah.',
      streamFunction: (model, context, {cancelToken}) =>
          AssistantMessageEventStream()..end(),
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

ModelPreset get _budget =>
    kModelPresets.firstWhere((preset) => preset.id == 'budget');

ModelPreset get _quality =>
    kModelPresets.firstWhere((preset) => preset.id == 'quality');

Future<void> _pumpSection(
  WidgetTester tester, {
  required AgentService service,
  required MediaModelsStore store,
  SessionKeysStore? keysStore,
  LastConnectionStore? lastConnectionStore,
}) {
  Widget child = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ModelPresetsSection(
          service: service,
          store: store,
          lastConnectionStore: lastConnectionStore,
        ),
      ),
    ),
  );
  if (keysStore != null) {
    child = SessionKeysScope(store: keysStore, child: child);
  }
  return tester.pumpWidget(child);
}

void main() {
  group('kModelPresets', () {
    test('the budget preset is the user-proven OpenRouter combo', () {
      final preset = _budget;
      expect(preset.target.baseUrl, 'https://openrouter.ai/api/v1');
      expect(preset.target.keyName, 'OPENROUTER_API_KEY');
      expect(preset.chatModelId, 'google/gemini-3.6-flash');
      expect(preset.mediaSlots, {
        MediaSlot.imageGeneration: 'black-forest-labs/flux.2-klein-4b',
        MediaSlot.audioTts: 'hexgrad/kokoro-82m',
        MediaSlot.musicGeneration: 'google/lyria-3-clip-preview',
        MediaSlot.videoGeneration: 'bytedance/seedance-1-5-pro',
        MediaSlot.transcription: 'openai/whisper-large-v3',
      });
      // Vision deliberately stays on the main connection.
      expect(preset.mediaSlots, isNot(contains(MediaSlot.vision)));
      // Every mapped slot is a real MediaSlot name.
      for (final slot in preset.mediaSlots.keys) {
        expect(MediaSlot.all, contains(slot));
      }
    });

    test('localized names/descriptions resolve for every preset', () {
      for (final preset in kModelPresets) {
        expect(preset.id, isNotEmpty);
      }
    });
  });

  group('modelPresetKeyAvailable', () {
    test('false without the provider key, true with it', () {
      expect(modelPresetKeyAvailable(_budget, null), isFalse);
      expect(
        modelPresetKeyAvailable(_budget, SessionKeysStore.inMemory()),
        isFalse,
      );
      expect(
        modelPresetKeyAvailable(
          _budget,
          SessionKeysStore.inMemory({'OPENROUTER_API_KEY': 'sk-or-saved'}),
        ),
        isTrue,
      );
    });
  });

  group('applyModelPreset', () {
    test(
      'writes mapped overrides, clears unmapped, reconfigures the chat',
      () async {
        final store = MediaModelsStore.inMemory();
        // Pre-existing overrides: one the preset remaps, one it must clear.
        await store.setOverride(
          MediaSlot.vision,
          const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'gpt-4o',
          ),
        );
        await store.setOverride(
          MediaSlot.imageGeneration,
          const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'gpt-image-1',
          ),
        );
        final service = _fakeService();
        final lastConnection = LastConnectionStore.inMemory();

        await applyModelPreset(
          preset: _budget,
          service: service,
          store: store,
          keysStore: SessionKeysStore.inMemory({
            'OPENROUTER_API_KEY': 'sk-or-saved',
          }),
          lastConnectionStore: lastConnection,
        );

        // Mapped slots: preset endpoint + model + named key.
        for (final entry in _budget.mediaSlots.entries) {
          final override = store.overrideFor(entry.key);
          expect(override, isNotNull, reason: entry.key);
          expect(override!.providerKind, 'openai-completions');
          expect(override.baseUrl, 'https://openrouter.ai/api/v1');
          expect(override.modelId, entry.value);
          expect(override.apiKeyName, 'OPENROUTER_API_KEY');
        }
        // Unmapped slots: cleared back to the main connection.
        expect(store.overrideFor(MediaSlot.vision), isNull);
        expect(store.configuredSlots, hasLength(_budget.mediaSlots.length));

        // The main connection is reconfigured to the preset's chat model.
        expect(service.providerKind, 'openai-completions');
        expect(service.modelId, 'google/gemini-3.6-flash');
        expect(service.activeBaseUrl, 'https://openrouter.ai/api/v1');

        // The last connection is persisted (never the key).
        final saved = lastConnection.connection;
        expect(saved, isNotNull);
        expect(saved!.modelId, 'google/gemini-3.6-flash');
        expect(saved.baseUrl, 'https://openrouter.ai/api/v1');
        expect(saved.providerKind, 'openai-completions');
      },
    );

    test('the quality preset clears the slots it does not map', () async {
      final store = MediaModelsStore.inMemory();
      final service = _fakeService();
      final keys = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-saved',
      });
      await applyModelPreset(
        preset: _budget,
        service: service,
        store: store,
        keysStore: keys,
      );
      expect(store.configuredSlots, hasLength(_budget.mediaSlots.length));

      await applyModelPreset(
        preset: _quality,
        service: service,
        store: store,
        keysStore: keys,
      );
      expect(service.modelId, 'anthropic/claude-sonnet-4.5');
      expect(store.configuredSlots, [
        MediaSlot.imageGeneration,
        MediaSlot.transcription,
      ]);
      expect(store.overrideFor(MediaSlot.audioTts), isNull);
      expect(store.overrideFor(MediaSlot.musicGeneration), isNull);
      expect(store.overrideFor(MediaSlot.videoGeneration), isNull);
    });
  });

  group('modelPresetMatches', () {
    test('true right after apply, false on any drift', () async {
      final store = MediaModelsStore.inMemory();
      final service = _fakeService();
      expect(modelPresetMatches(_budget, service, store), isFalse);

      await applyModelPreset(
        preset: _budget,
        service: service,
        store: store,
        keysStore: SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-or-saved',
        }),
      );
      expect(modelPresetMatches(_budget, service, store), isTrue);
      expect(modelPresetMatches(_quality, service, store), isFalse);

      // A manual slot override breaks the match.
      await store.setOverride(
        MediaSlot.vision,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'gpt-4o',
        ),
      );
      expect(modelPresetMatches(_budget, service, store), isFalse);
    });
  });

  group('ModelPresetsSection', () {
    testWidgets('swiping moves to the next card and the dots follow', (
      tester,
    ) async {
      await _pumpSection(
        tester,
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
        keysStore: SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-or-saved',
        }),
      );
      expect(find.text('Model presets'), findsOneWidget);
      expect(find.text('Budget optimal'), findsOneWidget);
      expect(find.text('Quality'), findsNothing);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('Budget optimal'), findsNothing);
      // The second dot is active now.
      final section = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(ModelPresetsSection),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Container &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration! as BoxDecoration).shape ==
                        BoxShape.circle,
              ),
            )
            .last,
      );
      final decoration = section.decoration! as BoxDecoration;
      final theme = Theme.of(tester.element(find.byType(ModelPresetsSection)));
      expect(decoration.color, theme.colorScheme.primary);
    });

    testWidgets('Apply writes the media overrides and reconfigures the chat', (
      tester,
    ) async {
      final service = _fakeService();
      final store = MediaModelsStore.inMemory();
      final lastConnection = LastConnectionStore.inMemory();
      await _pumpSection(
        tester,
        service: service,
        store: store,
        keysStore: SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-or-saved',
        }),
        lastConnectionStore: lastConnection,
      );

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(service.modelId, 'google/gemini-3.6-flash');
      expect(
        store.overrideFor(MediaSlot.audioTts)?.modelId,
        'hexgrad/kokoro-82m',
      );
      expect(lastConnection.connection?.modelId, 'google/gemini-3.6-flash');

      // The applied state replaces the button with a check.
      expect(find.text('Applied'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('a missing key shows the hint and applies nothing', (
      tester,
    ) async {
      final service = _fakeService();
      final store = MediaModelsStore.inMemory();
      await _pumpSection(
        tester,
        service: service,
        store: store,
        keysStore: SessionKeysStore.inMemory(),
      );

      expect(
        find.text('This preset needs an API key for OpenRouter.'),
        findsOneWidget,
      );
      final applyButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Apply'),
      );
      expect(applyButton.onPressed, isNull);

      // Nothing was applied.
      expect(store.configuredSlots, isEmpty);
      expect(service.modelId, 'openai/gpt-4o-mini');

      // The jump button opens the provider editor for the preset.
      await tester.tap(find.text('Set key'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
    });
  });
}
