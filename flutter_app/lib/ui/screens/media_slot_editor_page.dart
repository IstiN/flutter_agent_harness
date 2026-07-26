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
/// the media slot editor: GETs `<baseUrl>/models` (OpenAI shape, bearer key
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

/// The outcome of the [MediaSlotEditorPage]: either a [override] to save
/// or [cleared] (remove the slot's override, restoring the fallback).
final class MediaSlotEditorResult {
  const MediaSlotEditorResult.save(this.override) : cleared = false;

  const MediaSlotEditorResult.clear() : cleared = true, override = null;

  /// True when the user chose Clear.
  final bool cleared;

  /// The override to persist (null when [cleared]).
  final MediaSlotOverride? override;
}

/// The full-screen per-slot editor pushed from the settings Media models
/// section: a provider picker (the main connection default, the hosted
/// presets, the saved custom providers — or "Add provider" for a new one)
/// plus a model id with a `/models` quick select over the chosen
/// provider's endpoint (any custom id stays valid when the endpoint has no
/// `/models`), an optional API key NAME (a reference into the saved keys,
/// never a key value), and read-only capability hints derived from the
/// fetched model ids. The saved override stores the provider's RESOLVED
/// base URL (no store schema change). Save pops a
/// [MediaSlotEditorResult.save], Clear a [MediaSlotEditorResult.clear]
/// (only offered when [initial] exists), the back button pops null.
class MediaSlotEditorPage extends StatefulWidget {
  const MediaSlotEditorPage({
    super.key,
    required this.slot,
    required this.title,
    required this.mainBaseUrl,
    this.initial,
    this.registry,
    this.modelsFetcher,
  });

  /// The media slot being configured ([MediaSlot] name).
  final String slot;

  /// App bar title (`Edit Image generation`).
  final String title;

  /// The main connection's base URL: the "Main connection" provider
  /// option's resolved URL (and the `/models` fetch target while it is
  /// selected).
  final String mainBaseUrl;

  /// The slot's current override (edit mode); `null` configures a new one.
  final MediaSlotOverride? initial;

  /// The user-added providers listed in the provider picker; `null` falls
  /// back to a non-persisting in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests); defaults to the production HTTP
  /// fetch + shared parser ([defaultModelsEndpointFetcher]).
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<MediaSlotEditorPage> createState() => _MediaSlotEditorPageState();
}

class _MediaSlotEditorPageState extends State<MediaSlotEditorPage> {
  late final TextEditingController _modelController;
  late final TextEditingController _keyNameController;
  late final ProviderRegistry _registry;

  /// The provider the slot points at: [_mainConnection] (the default), a
  /// hosted [ProviderPreset], or a [CustomProvider].
  late Object _providerSelection;

  /// The provider-dropdown value for "use the main connection".
  static const Object _mainConnection = Object();

  /// The endpoint's `/models` ids feeding the model field's quick select.
  List<String> _endpointModels = const [];
  var _modelsLoading = false;

  /// Stale-response guard: bumped per fetch, only the latest applies.
  var _modelsFetchGeneration = 0;
  Timer? _modelsFetchDebounce;

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

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ?? ProviderRegistry.inMemory();
    _modelController = TextEditingController(
      text: widget.initial?.modelId ?? '',
    );
    _keyNameController = TextEditingController(
      text: widget.initial?.apiKeyName ?? '',
    );
    // The override's stored URL selects its provider; an unmatched URL (a
    // hand-edited store file) falls back to the main connection.
    _providerSelection = widget.initial == null
        ? _mainConnection
        : providerForBaseUrl(widget.initial!.baseUrl, _registry) ??
              _mainConnection;
    // Key-name edits refetch (debounced), like the settings form.
    _keyNameController.addListener(_scheduleModelsFetch);
    _scheduleModelsFetch();
  }

  @override
  void dispose() {
    _modelsFetchDebounce?.cancel();
    _modelFocusNode.dispose();
    _modelController.dispose();
    _keyNameController.dispose();
    super.dispose();
  }

  /// The base URL the selected provider resolves to: the main connection's
  /// for [_mainConnection] (OpenAI's default when there is none), the
  /// preset's/custom provider's endpoint otherwise. This resolved URL is
  /// what the override stores.
  String get _effectiveBaseUrl {
    final selection = _providerSelection;
    if (selection is ProviderPreset) return selection.baseUrl ?? '';
    if (selection is CustomProvider) return selection.baseUrl;
    return widget.mainBaseUrl.isEmpty
        ? MediaModelsStore.defaultBaseUrl
        : widget.mainBaseUrl;
  }

  /// Debounced refetch of the endpoint's model list for the quick select.
  void _scheduleModelsFetch() {
    _modelsFetchDebounce?.cancel();
    _modelsFetchDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_fetchEndpointModels());
    });
  }

  /// Fetches `<baseUrl>/models` (OpenAI shape) for the model field's quick
  /// select and the capability hints. Silent on failure — free-text entry
  /// always works, the field just loses its suggestions.
  Future<void> _fetchEndpointModels() async {
    final baseUrl = _effectiveBaseUrl;
    final generation = ++_modelsFetchGeneration;
    if (mounted) setState(() => _modelsLoading = true);
    try {
      // The key field holds a NAME; resolve it through the saved-keys store
      // (absent store or unknown name → the provider's own key — session
      // key for custom providers, the named key for hosted presets).
      final keyName = _keyNameController.text.trim();
      final selection = _providerSelection;
      final key = keyName.isNotEmpty
          ? SessionKeysScope.maybeOf(context)?.valueOf(keyName) ?? ''
          : selection == _mainConnection
          ? ''
          : resolveProviderKey(
              selection,
              registry: _registry,
              keysStore: SessionKeysScope.maybeOf(context),
            );
      final fetch = widget.modelsFetcher ?? defaultModelsEndpointFetcher;
      final (ids, _, _) = await fetch(baseUrl, apiKey: key);
      if (!mounted || generation != _modelsFetchGeneration) return;
      setState(() => _endpointModels = ids);
    } on Object {
      if (mounted && generation == _modelsFetchGeneration) {
        setState(() => _endpointModels = const []);
      }
    } finally {
      if (mounted && generation == _modelsFetchGeneration) {
        setState(() => _modelsLoading = false);
      }
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
    final modelId = _modelController.text.trim();
    if (modelId.isEmpty) {
      setState(() => _error = context.l10n.settingsModelIdRequired);
      return;
    }
    final keyName = _keyNameController.text.trim();
    Navigator.of(context).pop(
      MediaSlotEditorResult.save(
        MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: _effectiveBaseUrl,
          modelId: modelId,
          apiKeyName: keyName.isEmpty ? null : keyName,
        ),
      ),
    );
  }

  /// Adds a provider through the shared create page and selects it.
  Future<void> _addProvider() async {
    final added = await pushProviderEditor(
      context,
      _registry,
      title: context.l10n.settingsAddProvider,
    );
    if (added == null || !mounted) return;
    setState(() {
      _providerSelection = added;
      _scheduleModelsFetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capabilities = _suggestedCapabilities;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<Object>(
                // The key forces the FormField to re-seed when a provider is
                // added and selected programmatically.
                key: ValueKey<Object>(_providerSelection),
                initialValue: _providerSelection,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsProviderLabel,
                ),
                items: [
                  DropdownMenuItem(
                    value: _mainConnection,
                    child: Text(context.l10n.mediaModelsMainConnection),
                  ),
                  for (final preset in hostedProviderPresets)
                    DropdownMenuItem(
                      value: preset,
                      child: Text(preset.labelFor(context)),
                    ),
                  for (final provider in _registry.providers)
                    DropdownMenuItem(
                      value: provider,
                      child: Text(
                        provider.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _providerSelection = value;
                    _scheduleModelsFetch();
                  });
                },
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addProvider,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(context.l10n.settingsAddProvider),
                ),
              ),
              const SizedBox(height: 12),
              ModelIdAutocompleteField(
                controller: _modelController,
                focusNode: _modelFocusNode,
                models: _endpointModels,
                loading: _modelsLoading,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyNameController,
                decoration: InputDecoration(
                  labelText: context.l10n.mediaModelsApiKeyNameLabel,
                  helperText: context.l10n.mediaModelsApiKeyNameHelper,
                  helperMaxLines: 3,
                ),
                autocorrect: false,
                enableSuggestions: false,
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
              Row(
                children: [
                  if (widget.initial != null)
                    TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(const MediaSlotEditorResult.clear()),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: Text(context.l10n.mediaModelsClearButton),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
                    child: Text(context.l10n.settingsSaveButton),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
