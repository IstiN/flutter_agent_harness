import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'agent_service.dart';
import 'approval_ui.dart';
import 'gemma/gemma_cache_section.dart';
import 'gemma/gemma_service.dart';
import 'gemma/gemma_types.dart';
import 'last_connection.dart';
import 'provider_registry.dart';
import 'transformers_js/transformers_js_cache_section.dart';
import 'transformers_js/transformers_js_service.dart';
import 'transformers_js/transformers_js_types.dart';
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
/// on-device via the `flutter_gemma` plugin on iOS/Android (hidden
/// elsewhere — see [gemmaProviderSupported]); [transformersJs] runs Gemma 4
/// ONNX on-device in the browser via `@huggingface/transformers`
/// (web-only — see [transformersJsProviderSupported]).
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
  gemma(label: 'On-device (Gemma)', baseUrl: null, defaultModel: ''),
  transformersJs(
    label: 'On-device (Gemma, transformers.js)',
    baseUrl: null,
    defaultModel: '',
  );

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
      this == ProviderPreset.webllm ||
      this == ProviderPreset.gemma ||
      this == ProviderPreset.transformersJs;

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
    ProviderPreset.webllm ||
    ProviderPreset.gemma ||
    ProviderPreset.transformersJs => null,
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
/// only, so a reload requires re-entering it. The key is optional for
/// custom providers (built-in [ProviderPreset.custom] and saved
/// [CustomProvider]s) — local llama.cpp/Ollama/LM Studio servers need none;
/// the hosted presets (OpenRouter, Ollama Cloud) still require one.
class AgentSettingsForm extends StatefulWidget {
  const AgentSettingsForm({
    super.key,
    required this.onConnect,
    this.connectLabel = 'Start chat',
    this.registry,
    this.initialConnection,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
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

  /// The last successful connection (see [LastConnectionStore]), pre-selected
  /// when the form opens. For on-device kinds the stored model is verified
  /// against the engine's cache/installed state: still present → pre-selected;
  /// removed meanwhile → the provider stays pre-selected but the model falls
  /// back to the default preset with a small note. `null` keeps the
  /// env-based defaults.
  final LastConnection? initialConnection;

  /// Engine override for the on-device WebLLM provider (tests); defaults to
  /// the platform singleton.
  final WebLlmEngineApi? webLlmEngine;

  /// Engine override for the on-device Gemma provider (tests); defaults to
  /// the platform singleton.
  final GemmaEngineApi? gemmaEngine;

  /// Engine override for the on-device transformers.js provider (tests);
  /// defaults to the platform singleton.
  final TransformersJsEngineApi? transformersJsEngine;

  /// Platform override for tests (host tests run with `kIsWeb == false`, so
  /// the web-only provider visibility — [transformersJsProviderVisible],
  /// [gemmaProviderVisible] — is exercised through this seam, the same
  /// pattern as `GemmaCacheSection.isWeb`).
  final bool? isWeb;

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

  /// Selected on-device model (only meaningful for
  /// [ProviderPreset.transformersJs]).
  TransformersJsModelPreset _transformersJsModel =
      transformersJsModelPresets.first;

  /// Web-ness of the platform (overridable for tests — see
  /// [AgentSettingsForm.isWeb]).
  late final bool _isWeb = widget.isWeb ?? kIsWeb;

  /// Engine-init progress while the on-device model downloads/compiles.
  double? _loadFraction;
  String? _loadStatus;

  /// Note shown when the last connection's on-device model is no longer
  /// cached/installed (the provider stays pre-selected; the model falls back
  /// to the default preset). Cleared when the user changes the selection.
  String? _staleModelNote;

  /// The manual timer bounding the Gemma installed-check in
  /// [_verifyGemmaInstalled] — cancelled on dispose so a wedged plugin never
  /// leaves a pending timer behind (`Future.timeout`'s internal timer cannot
  /// be cancelled).
  Timer? _gemmaVerifyTimer;

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
    // The last connection wins over the env-based defaults; the key field is
    // never touched (keys are session-only and never persisted).
    final connection = widget.initialConnection;
    if (connection != null) _applyLastConnection(connection);
  }

  @override
  void dispose() {
    _gemmaVerifyTimer?.cancel();
    _registry.removeListener(_onRegistryChanged);
    _keyController.dispose();
    _modelController.dispose();
    _urlController.dispose();
    _hfTokenController.dispose();
    super.dispose();
  }

  bool get _isOnDevice => _selection == ProviderPreset.webllm;

  bool get _isGemma => _selection == ProviderPreset.gemma;

  bool get _isTransformersJs => _selection == ProviderPreset.transformersJs;

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
    _staleModelNote = null;
    _error = null;
  }

  void _applyCustomProvider(CustomProvider provider) {
    _selection = provider;
    _urlController.text = provider.baseUrl;
    _modelController.text = provider.modelId;
    _keyController.text = _registry.keyFor(provider.id) ?? '';
    _lastDefaultModel = provider.modelId;
    _staleModelNote = null;
    _error = null;
  }

  /// Pre-selects the provider/model of the last successful connection (see
  /// [AgentSettingsForm.initialConnection]). Hosted providers prefill
  /// model/URL (a saved [CustomProvider] with the same endpoint+model is
  /// re-selected so its edit/delete affordances appear); on-device kinds
  /// pre-select the provider and model preset, then verify asynchronously
  /// that the weights are still cached/installed — a model removed meanwhile
  /// falls back to the default preset with a note ([_staleModelNote]).
  void _applyLastConnection(LastConnection connection) {
    switch (connection.providerKind) {
      case webLlmProviderKind:
        final preset = findWebLlmPreset(
          connection.webllmPresetId ?? connection.modelId,
        );
        if (preset == null) return;
        _selection = ProviderPreset.webllm;
        _webllmModel = preset;
        unawaited(_verifyWebLlmCache(preset));
      case gemmaProviderKind:
        // The provider is iOS/Android-only — a record written there must not
        // resurrect it where the picker hides it (a selection outside the
        // dropdown's items breaks it).
        if (!gemmaProviderVisible(
          isWeb: _isWeb,
          platform: defaultTargetPlatform,
        )) {
          return;
        }
        final preset = findGemmaPreset(
          connection.gemmaPresetId ?? connection.modelId,
        );
        if (preset == null) return;
        _selection = ProviderPreset.gemma;
        _gemmaModel = preset;
        unawaited(_verifyGemmaInstalled(preset));
      case transformersJsProviderKind:
        // Web-only, like the picker entry.
        if (!transformersJsProviderVisible(isWeb: _isWeb)) return;
        final preset = findTransformersJsPreset(
          connection.transformersJsPresetId ?? connection.modelId,
        );
        if (preset == null) return;
        _selection = ProviderPreset.transformersJs;
        _transformersJsModel = preset;
        unawaited(_verifyTransformersJsCache(preset));
      default:
        final baseUrl = connection.baseUrl;
        if (baseUrl == null || baseUrl.isEmpty) return;
        for (final provider in _registry.providers) {
          if (provider.baseUrl == baseUrl &&
              provider.modelId == connection.modelId) {
            // Set fields directly instead of _applyCustomProvider: the key
            // field keeps its env-seeded value (session keys are empty at
            // boot anyway — keys are never persisted).
            _selection = provider;
            _urlController.text = provider.baseUrl;
            _modelController.text = provider.modelId;
            _lastDefaultModel = provider.modelId;
            return;
          }
        }
        final preset = ProviderPreset.fromBaseUrl(baseUrl);
        _selection = preset;
        _urlController.text = baseUrl;
        _modelController.text = connection.modelId.isNotEmpty
            ? connection.modelId
            : preset.defaultModel;
        _lastDefaultModel = _modelController.text;
    }
  }

  /// Falls the pre-selected WebLLM model back to the default preset when its
  /// weights were deleted from the cache meanwhile. An engine that cannot
  /// answer (unavailable platform, blocked storage) leaves the selection
  /// untouched — "unknown" must not cry "removed".
  Future<void> _verifyWebLlmCache(WebLlmModelPreset preset) async {
    final engine = widget.webLlmEngine ?? createWebLlmService();
    if (!engine.isAvailable) return;
    WebLlmCacheInfo? info;
    try {
      info = await engine.modelCacheInfo(preset.id);
    } on Object {
      return;
    }
    if (info == null || info.cached) return;
    if (!mounted) return;
    // The user moved on while the query ran — don't yank their selection.
    if (_selection != ProviderPreset.webllm || _webllmModel.id != preset.id) {
      return;
    }
    setState(() {
      _webllmModel = webLlmModelPresets.first;
      _staleModelNote =
          'The previously used model (${preset.displayName}) was removed '
          'from the cache — pick a model to download it again.';
    });
  }

  /// The Gemma variant of [_verifyWebLlmCache], over the plugin's installed
  /// model repository (with the cache section's scan timeout: a hung store
  /// must not pin the form; the timer is this State's own so dispose can
  /// cancel it).
  Future<void> _verifyGemmaInstalled(GemmaModelPreset preset) async {
    final engine = widget.gemmaEngine ?? createGemmaService();
    if (!engine.isAvailable) return;
    var installed = true;
    try {
      final completer = Completer<List<GemmaInstalledModel>>();
      _gemmaVerifyTimer = Timer(const Duration(seconds: 10), () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('Gemma repository scan timed out'),
          );
        }
      });
      unawaited(
        engine.installedModels().then(
          (models) {
            if (!completer.isCompleted) completer.complete(models);
          },
          onError: (Object error) {
            if (!completer.isCompleted) completer.completeError(error);
          },
        ),
      );
      final models = await completer.future;
      installed = models.any(
        (model) => model.filename == preset.filenameFor(isWeb: _isWeb),
      );
    } on Object {
      return;
    } finally {
      _gemmaVerifyTimer?.cancel();
    }
    if (installed || !mounted) return;
    if (_selection != ProviderPreset.gemma || _gemmaModel.id != preset.id) {
      return;
    }
    setState(() {
      _gemmaModel = gemmaModelPresets.first;
      _staleModelNote =
          'The previously used model (${preset.displayName}) was removed '
          'from this device — pick a model to download it again.';
    });
  }

  /// The transformers.js variant of [_verifyWebLlmCache].
  Future<void> _verifyTransformersJsCache(
    TransformersJsModelPreset preset,
  ) async {
    final engine = widget.transformersJsEngine ?? createTransformersJsService();
    if (!engine.isAvailable) return;
    TransformersJsCacheInfo? info;
    try {
      info = await engine.modelCacheInfo(preset.id);
    } on Object {
      return;
    }
    if (info == null || info.cached) return;
    if (!mounted) return;
    if (_selection != ProviderPreset.transformersJs ||
        _transformersJsModel.id != preset.id) {
      return;
    }
    setState(() {
      _transformersJsModel = transformersJsModelPresets.first;
      _staleModelNote =
          'The previously used model (${preset.displayName}) was removed '
          'from the cache — pick a model to download it again.';
    });
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
    if (_isTransformersJs) {
      return _connectTransformersJs();
    }
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();
    final baseUrl = _urlController.text.trim();
    // Custom providers may point at keyless local servers (llama.cpp,
    // Ollama, LM Studio), so the key is optional for them; the hosted
    // presets (OpenRouter, Ollama Cloud) keep requiring one.
    final keyOptional =
        _selection is CustomProvider || _selection == ProviderPreset.custom;
    if (key.isEmpty && !keyOptional) {
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
    final service = widget.webLlmEngine ?? createWebLlmService();
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

  /// On-device transformers.js connect: downloads/compiles the selected
  /// model (showing download progress in the form) before handing over to
  /// [onConnect]. The engine is a singleton, so the stream function reuses
  /// this warm instance — the first chat turn does not pay the load again.
  /// No HuggingFace token: the ONNX repos are public.
  Future<void> _connectTransformersJs() async {
    final preset = _transformersJsModel;
    final service =
        widget.transformersJsEngine ?? createTransformersJsService();
    setState(() {
      _loading = true;
      _error = null;
      _loadFraction = null;
      _loadStatus = null;
    });
    StreamSubscription<TransformersJsProgress>? progressSub;
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
          providerKind: transformersJsProviderKind,
          modelId: preset.id,
          baseUrl: '',
          apiKey: '',
          // No provider-specific system prompt: the default sandbox prompt
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
    // Custom providers may run keyless (local servers); see _connect.
    final keyOptional =
        selection is CustomProvider || selection == ProviderPreset.custom;
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
              // Gemma runs on iOS/Android only (on web the transformers.js
              // provider replaces it); transformers.js is web-only.
              if ((preset != ProviderPreset.gemma ||
                      gemmaProviderVisible(
                        isWeb: _isWeb,
                        platform: defaultTargetPlatform,
                      )) &&
                  (preset != ProviderPreset.transformersJs ||
                      transformersJsProviderVisible(isWeb: _isWeb)))
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
        else if (_isTransformersJs)
          _buildTransformersJsFields(theme)
        else ...[
          TextField(
            controller: _keyController,
            decoration: InputDecoration(
              labelText: keyOptional ? 'API key (optional)' : 'API key',
              hintText: keyOptional ? null : 'Paste your provider key',
              helperText: keyOptional
                  ? 'Leave empty for local servers (llama.cpp, Ollama, '
                        'LM Studio)'
                  : null,
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
        if (_staleModelNote != null) ...[
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
              Expanded(
                child: Text(_staleModelNote!, style: theme.textTheme.bodySmall),
              ),
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
          child: _loading && !_isOnDevice && !_isGemma && !_isTransformersJs
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
                    if (preset.isCoder) ...[
                      const _CoderBadge(),
                      const SizedBox(width: 4),
                    ],
                    const _ToolsBadge(),
                  ],
                ),
              ),
          ],
          onChanged: _loading
              ? null
              : (preset) {
                  if (preset == null) return;
                  setState(() {
                    _webllmModel = preset;
                    _staleModelNote = null;
                  });
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
                  '${preset.displayName} · '
                  '${preset.sizeLabelFor(isWeb: kIsWeb)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _loading
              ? null
              : (preset) {
                  if (preset == null) return;
                  setState(() {
                    _gemmaModel = preset;
                    _staleModelNote = null;
                  });
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

  /// The on-device (transformers.js) replacement for the key/model/URL
  /// fields: a model picker over [transformersJsModelPresets], the
  /// offline/WebGPU note, and — while a load is in flight — the download
  /// progress bar. No token field: the ONNX repos are public.
  Widget _buildTransformersJsFields(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<TransformersJsModelPreset>(
          initialValue: _transformersJsModel,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'On-device model'),
          items: [
            for (final preset in transformersJsModelPresets)
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
                    if (preset.supportsVision) ...[
                      const _VisionBadge(),
                      const SizedBox(width: 4),
                    ],
                    const _ToolsBadge(),
                  ],
                ),
              ),
          ],
          onChanged: _loading
              ? null
              : (preset) {
                  if (preset == null) return;
                  setState(() {
                    _transformersJsModel = preset;
                    _staleModelNote = null;
                  });
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
                '(Chrome/Edge/newer Safari) · weights download once from '
                'HuggingFace (public repo, no token) and are cached in your '
                'browser',
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
                  helperText:
                      'Leave empty for local servers (llama.cpp, Ollama, '
                      'LM Studio)',
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
    this.lastConnectionStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
  });

  /// The service whose backend the form reconfigures.
  final AgentService service;

  /// The user-added providers shown in the form's picker.
  final ProviderRegistry? registry;

  /// The last-connection store: prefills the form and is updated on every
  /// successful apply (see [LastConnectionStore]).
  final LastConnectionStore? lastConnectionStore;

  /// Engine override for the downloaded-models section (tests); defaults to
  /// the platform singleton.
  final WebLlmEngineApi? webLlmEngine;

  /// Engine override for the on-device Gemma provider and its cache section
  /// (tests); defaults to the platform singleton.
  final GemmaEngineApi? gemmaEngine;

  /// Engine override for the on-device transformers.js provider and its
  /// cache section (tests); defaults to the platform singleton.
  final TransformersJsEngineApi? transformersJsEngine;

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
                initialConnection: lastConnectionStore?.connection,
                webLlmEngine: webLlmEngine,
                gemmaEngine: gemmaEngine,
                transformersJsEngine: transformersJsEngine,
                onConnect: (config) async {
                  await service.reconfigure(config);
                  await lastConnectionStore?.saveFromConfig(config);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              ApprovalModeSelector(service: service),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              WebLlmCacheSection(engine: webLlmEngine),
              // The transformers.js section is web-only (its provider is);
              // the Gemma section hides where its provider is unsupported —
              // on web the litert-lm path is abandoned in favour of
              // transformers.js, on desktop neither exists.
              if (transformersJsProviderSupported) ...[
                const SizedBox(height: 16),
                TransformersJsCacheSection(engine: transformersJsEngine),
              ],
              if (gemmaProviderSupported) ...[
                const SizedBox(height: 16),
                GemmaCacheSection(engine: gemmaEngine),
              ],
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

/// The small "coder" chip shown next to WebLLM presets that are
/// code-specialized ([WebLlmModelPreset.isCoder], the Qwen2.5-Coder family).
class _CoderBadge extends StatelessWidget {
  const _CoderBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'coder',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// The small "vision" chip shown next to transformers.js presets that load
/// a vision encoder and accept image inputs
/// ([TransformersJsModelPreset.supportsVision]).
class _VisionBadge extends StatelessWidget {
  const _VisionBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'vision',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }
}
