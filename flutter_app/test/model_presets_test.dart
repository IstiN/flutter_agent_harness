// Unit + widget tests for `lib/ui/screens/model_presets.dart` — the
// declarative preset list, the one-tap apply semantics (media overrides +
// main-connection reconfigure), and the swipeable wizard section.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:fa_ui/src/stores/provider_registry.dart'
    show CustomProvider, ProviderRegistry;
import 'package:fa_ui/fa_ui.dart' show FaDesignTokens;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal [AgentService] (never connected: no network/file/JS backends)
/// — the pattern of `test/goldens/settings_golden_test.dart`.
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
      systemPrompt: 'You are Fa.',
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
  ProviderRegistry? registry,
  FaProductConfig? productConfig,
  Locale? locale,
}) {
  Widget child = MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ProductConfigScope(
      productConfig: productConfig ?? FaProductConfig.stock,
      child: Scaffold(
        body: SingleChildScrollView(
          child: ModelPresetsSection(
            service: service,
            store: store,
            lastConnectionStore: lastConnectionStore,
            registry: registry,
          ),
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
      // Only slots OpenRouter actually serves are mapped (TTS, music,
      // video and transcription have no OpenRouter models today).
      expect(preset.mediaSlots, {
        MediaSlot.imageGeneration: 'google/gemini-2.5-flash-image',
      });
      // Vision deliberately stays on the main connection.
      expect(preset.mediaSlots, isNot(contains(MediaSlot.vision)));
      // The task roles ride the same combo.
      expect(preset.taskSlots, {
        TaskRole.smol: 'google/gemini-3.5-flash-lite',
        TaskRole.subagent: 'google/gemini-3.6-flash',
      });
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
      expect(store.configuredSlots, [MediaSlot.imageGeneration]);
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

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.text('Quality'), findsOneWidget);
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
      final tokens = FaDesignTokens.of(
        tester.element(find.byType(ModelPresetsSection)),
      );
      expect(decoration.color, tokens.accent);
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

      await tester.tap(find.text('Apply').first);
      await tester.pumpAndSettle();

      expect(service.modelId, 'google/gemini-3.6-flash');
      expect(
        store.overrideFor(MediaSlot.imageGeneration)?.modelId,
        'google/gemini-2.5-flash-image',
      );
      expect(lastConnection.connection?.modelId, 'google/gemini-3.6-flash');

      // The applied state replaces the button with a check.
      expect(find.text('Applied'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    test(
      'applyModelPreset writes and clears the task-role overrides',
      () async {
        final service = _fakeService();
        final store = MediaModelsStore.inMemory();
        final taskStore = TaskModelsStore.inMemory();
        final keys = SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-or-saved',
        });

        await applyModelPreset(
          preset: _budget,
          service: service,
          store: store,
          keysStore: keys,
          taskStore: taskStore,
        );
        expect(
          taskStore.overrideFor(TaskRole.smol)?.modelId,
          'google/gemini-3.5-flash-lite',
        );
        expect(
          taskStore.overrideFor(TaskRole.subagent)?.modelId,
          'google/gemini-3.6-flash',
        );
        expect(
          modelPresetMatches(_budget, service, store, taskStore: taskStore),
          isTrue,
        );

        // A preset without taskSlots clears the roles back to the fallback.
        await applyModelPreset(
          preset: const ModelPreset(
            id: 'bare',
            target: HostedModelPresetTarget(ProviderPreset.openrouter),
            chatModelId: 'openai/gpt-5-mini',
          ),
          service: service,
          store: store,
          keysStore: keys,
          taskStore: taskStore,
        );
        expect(taskStore.overrideFor(TaskRole.smol), isNull);
        expect(taskStore.overrideFor(TaskRole.subagent), isNull);
      },
    );

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

      // Both OpenRouter presets warn (the carousel builds the peeking
      // neighbor too); both Apply buttons stay disabled without the key.
      expect(
        find.text('This preset needs an API key for OpenRouter.'),
        findsWidgets,
      );
      final applyButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Apply').first,
      );
      expect(applyButton.onPressed, isNull);

      // Nothing was applied.
      expect(store.configuredSlots, isEmpty);
      expect(service.modelId, 'openai/gpt-4o-mini');

      // The jump button opens the provider editor for the preset.
      await tester.tap(find.text('Set key').first);
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
    });
  });

  group('host-only catalog (gh-2391 addendum 8 item 5)', () {
    const ainOrigin = 'https://api.ain.example/v1';

    HostConnectionConfig section() => HostConnectionConfig.fromJson(
      {
        'baseUrl': ainOrigin,
        'sessionBridge': {
          'storage': 'localStorage',
          'key': 'aiin_agent_session',
        },
        'defaultModel': 'ain/ain_flash',
        'modelRoles': {
          'smol': 'ain/ain_flash',
          'subagent': 'ain/ain_pro',
          // Profile-only roles stay metadata; the card shows app roles.
          'plan': 'ain/ain_pro',
        },
        'mediaSlots': {
          'imageGeneration': {'model': 'ain/ain_image'},
          'videoGeneration': {'model': 'ain/ain_video'},
        },
      },
      apiEndpoint: Uri.parse(ainOrigin),
      displayName: () => 'AIN',
    );

    test('hostModelPreset mirrors the section', () {
      final preset = hostModelPreset(section());
      expect(preset.target.baseUrl, ainOrigin);
      expect(preset.chatModelId, 'ain/ain_flash');
      expect(preset.taskSlots, {
        TaskRole.smol: 'ain/ain_flash',
        TaskRole.subagent: 'ain/ain_pro',
      });
      expect(preset.mediaSlots, {
        MediaSlot.imageGeneration: 'ain/ain_image',
        MediaSlot.videoGeneration: 'ain/ain_video',
      });
    });

    Future<ProviderRegistry> bridgedRegistry() async {
      final registry = ProviderRegistry.inMemory();
      // The resolver upserts the host row before remembering the key —
      // the named-key seam resolves through that row.
      await registry.upsert(
        CustomProvider(
          id: 'host',
          name: 'AIN',
          baseUrl: ainOrigin,
          modelId: 'ain/ain_flash',
          provenance: 'host',
          kind: 'host-session',
        ),
      );
      return registry;
    }

    test('the host key resolves through the registry session seam', () async {
      final registry = await bridgedRegistry();
      expect(
        hostModelPreset(section()).target.resolveKey(registry: registry),
        isEmpty,
      );
      registry.rememberSessionKey('host', 'bridged-secret');
      expect(
        hostModelPreset(section()).target.resolveKey(registry: registry),
        'bridged-secret',
      );
      // The named-key seam is the resolver's own rule.
      expect(
        hostModelPreset(section()).target.keyName,
        ProviderRegistry.keyNameFor(ainOrigin),
      );
    });

    test(
      'key availability follows the bridged key, never saved keys',
      () async {
        final registry = await bridgedRegistry();
        final hostPreset = hostModelPreset(section());
        expect(
          modelPresetKeyAvailable(hostPreset, null, registry: registry),
          isFalse,
        );
        registry.rememberSessionKey('host', 'bridged-secret');
        expect(
          modelPresetKeyAvailable(hostPreset, null, registry: registry),
          isTrue,
        );
      },
    );

    test(
      'applyModelPreset writes the host combo over the bridged key',
      () async {
        final store = MediaModelsStore.inMemory();
        final service = _fakeService();
        final registry = ProviderRegistry.inMemory()
          ..rememberSessionKey('host', 'bridged-secret');
        final lastConnection = LastConnectionStore.inMemory();

        await applyModelPreset(
          preset: hostModelPreset(section()),
          service: service,
          store: store,
          registry: registry,
          lastConnectionStore: lastConnection,
        );

        expect(service.modelId, 'ain/ain_flash');
        expect(service.activeBaseUrl, ainOrigin);
        for (final entry in store.configuredSlots) {
          final override = store.overrideFor(entry)!;
          expect(override.baseUrl, ainOrigin);
          expect(override.apiKeyName, ProviderRegistry.keyNameFor(ainOrigin));
        }
        expect(lastConnection.connection!.modelId, 'ain/ain_flash');
      },
    );

    testWidgets('the section renders exactly one host card — no OpenRouter '
        'zoo, no key CTA', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await _pumpSection(
        tester,
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
        registry: registry,
        productConfig: FaProductConfig(
          productId: 'ain',
          displayName: 'AIIN Agent',
          apiEndpoint: Uri.parse(ainOrigin),
          featureFlags: const {},
          hostConnection: section(),
          providerCatalog: 'host-only',
        ),
      );
      expect(find.text('AIN'), findsOneWidget);
      expect(find.text('ain/ain_flash'), findsWidgets);
      expect(find.textContaining('OpenRouter'), findsNothing);
      expect(find.textContaining('API key'), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
    });

    testWidgets('host card: description follows the sign-in state, role '
        'labels localized (gh-2391 addendum 9 items 5b/5c)', (tester) async {
      FaProductConfig config() => FaProductConfig(
        productId: 'ain',
        displayName: 'AIIN Agent',
        apiEndpoint: Uri.parse(ainOrigin),
        featureFlags: const {},
        hostConnection: section(),
        providerCatalog: 'host-only',
      );

      // Signed OUT (EN): the after-sign-in wording.
      await _pumpSection(
        tester,
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
        registry: ProviderRegistry.inMemory(),
        productConfig: config(),
      );
      expect(find.text('Available after you sign in to AIN.'), findsOneWidget);

      // Signed IN (EN): the included wording.
      final signedIn = (await bridgedRegistry())
        ..rememberSessionKey('host', 'bridged-secret');
      await _pumpSection(
        tester,
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
        registry: signedIn,
        productConfig: config(),
      );
      expect(find.text('Included with your AIN sign-in.'), findsOneWidget);
      expect(find.text('Available after you sign in to AIN.'), findsNothing);

      // Signed IN (RU): localized description AND role labels.
      await _pumpSection(
        tester,
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
        registry: (await bridgedRegistry())
          ..rememberSessionKey('host', 'bridged-secret'),
        productConfig: config(),
        locale: const Locale('ru'),
      );
      expect(find.text('Включено с вашим входом в AIN.'), findsOneWidget);
      expect(find.text('Быстрая модель'), findsOneWidget);
      expect(find.text('Модель субагентов'), findsOneWidget);
      expect(find.text('Quick model'), findsNothing);
      expect(find.text('Subagents model'), findsNothing);
    });

    testWidgets('Apply on the host card carries the bridged key through', (
      tester,
    ) async {
      final service = _fakeService();
      final store = MediaModelsStore.inMemory();
      final lastConnection = LastConnectionStore.inMemory();
      final registry = await bridgedRegistry()
        ..rememberSessionKey('host', 'bridged-secret');
      await _pumpSection(
        tester,
        service: service,
        store: store,
        lastConnectionStore: lastConnection,
        registry: registry,
        productConfig: FaProductConfig(
          productId: 'ain',
          displayName: 'AIIN Agent',
          apiEndpoint: Uri.parse(ainOrigin),
          featureFlags: const {},
          hostConnection: section(),
          providerCatalog: 'host-only',
        ),
      );

      await tester.tap(find.text('Apply').first);
      await tester.pumpAndSettle();

      expect(find.text('Applied'), findsOneWidget);
      expect(service.modelId, 'ain/ain_flash');
      expect(service.activeBaseUrl, ainOrigin);
      // The apply must ride the same registry seam keyAvailable consulted —
      // dropping it here reconfigures the live connection with an empty key.
      expect(service.activeApiKeyForTest, 'bridged-secret');
    });

    testWidgets('stock keeps the two-card carousel (REG)', (tester) async {
      await _pumpSection(
        tester,
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
        registry: ProviderRegistry.inMemory(),
      );
      expect(find.text('Budget optimal'), findsOneWidget);
      expect(find.textContaining('OpenRouter'), findsWidgets);
    });
  });
}
