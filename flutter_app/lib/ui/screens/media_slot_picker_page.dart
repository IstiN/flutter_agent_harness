// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/vision_models.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/settings.dart';

/// The production [ModelsEndpointFetcher] shared by the settings form and
/// the media slot picker: GETs `<baseUrl>/models` (OpenAI shape, bearer key
/// when present) and parses it with the shared harness parser (ids, context
/// windows, output caps). Failures return empty info — free-text model entry
/// keeps working.
Future<ModelsEndpointInfo> defaultModelsEndpointFetcher(
  String baseUrl, {
  required String apiKey,
}) async {
  try {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }
    return parseModelsResponse(response.body);
  } on Object {
    return (const <String>[], const <String, int>{}, const <String, int>{});
  }
}

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
    required this.slot,
    required this.title,
    this.initial,
    this.mainBaseUrl = '',
    this.registry,
    this.modelsFetcher,
  });

  /// The media slot being configured ([MediaSlot] name).
  final String slot;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
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
                _providerTile(
                  context,
                  theme,
                  label: context.l10n.mediaModelsMainConnection,
                  subtitle: mainBaseUrl.isEmpty
                      ? null
                      : providerHostOf(mainBaseUrl),
                  checked: initial == null,
                  onTap: () => Navigator.of(
                    context,
                  ).pop(const MediaSlotEditorResult.clear()),
                ),
                for (final preset in hostedProviderPresets)
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
                const Divider(),
                _providerTile(
                  context,
                  theme,
                  label: context.l10n.settingsAddProvider,
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

  Future<void> _openModelPage(
    BuildContext context,
    ProviderRegistry registry,
    Object provider,
  ) async {
    final result = await Navigator.of(context).push<MediaSlotEditorResult>(
      MaterialPageRoute(
        builder: (_) => MediaSlotModelPage(
          slot: slot,
          provider: provider,
          registry: registry,
          initialModel: _initialModelFor(provider),
          modelsFetcher: modelsFetcher,
        ),
      ),
    );
    // A saved override (or a clear) ends the whole flow.
    if (result != null && context.mounted) Navigator.of(context).pop(result);
  }

  /// Adds a provider through the shared create page and continues straight
  /// to its model page.
  Future<void> _addProvider(
    BuildContext context,
    ProviderRegistry registry,
  ) async {
    final added = await pushProviderEditor(
      context,
      registry,
      title: context.l10n.settingsAddProvider,
    );
    if (added == null || !context.mounted) return;
    await _openModelPage(context, registry, added);
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
    required this.slot,
    required this.provider,
    this.registry,
    this.initialModel = '',
    this.modelsFetcher,
  });

  /// The media slot being configured ([MediaSlot] name).
  final String slot;

  /// The picked provider: a hosted [ProviderPreset] or a [CustomProvider].
  final Object provider;

  /// The provider registry (custom-provider session keys, preset model
  /// overrides).
  final ProviderRegistry? registry;

  /// The model id the field starts with (the current override's model, or
  /// the provider's default).
  final String initialModel;

  /// `/models` fetch override (tests); defaults to the production HTTP
  /// fetch + shared parser ([defaultModelsEndpointFetcher]).
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<MediaSlotModelPage> createState() => _MediaSlotModelPageState();
}

class _MediaSlotModelPageState extends State<MediaSlotModelPage> {
  late final TextEditingController _modelController;

  /// The endpoint's `/models` ids feeding the model field's quick select.
  List<String> _endpointModels = const [];
  var _modelsLoading = false;

  /// The model field's focus node (drives the quick-select overlay).
  final FocusNode _modelFocusNode = FocusNode();

  String? _error;

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

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(text: widget.initialModel);
    // The fetch resolves the provider key through the inherited saved-keys
    // scope — unavailable during initState, so it runs after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fetchEndpointModels());
    });
  }

  @override
  void dispose() {
    _modelFocusNode.dispose();
    _modelController.dispose();
    super.dispose();
  }

  /// Fetches `<baseUrl>/models` (OpenAI shape) for the model field's quick
  /// select and the capability hints. Silent on failure — free-text entry
  /// always works, the field just loses its suggestions.
  Future<void> _fetchEndpointModels() async {
    final baseUrl = _baseUrl;
    if (baseUrl.isEmpty) return;
    setState(() => _modelsLoading = true);
    try {
      final fetch = widget.modelsFetcher ?? defaultModelsEndpointFetcher;
      final key = resolveProviderKey(
        widget.provider,
        registry: widget.registry,
        keysStore: SessionKeysScope.maybeOf(context),
      );
      final (ids, _, _) = await fetch(baseUrl, apiKey: key);
      if (!mounted) return;
      setState(() => _endpointModels = ids);
    } on Object {
      if (mounted) setState(() => _endpointModels = const []);
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  /// The media capabilities the fetched model ids suggest, in [MediaSlot.all]
  /// order. Empty when nothing was fetched or nothing matched — the hints
  /// stay hidden rather than claiming "no support".
  List<String> get _suggestedCapabilities {
    if (_endpointModels.isEmpty) return const [];
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
      setState(() => _error = context.l10n.settingsModelIdRequired);
      return;
    }
    final provider = widget.provider;
    final keyName = switch (provider) {
      ProviderPreset preset => hostedProviderKeyName(preset),
      CustomProvider _ => ProviderRegistry.keyNameFor(_baseUrl),
      _ => null,
    };
    Navigator.of(context).pop(
      MediaSlotEditorResult.save(
        MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: _baseUrl,
          modelId: model,
          apiKeyName: keyName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              ModelIdAutocompleteField(
                controller: _modelController,
                focusNode: _modelFocusNode,
                models: _endpointModels,
                loading: _modelsLoading,
              ),
              if (capabilities.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  context.l10n.mediaModelsCapabilitiesNote,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final capability in capabilities)
                      Chip(
                        label: Text(
                          MediaModelsSection.slotLabelFor(
                            context.l10n,
                            capability,
                          ),
                        ),
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
                child: Text(context.l10n.settingsSaveButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
