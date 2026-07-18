import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'agent_service.dart';
import 'gemma/gemma_service.dart';
import 'gemma/gemma_types.dart';
import 'provider_registry.dart';
import 'webllm/webllm_cache_section.dart';
import 'webllm/webllm_service.dart';
import 'webllm/webllm_types.dart';

/// Compile-time configuration injected via `--dart-define`. Values fall back
/// to the `.env` file (local dev) at runtime — see [settingsEnv].
const settingsDartDefines = <String, String>{
  'OPENROUTER_API_KEY': String.fromEnvironment('OPENROUTER_API_KEY'),
  'MODEL_ID': String.fromEnvironment('MODEL_ID'),
  'BASE_URL': String.fromEnvironment('BASE_URL'),
  'HUGGINGFACE_TOKEN': String.fromEnvironment('HUGGINGFACE_TOKEN'),
};

/// Resolves a configuration default: `--dart-define` wins, then `.env`, then
/// [fallback].
String settingsEnv(String name, String fallback) {
  final dartValue = settingsDartDefines[name];
  if (dartValue != null && dartValue.isNotEmpty) return dartValue;
  if (dotenv.isInitialized && dotenv.env.containsKey(name)) {
    return dotenv.env[name]!;
  }
  return fallback;
}

/// A bring-your-own-key provider preset. Hosted presets talk to an
/// OpenAI-compatible chat-completions endpoint; [webllm] runs a small model
/// on-device in the browser (no key, no endpoint); [gemma] runs Gemma 4
/// on-device via the `flutter_gemma` plugin — on iOS/Android and on web
/// (hidden on desktop — see [gemmaProviderSupported]).
///
/// Presets are built-in and cannot be deleted; user-added providers
/// ([CustomProvider], managed by [ProviderRegistry]) appear in the same
/// picker and can be edited and removed.
enum ProviderPreset {
  openrouter(
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o-mini',
  ),
  ollamaCloud(
    label: 'Ollama',
    baseUrl: 'https://ollama.com/v1',
    defaultModel: 'gpt-oss:120b',
  ),
  custom(label: 'Custom', baseUrl: null, defaultModel: ''),
  webllm(label: 'On-device (WebLLM)', baseUrl: null, defaultModel: ''),
  gemma(label: 'On-device (Gemma)', baseUrl: null, defaultModel: '');

  const ProviderPreset({
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
  });

  /// Short label shown in the provider picker.
  final String label;

  /// Fixed endpoint for hosted presets; `null` for [custom] (user-editable)
  /// and the on-device presets (no endpoint at all).
  final String? baseUrl;

  /// Model prefill applied while the user has not typed their own.
  final String defaultModel;

  /// Whether the base-URL field is editable for this preset.
  bool get hasEditableBaseUrl => this == ProviderPreset.custom;

  /// Whether this preset is an on-device provider, which replaces the
  /// key/model/URL fields with a model picker and a download bar.
  bool get isOnDevice =>
      this == ProviderPreset.webllm || this == ProviderPreset.gemma;

  /// Shown under the form for providers that may reject browser (CORS)
  /// calls. OpenRouter allows cross-origin browser requests, so it has no
  /// note; other endpoints are not guaranteed to.
  String? get corsNote => switch (this) {
    ProviderPreset.openrouter => null,
    ProviderPreset.ollamaCloud =>
      'Calls go straight from your browser to ollama.com, which currently '
          'does not send CORS headers — browser calls fail. Use OpenRouter '
          'here, or pick Ollama from the mobile/desktop app instead.',
    ProviderPreset.custom =>
      'Any OpenAI-compatible endpoint. The provider must allow browser '
          '(CORS) requests — api.anthropic.com does not, so reach Anthropic '
          'models via OpenRouter instead.',
    ProviderPreset.webllm || ProviderPreset.gemma => null,
  };

  /// Infers a preset from a configured base URL (for env-prefilled setups).
  static ProviderPreset fromBaseUrl(String url) {
    if (url.contains('openrouter.ai')) return ProviderPreset.openrouter;
    if (url.contains('ollama.com')) return ProviderPreset.ollamaCloud;
    return ProviderPreset.custom;
  }
}

/// The BYOK connection form shared by the first-run [SetupScreen] and the
/// in-chat [SettingsDialog].
///
/// The provider picker mixes the built-in [ProviderPreset]s with user-added
/// [CustomProvider]s from [registry]; "Add provider" saves a named
/// OpenAI-compatible endpoint (name, base URL, model id) that persists
/// across reloads (see [ProviderRegistry]). API keys are never persisted:
/// for custom providers the key is remembered in memory for the session
/// only, so a reload requires re-entering it.
class AgentSettingsForm extends StatefulWidget {
  const AgentSettingsForm({
    super.key,
    required this.onConnect,
    this.connectLabel = 'Start chat',
    this.registry,
    this.gemmaEngine,
  });

  /// Called with the assembled [AgentConfig]. Throw to surface an error in
  /// the form; return normally when the connection succeeded.
  final Future<void> Function(AgentConfig config) onConnect;

  /// Label of the primary button (`Start chat` on first run, `Apply` from
  /// the settings dialog).
  final String connectLabel;

  /// The user-added providers shown in the picker. `null` falls back to a
  /// non-persisting in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// Engine override for the on-device Gemma provider (tests); defaults to
  /// the platform singleton.
  final GemmaEngineApi? gemmaEngine;

  @override
  State<AgentSettingsForm> createState() => _AgentSettingsFormState();
}

class _AgentSettingsFormState extends State<AgentSettingsForm> {
  /// The picker selection: a built-in [ProviderPreset] or a user-added
  /// [CustomProvider].
  late Object _selection;
  late String _lastDefaultModel;

  late final ProviderRegistry _registry;
  late final TextEditingController _keyController;
  late final TextEditingController _modelController;
  late final TextEditingController _urlController;
  late final TextEditingController _hfTokenController;

  /// Selected on-device model (only meaningful for [ProviderPreset.webllm]).
  WebLlmModelPreset _webllmModel = webLlmModelPresets.first;

  /// Selected on-device model (only meaningful for [ProviderPreset.gemma]).
  GemmaModelPreset _gemmaModel = gemmaModelPresets.first;

  /// Engine-init progress while the on-device model downloads/compiles.
  double? _loadFraction;
  String? _loadStatus;

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ?? ProviderRegistry.inMemory();
    _registry.addListener(_onRegistryChanged);
    final initialUrl = settingsEnv(
      'BASE_URL',
      ProviderPreset.openrouter.baseUrl!,
    );
    final preset = ProviderPreset.fromBaseUrl(initialUrl);
    _selection = preset;
    _keyController = TextEditingController(
      text: settingsEnv('OPENROUTER_API_KEY', ''),
    );
    _lastDefaultModel = preset.defaultModel;
    _modelController = TextEditingController(
      text: settingsEnv('MODEL_ID', preset.defaultModel),
    );
    _urlController = TextEditingController(text: initialUrl);
    _hfTokenController = TextEditingController(
      text: settingsEnv('HUGGINGFACE_TOKEN', ''),
    );
  }

  @override
  void dispose() {
    _registry.removeListener(_onRegistryChanged);
    _keyController.dispose();
    _modelController.dispose();
    _urlController.dispose();
    _hfTokenController.dispose();
    super.dispose();
  }

  bool get _isOnDevice => _selection == ProviderPreset.webllm;

  bool get _isGemma => _selection == ProviderPreset.gemma;

  bool get _hasEditableBaseUrl =>
      _selection is CustomProvider || _selection == ProviderPreset.custom;

  /// Keeps the picker consistent when providers are edited or deleted: a
  /// deleted selection falls back to OpenRouter; an edited one tracks the
  /// registry's instance.
  void _onRegistryChanged() {
    if (!mounted) return;
    final selection = _selection;
    if (selection is! CustomProvider) {
      setState(() {});
      return;
    }
    CustomProvider? match;
    for (final provider in _registry.providers) {
      if (provider.id == selection.id) {
        match = provider;
        break;
      }
    }
    setState(() {
      if (match != null) {
        _selection = match;
      } else {
        _applyPreset(ProviderPreset.openrouter);
        // The deleted provider's key must not linger next to a different
        // endpoint.
        _keyController.clear();
      }
    });
  }

  void _applyPreset(ProviderPreset preset) {
    _selection = preset;
    final baseUrl = preset.baseUrl;
    if (baseUrl != null) {
      _urlController.text = baseUrl;
    }
    // Follow the preset's default model only while the user has not typed
    // a custom one (still empty or equal to the previous default).
    final current = _modelController.text.trim();
    if (current.isEmpty || current == _lastDefaultModel) {
      _modelController.text = preset.defaultModel;
    }
    _lastDefaultModel = preset.defaultModel;
    _error = null;
  }

  void _applyCustomProvider(CustomProvider provider) {
    _selection = provider;
    _urlController.text = provider.baseUrl;
    _modelController.text = provider.modelId;
    _keyController.text = _registry.keyFor(provider.id) ?? '';
    _lastDefaultModel = provider.modelId;
    _error = null;
  }

  void _selectProvider(Object value) {
    setState(() {
      switch (value) {
        case ProviderPreset preset:
          _applyPreset(preset);
        case CustomProvider provider:
          _applyCustomProvider(provider);
      }
    });
  }

  Future<void> _addProvider() async {
    final result = await showDialog<ProviderEditorResult>(
      context: context,
      builder: (_) => const ProviderEditorDialog(title: 'Add provider'),
    );
    if (result == null) return;
    final provider = await _registry.add(
      name: result.name,
      baseUrl: result.baseUrl,
      modelId: result.modelId,
    );
    if (result.apiKey.isNotEmpty) {
      _registry.rememberKey(provider.id, result.apiKey);
    }
    setState(() => _applyCustomProvider(provider));
  }

  Future<void> _editProvider() async {
    final selection = _selection;
    if (selection is! CustomProvider) return;
    final result = await showDialog<ProviderEditorResult>(
      context: context,
      builder: (_) => ProviderEditorDialog(
        title: 'Edit provider',
        initial: selection,
        initialKey: _registry.keyFor(selection.id),
      ),
    );
    if (result == null) return;
    final updated = CustomProvider(
      id: selection.id,
      name: result.name,
      baseUrl: result.baseUrl,
      modelId: result.modelId,
    );
    await _registry.update(updated);
    if (result.apiKey.isNotEmpty) {
      _registry.rememberKey(updated.id, result.apiKey);
    }
    setState(() => _applyCustomProvider(updated));
  }

  Future<void> _deleteProvider() async {
    final selection = _selection;
    if (selection is! CustomProvider) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${selection.name}?'),
        content: const Text(
          'The provider is removed from the picker. The current connection '
          'is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // _onRegistryChanged resets the selection to OpenRouter.
    await _registry.remove(selection.id);
  }

  Future<void> _connect() async {
    if (_isOnDevice) {
      return _connectWebLlm();
    }
    if (_isGemma) {
      return _connectGemma();
    }
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();
    final baseUrl = _urlController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'API key is required');
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = 'Model id is required');
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _error = 'Base URL is required');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.onConnect(
        AgentConfig(
          providerKind: 'openai-completions',
          modelId: model,
          baseUrl: baseUrl,
          apiKey: key,
        ),
      );
      // Connected: keep the key for this session so reopening settings (or
      // re-picking the provider) prefills it. Never persisted.
      final selection = _selection;
      if (selection is CustomProvider) {
        _registry.rememberKey(selection.id, key);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// On-device connect: downloads/compiles the selected model (showing
  /// engine-init progress in the form) before handing over to [onConnect].
  /// The engine is a singleton, so the stream function reuses this warm
  /// instance — the first chat turn does not pay the load again.
  Future<void> _connectWebLlm() async {
    final preset = _webllmModel;
    final service = createWebLlmService();
    setState(() {
      _loading = true;
      _error = null;
      _loadFraction = null;
      _loadStatus = null;
    });
    StreamSubscription<WebLlmProgress>? progressSub;
    try {
      progressSub = service.progressEvents.listen((report) {
        if (!mounted) return;
        setState(() {
          _loadFraction = report.fraction;
          _loadStatus = report.text;
        });
      });
      await service.loadModel(preset);
      if (!mounted) return;
      await widget.onConnect(
        AgentConfig(
          providerKind: webLlmProviderKind,
          modelId: preset.id,
          baseUrl: '',
          apiKey: '',
          // No WebLLM-specific system prompt: the default sandbox prompt
          // (identity + capabilities) applies, and the prompt-tools wrapper
          // appends the tool instructions upstream.
          contextWindow: preset.contextWindow,
          maxTokens: 1024,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : e.toString());
      }
    } finally {
      // Not awaited: the subscription detaches synchronously on cancel(),
      // and awaiting the completion future can stall this finally inside
      // widget-test zones (the returned future is zone-scheduled).
      unawaited(progressSub?.cancel());
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFraction = null;
          _loadStatus = null;
        });
      }
    }
  }

  /// On-device Gemma connect: downloads the selected model (skipping what is
  /// already installed, showing progress in the form), loads it into memory,
  /// then hands over to [onConnect]. The engine is a singleton, so the
  /// stream function reuses this warm instance — the first chat turn does
  /// not pay the load again. The HuggingFace token is used for this install
  /// only and never persisted.
  Future<void> _connectGemma() async {
    final preset = _gemmaModel;
    final service = widget.gemmaEngine ?? createGemmaService();
    setState(() {
      _loading = true;
      _error = null;
      _loadFraction = null;
      _loadStatus = null;
    });
    StreamSubscription<GemmaProgress>? progressSub;
    try {
      if (!service.isAvailable) {
        throw StateError(gemmaUnsupportedPlatformMessage);
      }
      progressSub = service.progressEvents.listen((report) {
        if (!mounted) return;
        setState(() {
          _loadFraction = report.fraction;
          _loadStatus = report.text;
        });
      });
      final hfToken = _hfTokenController.text.trim();
      await service.installModel(
        preset,
        huggingFaceToken: hfToken.isEmpty ? null : hfToken,
      );
      await service.loadModel(preset);
      if (!mounted) return;
      await widget.onConnect(
        AgentConfig(
          providerKind: gemmaProviderKind,
          modelId: preset.id,
          baseUrl: '',
          apiKey: '',
          contextWindow: preset.contextWindow,
          maxTokens: 1024,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : e.toString());
      }
    } finally {
      // See _connectWebLlm: not awaited on purpose.
      unawaited(progressSub?.cancel());
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFraction = null;
          _loadStatus = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selection = _selection;
    final corsNote = switch (selection) {
      ProviderPreset preset => preset.corsNote,
      // Custom providers share the custom preset's CORS note.
      _ => ProviderPreset.custom.corsNote,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<Object>(
          // The key forces the FormField to re-seed when the selection is
          // changed programmatically (provider added/selected/deleted).
          key: ValueKey<Object>(_selection),
          initialValue: _selection,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: [
            for (final preset in ProviderPreset.values)
              // Gemma runs on web + iOS/Android; hidden on desktop.
              if (preset != ProviderPreset.gemma || gemmaProviderSupported)
                DropdownMenuItem(value: preset, child: Text(preset.label)),
            for (final provider in _registry.providers)
              DropdownMenuItem(
                value: provider,
                child: Text(provider.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _loading
              ? null
              : (value) {
                  if (value != null) _selectProvider(value);
                },
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed: _loading ? null : _addProvider,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add provider'),
            ),
            if (selection is CustomProvider) ...[
              TextButton(
                onPressed: _loading ? null : _editProvider,
                child: const Text('Edit'),
              ),
              TextButton(
                onPressed: _loading ? null : _deleteProvider,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text('Delete'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        if (_isOnDevice)
          _buildWebLlmFields(theme)
        else if (_isGemma)
          _buildGemmaFields(theme)
        else ...[
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(
              labelText: 'API key',
              hintText: 'Paste your provider key',
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(labelText: 'Model id'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            enabled: _hasEditableBaseUrl,
            decoration: InputDecoration(
              labelText: 'Base URL',
              helperText: _hasEditableBaseUrl
                  ? 'OpenAI-compatible endpoint'
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selection is CustomProvider
                      ? 'The provider definition (name, URL, model) is saved '
                            '— no secrets. The API key stays in memory for '
                            'this session only and is gone on reload.'
                      : 'In-memory only: your key is never persisted and is '
                            'gone on reload. Calls go straight from your '
                            'browser to the provider — nothing is proxied or '
                            'stored.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
        if (corsNote != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(corsNote, style: theme.textTheme.bodySmall)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _loading ? null : _connect,
          child: _loading && !_isOnDevice && !_isGemma
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_loading ? 'Loading model…' : widget.connectLabel),
        ),
      ],
    );
  }

  /// The on-device (WebLLM) replacement for the key/model/URL fields: a
  /// model picker over [webLlmModelPresets], the offline/WebGPU note, and —
  /// while a load is in flight — the engine-init progress bar.
  Widget _buildWebLlmFields(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<WebLlmModelPreset>(
          initialValue: _webllmModel,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'On-device model'),
          items: [
            for (final preset in webLlmModelPresets)
              DropdownMenuItem(
                value: preset,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${preset.displayName} · ${preset.sizeLabel}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const _ToolsBadge(),
                  ],
                ),
              ),
          ],
          onChanged: _loading
              ? null
              : (preset) {
                  if (preset == null) return;
                  setState(() => _webllmModel = preset);
                },
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.memory, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Runs fully offline after download · needs WebGPU '
                '(Chrome/Edge/newer Safari) · weights ~0.5-4 GB cached in '
                'your browser',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (_loading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _loadFraction),
          const SizedBox(height: 4),
          Text(
            _loadStatus != null && _loadStatus!.isNotEmpty
                ? _loadStatus!
                : 'Downloading model weights…',
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  /// The on-device (Gemma) replacement for the key/model/URL fields: a
  /// model picker over [gemmaModelPresets], the HuggingFace token field
  /// (session-only), the offline note, and — while an install/load is in
  /// flight — the progress bar.
  Widget _buildGemmaFields(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<GemmaModelPreset>(
          initialValue: _gemmaModel,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'On-device model'),
          items: [
            for (final preset in gemmaModelPresets)
              DropdownMenuItem(
                value: preset,
                child: Text(
                  '${preset.displayName} · ${preset.sizeLabel}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _loading
              ? null
              : (preset) {
                  if (preset == null) return;
                  setState(() => _gemmaModel = preset);
                },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hfTokenController,
          decoration: const InputDecoration(
            labelText: 'HuggingFace token (optional)',
            hintText: 'hf_… — needed if the repo is gated',
          ),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.memory, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                gemmaStorageNote(isWeb: kIsWeb, preset: _gemmaModel),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (_loading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _loadFraction),
          const SizedBox(height: 4),
          Text(
            _loadStatus != null && _loadStatus!.isNotEmpty
                ? _loadStatus!
                : 'Downloading model weights…',
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// The values collected by the add/edit-provider dialog.
///
/// [apiKey] is optional; when given it is remembered in memory for the
/// session only (see [ProviderRegistry.rememberKey]) — never persisted.
final class ProviderEditorResult {
  /// Creates an editor result.
  const ProviderEditorResult({
    required this.name,
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
  });

  /// Display name in the provider picker.
  final String name;

  /// OpenAI-compatible endpoint.
  final String baseUrl;

  /// Default model id.
  final String modelId;

  /// Session-only API key (may be empty).
  final String apiKey;
}

/// The add/edit dialog for a [CustomProvider]. With [initial] set it edits
/// that provider, otherwise it collects a new one. Pops with a
/// [ProviderEditorResult], or `null` when cancelled.
class ProviderEditorDialog extends StatefulWidget {
  const ProviderEditorDialog({
    super.key,
    required this.title,
    this.initial,
    this.initialKey,
  });

  /// Dialog title (`Add provider` / `Edit provider`).
  final String title;

  /// The provider being edited; `null` when adding a new one.
  final CustomProvider? initial;

  /// The session key prefill (edit mode); leave empty to keep the current
  /// key.
  final String? initialKey;

  @override
  State<ProviderEditorDialog> createState() => _ProviderEditorDialogState();
}

class _ProviderEditorDialogState extends State<ProviderEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _modelController;
  late final TextEditingController _keyController;

  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial?.name ?? '');
    _urlController = TextEditingController(text: widget.initial?.baseUrl ?? '');
    _modelController = TextEditingController(
      text: widget.initial?.modelId ?? '',
    );
    _keyController = TextEditingController(text: widget.initialKey ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _modelController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    final baseUrl = _urlController.text.trim();
    final modelId = _modelController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _error = 'Base URL is required');
      return;
    }
    if (modelId.isEmpty) {
      setState(() => _error = 'Model id is required');
      return;
    }
    Navigator.of(context).pop(
      ProviderEditorResult(
        name: name,
        baseUrl: baseUrl,
        modelId: modelId,
        apiKey: _keyController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: _dialogContentWidth(context, 380),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'My provider',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://example.com/v1',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(labelText: 'Model id'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: 'API key (optional)',
                ),
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              Text(
                'Name, URL and model are saved; the key is kept in memory '
                'for this session only — never persisted.',
                style: theme.textTheme.bodySmall,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// The gear-icon dialog from the chat screen (also opened from the session
/// sidebar's model tile): reconfigure provider/model/key mid-session,
/// manage saved providers, and manage the on-device model cache.
/// Applying swaps the backend of [service] via [AgentService.reconfigure] —
/// the visible transcript, the sandbox filesystem, and the current session
/// all survive.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({
    super.key,
    required this.service,
    this.registry,
    this.webLlmEngine,
    this.gemmaEngine,
  });

  /// The service whose backend the form reconfigures.
  final AgentService service;

  /// The user-added providers shown in the form's picker.
  final ProviderRegistry? registry;

  /// Engine override for the downloaded-models section (tests); defaults to
  /// the platform singleton.
  final WebLlmEngineApi? webLlmEngine;

  /// Engine override for the on-device Gemma provider (tests); defaults to
  /// the platform singleton.
  final GemmaEngineApi? gemmaEngine;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: _dialogContentWidth(context, 440),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AgentSettingsForm(
                connectLabel: 'Apply',
                registry: registry,
                gemmaEngine: gemmaEngine,
                onConnect: (config) async {
                  await service.reconfigure(config);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              WebLlmCacheSection(engine: webLlmEngine),
            ],
          ),
        ),
      ),
    );
  }
}

/// Responsive dialog content width: [preferred] on wide screens, shrinking
/// to fit narrow phones (AlertDialog's default inset padding is 16-24 px).
double _dialogContentWidth(BuildContext context, double preferred) {
  final available = MediaQuery.sizeOf(context).width - 32;
  return available < preferred ? available.clamp(0.0, preferred) : preferred;
}

/// The small "tools via prompt" chip shown next to every preset in the
/// on-device (WebLLM) model picker: tool calling works for all presets
/// through the harness's prompt-tools wrapper (fenced `tool_call` blocks),
/// not the engine's native function calling.
class _ToolsBadge extends StatelessWidget {
  const _ToolsBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'tools via prompt',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
