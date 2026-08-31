// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/default_chat_model.dart';
import 'package:fa_ui/src/providers/media_slot_picker_page.dart'
    show defaultModelsEndpointFetcher;
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// A provider-specific model-list fetcher. Used by
/// [UnifiedModelPickerPage] to support non-standard endpoints (e.g.
/// CodeMie's `/llm_models` with `Cookie:` auth instead of `/models` with
/// `Bearer`). When null, the standard `defaultModelsEndpointFetcher` is
/// used. The host (app) injects this to handle CodeMie providers.
typedef ProviderModelFetcher =
    Future<List<String>> Function(String baseUrl, String apiKey);

/// A model entry in the [UnifiedModelPickerPage]: the provider that owns it,
/// the model id, and the display label.
final class _ModelEntry {
  _ModelEntry({
    required this.provider,
    required this.providerId,
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
    required this.contextWindow,
    required this.maxTokens,
  });

  final String provider;
  final String? providerId;
  final String baseUrl;
  final String apiKey;
  final String modelId;
  final int contextWindow;
  final int maxTokens;

  bool matches(String filter) {
    final lower = filter.toLowerCase();
    return provider.toLowerCase().contains(lower) ||
        modelId.toLowerCase().contains(lower);
  }
}

/// A unified model picker that shows **all** models from **all** configured
/// providers in a single flat list, mirroring the CLI's `/model` command.
///
/// Features:
/// - Fetches `/models` from every saved [CustomProvider] in parallel.
/// - Search field at the top filters by provider name OR model id.
/// - Each row shows `provider / model-id` with a vision marker.
/// - On-device routes (WebLLM, Gemma, …) appear as separate tiles at the
///   bottom.
/// - An "Add provider" tile opens the preset picker.
///
/// Selecting a model builds a [FaChatModelConfig] with the right provider's
/// resolved key and runs [onApply]. Selecting an on-device route delegates
/// to its page builder.
class UnifiedModelPickerPage extends StatefulWidget {
  /// Creates the picker.
  const UnifiedModelPickerPage({
    super.key,
    required this.connection,
    required this.onApply,
    this.registry,
    this.modelsFetcher,
    this.providerModelFetcher,
    this.onDeviceProviders = const [],
    this.providerKindLabels = const {},
    this.addProviderPage,
  });

  /// The active connection — its model is highlighted as "current".
  final FaChatConnection connection;

  /// Applies the chosen config as the main connection.
  final Future<void> Function(FaChatModelConfig config) onApply;

  /// The user-added providers.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests); defaults to
  /// [defaultModelsEndpointFetcher].
  final ModelsEndpointFetcher? modelsFetcher;

  /// Provider-specific model-list fetcher for non-standard endpoints (e.g.
  /// CodeMie). When provided, the picker calls this instead of
  /// [modelsFetcher] for any baseUrl where the standard fetcher returns
  /// empty. The host injects `fetchCodeMieModels` for CodeMie providers.
  final ProviderModelFetcher? providerModelFetcher;

  /// On-device provider routes (Gemma, WebLLM, …), appended to the list.
  final List<FaOnDeviceRoute> onDeviceProviders;

  /// Display labels for non-endpoint provider kinds (on-device backends).
  final Map<String, String> providerKindLabels;

  /// A host-provided widget builder for the "Add provider" page (preset
  /// picker). When null, a simple [pushProviderEditor] is used.
  final WidgetBuilder? addProviderPage;

  @override
  State<UnifiedModelPickerPage> createState() => _UnifiedModelPickerPageState();
}

class _UnifiedModelPickerPageState extends State<UnifiedModelPickerPage> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// All fetched model entries across every provider.
  List<_ModelEntry> _entries = const [];
  var _loading = true;
  String? _error;

  /// The provider kind for a picked model entry — matches the dispatch
  /// hint so the stream adapter gets the right wire shape. Google
  /// endpoints need the Gemini adapter (inlineData, not image_url);
  /// DIAL and Copilot have their own dialects; Codex is bundled-list only.
  String _providerKindFor(String baseUrl) {
    final preset = ProviderPreset.fromBaseUrl(baseUrl);
    if (preset == ProviderPreset.dial) return 'dial';
    if (isCopilotBaseUrl(baseUrl)) return 'copilot';
    if (baseUrl.contains('generativelanguage.googleapis.com')) return 'google';
    return 'openai-completions';
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchAllModels();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _fetchAllModels() async {
    final registry = widget.registry;
    final entries = <_ModelEntry>[];
    final fetch = widget.modelsFetcher ?? defaultModelsEndpointFetcher;

    // Gather all CONNECTED endpoint providers: saved custom providers plus
    // hosted presets whose key resolves (hostedProviderConnected) — the
    // same set every other picker in the app shows. A custom provider on a
    // preset's endpoint covers the preset (never both).
    final providers = <({String name, String id, String baseUrl})>[];
    if (registry != null) {
      for (final p in registry.providers) {
        providers.add((name: p.name, id: p.id, baseUrl: p.baseUrl));
      }
      for (final preset in hostedProviderPresets) {
        if (preset.baseUrl == null) continue;
        if (providers.any((p) => p.baseUrl == preset.baseUrl)) continue;
        if (!hostedProviderConnected(preset)) continue;
        providers.add((
          name: preset.labelFor(context),
          id: preset.name,
          baseUrl: preset.baseUrl!,
        ));
      }
    }

    if (providers.isEmpty) {
      // No saved providers — just show the active model.
      entries.add(_entryFromActive());
      if (mounted) setState(() => _loading = false);
      return;
    }

    // Fetch in parallel.
    final results = await Future.wait(
      providers.map((p) => _fetchOne(p, fetch)),
    );

    for (final result in results) {
      entries.addAll(result);
    }

    // Always include the active model even if the fetch failed.
    final activeModel = widget.connection.modelId;
    final activeBase = widget.connection.activeBaseUrl;
    if (!entries.any(
      (e) => e.modelId == activeModel && e.baseUrl == activeBase,
    )) {
      entries.insert(0, _entryFromActive());
    }

    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  _ModelEntry _entryFromActive() => _ModelEntry(
    provider: _activeProviderLabel(),
    providerId: widget.connection.activeProviderId,
    baseUrl: widget.connection.activeBaseUrl,
    apiKey: '',
    modelId: widget.connection.modelId,
    contextWindow: fallbackContextWindow,
    maxTokens: fallbackMaxTokens,
  );

  String _activeProviderLabel() {
    final kindLabel = widget.providerKindLabels[widget.connection.providerKind];
    if (kindLabel != null) return kindLabel;
    final base = widget.connection.activeBaseUrl;
    final registry = widget.registry;
    if (registry != null) {
      final match = providerForBaseUrl(base, registry);
      if (match != null)
        return match is CustomProvider ? match.name : match.toString();
    }
    return providerHostOf(base);
  }

  Future<List<_ModelEntry>> _fetchOne(
    ({String name, String id, String baseUrl}) provider,
    ModelsEndpointFetcher fetch,
  ) async {
    try {
      var key = widget.registry?.keyFor(provider.id) ?? '';
      if (key.isEmpty) {
        // A hosted preset entry: its named key resolves through the host's
        // key chain (env / secure store / saved keys).
        final preset = hostedProviderPresets
            .where((p) => p.name == provider.id)
            .firstOrNull;
        if (preset != null) {
          key = resolveProviderKey(
            preset,
            registry: widget.registry,
            keysStore: SessionKeysScope.maybeOf(context),
          );
        }
      }
      if (key.isEmpty) {
        // A saved custom provider whose registry key did not resolve —
        // Copilot tokens live entry-scoped (`FA_KEY_COPILOT_<NAME>`) after
        // a restart on platforms without a Keychain backend.
        final custom = widget.registry?.providers
            .where((p) => p.id == provider.id)
            .firstOrNull;
        if (custom != null) {
          key = resolveProviderKey(
            custom,
            registry: widget.registry,
            keysStore: SessionKeysScope.maybeOf(context),
          );
        }
      }

      // The host/test override wins; production goes through the core
      // dispatch (DIAL deployments, the CodeMie marker, the bundled Codex
      // catalog, and the Copilot token exchange all live in there).
      var (ids, windows, caps) = widget.modelsFetcher != null
          ? await fetch(provider.baseUrl, apiKey: key)
          : await fetchModelsForEndpoint(
              provider.baseUrl,
              apiKey: key,
              provider: modelsDispatchHintFor(provider.baseUrl),
            );

      // CodeMie (and other non-standard endpoints): fall back to the
      // provider-specific fetcher when the standard one returns empty.
      // This handles the Cookie-auth `/llm_models` endpoint.
      if (ids.isEmpty &&
          widget.providerModelFetcher != null &&
          _isNonStandardProvider(provider.baseUrl)) {
        try {
          final providerIds = await widget.providerModelFetcher!(
            provider.baseUrl,
            key,
          );
          ids = providerIds;
        } on Object {
          // Provider-specific fetch also failed — fall through to the
          // saved model fallback below.
        }
      }

      if (ids.isEmpty) {
        // Fall back to the provider's saved model.
        final savedModel = widget.registry?.providers
            .where((p) => p.id == provider.id)
            .first
            .modelId;
        if (savedModel != null && savedModel.isNotEmpty) {
          return [
            _ModelEntry(
              provider: provider.name,
              providerId: provider.id,
              baseUrl: provider.baseUrl,
              apiKey: key,
              modelId: savedModel,
              contextWindow: fallbackContextWindow,
              maxTokens: fallbackMaxTokens,
            ),
          ];
        }
        return const [];
      }
      return [
        for (final id in ids)
          _ModelEntry(
            provider: provider.name,
            providerId: provider.id,
            baseUrl: provider.baseUrl,
            apiKey: key,
            modelId: id,
            contextWindow: windows[id] ?? fallbackContextWindow,
            maxTokens: caps[id] ?? fallbackMaxTokens,
          ),
      ];
    } on Object {
      // Dead endpoint — try the saved model.
      final savedModel = widget.registry?.providers
          .where((p) => p.id == provider.id)
          .first
          .modelId;
      if (savedModel != null && savedModel.isNotEmpty) {
        return [
          _ModelEntry(
            provider: provider.name,
            providerId: provider.id,
            baseUrl: provider.baseUrl,
            apiKey: widget.registry?.keyFor(provider.id) ?? '',
            modelId: savedModel,
            contextWindow: fallbackContextWindow,
            maxTokens: fallbackMaxTokens,
          ),
        ];
      }
      return const [];
    }
  }

  String get _filter => _searchController.text.trim();

  List<_ModelEntry> get _filtered {
    if (_filter.isEmpty) return _entries;
    return _entries.where((e) => e.matches(_filter)).toList();
  }

  /// The manual escape's target: the typed id applied on the ACTIVE
  /// provider's endpoint, its key resolved through the registry like any
  /// listed entry's.
  _ModelEntry _manualEntry(String typedId) {
    final base = _entryFromActive();
    final registry = widget.registry;
    var key = '';
    if (registry != null) {
      final activeId = widget.connection.activeProviderId;
      if (activeId != null) {
        key = registry.keyFor(activeId) ?? '';
      } else {
        final match = providerForBaseUrl(base.baseUrl, registry);
        if (match is CustomProvider) key = registry.keyFor(match.id) ?? '';
      }
    }
    return _ModelEntry(
      provider: base.provider,
      providerId: base.providerId,
      baseUrl: base.baseUrl,
      apiKey: key,
      modelId: typedId,
      contextWindow: fallbackContextWindow,
      maxTokens: fallbackMaxTokens,
    );
  }

  Future<void> _selectModel(_ModelEntry entry) async {
    setState(() => _error = null);
    try {
      await widget.onApply(
        FaChatModelConfig(
          // DIAL deployments live on a dial adapter kind (URL/auth dialect);
          // Google endpoints use the Gemini adapter (inlineData, not
          // image_url); everything else is plain openai-completions.
          providerKind: _providerKindFor(entry.baseUrl),
          modelId: entry.modelId,
          baseUrl: entry.baseUrl,
          apiKey: entry.apiKey,
          contextWindow: entry.contextWindow,
          maxTokens: entry.maxTokens,
          supportsImages: modelIdSuggestsVision(entry.modelId),
          providerId: entry.providerId,
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openOnDevice(FaOnDeviceRoute route) async {
    final ctx = context;
    final applied = await pushFaPage<bool>(
      ctx,
      route.pageBuilder(ctx, widget.onApply),
    );
    if (applied == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final entries = _filtered;
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsPickModelTitle)),
      body: SafeArea(
        child: Column(
          children: [
            // Search field.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Filter models…',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _filter.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _searchFocus.requestFocus();
                          },
                        )
                      : null,
                ),
              ),
            ),
            // Model list.
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        // The manual escape: the typed id is always
                        // applicable on the active provider's endpoint.
                        if (_filter.isNotEmpty &&
                            !_entries.any((e) => e.modelId == _filter))
                          ListTile(
                            leading: Icon(
                              Icons.edit_outlined,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            title: Text(
                              strings.modelPickerUseManual(_filter),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _activeProviderLabel(),
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectModel(_manualEntry(_filter)),
                          ),
                        for (final entry in entries)
                          _modelTile(context, theme, entry),
                        // On-device routes.
                        for (final route in widget.onDeviceProviders)
                          ListTile(
                            leading: Icon(
                              Icons.memory_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            title: Text(route.label),
                            trailing: Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            onTap: () => _openOnDevice(route),
                          ),
                        const Divider(),
                        // Add provider.
                        ListTile(
                          leading: Icon(
                            Icons.add,
                            color: theme.colorScheme.primary,
                          ),
                          title: Text(strings.settingsAddProvider),
                          onTap: () async {
                            if (widget.addProviderPage != null) {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      widget.addProviderPage!(context),
                                ),
                              );
                              if (mounted) _fetchAllModels();
                            } else {
                              await pushProviderEditor(
                                context,
                                widget.registry ?? ProviderRegistry.inMemory(),
                                title: strings.settingsAddProvider,
                              );
                              if (mounted) {
                                setState(() => _loading = true);
                                _fetchAllModels();
                              }
                            }
                          },
                        ),
                      ],
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(BuildContext context, ThemeData theme, _ModelEntry entry) {
    final isActive =
        entry.modelId == widget.connection.modelId &&
        entry.baseUrl == widget.connection.activeBaseUrl;
    return ListTile(
      leading: Icon(
        isActive ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 20,
        color: isActive
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: theme.textTheme.bodyMedium,
          children: [
            TextSpan(
              text: entry.provider,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            TextSpan(
              text: ' / ',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
            TextSpan(
              text: entry.modelId,
              style: TextStyle(
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
      subtitle: Text(
        visionMarkerText(entry.modelId),
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => _selectModel(entry),
    );
  }
}

/// The vision marker text for [modelId] (empty when the model does not
/// suggest vision input).
String visionMarkerText(String modelId) =>
    modelIdSuggestsVision(modelId) ? 'vision ✓' : '';

/// Whether [baseUrl] belongs to a provider with a non-standard model-list
/// endpoint (CodeMie uses `/llm_models` with `Cookie:` auth instead of
/// `/models` with `Bearer`).
bool _isNonStandardProvider(String baseUrl) =>
    baseUrl.contains('/code-assistant-api/');
