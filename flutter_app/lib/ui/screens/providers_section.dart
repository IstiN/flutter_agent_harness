// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/vision_models.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/ui/screens/media_slot_picker_page.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/webllm/webllm_types.dart';

/// The settings "Providers" section — the first section of
/// [SettingsScreen]: every hosted preset and saved [CustomProvider], the
/// one backing the active connection marked with a check. Tapping a row
/// pushes the full-screen [ProviderEditorPage] (presets: key only; custom
/// providers: name/URL/model/key + Delete); the "Add provider" row opens
/// the same page in create mode.
class ProvidersSection extends StatelessWidget {
  const ProvidersSection({super.key, this.service, this.registry});

  /// The active connection, for the current-provider mark. `null` renders
  /// the list without marks (tests).
  final AgentService? service;

  /// The user-added providers; `null` falls back to a non-persisting
  /// in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  bool _isCurrent(Object provider) {
    final service = this.service;
    if (service == null || service.providerKind != 'openai-completions') {
      return false;
    }
    final baseUrl = switch (provider) {
      ProviderPreset preset => preset.baseUrl,
      CustomProvider custom => custom.baseUrl,
      _ => null,
    };
    return baseUrl != null && service.activeBaseUrl == baseUrl;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.settingsProvidersSectionTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (final preset in hostedProviderPresets)
              _buildRow(
                context,
                theme,
                label: preset.labelFor(context),
                subtitle: providerHostOf(preset.baseUrl!),
                current: _isCurrent(preset),
                onTap: () => _editPreset(context, preset),
              ),
            for (final provider in registry.providers)
              _buildRow(
                context,
                theme,
                label: provider.name,
                subtitle: provider.modelId.isEmpty
                    ? providerHostOf(provider.baseUrl)
                    : context.l10n.mediaModelsOverrideSummary(
                        provider.modelId,
                        providerHostOf(provider.baseUrl),
                      ),
                current: _isCurrent(provider),
                onTap: () => _editCustom(context, registry, provider),
              ),
            _buildRow(
              context,
              theme,
              label: context.l10n.settingsAddProvider,
              leading: Icons.add,
              onTap: () => _addProvider(context, registry),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme, {
    required String label,
    String? subtitle,
    bool current = false,
    IconData leading = Icons.cloud_outlined,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(leading, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (current)
              Icon(Icons.check, size: 20, color: theme.colorScheme.primary)
            else
              Icon(
                Icons.chevron_right,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPreset(BuildContext context, ProviderPreset preset) async {
    final keysStore = SessionKeysScope.maybeOf(context);
    final registry = this.registry;
    final keyName = hostedProviderKeyName(preset);
    final result = await Navigator.of(context).push<ProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) => ProviderEditorPage(
          title: preset.labelFor(context),
          preset: preset,
          hasSavedKey:
              keyName != null && settingsKeyEnv(keyName, keysStore).isNotEmpty,
          registry: registry,
        ),
      ),
    );
    if (result == null) return;
    // The preset's default model is user-editable: persist the override,
    // clearing it when the field is empty or back to the built-in default.
    if (registry != null) {
      final model = result.modelId;
      await registry.setPresetModelOverride(
        preset.name,
        model.isEmpty || model == preset.defaultModel ? null : model,
      );
    }
    if (result.apiKey.isEmpty || keyName == null) return;
    await keysStore?.set(keyName, result.apiKey);
  }

  Future<void> _editCustom(
    BuildContext context,
    ProviderRegistry registry,
    CustomProvider provider,
  ) async {
    final result = await Navigator.of(context).push<ProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) => ProviderEditorPage(
          title: context.l10n.settingsEditProviderTitle,
          initial: provider,
          hasSavedKey: (registry.keyFor(provider.id) ?? '').isNotEmpty,
        ),
      ),
    );
    if (result == null) return;
    if (result.deleted) {
      await registry.remove(provider.id);
      return;
    }
    final updated = CustomProvider(
      id: provider.id,
      name: result.name,
      baseUrl: result.baseUrl,
      modelId: result.modelId,
    );
    await registry.update(updated);
    if (result.apiKey.isNotEmpty) {
      registry.rememberKey(updated.id, result.apiKey);
    }
  }

  Future<void> _addProvider(
    BuildContext context,
    ProviderRegistry registry,
  ) async {
    await pushProviderEditor(
      context,
      registry,
      title: context.l10n.settingsAddProvider,
    );
  }
}

/// The settings "Default chat model" section — one row showing the active
/// provider + model. Tapping pushes the two-step flow
/// ([DefaultModelProviderPickerPage] → model page); applying reconfigures
/// [service] and saves the last connection, like the old form's Apply.
class DefaultChatModelSection extends StatelessWidget {
  const DefaultChatModelSection({
    super.key,
    required this.service,
    this.registry,
    this.lastConnectionStore,
    this.modelsFetcher,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  /// The service whose backend the flow reconfigures.
  final AgentService service;

  /// The user-added providers listed in the picker.
  final ProviderRegistry? registry;

  /// Updated on every successful apply (see [LastConnectionStore]).
  final LastConnectionStore? lastConnectionStore;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// Engine overrides for the on-device routes (tests).
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Platform override for tests (see [AgentSettingsForm.isWeb]).
  final bool? isWeb;

  /// Applies [config] as the main connection (the old Apply button's
  /// effect): reconfigure the service, persist the last connection.
  Future<void> _apply(AgentConfig config) async {
    await service.reconfigure(config);
    await lastConnectionStore?.saveFromConfig(config);
  }

  String _activeProviderLabel(BuildContext context) {
    final kind = service.providerKind;
    if (kind == webLlmProviderKind) {
      return ProviderPreset.webllm.labelFor(context);
    }
    if (kind == gemmaProviderKind)
      return ProviderPreset.gemma.labelFor(context);
    if (kind == transformersJsProviderKind) {
      return ProviderPreset.transformersJs.labelFor(context);
    }
    final provider = providerForBaseUrl(service.activeBaseUrl, registry);
    if (provider != null) return providerDisplayName(context, provider);
    return providerHostOf(service.activeBaseUrl);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.settingsDefaultChatModelTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DefaultModelProviderPickerPage(
                      registry: registry,
                      onApply: _apply,
                      modelsFetcher: modelsFetcher,
                      webLlmEngine: webLlmEngine,
                      gemmaEngine: gemmaEngine,
                      transformersJsEngine: transformersJsEngine,
                      isWeb: isWeb,
                    ),
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
                        context.l10n.settingsProviderModelSummary(
                          service.modelId,
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
/// preset, a saved [CustomProvider], an on-device preset (its model page
/// is the regular [AgentSettingsForm] pre-selected to that provider), or
/// "Add provider" (the create page, then back to picking).
class DefaultModelProviderPickerPage extends StatelessWidget {
  const DefaultModelProviderPickerPage({
    super.key,
    required this.onApply,
    this.registry,
    this.modelsFetcher,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  /// Applies the chosen config as the main connection (reconfigure + save
  /// the last connection). Throw to surface an error on the model page.
  final Future<void> Function(AgentConfig config) onApply;

  /// The user-added providers; `null` falls back to a non-persisting
  /// in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// Engine overrides for the on-device routes (tests).
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Platform override for tests (see [AgentSettingsForm.isWeb]).
  final bool? isWeb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
    final web = isWeb ?? kIsWeb;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsPickProviderTitle)),
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
                // The on-device presets connect through the regular form
                // (engine download + progress) pre-selected to the provider.
                _providerTile(
                  context,
                  theme,
                  label: ProviderPreset.webllm.labelFor(context),
                  onTap: () => _pickOnDevice(context, ProviderPreset.webllm),
                ),
                if (gemmaProviderVisible(
                  isWeb: web,
                  platform: defaultTargetPlatform,
                ))
                  _providerTile(
                    context,
                    theme,
                    label: ProviderPreset.gemma.labelFor(context),
                    onTap: () => _pickOnDevice(context, ProviderPreset.gemma),
                  ),
                if (transformersJsProviderVisible(isWeb: web))
                  _providerTile(
                    context,
                    theme,
                    label: ProviderPreset.transformersJs.labelFor(context),
                    onTap: () =>
                        _pickOnDevice(context, ProviderPreset.transformersJs),
                  ),
                const Divider(),
                _providerTile(
                  context,
                  theme,
                  label: context.l10n.settingsAddProvider,
                  leading: Icons.add,
                  onTap: () => pushProviderEditor(
                    context,
                    registry,
                    title: context.l10n.settingsAddProvider,
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
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DefaultModelPickerPage(
          provider: provider,
          registry: registry,
          onApply: onApply,
          modelsFetcher: modelsFetcher,
        ),
      ),
    );
    // Applied: the flow is done — back to the settings screen.
    if (applied == true && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _pickOnDevice(
    BuildContext context,
    ProviderPreset preset,
  ) async {
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _OnDeviceFormPage(
          preset: preset,
          registry: registry ?? ProviderRegistry.inMemory(),
          onApply: onApply,
          webLlmEngine: webLlmEngine,
          gemmaEngine: gemmaEngine,
          transformersJsEngine: transformersJsEngine,
          isWeb: isWeb,
        ),
      ),
    );
    if (applied == true && context.mounted) Navigator.of(context).pop();
  }
}

/// The on-device route of the default-chat-model flow: the regular
/// [AgentSettingsForm] (model picker, download progress, HF token) locked
/// to [preset]; a successful connect applies the config and pops true.
class _OnDeviceFormPage extends StatelessWidget {
  const _OnDeviceFormPage({
    required this.preset,
    required this.registry,
    required this.onApply,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  final ProviderPreset preset;
  final ProviderRegistry registry;
  final Future<void> Function(AgentConfig config) onApply;
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;
  final bool? isWeb;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(preset.labelFor(context))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: AgentSettingsForm(
            initialProvider: preset,
            connectLabel: context.l10n.settingsApplyButton,
            registry: registry,
            keysStore: SessionKeysScope.maybeOf(context),
            webLlmEngine: webLlmEngine,
            gemmaEngine: gemmaEngine,
            transformersJsEngine: transformersJsEngine,
            isWeb: isWeb,
            onConnect: (config) async {
              await onApply(config);
              if (context.mounted) Navigator.of(context).pop(true);
            },
          ),
        ),
      ),
    );
  }
}

/// Step (b) of the default-chat-model flow for an endpoint provider: pick
/// its model — the endpoint's `/models` list feeds the quick select (any
/// custom id stays valid), the provider's default model is prefilled.
/// Apply reconfigures the main connection (keys resolve from the
/// registry / saved-keys store exactly like the old connect button) and
/// pops true so the picker unwinds too. Hosted presets require a key;
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
  final Future<void> Function(AgentConfig config) onApply;

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
    final model = _modelController.text.trim();
    if (model.isEmpty) {
      setState(() => _error = context.l10n.settingsModelIdRequired);
      return;
    }
    final key = _resolvedKey();
    if (key.isEmpty && !_keyOptional) {
      setState(() => _error = context.l10n.settingsApiKeyRequired);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.onApply(
        AgentConfig(
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
      // session, like the old form did. Never persisted.
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
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsPickModelTitle)),
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
                    : Text(context.l10n.settingsApplyButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
