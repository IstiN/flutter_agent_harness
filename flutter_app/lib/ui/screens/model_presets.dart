// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/vision_models.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/settings.dart';

/// Where a [ModelPreset] points the main connection (and the media slots it
/// overrides). Sealed so further kinds — saved custom providers, on-device
/// backends — can join later without changing consumers.
sealed class ModelPresetTarget {
  /// Creates a target.
  const ModelPresetTarget();

  /// The OpenAI-compatible base URL the preset connects to ('' for keyless
  /// on-device targets, when those are added).
  String get baseUrl;

  /// The name of the saved-keys entry backing this target (see
  /// [hostedProviderKeyName]); `null` for keyless targets.
  String? get keyName;

  /// The key this target connects with, resolved exactly like the connection
  /// form; empty means "no credential".
  String resolveKey({SessionKeysStore? keysStore});
}

/// A hosted provider preset (OpenRouter, Ollama Cloud) — an
/// OpenAI-compatible endpoint that requires a named API key.
final class HostedModelPresetTarget extends ModelPresetTarget {
  /// Creates a target over a hosted [ProviderPreset].
  const HostedModelPresetTarget(this.provider);

  /// The backing provider preset.
  final ProviderPreset provider;

  @override
  String get baseUrl => provider.baseUrl!;

  @override
  String? get keyName => hostedProviderKeyName(provider);

  @override
  String resolveKey({SessionKeysStore? keysStore}) =>
      resolveProviderKey(provider, keysStore: keysStore);
}

/// A complete model combo applied in one tap: the chat model of the main
/// connection plus a set of media slot overrides (see [MediaModelsStore]).
///
/// Presets are declarative — see [kModelPresets] for how to add one.
final class ModelPreset {
  /// Creates a preset.
  const ModelPreset({
    required this.id,
    required this.target,
    required this.chatModelId,
    this.mediaSlots = const {},
  });

  /// Stable identifier (drives the localized name/description lookup).
  final String id;

  /// The provider the whole combo rides on.
  final ModelPresetTarget target;

  /// The chat model applied as the main connection.
  final String chatModelId;

  /// Media slot overrides: `{MediaSlot.x → model id}`. Slots NOT listed here
  /// stay on the main connection — their override is CLEARED on apply.
  final Map<String, String> mediaSlots;

  /// The localized preset name (the id itself for unknown presets).
  String nameFor(AppLocalizations l10n) => switch (id) {
    'budget' => l10n.modelPresetBudgetName,
    'quality' => l10n.modelPresetQualityName,
    _ => id,
  };

  /// The localized one-line cost/quality positioning.
  String descriptionFor(AppLocalizations l10n) => switch (id) {
    'budget' => l10n.modelPresetBudgetDescription,
    'quality' => l10n.modelPresetQualityDescription,
    _ => '',
  };
}

/// The swipeable preset cards of the settings "Model presets" section, in
/// page order.
///
/// HOW TO ADD A PRESET:
/// 1. Append a [ModelPreset] here with a unique `id`, a `target` (a hosted
///    preset today — add a [ModelPresetTarget] subtype for custom or
///    on-device providers), the chat `chatModelId`, and `mediaSlots` mapping
///    [MediaSlot] names to model ids (slots left out keep "same as main
///    connection").
/// 2. Add `modelPreset<Id>Name` / `modelPreset<Id>Description` to
///    `lib/l10n/app_en.arb` + `app_ru.arb` and extend
///    [ModelPreset.nameFor]/[ModelPreset.descriptionFor].
/// 3. Run `flutter gen-l10n`, update the tests, and regenerate the
///    `model_presets` goldens.
const kModelPresets = <ModelPreset>[
  ModelPreset(
    id: 'budget',
    target: HostedModelPresetTarget(ProviderPreset.openrouter),
    chatModelId: 'google/gemini-3.6-flash',
    mediaSlots: {
      MediaSlot.imageGeneration: 'black-forest-labs/flux.2-klein-4b',
      MediaSlot.audioTts: 'hexgrad/kokoro-82m',
      MediaSlot.musicGeneration: 'google/lyria-3-clip-preview',
      MediaSlot.videoGeneration: 'bytedance/seedance-1-5-pro',
      MediaSlot.transcription: 'openai/whisper-large-v3',
      // Vision stays on the main connection (no override).
    },
  ),
  ModelPreset(
    id: 'quality',
    target: HostedModelPresetTarget(ProviderPreset.openrouter),
    chatModelId: 'anthropic/claude-sonnet-4.5',
    mediaSlots: {
      MediaSlot.imageGeneration: 'google/gemini-2.5-flash-image',
      MediaSlot.transcription: 'openai/whisper-large-v3',
      // Everything else stays on the main connection.
    },
  ),
];

/// Whether the preset's provider credential resolves (hosted presets require
/// a saved/env key; keyless targets always apply).
bool modelPresetKeyAvailable(ModelPreset preset, SessionKeysStore? keysStore) {
  final name = preset.target.keyName;
  return name == null || settingsKeyEnv(name, keysStore).isNotEmpty;
}

/// Whether the current connection + slot overrides exactly match [preset]:
/// the chat model and endpoint of the main connection, an override for every
/// mapped slot, and NO override for every unmapped one.
bool modelPresetMatches(
  ModelPreset preset,
  AgentService service,
  MediaModelsStore store,
) {
  if (service.providerKind != 'openai-completions') return false;
  if (service.modelId != preset.chatModelId) return false;
  if (service.activeBaseUrl != preset.target.baseUrl) return false;
  for (final slot in MediaSlot.all) {
    final modelId = preset.mediaSlots[slot];
    final override = store.overrideFor(slot);
    if (modelId == null) {
      if (override != null) return false;
    } else if (override == null ||
        override.modelId != modelId ||
        override.baseUrl != preset.target.baseUrl) {
      return false;
    }
  }
  return true;
}

/// Applies [preset] in one shot: every mapped media slot gets an
/// OpenAI-compatible override pointing at the preset's endpoint (keyed by
/// the provider's named key), every UNMAPPED slot's override is cleared back
/// to "same as main connection", and the main connection is reconfigured to
/// the preset's chat model — the same apply the default-chat-model flow
/// performs (reconfigure + persist the last connection). Callers must check
/// [modelPresetKeyAvailable] first; hosted presets need a key.
///
/// [service] may be null in the pre-connection onboarding flow: then only
/// the slot overrides and the last connection are persisted — the boot
/// auto-connect picks the saved connection up and builds the real service.
Future<void> applyModelPreset({
  required ModelPreset preset,
  required AgentService? service,
  required MediaModelsStore store,
  SessionKeysStore? keysStore,
  LastConnectionStore? lastConnectionStore,
}) async {
  final baseUrl = preset.target.baseUrl;
  final keyName = preset.target.keyName;
  for (final slot in MediaSlot.all) {
    final modelId = preset.mediaSlots[slot];
    await store.setOverride(
      slot,
      modelId == null
          ? null
          : MediaSlotOverride(
              providerKind: 'openai-completions',
              baseUrl: baseUrl,
              modelId: modelId,
              apiKeyName: keyName,
            ),
    );
  }
  final config = AgentConfig(
    providerKind: 'openai-completions',
    modelId: preset.chatModelId,
    baseUrl: baseUrl,
    apiKey: preset.target.resolveKey(keysStore: keysStore),
    contextWindow: fallbackContextWindow,
    maxTokens: fallbackMaxTokens,
    supportsImages: modelIdSuggestsVision(preset.chatModelId),
  );
  await service?.reconfigure(config);
  await lastConnectionStore?.saveFromConfig(config);
}

/// The settings "Model presets" section: a mini-wizard of swipeable preset
/// cards (a page-snapping [PageView] with dot indicators) applying a
/// complete model combo — chat model + media slots — in one tap via
/// [applyModelPreset]. A card whose provider key is missing shows an inline
/// hint with a jump to the provider editor instead of applying.
///
/// The store comes from [store] or the nearest [MediaModelsScope]; the whole
/// section hides when no store is available (like [MediaModelsSection]).
class ModelPresetsSection extends StatefulWidget {
  /// Creates the section.
  const ModelPresetsSection({
    super.key,
    required this.service,
    this.store,
    this.lastConnectionStore,
  });

  /// The service whose backend applying a preset reconfigures.
  final AgentService service;

  /// Store override; falls back to the nearest [MediaModelsScope].
  final MediaModelsStore? store;

  /// Updated on every successful apply (see [LastConnectionStore]).
  final LastConnectionStore? lastConnectionStore;

  @override
  State<ModelPresetsSection> createState() => _ModelPresetsSectionState();
}

class _ModelPresetsSectionState extends State<ModelPresetsSection> {
  final PageController _pageController = PageController(viewportFraction: 0.9);
  var _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = widget.store ?? MediaModelsScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    // The saved-keys scope registers as a dependency, so saving the preset's
    // key from the editor re-enables Apply without a manual refresh.
    final keysStore = SessionKeysScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.service, store]),
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.modelPresetsSectionTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            // The carousel is full-BLEED: it breaks out of the settings
            // page padding so swiped cards slide behind the screen edges
            // (peek effect) instead of being clipped by the padding void.
            // viewportFraction 0.9 keeps the active card centered with the
            // neighbors peeking in from beyond the edges.
            SizedBox(
              height: 380,
              child: OverflowBox(
                maxWidth: double.infinity,
                child: SizedBox(
                  width: MediaQuery.sizeOf(context).width,
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: kModelPresets.length,
                    onPageChanged: (page) => setState(() => _page = page),
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: _PresetCard(
                        preset: kModelPresets[index],
                        service: widget.service,
                        store: store,
                        keysStore: keysStore,
                        lastConnectionStore: widget.lastConnectionStore,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (kModelPresets.length > 1) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < kModelPresets.length; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.3,
                              ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// One swipeable preset card: name, description, the combo summary (chat +
/// per-slot models with the media slot icons), the missing-key warning when
/// applicable, and the Apply button (a check once the current config
/// matches).
class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.service,
    required this.store,
    required this.keysStore,
    required this.lastConnectionStore,
  });

  final ModelPreset preset;
  final AgentService service;
  final MediaModelsStore store;
  final SessionKeysStore? keysStore;
  final LastConnectionStore? lastConnectionStore;

  Future<void> _setupKey(BuildContext context) async {
    final target = preset.target;
    if (target is! HostedModelPresetTarget) return;
    final provider = target.provider;
    final keyName = hostedProviderKeyName(provider);
    final result = await Navigator.of(context).push<ProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) => ProviderEditorPage(
          title: provider.labelFor(context),
          preset: provider,
          hasSavedKey:
              keyName != null && settingsKeyEnv(keyName, keysStore).isNotEmpty,
        ),
      ),
    );
    if (result == null || result.apiKey.isEmpty || keyName == null) return;
    await keysStore?.set(keyName, result.apiKey);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final keyAvailable = modelPresetKeyAvailable(preset, keysStore);
    final applied = modelPresetMatches(preset, service, store);
    final providerLabel = switch (preset.target) {
      HostedModelPresetTarget(:final provider) => provider.labelFor(context),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(preset.nameFor(l10n), style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              preset.descriptionFor(l10n),
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            _comboRow(
              context,
              icon: Icons.chat_bubble_outline,
              label: l10n.modelPresetsChatLabel,
              modelId: preset.chatModelId,
            ),
            for (final slot in MediaSlot.all)
              _comboRow(
                context,
                icon: MediaModelsSection.slotIcons[slot] ?? Icons.tune,
                label: MediaModelsSection.slotLabelFor(l10n, slot),
                modelId:
                    preset.mediaSlots[slot] ?? l10n.mediaModelsFallbackSummary,
              ),
            const Spacer(),
            if (!keyAvailable)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.key_outlined,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.modelPresetsKeyMissing(providerLabel),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _setupKey(context),
                      child: Text(l10n.modelPresetsSetKey),
                    ),
                  ],
                ),
              ),
            if (applied)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.modelPresetsApplied,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              )
            else
              FilledButton(
                onPressed: keyAvailable
                    ? () => applyModelPreset(
                        preset: preset,
                        service: service,
                        store: store,
                        keysStore: keysStore,
                        lastConnectionStore: lastConnectionStore,
                      )
                    : null,
                child: Text(l10n.settingsApplyButton),
              ),
          ],
        ),
      ),
    );
  }

  Widget _comboRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String modelId,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              modelId,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
