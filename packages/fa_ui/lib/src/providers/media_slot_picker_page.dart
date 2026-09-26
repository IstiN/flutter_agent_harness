// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/add_provider_picker.dart';
import 'package:fa_ui/src/providers/connection.dart' show FaChatModelConfig;
import 'package:fa_ui/src/providers/default_chat_model.dart'
    show FaOnDeviceRoute;
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/providers/voice_presets.dart';
import 'package:fa_ui/src/stores/media_models_store.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/widgets/model_list_picker.dart';

/// The outcome of the media slot flow ([MediaSlotProviderPickerPage] →
/// [MediaSlotModelPage]): either a [override] to save or [cleared] (remove
/// the slot's override, restoring the fallback).
final class MediaSlotEditorResult {
  const MediaSlotEditorResult.save(this.override) : cleared = false;

  const MediaSlotEditorResult.clear() : cleared = true, override = null;

  /// True when the user chose the main connection (clearing the override).
  final bool cleared;

  /// The override to persist (null when [cleared]).
  final MediaSlotOverride? override;
}

/// Step (a) of the media slot flow: pick a provider — "Same as main
/// connection" (clears the override), a hosted [ProviderPreset], or a saved
/// [CustomProvider] (check icon on the one backing [initial]) — or add a
/// new one. Endpoint providers continue to [MediaSlotModelPage]; a non-null
/// result from it pops the picker with the same result, so the settings
/// section's one push handles the whole flow.
class MediaSlotProviderPickerPage extends StatelessWidget {
  const MediaSlotProviderPickerPage({
    super.key,
    this.slot,
    required this.title,
    this.initial,
    this.mainBaseUrl = '',
    this.registry,
    this.modelsFetcher,
    this.connectedOnly = false,
    this.allowMainConnection = true,
    this.onDeviceRoutes = const [],
    this.addProviderPage,
  });

  /// The media slot being configured ([MediaSlot] name); null for the
  /// generic provider→model flow (agent/task roles): the model page then
  /// skips the slot-specific extras (voice field, capability chips).
  final String? slot;

  /// App bar title (`Edit Image generation`).
  final String title;

  /// The slot's current override (edit mode); `null` means the slot follows
  /// the main connection.
  final MediaSlotOverride? initial;

  /// The main connection's base URL, shown under the "Same as main
  /// connection" row.
  final String mainBaseUrl;

  /// The user-added providers listed in the picker; `null` falls back to a
  /// non-persisting in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// When true (the agent-role flow), hosted presets only appear when their
  /// key actually resolves — the role pickers choose among CONNECTED
  /// providers, not every preset the app knows about. Saved custom providers
  /// always list.
  final bool connectedOnly;

  /// Whether the leading "Same as main connection" row shows. False when
  /// editing the main connection itself (the default-chat-model flow) —
  /// clearing it makes no sense there.
  final bool allowMainConnection;

  /// On-device engine routes (Gemma/WebLLM/…), rendered as tiles before the
  /// Add provider row (the default-chat flow offers them; role/media
  /// overrides don't).
  final List<FaOnDeviceRoute> onDeviceRoutes;

  /// A host-provided "Add provider" page builder — the preset picker with
  /// the host's SSO/OAuth tiles. When null, the same
  /// [AddProviderPresetPickerPage] is built from this picker's registry
  /// (issue #975: every add-provider entry opens the ONE settings flow).
  final WidgetBuilder? addProviderPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
    debugPrint(
      '[fah][picker] $title: '
      'registry=${registry.providers.length} providers='
      '${registry.providers.map((p) => p.name).toList()} '
      'connectedOnly=$connectedOnly '
      'hadRegistry=${this.registry != null}',
    );
    // The provider backing the current override gets the check icon.
    final initial = this.initial;
    final selected = initial == null
        ? null
        : providerForBaseUrl(initial.baseUrl, registry);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: registry,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (allowMainConnection)
                  _providerTile(
                    context,
                    theme,
                    label: strings.mediaModelsMainConnection,
                    subtitle: mainBaseUrl.isEmpty
                        ? null
                        : providerHostOf(mainBaseUrl),
                    checked: initial == null,
                    onTap: () => Navigator.of(
                      context,
                    ).pop(const MediaSlotEditorResult.clear()),
                  ),
                // Dedupe: a saved custom provider on a hosted preset's
                // endpoint covers it (the CodeMie/ChatGPT/OpenRouter flows
                // register their instance there) — never show both.
                for (final preset in hostedProviderPresets.where(
                  (preset) =>
                      !registry.providers.any(
                        (custom) => custom.baseUrl == preset.baseUrl,
                      ) &&
                      (!connectedOnly || hostedProviderConnected(preset)),
                ))
                  _providerTile(
                    context,
                    theme,
                    label: preset.labelFor(context),
                    subtitle: providerHostOf(preset.baseUrl!),
                    checked: selected == preset,
                    onTap: () => _openModelPage(context, registry, preset),
                  ),
                for (final provider in registry.providers)
                  _providerTile(
                    context,
                    theme,
                    label: provider.name,
                    subtitle: providerHostOf(provider.baseUrl),
                    checked: selected == provider,
                    onTap: () => _openModelPage(context, registry, provider),
                  ),
                for (final route in onDeviceRoutes)
                  _providerTile(
                    context,
                    theme,
                    label: route.label,
                    leading: Icons.memory_outlined,
                    onTap: () => _openOnDevice(context, route),
                  ),
                const Divider(),
                _providerTile(
                  context,
                  theme,
                  label: strings.settingsAddProvider,
                  leading: Icons.add,
                  onTap: () => _addProvider(context, registry),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _providerTile(
    BuildContext context,
    ThemeData theme, {
    required String label,
    String? subtitle,
    IconData leading = Icons.cloud_outlined,
    bool checked = false,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(leading, color: theme.colorScheme.primary),
      title: Text(label),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, overflow: TextOverflow.ellipsis),
      trailing: checked
          ? Icon(Icons.check, size: 20, color: theme.colorScheme.primary)
          : Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      onTap: onTap,
    );
  }

  /// The model id the model page prefills for [provider]: the current
  /// override's model when it points at this provider, otherwise the
  /// provider's own default (a saved preset-model override wins).
  String _initialModelFor(Object provider) {
    final initial = this.initial;
    final baseUrl = switch (provider) {
      ProviderPreset preset => preset.baseUrl ?? '',
      CustomProvider custom => custom.baseUrl,
      _ => '',
    };
    if (initial != null && initial.baseUrl == baseUrl) return initial.modelId;
    return switch (provider) {
      ProviderPreset preset =>
        registry?.presetModelOverride(preset.name) ?? preset.defaultModel,
      CustomProvider custom => custom.modelId,
      _ => '',
    };
  }

  /// The voice the model page prefills for [provider]: the current
  /// override's voice when it points at this provider, otherwise null
  /// (a provider switch must not leak the old endpoint's voice).
  String? _initialVoiceFor(Object provider) {
    final initial = this.initial;
    final baseUrl = switch (provider) {
      ProviderPreset preset => preset.baseUrl ?? '',
      CustomProvider custom => custom.baseUrl,
      _ => '',
    };
    if (initial != null && initial.baseUrl == baseUrl) return initial.voice;
    return null;
  }

  Future<void> _openModelPage(
    BuildContext context,
    ProviderRegistry registry,
    Object provider,
  ) async {
    final result = await pushFaPage<MediaSlotEditorResult>(
      context,
      MediaSlotModelPage(
        slot: slot,
        provider: provider,
        registry: registry,
        initialModel: _initialModelFor(provider),
        initialVoice: _initialVoiceFor(provider),
        modelsFetcher: modelsFetcher,
      ),
    );
    // A saved override (or a clear) ends the whole flow.
    if (result != null && context.mounted) Navigator.of(context).pop(result);
  }

  /// On-device tile: the route's connect page; a completed connect maps to
  /// an override result carrying the engine's kind and pops the picker.
  Future<void> _openOnDevice(
    BuildContext context,
    FaOnDeviceRoute route,
  ) async {
    final config = await pushFaPage<FaChatModelConfig?>(
      context,
      route.pageBuilder(context, (config) async {
        if (context.mounted) Navigator.of(context).pop(config);
      }),
    );
    if (config == null || !context.mounted) return;
    Navigator.of(context).pop(
      MediaSlotEditorResult.save(
        MediaSlotOverride(
          providerKind: config.providerKind,
          baseUrl: config.baseUrl,
          modelId: config.modelId,
          apiKeyName: null,
        ),
      ),
    );
  }

  /// Adds a provider through the ONE add-provider flow (issue #975): the
  /// settings preset picker — the host builder adds the SSO/OAuth/on-device
  /// tiles, the fallback builds the same page from this picker's registry.
  /// The registry listener refreshes this list when it returns.
  Future<void> _addProvider(
    BuildContext context,
    ProviderRegistry registry,
  ) async {
    final hostPage = addProviderPage;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => hostPage != null
            ? hostPage(routeContext)
            : AddProviderPresetPickerPage(
                registry: registry,
                modelsFetcher: modelsFetcher,
              ),
      ),
    );
  }
}

/// Step (b) of the media slot flow for an endpoint provider: pick its model
/// — the endpoint's `/models` list feeds the quick select (any custom id
/// stays valid), capability hint chips derive from the fetched ids. Save
/// pops a [MediaSlotEditorResult.save] whose override stores the provider's
/// resolved URL and its key NAME (never a key value): the hosted preset's
/// well-known name ([hostedProviderKeyName], null for keyless presets), a
/// custom provider's host-scoped name ([ProviderRegistry.keyNameFor]).
class MediaSlotModelPage extends StatefulWidget {
  const MediaSlotModelPage({
    super.key,
    this.slot,
    required this.provider,
    this.registry,
    this.initialModel = '',
    this.initialVoice,
    this.apiKeyOverride,
    this.modelsFetcher,
  });

  /// The media slot being configured ([MediaSlot] name); null for the
  /// generic provider→model flow (agent/task roles) — no voice field, no
  /// capability chips, and the saved override carries the dial-aware
  /// provider kind.
  final String? slot;

  /// The picked provider: a hosted [ProviderPreset] or a [CustomProvider].
  final Object provider;

  /// The provider registry (custom-provider session keys, preset model
  /// overrides).
  final ProviderRegistry? registry;

  /// The model id the field starts with (the current override's model, or
  /// the provider's default).
  final String initialModel;

  /// The voice the TTS field starts with (the current override's voice);
  /// the field only renders for the [MediaSlot.audioTts] slot.
  final String? initialVoice;

  /// The API key the `/models` fetch authorizes with INSTEAD of the stored
  /// one — the provider editor passes the freshly typed (unsaved) key so
  /// the picker works before the provider is saved. Null falls back to
  /// [resolveProviderKey].
  final String? apiKeyOverride;

  /// `/models` fetch override (tests); production goes through the core
  /// [fetchModelsForEndpoint] dispatch directly.
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<MediaSlotModelPage> createState() => _MediaSlotModelPageState();
}

class _MediaSlotModelPageState extends State<MediaSlotModelPage> {
  late final TextEditingController _modelController;
  late final TextEditingController _voiceController;

  /// The endpoint's `/models` ids feeding the model field's quick select.
  List<String> _endpointModels = const [];
  var _modelsLoading = false;

  /// Whether the list answered from the bundled offline catalog (the live
  /// fetch failed) — drives the picker's provenance note.
  var _fromBundledCatalog = false;

  String? _error;

  /// The provider kind for a save: DIAL endpoints get 'dial' (their own
  /// URL/auth dialect), Copilot endpoints get 'copilot' (the GitHub→
  /// Copilot token exchange + Bearer wire), Google endpoints get 'google'
  /// (the Gemini adapter handles inlineData images), everything else is
  /// openai-completions. Media-slot saves always speak the OpenAI dialect;
  /// the generic role flow (slot == null) maps each endpoint to its real
  /// adapter so role runs use the same wire as the chat path.
  ///
  /// Identity first: a persisted entry kind ([_entryKind], e.g.
  /// 'chatgpt-codex' after OAuth) wins over every URL-shape check below,
  /// so an edited/proxied codex URL still saves — and dispatches — as its
  /// real kind; URL shape only classifies entries without a persisted
  /// kind.
  String _mediaSlotProviderKind(String? slot, String baseUrl) {
    if (slot != null) return 'openai-completions';
    final kind = _entryKind;
    if (kind != null) return kind;
    if (isCopilotBaseUrl(baseUrl)) return 'copilot';
    final preset = ProviderPreset.fromBaseUrl(baseUrl);
    if (preset == ProviderPreset.dial) return 'dial';
    if (baseUrl.contains('generativelanguage.googleapis.com')) return 'google';
    if (isChatGptCodexEndpoint(baseUrl)) return 'chatgpt-codex';
    return 'openai-completions';
  }

  /// Id fragments suggesting a media capability, matched case-insensitively
  /// against the endpoint's `/models` ids. Vision uses the shared
  /// [modelIdSuggestsVision] heuristic instead (its marker list is far
  /// broader). These are HINTS only — most endpoints expose no modality
  /// metadata, so the chips never gate anything.
  static const _capabilityMarkers = <String, List<String>>{
    MediaSlot.imageGeneration: [
      'image',
      'dall-e',
      'flux',
      'stable-diffusion',
      'sdxl',
    ],
    MediaSlot.audioTts: ['tts', 'speech'],
    MediaSlot.musicGeneration: ['music'],
    MediaSlot.videoGeneration: ['video', 'sora', 'veo'],
    MediaSlot.transcription: ['whisper', 'transcribe', 'asr'],
  };

  String get _baseUrl => switch (widget.provider) {
    ProviderPreset preset => preset.baseUrl ?? '',
    CustomProvider custom => custom.baseUrl,
    _ => '',
  };

  /// The source entry's persisted identity ([CustomProvider.kind]) — wins
  /// over URL matching in the fetch hint and the generic-role save path.
  String? get _entryKind => switch (widget.provider) {
    CustomProvider custom => custom.kind,
    _ => null,
  };

  void _onModelChanged() => setState(() {});

  /// The voice presets matching the currently typed model id (empty → the
  /// free-text voice field stays).
  List<FaVoicePreset> get _voicePresets => faVoicePresetsFor(
    baseUrl: _baseUrl.isEmpty ? null : _baseUrl,
    modelId: _modelController.text,
  );

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(text: widget.initialModel);
    _voiceController = TextEditingController(text: widget.initialVoice);
    // The TTS voice presets derive from the typed model id — rebuild on
    // every edit so the picker appears/disappears live.
    _modelController.addListener(_onModelChanged);
    // The fetch resolves the provider key through the inherited saved-keys
    // scope — unavailable during initState, so it runs after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fetchEndpointModels());
    });
  }

  @override
  void dispose() {
    _modelController.dispose();
    _voiceController.dispose();
    super.dispose();
  }

  /// Fetches the endpoint's model list for the picker: the injected
  /// [MediaSlotModelPage.modelsFetcher] override (tests, host codemie
  /// wiring) wins; otherwise the core [fetchModelsForEndpoint] dispatch
  /// handles the DIAL deployments endpoint, the CodeMie marker, the
  /// bundled Codex catalog, and the Copilot token exchange itself (see
  /// [modelsDispatchHintFor]). Silent on failure — free-text entry always
  /// works; a bundled-catalog answer shows the provenance note.
  Future<void> _fetchEndpointModels() async {
    final baseUrl = _baseUrl;
    if (baseUrl.isEmpty) return;
    setState(() => _modelsLoading = true);
    var fromBundledCatalog = false;
    try {
      final key =
          widget.apiKeyOverride ??
          resolveProviderKey(
            widget.provider,
            registry: widget.registry,
            keysStore: SessionKeysScope.maybeOf(context),
          );
      final override = widget.modelsFetcher;
      final (ids, _, _) = override != null
          ? await override(baseUrl, apiKey: key)
          : await fetchModelsForEndpoint(
              baseUrl,
              apiKey: key,
              provider: modelsDispatchHintForEntry(_entryKind, baseUrl),
              onBundledFallback: () => fromBundledCatalog = true,
            );
      if (!mounted) return;
      setState(() {
        _endpointModels = ids;
        _fromBundledCatalog = fromBundledCatalog;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _endpointModels = const [];
          _fromBundledCatalog = false;
        });
      }
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  /// The media capabilities the fetched model ids suggest, in [MediaSlot.all]
  /// order. Empty when nothing was fetched or nothing matched — the hints
  /// stay hidden rather than claiming "no support".
  /// The media capabilities the fetched model ids suggest, in [MediaSlot.all]
  /// order. Empty when nothing was fetched or nothing matched — the hints
  /// stay hidden rather than claiming "no support". Always empty in the
  /// generic role flow (no slot).
  List<String> get _suggestedCapabilities {
    if (widget.slot == null || _endpointModels.isEmpty) return const [];
    bool suggests(String slot, String id) {
      if (slot == MediaSlot.vision) return modelIdSuggestsVision(id);
      final markers = _capabilityMarkers[slot];
      return markers != null && markers.any(id.contains);
    }

    return [
      for (final slot in MediaSlot.all)
        if (_endpointModels
            .map((id) => id.toLowerCase())
            .any((id) => suggests(slot, id)))
          slot,
    ];
  }

  void _save() {
    final model = _modelController.text.trim();
    if (model.isEmpty) {
      setState(() => _error = FaUiStrings.of(context).settingsModelIdRequired);
      return;
    }
    final provider = widget.provider;
    final keyName = switch (provider) {
      ProviderPreset preset => hostedProviderKeyName(preset),
      CustomProvider _ => ProviderRegistry.keyNameFor(_baseUrl),
      _ => null,
    };
    // The voice only applies to the TTS slot; an empty field clears it.
    final voice = widget.slot == MediaSlot.audioTts
        ? _voiceController.text.trim()
        : '';
    Navigator.of(context).pop(
      MediaSlotEditorResult.save(
        MediaSlotOverride(
          // Media tools speak the OpenAI dialect; the generic role flow
          // (slot == null) maps DIAL endpoints to their own adapter kind.
          // Google endpoints use the Gemini adapter (inlineData, not
          // image_url) so image-based media slots work.
          providerKind: _mediaSlotProviderKind(widget.slot, _baseUrl),
          baseUrl: _baseUrl,
          modelId: model,
          apiKeyName: keyName,
          voice: voice.isEmpty ? null : voice,
          providerId: switch (provider) {
            CustomProvider custom => custom.id,
            ProviderPreset preset => preset.name,
            _ => null,
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final capabilities = _suggestedCapabilities;
    return Scaffold(
      appBar: AppBar(
        title: Text(providerDisplayName(context, widget.provider)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.cloud_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(providerDisplayName(context, widget.provider)),
                subtitle: Text(
                  providerHostOf(_baseUrl),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 12),
              FaModelListPicker(
                controller: _modelController,
                models: _endpointModels,
                loading: _modelsLoading,
                fromBundledCatalog: _fromBundledCatalog,
              ),
              if (widget.slot == MediaSlot.audioTts) ...[
                const SizedBox(height: 16),
                // Known models get the preset picker (with sample previews);
                // anything else keeps the free-text field.
                if (_voicePresets.isNotEmpty)
                  FaVoicePresetPicker(
                    presets: _voicePresets,
                    value: _voiceController.text.trim().isEmpty
                        ? null
                        : _voiceController.text.trim(),
                    onChanged: (voice) =>
                        setState(() => _voiceController.text = voice),
                  )
                else
                  TextField(
                    controller: _voiceController,
                    decoration: InputDecoration(
                      labelText: strings.mediaModelsVoiceLabel,
                      hintText: strings.mediaModelsVoiceHint,
                    ),
                  ),
              ],
              if (capabilities.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  strings.mediaModelsCapabilitiesNote,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final capability in capabilities)
                      Chip(
                        label: Text(faMediaSlotLabel(strings, capability)),
                        // The slot being edited is highlighted; the rest are
                        // neutral hints about the provider.
                        backgroundColor: capability == widget.slot
                            ? theme.colorScheme.primaryContainer
                            : null,
                        side: capability == widget.slot
                            ? BorderSide.none
                            : BorderSide(
                                color: theme.colorScheme.outlineVariant,
                              ),
                      ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                child: Text(strings.settingsSaveButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
