// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/vision_models.dart';
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
/// section: model id with a per-provider picker (the configured endpoint's
/// `/models` list feeds the quick select; any custom id stays valid when the
/// endpoint has no `/models`), base URL ([mainBaseUrl] — the main
/// connection's endpoint — as placeholder and save-time default), an
/// optional API key NAME (a reference into the saved keys, never a key
/// value), and read-only capability hints derived from the fetched model
/// ids. Save pops a [MediaSlotEditorResult.save], Clear a
/// [MediaSlotEditorResult.clear] (only offered when [initial] exists),
/// the back button pops null.
class MediaSlotEditorPage extends StatefulWidget {
  const MediaSlotEditorPage({
    super.key,
    required this.slot,
    required this.title,
    required this.mainBaseUrl,
    this.initial,
    this.modelsFetcher,
  });

  /// The media slot being configured ([MediaSlot] name).
  final String slot;

  /// App bar title (`Edit Image generation`).
  final String title;

  /// The main connection's base URL: the URL field's placeholder, the value
  /// saved when the field is left empty, and the fetch target until the user
  /// types their own URL.
  final String mainBaseUrl;

  /// The slot's current override (edit mode); `null` configures a new one.
  final MediaSlotOverride? initial;

  /// `/models` fetch override (tests); defaults to the production HTTP
  /// fetch + shared parser ([defaultModelsEndpointFetcher]).
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<MediaSlotEditorPage> createState() => _MediaSlotEditorPageState();
}

class _MediaSlotEditorPageState extends State<MediaSlotEditorPage> {
  late final TextEditingController _modelController;
  late final TextEditingController _urlController;
  late final TextEditingController _keyNameController;

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
    _modelController = TextEditingController(
      text: widget.initial?.modelId ?? '',
    );
    _urlController = TextEditingController(text: widget.initial?.baseUrl ?? '');
    _keyNameController = TextEditingController(
      text: widget.initial?.apiKeyName ?? '',
    );
    // Endpoint/key edits refetch (debounced), like the settings form.
    _urlController.addListener(_scheduleModelsFetch);
    _keyNameController.addListener(_scheduleModelsFetch);
    _scheduleModelsFetch();
  }

  @override
  void dispose() {
    _modelsFetchDebounce?.cancel();
    _modelFocusNode.dispose();
    _modelController.dispose();
    _urlController.dispose();
    _keyNameController.dispose();
    super.dispose();
  }

  /// The base URL the `/models` fetch targets: the typed URL, else the main
  /// connection's (the save-time default), else OpenAI's.
  String get _effectiveBaseUrl {
    final typed = _urlController.text.trim();
    if (typed.isNotEmpty) return typed;
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
      // (absent store or unknown name → fetch without a credential).
      final keyName = _keyNameController.text.trim();
      final key = keyName.isEmpty
          ? ''
          : SessionKeysScope.maybeOf(context)?.valueOf(keyName) ?? '';
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
              RawAutocomplete<String>(
                textEditingController: _modelController,
                focusNode: _modelFocusNode,
                // Quick select over the endpoint's /models list, filtered by
                // the typed text; any custom id stays valid (free text).
                optionsBuilder: (value) {
                  final query = value.text.trim().toLowerCase();
                  if (query.isEmpty) return _endpointModels;
                  return _endpointModels.where(
                    (id) => id.toLowerCase().contains(query),
                  );
                },
                onSelected: (id) => _modelController.text = id,
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: InputDecoration(
                          labelText: context.l10n.settingsModelIdLabel,
                          helperText: _modelsLoading
                              ? context.l10n.settingsModelsFetching
                              : null,
                          suffixIcon: _modelsLoading
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      );
                    },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 240,
                          maxWidth: 440,
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return ListTile(
                              dense: true,
                              title: Text(option),
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsBaseUrlLabel,
                  hintText: widget.mainBaseUrl.isEmpty
                      ? MediaModelsStore.defaultBaseUrl
                      : widget.mainBaseUrl,
                ),
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
