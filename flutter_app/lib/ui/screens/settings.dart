import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa/gemma/gemma_cache_section.dart';
import 'package:fa/gemma/gemma_service.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/transformers_js/transformers_js_cache_section.dart';
import 'package:fa/transformers_js/transformers_js_service.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/services/vision_models.dart';
import 'package:fa/ui/screens/media_slot_picker_page.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/webllm/webllm_cache_section.dart';
import 'package:fa/webllm/webllm_service.dart';
import 'package:fa/webllm/webllm_types.dart';

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

/// Resolves a key default with the saved-keys store between `--dart-define`
/// and `.env` (overlay semantics, like `DotEnvSecretsStore`): an explicitly
/// saved key shadows the dev `.env`, a compile-time define shadows both.
String settingsKeyEnv(String name, SessionKeysStore? keysStore) {
  final dartValue = settingsDartDefines[name];
  if (dartValue != null && dartValue.isNotEmpty) return dartValue;
  final stored = keysStore?.valueOf(name);
  if (stored != null && stored.isNotEmpty) return stored;
  if (dotenv.isInitialized && dotenv.env.containsKey(name)) {
    return dotenv.env[name]!;
  }
  return '';
}

/// The key-storage notes match the platform: on iOS/macOS saved keys land
/// in the Keychain (see [KeychainStore]); elsewhere the session/app-sandbox
/// wording applies.
String settingsKeyNoteHostedFor(AppLocalizations l10n) =>
    KeychainStore.isSupported
    ? l10n.settingsKeyNoteHostedSecure
    : l10n.settingsKeyNoteHosted;

/// Custom-provider variant of [settingsKeyNoteHostedFor].
String settingsKeyNoteCustomFor(AppLocalizations l10n) =>
    KeychainStore.isSupported
    ? l10n.settingsKeyNoteCustomSecure
    : l10n.settingsKeyNoteCustom;

/// Provider-editor variant of [settingsKeyNoteHostedFor].
String settingsEditorKeyNoteFor(AppLocalizations l10n) =>
    KeychainStore.isSupported
    ? l10n.settingsEditorKeyNoteSecure
    : l10n.settingsEditorKeyNote;

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
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o-mini',
  ),
  ollamaCloud(baseUrl: 'https://ollama.com/v1', defaultModel: 'gpt-oss:120b'),
  custom(baseUrl: null, defaultModel: ''),
  webllm(baseUrl: null, defaultModel: ''),
  gemma(baseUrl: null, defaultModel: ''),
  transformersJs(baseUrl: null, defaultModel: '');

  const ProviderPreset({required this.baseUrl, required this.defaultModel});

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

  /// Short label shown in the provider picker.
  String labelFor(BuildContext context) => switch (this) {
    ProviderPreset.openrouter => context.l10n.settingsPresetOpenrouter,
    ProviderPreset.ollamaCloud => context.l10n.settingsPresetOllama,
    ProviderPreset.custom => context.l10n.settingsPresetCustom,
    ProviderPreset.webllm => context.l10n.settingsPresetWebllm,
    ProviderPreset.gemma => context.l10n.settingsPresetGemma,
    ProviderPreset.transformersJs => context.l10n.settingsPresetTransformersJs,
  };

  /// Shown under the form for providers that may reject browser (CORS)
  /// calls. OpenRouter allows cross-origin browser requests, so it has no
  /// note; other endpoints are not guaranteed to.
  String? corsNote(BuildContext context) => switch (this) {
    ProviderPreset.openrouter => null,
    ProviderPreset.ollamaCloud => context.l10n.settingsCorsNoteOllama,
    ProviderPreset.custom => context.l10n.settingsCorsNoteCustom,
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
/// in-chat [SettingsScreen].
///
/// The provider picker mixes the built-in [ProviderPreset]s with user-added
/// [CustomProvider]s from [registry]; "Add provider" saves a named
/// OpenAI-compatible endpoint (name, base URL, model id) that persists
/// across reloads (see [ProviderRegistry]). Keys typed into this form are
/// remembered in memory for the session only (see
/// [ProviderRegistry.rememberKey]); persisting a key is an explicit action
/// in the settings Keys section (see [SessionKeysStore]), and saved keys
/// prefill this form (see [AgentSettingsForm.keysStore]). The key is
/// optional for custom providers (built-in [ProviderPreset.custom] and
/// saved [CustomProvider]s) — local llama.cpp/Ollama/LM Studio servers need
/// none;
/// the hosted presets (OpenRouter, Ollama Cloud) still require one.
class AgentSettingsForm extends StatefulWidget {
  const AgentSettingsForm({
    super.key,
    required this.onConnect,
    this.connectLabel,
    this.registry,
    this.initialConnection,
    this.initialProvider,
    this.keysStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
    this.modelsFetcher,
  });

  /// Called with the assembled [AgentConfig]. Throw to surface an error in
  /// the form; return normally when the connection succeeded.
  final Future<void> Function(AgentConfig config) onConnect;

  /// Label of the primary button (`Start chat` on first run, `Apply` from
  /// the settings dialog). `null` falls back to the localized `Start chat`.
  final String? connectLabel;

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

  /// A provider preset to pre-select (the settings default-chat-model
  /// flow's on-device route), overriding the env-based defaults.
  /// [initialConnection], when also given, still wins.
  final ProviderPreset? initialProvider;

  /// The saved-keys store (see [SessionKeysStore]): key fields prefill from
  /// it when neither `--dart-define` nor `.env` provides a value. `null`
  /// keeps the env-only behavior (tests).
  final SessionKeysStore? keysStore;

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

  /// `/models` fetch override (tests); defaults to the production HTTP
  /// fetch + shared parser. Feeds the model quick select AND the
  /// connect-time limits.
  final ModelsEndpointFetcher? modelsFetcher;

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

  /// The endpoint's `/models` ids feeding the model field's quick select.
  /// Free text always stays valid (the field is a [RawAutocomplete]).
  List<String> _endpointModels = const [];

  /// Endpoint-reported per-model limits (see [parseModelsResponse]),
  /// applied to the [AgentConfig] at connect — same source of truth as the
  /// CLI's auto-correction instead of the hardcoded defaults.
  Map<String, int> _endpointContextWindows = const {};
  Map<String, int> _endpointMaxTokens = const {};
  var _modelsLoading = false;

  /// Stale-response guard: bumped per fetch, only the latest applies.
  var _modelsFetchGeneration = 0;
  Timer? _modelsFetchDebounce;

  /// The model field's focus node (drives the quick-select overlay).
  final FocusNode _modelFocusNode = FocusNode();

  bool _loading = false;
  String? _error;

  /// Whether the hosted model accepts image input (the "vision" checkbox).
  /// Initialized from the [modelIdSuggestsVision] heuristic and re-derived
  /// on every model-id edit until the user toggles it manually.
  bool _vision = false;
  bool _visionOverridden = false;

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
      text: settingsKeyEnv('OPENROUTER_API_KEY', widget.keysStore),
    );
    _lastDefaultModel = _presetDefaultModel(preset);
    _modelController = TextEditingController(
      text: settingsEnv('MODEL_ID', _presetDefaultModel(preset)),
    );
    _vision = modelIdSuggestsVision(_modelController.text);
    _modelController.addListener(_onModelIdChanged);
    _urlController = TextEditingController(text: initialUrl);
    _hfTokenController = TextEditingController(
      text: settingsKeyEnv('HUGGINGFACE_TOKEN', widget.keysStore),
    );
    // The last connection wins over the env-based defaults; the key field is
    // never touched (keys are session-only and never persisted).
    final forcedProvider = widget.initialProvider;
    if (forcedProvider != null) _applyPreset(forcedProvider);
    final connection = widget.initialConnection;
    if (connection != null) _applyLastConnection(connection);
    // The endpoint's model list feeds the model field's quick select;
    // endpoint/key edits refetch (debounced).
    _urlController.addListener(_scheduleModelsFetch);
    _keyController.addListener(_scheduleModelsFetch);
    _scheduleModelsFetch();
  }

  void _onModelIdChanged() {
    if (_visionOverridden) return;
    final suggested = modelIdSuggestsVision(_modelController.text);
    if (suggested != _vision) setState(() => _vision = suggested);
  }

  /// Debounced refetch of the endpoint's model list for the quick select.
  void _scheduleModelsFetch() {
    _modelsFetchDebounce?.cancel();
    _modelsFetchDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_fetchEndpointModels());
    });
  }

  /// Fetches `<baseUrl>/models` (OpenAI shape) for the model field's quick
  /// select. Silent on failure — free-text entry always works, the field
  /// just loses its suggestions.
  Future<void> _fetchEndpointModels() async {
    if (_isOnDevice || _isGemma || _isTransformersJs) return;
    final baseUrl = _urlController.text.trim();
    if (baseUrl.isEmpty) return;
    final generation = ++_modelsFetchGeneration;
    if (mounted) setState(() => _modelsLoading = true);
    try {
      final key = _keyController.text.trim();
      final fetch = widget.modelsFetcher ?? defaultModelsEndpointFetcher;
      final (ids, windows, caps) = await fetch(baseUrl, apiKey: key);
      if (!mounted || generation != _modelsFetchGeneration) return;
      setState(() {
        _endpointModels = ids;
        _endpointContextWindows = windows;
        _endpointMaxTokens = caps;
      });
      AppAnalytics.instance.modelsFetchResult(ids.length);
    } on Object {
      if (mounted && generation == _modelsFetchGeneration) {
        setState(() {
          _endpointModels = const [];
          _endpointContextWindows = const {};
          _endpointMaxTokens = const {};
        });
      }
    } finally {
      if (mounted && generation == _modelsFetchGeneration) {
        setState(() => _modelsLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _gemmaVerifyTimer?.cancel();
    _modelsFetchDebounce?.cancel();
    _modelFocusNode.dispose();
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

  /// The default model of [preset]: the registry's saved preset-model
  /// override when there is one, the preset's built-in default otherwise.
  String _presetDefaultModel(ProviderPreset preset) =>
      _registry.presetModelOverride(preset.name) ?? preset.defaultModel;

  void _applyPreset(ProviderPreset preset) {
    _selection = preset;
    _visionOverridden = false;
    final baseUrl = preset.baseUrl;
    if (baseUrl != null) {
      _urlController.text = baseUrl;
    }
    // Follow the preset's default model only while the user has not typed
    // a custom one (still empty or equal to the previous default).
    final defaultModel = _presetDefaultModel(preset);
    final current = _modelController.text.trim();
    if (current.isEmpty || current == _lastDefaultModel) {
      _modelController.text = defaultModel;
    }
    _lastDefaultModel = defaultModel;
    _staleModelNote = null;
    _error = null;
  }

  void _applyCustomProvider(CustomProvider provider) {
    _selection = provider;
    _visionOverridden = false;
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
            : _presetDefaultModel(preset);
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
      _staleModelNote = context.l10n.settingsStaleModelCache(
        preset.displayName,
      );
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
      _staleModelNote = context.l10n.settingsStaleModelDevice(
        preset.displayName,
      );
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
      _staleModelNote = context.l10n.settingsStaleModelCache(
        preset.displayName,
      );
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
    final result = await Navigator.of(context).push<ProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) =>
            ProviderEditorPage(title: context.l10n.settingsAddProvider),
      ),
    );
    if (result == null || result.deleted) return;
    final provider = await _registry.add(
      name: result.name,
      baseUrl: result.baseUrl,
      modelId: result.modelId,
    );
    if (result.apiKey.isNotEmpty) {
      _registry.rememberKey(provider.id, result.apiKey);
    }
    setState(() => _applyCustomProvider(provider));
    AppAnalytics.instance.providerSaved('add');
  }

  Future<void> _editProvider() async {
    final selection = _selection;
    if (selection is! CustomProvider) return;
    final result = await Navigator.of(context).push<ProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) => ProviderEditorPage(
          title: context.l10n.settingsEditProviderTitle,
          initial: selection,
          hasSavedKey: (_registry.keyFor(selection.id) ?? '').isNotEmpty,
        ),
      ),
    );
    if (result == null) return;
    if (result.deleted) {
      // _onRegistryChanged resets the selection to OpenRouter.
      await _registry.remove(selection.id);
      AppAnalytics.instance.providerSaved('delete');
      return;
    }
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
    AppAnalytics.instance.providerSaved('edit');
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
      setState(() => _error = context.l10n.settingsApiKeyRequired);
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = context.l10n.settingsModelIdRequired);
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _error = context.l10n.settingsBaseUrlRequired);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      AppAnalytics.instance.modelPickedFromSuggestions(
        fromSuggestions: _endpointModels.contains(model),
      );
      await widget.onConnect(
        AgentConfig(
          providerKind: 'openai-completions',
          modelId: model,
          baseUrl: baseUrl,
          apiKey: key,
          // Endpoint-reported limits (the /models quick-select fetch) win
          // over the shared fallbacks — same correction as the CLI.
          contextWindow:
              _endpointContextWindows[model] ?? fallbackContextWindow,
          maxTokens: _endpointMaxTokens[model] ?? fallbackMaxTokens,
          supportsImages: _vision,
        ),
      );
      AppAnalytics.instance.connectResult(
        success: true,
        providerKind: 'openai-completions',
        isCustomProvider: _selection is CustomProvider,
        isOnDevice: false,
      );
      // Connected: keep the key for this session so reopening settings (or
      // re-picking the provider) prefills it. Never persisted.
      final selection = _selection;
      if (selection is CustomProvider) {
        _registry.rememberKey(selection.id, key);
      }
    } catch (e) {
      AppAnalytics.instance.connectResult(
        success: false,
        providerKind: 'openai-completions',
        isCustomProvider: _selection is CustomProvider,
        isOnDevice: false,
      );
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
          supportsImages: preset.supportsVision,
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
      ProviderPreset preset => preset.corsNote(context),
      // Custom providers share the custom preset's CORS note.
      _ => ProviderPreset.custom.corsNote(context),
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
          decoration: InputDecoration(
            labelText: context.l10n.settingsProviderLabel,
          ),
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
                DropdownMenuItem(
                  value: preset,
                  child: Text(preset.labelFor(context)),
                ),
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
              label: Text(context.l10n.settingsAddProvider),
            ),
            if (selection is CustomProvider) ...[
              TextButton(
                onPressed: _loading ? null : _editProvider,
                child: Text(context.l10n.settingsEditButton),
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
              labelText: keyOptional
                  ? context.l10n.settingsApiKeyOptionalLabel
                  : context.l10n.settingsApiKeyLabel,
              hintText: keyOptional ? null : context.l10n.settingsApiKeyHint,
              helperText: keyOptional
                  ? context.l10n.settingsApiKeyLocalHelper
                  : null,
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          ModelIdAutocompleteField(
            controller: _modelController,
            focusNode: _modelFocusNode,
            models: _endpointModels,
            loading: _modelsLoading,
          ),
          CheckboxListTile(
            value: _vision,
            onChanged: (value) => setState(() {
              _vision = value ?? false;
              _visionOverridden = true;
            }),
            title: Text(context.l10n.settingsVisionLabel),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            enabled: _hasEditableBaseUrl,
            decoration: InputDecoration(
              labelText: context.l10n.settingsBaseUrlLabel,
              helperText: _hasEditableBaseUrl
                  ? context.l10n.settingsBaseUrlHelper
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
                      ? settingsKeyNoteCustomFor(context.l10n)
                      : settingsKeyNoteHostedFor(context.l10n),
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
              : Text(
                  _loading
                      ? context.l10n.settingsLoadingModel
                      : widget.connectLabel ?? context.l10n.settingsStartChat,
                ),
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
          decoration: InputDecoration(
            labelText: context.l10n.settingsOnDeviceModelLabel,
          ),
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
                context.l10n.settingsWebllmNote,
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
                : context.l10n.settingsDownloadingWeights,
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
          decoration: InputDecoration(
            labelText: context.l10n.settingsOnDeviceModelLabel,
          ),
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
          decoration: InputDecoration(
            labelText: context.l10n.settingsHfTokenLabel,
            hintText: context.l10n.settingsHfTokenHint,
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
                : context.l10n.settingsDownloadingWeights,
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
          decoration: InputDecoration(
            labelText: context.l10n.settingsOnDeviceModelLabel,
          ),
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
                context.l10n.settingsTransformersJsNote,
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
                : context.l10n.settingsDownloadingWeights,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// The settings "Theme" section: a dropdown over [FahThemeMode] bound to the
/// app-wide [ThemeController] (explicit [controller], else the nearest
/// [FahThemeScope]). Hidden when no controller is available (tests pumping
/// the bare form).
class ThemeModeSection extends StatelessWidget {
  const ThemeModeSection({super.key, this.controller});

  /// Controller override; falls back to the nearest [FahThemeScope].
  final ThemeController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = this.controller ?? FahThemeScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.settingsThemeLabel,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<FahThemeMode>(
              // The key forces the FormField to re-seed when the mode is
              // changed from elsewhere.
              key: ValueKey<FahThemeMode>(controller.mode),
              initialValue: controller.mode,
              isExpanded: true,
              items: [
                DropdownMenuItem(
                  value: FahThemeMode.system,
                  child: Text(context.l10n.settingsThemeSystem),
                ),
                DropdownMenuItem(
                  value: FahThemeMode.light,
                  child: Text(context.l10n.settingsThemeLight),
                ),
                DropdownMenuItem(
                  value: FahThemeMode.dark,
                  child: Text(context.l10n.settingsThemeDark),
                ),
              ],
              onChanged: (mode) {
                if (mode != null) controller.setMode(mode);
              },
            ),
          ],
        );
      },
    );
  }
}

/// The settings "Keys" section: lists the known key names
/// ([knownKeyNames] plus anything saved) and every custom provider with a
/// remembered session key, each with its source (`env file` / `saved` /
/// `this session`) and set/delete actions. The "Add key" action saves an
/// arbitrary named key (see [AddKeyDialog]) — saved names are advertised to
/// the agent as available `$NAME` env vars. Values are never displayed;
/// saving happens only on an explicit Set here (keys typed into the
/// connection form stay session-only, see [ProviderRegistry.rememberKey]).
///
/// The store comes from [store] or the nearest [SessionKeysScope]; the
/// whole section hides when neither a store nor a registry is available.
class KeysSection extends StatelessWidget {
  const KeysSection({super.key, this.store, this.registry});

  /// Store override; falls back to the nearest [SessionKeysScope].
  final SessionKeysStore? store;

  /// The provider registry, for the per-provider session-key rows.
  final ProviderRegistry? registry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = this.store ?? SessionKeysScope.maybeOf(context);
    final registry = this.registry;
    if (store == null && registry == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([?store, ?registry]),
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.keysSectionTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (store != null)
                  TextButton.icon(
                    onPressed: () => _addKey(context, store),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(context.l10n.keysAddButton),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.keysSectionNote,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (store != null)
              for (final name in _listedNames(store))
                _buildKeyRow(
                  context,
                  theme,
                  title: name,
                  source: _sourceFor(context, store, name),
                  onSet: () => _setStoredKey(context, store, name),
                  onDelete: store.has(name)
                      ? () => _deleteStoredKey(context, store, name)
                      : null,
                ),
            if (registry != null)
              for (final provider in registry.providers)
                if ((registry.keyFor(provider.id) ?? '').isNotEmpty)
                  _buildKeyRow(
                    context,
                    theme,
                    title: provider.name,
                    source: context.l10n.keysSourceProviderSession,
                    onSet: () => _setProviderKey(context, registry, provider),
                    onDelete: () => registry.rememberKey(provider.id, ''),
                  ),
          ],
        );
      },
    );
  }

  /// [knownKeyNames] first, then any extra saved names, sorted.
  static List<String> _listedNames(SessionKeysStore store) => [
    ...knownKeyNames,
    ...store.names.where((name) => !knownKeyNames.contains(name)),
  ];

  static String _sourceFor(
    BuildContext context,
    SessionKeysStore store,
    String name,
  ) {
    final hasSaved = store.has(name);
    final hasEnv = settingsEnv(name, '').isNotEmpty;
    if (hasSaved && hasEnv) {
      return '${context.l10n.keysSourceSaved} · ${context.l10n.keysSourceEnv}';
    }
    if (hasSaved) return context.l10n.keysSourceSaved;
    if (hasEnv) return context.l10n.keysSourceEnv;
    return context.l10n.keysSourceNone;
  }

  Widget _buildKeyRow(
    BuildContext context,
    ThemeData theme, {
    required String title,
    required String source,
    VoidCallback? onSet,
    VoidCallback? onDelete,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: FahPalette.mono(
                    color: theme.colorScheme.onSurface,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(source, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (onSet != null)
            TextButton(
              onPressed: onSet,
              child: Text(context.l10n.keysSetButton),
            ),
          if (onDelete != null)
            IconButton(
              tooltip: context.l10n.commonDelete,
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _setStoredKey(
    BuildContext context,
    SessionKeysStore store,
    String name,
  ) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) =>
          KeyEditorDialog(title: context.l10n.keysSetDialogTitle(name)),
    );
    if (value == null || value.isEmpty) return;
    await store.set(name, value);
    AppAnalytics.instance.keyAction('set', name);
  }

  /// Opens the add-key dialog for an arbitrary key name (e.g.
  /// `GITHUB_TOKEN`) so the agent can reference it as `$NAME` in shell
  /// commands; the saved names are listed in the agent's system prompt.
  Future<void> _addKey(BuildContext context, SessionKeysStore store) async {
    final entry = await showDialog<({String name, String value})>(
      context: context,
      builder: (_) => AddKeyDialog(isDuplicate: _isListedName(store)),
    );
    if (entry == null) return;
    await store.set(entry.name, entry.value);
  }

  /// Names that already have a row: the known names plus everything saved.
  static bool Function(String) _isListedName(SessionKeysStore store) =>
      (name) => knownKeyNames.contains(name) || store.has(name);

  Future<void> _deleteStoredKey(
    BuildContext context,
    SessionKeysStore store,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.keysDeleteTitle(name)),
        content: Text(context.l10n.keysDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.delete(name);
    AppAnalytics.instance.keyAction('delete', name);
  }

  Future<void> _setProviderKey(
    BuildContext context,
    ProviderRegistry registry,
    CustomProvider provider,
  ) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => KeyEditorDialog(
        title: context.l10n.keysSetDialogTitle(provider.name),
      ),
    );
    if (value == null || value.isEmpty) return;
    registry.rememberKey(provider.id, value);
  }
}

/// The set-key dialog opened from [KeysSection]: collects a replacement
/// value for a named key. Pops with the entered value, or `null` when
/// cancelled or empty (an empty value never overwrites — use delete).
class KeyEditorDialog extends StatefulWidget {
  const KeyEditorDialog({super.key, required this.title});

  /// Dialog title (`Set OPENROUTER_API_KEY`).
  final String title;

  @override
  State<KeyEditorDialog> createState() => _KeyEditorDialogState();
}

class _KeyEditorDialogState extends State<KeyEditorDialog> {
  final TextEditingController _valueController = TextEditingController();

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: _dialogContentWidth(context, 380),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: context.l10n.keysValueLabel,
                hintText: context.l10n.keysValueHint,
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: _save,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.keysSectionNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        ListenableBuilder(
          listenable: _valueController,
          builder: (context, _) => FilledButton(
            onPressed: _valueController.text.trim().isEmpty
                ? null
                : () => _save(_valueController.text),
            child: Text(context.l10n.settingsSaveButton),
          ),
        ),
      ],
    );
  }

  void _save(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(trimmed);
  }
}

/// The add-key dialog opened from [KeysSection]: collects an arbitrary key
/// name (validated against [namePattern], uppercase-normalized, duplicates
/// rejected via [isDuplicate]) plus its (obscured) value. Pops with the
/// `(name, value)` record, or `null` when cancelled.
class AddKeyDialog extends StatefulWidget {
  const AddKeyDialog({super.key, required this.isDuplicate});

  /// The accepted name shape (shell-env style, e.g. `GITHUB_TOKEN`).
  static final RegExp namePattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

  /// Whether a (normalized) name already has a row in the Keys section.
  final bool Function(String name) isDuplicate;

  @override
  State<AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<AddKeyDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();

  /// The validation error under the name field; `null` while valid/untried.
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.keysAddDialogTitle),
      content: SizedBox(
        width: _dialogContentWidth(context, 380),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: context.l10n.keysAddNameLabel,
                hintText: context.l10n.keysAddNameHint,
                errorText: _nameError,
              ),
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              onChanged: (_) => setState(() => _nameError = null),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: context.l10n.keysValueLabel,
                hintText: context.l10n.keysValueHint,
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_nameController, _valueController]),
          builder: (context, _) => FilledButton(
            onPressed:
                _nameController.text.trim().isEmpty ||
                    _valueController.text.trim().isEmpty
                ? null
                : _save,
            child: Text(context.l10n.settingsSaveButton),
          ),
        ),
      ],
    );
  }

  void _save() {
    final name = _nameController.text.trim().toUpperCase();
    final value = _valueController.text.trim();
    if (value.isEmpty) return;
    if (!AddKeyDialog.namePattern.hasMatch(name)) {
      setState(() => _nameError = context.l10n.keysAddNameInvalid);
      return;
    }
    if (widget.isDuplicate(name)) {
      setState(() => _nameError = context.l10n.keysAddNameDuplicate);
      return;
    }
    Navigator.of(context).pop((name: name, value: value));
  }
}

/// The settings "Media models" section: one row per [MediaSlot] showing the
/// effective endpoint — the slot's override (`model · host`) or the main
/// connection fallback. Tapping a row pushes the two-step flow
/// ([MediaSlotProviderPickerPage] → [MediaSlotModelPage]); picking "Same as
/// main connection" removes the override, restoring the fallback.
///
/// The store comes from [store] or the nearest [MediaModelsScope]; the whole
/// section hides when no store is available (tests pumping the bare form).
/// [service] supplies the main connection's base URL for the editor's
/// placeholder/default.
class MediaModelsSection extends StatelessWidget {
  const MediaModelsSection({
    super.key,
    this.store,
    this.service,
    this.registry,
    this.modelsFetcher,
  });

  /// Store override; falls back to the nearest [MediaModelsScope].
  final MediaModelsStore? store;

  /// The active connection, for the editor's base-URL placeholder/default.
  final AgentService? service;

  /// The provider registry: slot rows summarize overrides with the
  /// provider NAME (never the URL), and the slot editor lists the saved
  /// custom providers. `null` summarizes unknown URLs by host.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the editor page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// The icon each slot's row (and the model preset combo summary) shows.
  static const slotIcons = <String, IconData>{
    MediaSlot.imageGeneration: Icons.image_outlined,
    MediaSlot.audioTts: Icons.record_voice_over_outlined,
    MediaSlot.musicGeneration: Icons.music_note_outlined,
    MediaSlot.videoGeneration: Icons.videocam_outlined,
    MediaSlot.vision: Icons.visibility_outlined,
    MediaSlot.transcription: Icons.transcribe_outlined,
  };

  /// The localized label for [slot] (the raw name for unknown slots).
  static String slotLabelFor(AppLocalizations l10n, String slot) =>
      switch (slot) {
        MediaSlot.imageGeneration => l10n.mediaModelsSlotImageGeneration,
        MediaSlot.audioTts => l10n.mediaModelsSlotAudioTts,
        MediaSlot.musicGeneration => l10n.mediaModelsSlotMusicGeneration,
        MediaSlot.videoGeneration => l10n.mediaModelsSlotVideoGeneration,
        MediaSlot.vision => l10n.mediaModelsSlotVision,
        MediaSlot.transcription => l10n.mediaModelsSlotTranscription,
        _ => slot,
      };

  /// The host part of [baseUrl] for the row summary (the raw string when it
  /// does not parse as a URI with a host).
  static String _hostOf(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    return host.isEmpty ? baseUrl : host;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = this.store ?? MediaModelsScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.mediaModelsSectionTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.mediaModelsSectionNote,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final slot in MediaSlot.all)
              _buildSlotRow(context, theme, store, slot),
          ],
        );
      },
    );
  }

  Widget _buildSlotRow(
    BuildContext context,
    ThemeData theme,
    MediaModelsStore store,
    String slot,
  ) {
    final override = store.overrideFor(slot);
    // Overrides are summarized with the provider NAME, never the raw URL;
    // an override whose URL matches no known provider falls back to the
    // host (a hand-edited store file).
    final provider = override == null
        ? null
        : providerForBaseUrl(override.baseUrl, registry);
    final summary = override == null
        ? context.l10n.mediaModelsFallbackSummary
        : context.l10n.mediaModelsOverrideSummary(
            provider != null
                ? providerDisplayName(context, provider)
                : _hostOf(override.baseUrl),
            override.modelId,
          );
    return InkWell(
      onTap: () => _editSlot(context, store, slot),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              slotIcons[slot] ?? Icons.tune,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(slotLabelFor(context.l10n, slot)),
                  Text(
                    summary,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
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
    );
  }

  Future<void> _editSlot(
    BuildContext context,
    MediaModelsStore store,
    String slot,
  ) async {
    final result = await Navigator.of(context).push<MediaSlotEditorResult>(
      MaterialPageRoute(
        builder: (_) => MediaSlotProviderPickerPage(
          slot: slot,
          title: context.l10n.mediaModelsEditTitle(
            slotLabelFor(context.l10n, slot),
          ),
          initial: store.overrideFor(slot),
          mainBaseUrl: service?.activeBaseUrl ?? '',
          registry: registry,
          modelsFetcher: modelsFetcher,
        ),
      ),
    );
    if (result == null) return;
    await store.setOverride(slot, result.cleared ? null : result.override);
  }
}

/// The gear-icon screen from the chat screen (also opened from the session
/// sidebar's model tile): providers-first — the Providers section (hosted
/// presets + saved custom providers, the current one marked), the Default
/// chat model flow (pick a provider, pick its model → the main connection
/// is reconfigured), per-slot media model overrides, theme, keys, approval
/// mode, and the on-device model caches.
/// Applying a chat model swaps the backend of [service] via
/// [AgentService.reconfigure] — the visible transcript, the sandbox
/// filesystem, and the current session all survive.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.service,
    this.registry,
    this.lastConnectionStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.modelsFetcher,
  });

  /// The service whose backend the default-chat-model flow reconfigures.
  final AgentService service;

  /// The user-added providers shown in the Providers section and the
  /// pickers.
  final ProviderRegistry? registry;

  /// The last-connection store: updated on every successful apply (see
  /// [LastConnectionStore]).
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

  /// `/models` fetch override (tests), forwarded to the default-chat-model
  /// flow and the media slot editor.
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProvidersSection(service: service, registry: registry),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              DefaultChatModelSection(
                service: service,
                registry: registry,
                lastConnectionStore: lastConnectionStore,
                modelsFetcher: modelsFetcher,
                webLlmEngine: webLlmEngine,
                gemmaEngine: gemmaEngine,
                transformersJsEngine: transformersJsEngine,
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              ModelPresetsSection(
                service: service,
                lastConnectionStore: lastConnectionStore,
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              MediaModelsSection(
                service: service,
                registry: registry,
                modelsFetcher: modelsFetcher,
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              const ThemeModeSection(),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              KeysSection(registry: registry),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              ApprovalModeSelector(service: service),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              WebLlmCacheSection(engine: webLlmEngine),
              // The transformers.js section is web-only (its provider is);
              // the Gemma section hides where its provider is unsupported —
              // on web the litert-lm path is abandoned in favour of
              // transformers.js, on desktop neither exists.
              if (transformersJsProviderSupported) ...[
                const SizedBox(height: 24),
                TransformersJsCacheSection(engine: transformersJsEngine),
              ],
              if (gemmaProviderSupported) ...[
                const SizedBox(height: 24),
                GemmaCacheSection(engine: gemmaEngine),
              ],
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              const DebugLogsSection(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// The settings "Debug logs" row: copies the in-app debug log ([AppLog] —
/// the tee'd `debugPrint` traffic plus tagged subsystem logs) to the
/// clipboard so the user can paste it into a bug report. Deliberately
/// quiet: one icon-button row at the bottom of the screen.
class DebugLogsSection extends StatelessWidget {
  const DebugLogsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.bug_report_outlined),
          tooltip: context.l10n.settingsCopyDebugLogs,
          onPressed: () => _copyLogs(context),
        ),
        Expanded(
          child: Text(
            context.l10n.settingsCopyDebugLogs,
            style: TextStyle(color: colors.dim, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Future<void> _copyLogs(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: AppLog.dump()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.settingsDebugLogsCopied)),
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
        context.l10n.settingsToolsBadge,
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
        context.l10n.settingsCoderBadge,
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
        context.l10n.settingsVisionBadge,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// The model-id field with the `/models` quick select shared by the
/// connection form, the media slot editor, and the default-chat-model
/// picker: a free-text field whose autocomplete options are the endpoint's
/// model ids, filtered by the typed text (any custom id stays valid).
/// While [loading] the field shows the fetching helper and a spinner.
class ModelIdAutocompleteField extends StatelessWidget {
  const ModelIdAutocompleteField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.models,
    required this.loading,
  });

  /// The model id being edited (also receives the picked option).
  final TextEditingController controller;

  /// The field's focus node (drives the quick-select overlay).
  final FocusNode focusNode;

  /// The endpoint's `/models` ids feeding the quick select.
  final List<String> models;

  /// Whether a `/models` fetch is in flight.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focusNode,
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return models;
        return models.where((id) => id.toLowerCase().contains(query));
      },
      onSelected: (id) => controller.text = id,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: context.l10n.settingsModelIdLabel,
            helperText: loading ? context.l10n.settingsModelsFetching : null,
            suffixIcon: loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 440),
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
    );
  }
}
