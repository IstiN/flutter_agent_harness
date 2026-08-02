// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/media_slot_picker_page.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';
import 'package:fa_ui/src/utils/vision_models.dart';
import 'package:fa_ui/src/widgets/model_id_field.dart';

/// Builds the connect page of an on-device provider (engine download,
/// progress, token field — all host territory). The page must call
/// [onApply] with the assembled [FaChatModelConfig] and pop `true` on success.
typedef FaOnDevicePageBuilder =
    Widget Function(
      BuildContext context,
      Future<void> Function(FaChatModelConfig config) onApply,
    );

/// One on-device provider entry of the default-chat-model picker (WebLLM,
/// Gemma, transformers.js — whatever the host supports). fa_ui knows
/// nothing about engines; the host supplies the tile label and the page
/// builder, and pre-filters the list by platform visibility.
final class FaOnDeviceRoute {
  /// Creates a route. [label] is the picker tile's text; [pageBuilder]
  /// builds the pushed connect page.
  const FaOnDeviceRoute({required this.label, required this.pageBuilder});

  /// The picker tile's label (resolve localization before building — the
  /// route itself is context-free).
  final String label;

  /// Builds the on-device connect page.
  final FaOnDevicePageBuilder pageBuilder;
}

/// The settings "Default chat model" section — one row showing the active
/// provider + model. Tapping pushes the two-step flow
/// ([DefaultModelProviderPickerPage] → model page); applying runs
/// [onApply] (the host reconfigures its service and persists the choice).
class DefaultChatModelSection extends StatelessWidget {
  const DefaultChatModelSection({
    super.key,
    required this.connection,
    required this.onApply,
    this.registry,
    this.modelsFetcher,
    this.onDeviceProviders = const [],
    this.providerKindLabels = const {},
  });

  /// The active connection, displayed and listened to.
  final FaChatConnection connection;

  /// Applies the chosen config as the main connection (reconfigure +
  /// persist). Throw to surface an error on the model page.
  final Future<void> Function(FaChatModelConfig config) onApply;

  /// The user-added providers listed in the picker.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// The on-device provider entries appended to the picker (already
  /// filtered for the platform by the host).
  final List<FaOnDeviceRoute> onDeviceProviders;

  /// Display labels for non-endpoint provider kinds (on-device backends),
  /// keyed by [FaChatConnection.providerKind] — a connection whose kind is
  /// listed here summarizes with the label instead of its (empty) base URL.
  final Map<String, String> providerKindLabels;

  String _activeProviderLabel(BuildContext context) {
    final kindLabel = providerKindLabels[connection.providerKind];
    if (kindLabel != null) return kindLabel;
    final provider = providerForBaseUrl(connection.activeBaseUrl, registry);
    if (provider != null) return providerDisplayName(context, provider);
    return providerHostOf(connection.activeBaseUrl);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.settingsDefaultChatModelTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                await pushFaPage<void>(
                  context,
                  DefaultModelProviderPickerPage(
                    registry: registry,
                    onApply: onApply,
                    modelsFetcher: modelsFetcher,
                    onDeviceProviders: onDeviceProviders,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        strings.settingsProviderModelSummary(
                          connection.modelId,
                          _activeProviderLabel(context),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Step (a) of the default-chat-model flow: pick a provider — a hosted
/// preset, a saved [CustomProvider], an on-device route ([onDeviceProviders],
/// host-built), or "Add provider" (the create page, then back to picking).
class DefaultModelProviderPickerPage extends StatelessWidget {
  const DefaultModelProviderPickerPage({
    super.key,
    required this.onApply,
    this.registry,
    this.modelsFetcher,
    this.onDeviceProviders = const [],
  });

  /// Applies the chosen config as the main connection (reconfigure + save
  /// the last connection). Throw to surface an error on the model page.
  final Future<void> Function(FaChatModelConfig config) onApply;

  /// The user-added providers; `null` falls back to a non-persisting
  /// in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// The on-device provider entries (already filtered for the platform).
  final List<FaOnDeviceRoute> onDeviceProviders;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsPickProviderTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: registry,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final preset in hostedProviderPresets)
                  _providerTile(
                    context,
                    theme,
                    label: preset.labelFor(context),
                    subtitle: providerHostOf(preset.baseUrl!),
                    onTap: () => _pickEndpoint(context, registry, preset),
                  ),
                for (final provider in registry.providers)
                  _providerTile(
                    context,
                    theme,
                    label: provider.name,
                    subtitle: providerHostOf(provider.baseUrl),
                    onTap: () => _pickEndpoint(context, registry, provider),
                  ),
                for (final route in onDeviceProviders)
                  _providerTile(
                    context,
                    theme,
                    label: route.label,
                    onTap: () => _pickOnDevice(context, route),
                  ),
                const Divider(),
                _providerTile(
                  context,
                  theme,
                  label: strings.settingsAddProvider,
                  leading: Icons.add,
                  onTap: () => pushProviderEditor(
                    context,
                    registry,
                    title: strings.settingsAddProvider,
                  ),
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
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(leading, color: theme.colorScheme.primary),
      title: Text(label),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        Icons.chevron_right,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }

  Future<void> _pickEndpoint(
    BuildContext context,
    ProviderRegistry registry,
    Object provider,
  ) async {
    final applied = await pushFaPage<bool>(
      context,
      DefaultModelPickerPage(
        provider: provider,
        registry: registry,
        onApply: onApply,
        modelsFetcher: modelsFetcher,
      ),
    );
    // Applied: the flow is done — back to the settings screen.
    if (applied == true && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _pickOnDevice(
    BuildContext context,
    FaOnDeviceRoute route,
  ) async {
    final applied = await pushFaPage<bool>(
      context,
      route.pageBuilder(context, onApply),
    );
    if (applied == true && context.mounted) Navigator.of(context).pop();
  }
}

/// Step (b) of the default-chat-model flow for an endpoint provider: pick
/// its model — the endpoint's `/models` list feeds the quick select (any
/// custom id stays valid), the provider's default model is prefilled.
/// Apply runs [onApply] (keys resolve from the registry / saved-keys store)
/// and pops true so the picker unwinds too. Hosted presets require a key;
/// custom providers may connect keyless (local servers).
class DefaultModelPickerPage extends StatefulWidget {
  const DefaultModelPickerPage({
    super.key,
    required this.provider,
    required this.onApply,
    this.registry,
    this.modelsFetcher,
  });

  /// The picked provider: a hosted [ProviderPreset] or a [CustomProvider].
  final Object provider;

  /// Applies the chosen config as the main connection.
  final Future<void> Function(FaChatModelConfig config) onApply;

  /// The provider registry (custom-provider session keys).
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests); defaults to the production HTTP
  /// fetch + shared parser ([defaultModelsEndpointFetcher]).
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<DefaultModelPickerPage> createState() => _DefaultModelPickerPageState();
}

class _DefaultModelPickerPageState extends State<DefaultModelPickerPage> {
  late final TextEditingController _modelController;

  /// The endpoint's `/models` ids feeding the model field's quick select.
  List<String> _endpointModels = const [];
  Map<String, int> _endpointContextWindows = const {};
  Map<String, int> _endpointMaxTokens = const {};
  var _modelsLoading = false;

  final FocusNode _modelFocusNode = FocusNode();

  var _loading = false;
  String? _error;

  String get _baseUrl => switch (widget.provider) {
    ProviderPreset preset => preset.baseUrl ?? '',
    CustomProvider custom => custom.baseUrl,
    _ => '',
  };

  /// Custom providers may run keyless (local servers); the hosted presets
  /// keep requiring a key.
  bool get _keyOptional => widget.provider is CustomProvider;

  String _resolvedKey() => resolveProviderKey(
    widget.provider,
    registry: widget.registry,
    keysStore: SessionKeysScope.maybeOf(context),
  );

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(
      text: switch (widget.provider) {
        // A saved preset-model override wins over the built-in default.
        ProviderPreset preset =>
          widget.registry?.presetModelOverride(preset.name) ??
              preset.defaultModel,
        CustomProvider custom => custom.modelId,
        _ => '',
      },
    );
    // The fetch resolves the provider key through the inherited saved-keys
    // scope — unavailable during initState, so it runs after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchEndpointModels();
    });
  }

  @override
  void dispose() {
    _modelFocusNode.dispose();
    _modelController.dispose();
    super.dispose();
  }

  /// Fetches `<baseUrl>/models` (OpenAI shape) for the model field's quick
  /// select and the connect-time limits. Silent on failure — free-text
  /// entry always works, the field just loses its suggestions.
  Future<void> _fetchEndpointModels() async {
    final baseUrl = _baseUrl;
    if (baseUrl.isEmpty) return;
    setState(() => _modelsLoading = true);
    try {
      final fetch = widget.modelsFetcher ?? defaultModelsEndpointFetcher;
      final (ids, windows, caps) = await fetch(baseUrl, apiKey: _resolvedKey());
      if (!mounted) return;
      setState(() {
        _endpointModels = ids;
        _endpointContextWindows = windows;
        _endpointMaxTokens = caps;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _endpointModels = const [];
          _endpointContextWindows = const {};
          _endpointMaxTokens = const {};
        });
      }
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  Future<void> _apply() async {
    final strings = FaUiStrings.of(context);
    final model = _modelController.text.trim();
    if (model.isEmpty) {
      setState(() => _error = strings.settingsModelIdRequired);
      return;
    }
    final key = _resolvedKey();
    if (key.isEmpty && !_keyOptional) {
      setState(() => _error = strings.settingsApiKeyRequired);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.onApply(
        FaChatModelConfig(
          providerKind: 'openai-completions',
          modelId: model,
          baseUrl: _baseUrl,
          apiKey: key,
          // Endpoint-reported limits (the /models fetch) win over the shared
          // fallbacks — same correction as the old connect button.
          contextWindow:
              _endpointContextWindows[model] ?? fallbackContextWindow,
          maxTokens: _endpointMaxTokens[model] ?? fallbackMaxTokens,
          supportsImages: modelIdSuggestsVision(model),
        ),
      );
      // A successful connect keeps the custom provider's key for the
      // session. Never persisted.
      final provider = widget.provider;
      if (provider is CustomProvider && key.isNotEmpty) {
        widget.registry?.rememberKey(provider.id, key);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsPickModelTitle)),
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
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : _apply,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(strings.settingsApplyButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
