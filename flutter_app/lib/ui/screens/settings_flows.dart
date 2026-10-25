// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The settings connect/re-auth flow helpers (gh-1848 tier-3): part of
/// `settings.dart`'s library (gh-1232 god-file ceiling — the sweep's
/// extractions live here so the host file stays under the loc gate).
/// Extension members resolve statically inside the library, so the
/// callers in `settings.dart` are unchanged.
part of 'settings.dart';

/// Connect/re-auth/reset flow helpers of [_SettingsScreenState].
extension _SettingsFlowHelpers on _SettingsScreenState {
  /// The non-AIIN re-auth dispatch (gh-1848 tier-3 split): the Copilot
  /// connect flow for Copilot base URLs, the Codemie SSO flow otherwise.
  Future<bool> _reauthenticateOther(
    BuildContext context,
    ProviderRegistry registry,
    AgentService? service,
    CustomProvider provider,
  ) {
    if (isCopilotBaseUrl(provider.baseUrl)) {
      return runCopilotConnectFlow(
        context: context,
        registry: registry,
        service: service,
        lastConnectionStore: _fallbackConnectionStore(),
      );
    }
    return runCodemieSsoFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: _fallbackConnectionStore(),
      orgUrl: codeMieOrgUrl(provider.baseUrl),
    );
  }

  /// AIIN entries re-run the AIIN sign-in flow in re-auth mode
  /// (gh-1848 split).
  Future<bool> _reauthenticateAiin(
    BuildContext context,
    ProviderRegistry registry,
    AgentService? service,
    CustomProvider provider,
  ) {
    return runAiinConnectFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: _fallbackConnectionStore(),
      reauthenticateFor: provider,
    );
  }

  /// Runs one connect flow after a registry guard — the shared shape of
  /// the section's connect callbacks: a null registry renders the
  /// section but the flows do nothing (gh-1848 split).
  Future<void> _runConnectFlow(
    Future<void> Function(ProviderRegistry registry) run,
  ) async {
    final registry = widget.registry;
    if (registry == null) return;
    await run(registry);
  }
}

/// Build/connect/re-auth-flow helpers of the provider-connection form
/// (`_AgentSettingsFormState`, gh-1848 tier-4): part of `settings.dart`'s
/// library (gh-1232 god-file ceiling — the sweep's extractions live here
/// so the host file stays under the loc gate). Extension members resolve
/// statically inside the library, so the callers in `settings.dart` are
/// unchanged.
extension _SettingsFormFlowHelpers on _AgentSettingsFormState {
  // ─── build (gh-1848 tier-4) ──────────────────────────────────────────────

  /// The CORS note of the current selection; custom providers share the
  /// custom preset's note.
  String? _corsNoteFor(Object selection) => switch (selection) {
    ProviderPreset preset => preset.corsNote(context),
    _ => ProviderPreset.custom.corsNote(context),
  };

  /// Custom providers may run keyless (local servers); see _connect.
  bool get _keyIsOptional =>
      _selection is CustomProvider || _selection == ProviderPreset.custom;

  /// The provider-first flow header: the picker (visible unless a
  /// provider was forced — the on-device settings route locks to its
  /// engine: no provider list, no change-provider detour) and the
  /// change-provider link once a provider is picked.
  List<Widget> _buildProviderHeader() => [
    if (widget.initialProvider == null)
      ProviderSelectionList(
        selected: _selection,
        onSelect: (value) => _selectProvider(value),
        onAdd: _addProvider,
        registry: _registry,
        onEdit: (provider) => _editProvider(provider),
        isWeb: _isWeb,
      ),
    if (!_showProviderListOnly && widget.initialProvider == null) ...[
      const SizedBox(height: 12),
      _buildChangeProviderLink(),
      const SizedBox(height: 4),
    ],
  ];

  /// "Back to providers" link.
  Widget _buildChangeProviderLink() => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: () => _formSetState(() => _showProviderListOnly = true),
      icon: const Icon(Icons.arrow_back, size: 16),
      label: const Text(
        'Change provider',
      ), // l10n:ignore — prototype redesign ships en-only copy for now
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
  );

  /// The fields section of the picked provider kind: the on-device
  /// engines have dedicated pickers, the rest share the key/model/URL
  /// form.
  Widget _buildProviderConfigFields(
    ThemeData theme,
    Object selection,
    String? corsNote,
  ) {
    if (_isOnDevice) return _buildWebLlmFields(theme);
    if (_isGemma) return _buildGemmaFields(theme);
    if (_isTransformersJs) return _buildTransformersJsFields(theme);
    return _buildStandardFields(theme, selection, corsNote);
  }

  /// The hosted/custom form: API key, model id, vision, base URL, the
  /// key-storage note, and the info notes (CORS, stale model).
  Widget _buildStandardFields(
    ThemeData theme,
    Object selection,
    String? corsNote,
  ) => Column(
    children: [
      _buildApiKeyField(),
      if (selection == ProviderPreset.openrouter) ...[
        const SizedBox(height: 12),
        _buildOpenRouterButton(),
      ],
      const SizedBox(height: 12),
      _buildModelIdField(),
      _buildVisionCheckbox(),
      const SizedBox(height: 12),
      _buildBaseUrlField(),
      const SizedBox(height: 16),
      _buildKeyNoteRow(theme, selection),
      ..._buildConfigNotes(theme, corsNote),
    ],
  );

  Widget _buildApiKeyField() {
    final keyOptional = _keyIsOptional;
    return TextField(
      controller: _keyController,
      decoration: InputDecoration(
        labelText: keyOptional
            ? context.l10n.settingsApiKeyOptionalLabel
            : context.l10n.settingsApiKeyLabel,
        hintText: keyOptional ? null : context.l10n.settingsApiKeyHint,
        helperText: keyOptional ? context.l10n.settingsApiKeyLocalHelper : null,
      ),
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
    );
  }

  Widget _buildOpenRouterButton() => faui.OpenRouterOAuthButton(
    callbackUrl: _oauthCallbackUrl,
    onCapture: _captureOAuthCallback,
    onStoreVerifier: storeOpenRouterOAuthVerifier,
    onSuccess: (key) {
      _keyController.text = key;
      final keyName = faui.hostedProviderKeyName(ProviderPreset.openrouter);
      if (keyName != null) {
        widget.keysStore?.set(keyName, key);
      }
    },
  );

  Widget _buildModelIdField() => ModelIdAutocompleteField(
    controller: _modelController,
    focusNode: _modelFocusNode,
    models: _models.models,
    loading: _models.loading,
    fromBundledCatalog: _models.fromBundledCatalog,
  );

  Widget _buildVisionCheckbox() => CheckboxListTile(
    value: _vision,
    onChanged: (value) => _formSetState(() {
      _vision = value ?? false;
      _visionOverridden = true;
    }),
    title: Text(context.l10n.settingsVisionLabel),
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
  );

  Widget _buildBaseUrlField() => TextField(
    controller: _urlController,
    enabled: _hasEditableBaseUrl,
    decoration: InputDecoration(
      labelText: context.l10n.settingsBaseUrlLabel,
      helperText: _hasEditableBaseUrl
          ? context.l10n.settingsBaseUrlHelper
          : null,
    ),
  );

  Widget _buildKeyNoteRow(ThemeData theme, Object selection) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.primary),
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
  );

  List<Widget> _buildConfigNotes(ThemeData theme, String? corsNote) => [
    if (corsNote != null) _infoNote(theme, corsNote),
    if (_staleModelNote != null) _infoNote(theme, _staleModelNote!),
  ];

  Widget _infoNote(ThemeData theme, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.info_outline, size: 16, color: theme.colorScheme.tertiary),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
    ],
  );

  Widget _buildErrorText(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
  );

  Widget _buildConnectButton(ThemeData theme) => FilledButton(
    onPressed: _loading ? null : _connect,
    child: _connectButtonChild(theme),
  );

  Widget _connectButtonChild(ThemeData theme) =>
      _loading && !_isOnDevice && !_isGemma && !_isTransformersJs
      ? const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : _connectButtonLabel();

  Widget _connectButtonLabel() => Text(
    _loading
        ? context.l10n.settingsLoadingModel
        : widget.connectLabel ?? context.l10n.settingsStartChat,
  );

  // ─── _applyLastConnection (gh-1848 tier-4) ───────────────────────────────

  /// WebLLM record: Web-only; a record written on web must not resurrect
  /// the row on host platforms where the picker hides it.
  void _applyWebLlmLastConnection(LastConnection connection) {
    if (!webLlmProviderVisible(isWeb: _isWeb)) return;
    final preset = findWebLlmPreset(
      connection.webllmPresetId ?? connection.modelId,
    );
    if (preset == null) return;
    _selection = ProviderPreset.webllm;
    _webllmModel = preset;
    unawaited(_verifyWebLlmCache(preset));
  }

  /// Gemma record: the provider is iOS/Android/macOS-only — a record
  /// written there must not resurrect it where the picker hides it (a
  /// selection outside the dropdown's items breaks it).
  void _applyGemmaLastConnection(LastConnection connection) {
    if (!gemmaProviderVisible(isWeb: _isWeb, platform: defaultTargetPlatform)) {
      return;
    }
    final preset = findGemmaPreset(
      connection.gemmaPresetId ?? connection.modelId,
    );
    if (preset == null) return;
    _selection = ProviderPreset.gemma;
    _gemmaModel = preset;
    unawaited(_verifyGemmaInstalled(preset));
  }

  /// transformers.js record: web-only, like the picker entry.
  void _applyTransformersJsLastConnection(LastConnection connection) {
    if (!transformersJsProviderVisible(isWeb: _isWeb)) return;
    final preset = findTransformersJsPreset(
      connection.transformersJsPresetId ?? connection.modelId,
    );
    if (preset == null) return;
    _selection = ProviderPreset.transformersJs;
    _transformersJsModel = preset;
    unawaited(_verifyTransformersJsCache(preset));
  }

  /// Hosted/custom record: re-select the saved custom provider with the
  /// same endpoint+model when there is one, else fall back to the preset
  /// for the base URL and prefill model/key from it.
  void _applyHostedLastConnection(LastConnection connection) {
    final baseUrl = connection.baseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return;
    for (final provider in _registry.providers) {
      if (provider.baseUrl == baseUrl &&
          provider.modelId == connection.modelId) {
        // Use _applyCustomProvider so the key is loaded from the registry
        // (keychain on iOS/macOS, session memory otherwise).
        _applyCustomProvider(provider);
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
    _keyController.text = _prefillKeyForPreset(preset);
  }

  // ─── _connect (gh-1848 tier-4) ───────────────────────────────────────────

  /// The hosted connect: validate the form, flip into the loading state,
  /// hand the config to onConnect; analytics + the session key remember
  /// ride the success path, failures surface in [_SettingsScreenState._error].
  Future<void> _connectHosted() async {
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();
    final baseUrl = _urlController.text.trim();
    final errorText = _hostedValidationError(
      key: key,
      model: model,
      baseUrl: baseUrl,
    );
    if (errorText != null) {
      _formSetState(() => _error = errorText);
      return;
    }
    _formSetState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _connectHostedWith(key: key, model: model, baseUrl: baseUrl);
    } catch (e) {
      _showHostedConnectFailure(e);
    } finally {
      if (mounted) _formSetState(() => _loading = false);
    }
  }

  /// Custom providers may point at keyless local servers (llama.cpp,
  /// Ollama, LM Studio), so the key is optional for them; the hosted
  /// presets (OpenRouter, Ollama Cloud) keep requiring one.
  String? _hostedValidationError({
    required String key,
    required String model,
    required String baseUrl,
  }) {
    if (!_keyIsOptional && key.isEmpty) {
      return context.l10n.settingsApiKeyRequired;
    }
    if (model.isEmpty) return context.l10n.settingsModelIdRequired;
    if (baseUrl.isEmpty) return context.l10n.settingsBaseUrlRequired;
    return null;
  }

  Future<void> _connectHostedWith({
    required String key,
    required String model,
    required String baseUrl,
  }) async {
    AppAnalytics.instance.modelPickedFromSuggestions(
      fromSuggestions: _models.models.contains(model),
    );
    await widget.onConnect(
      AgentConfig(
        providerKind: 'openai-completions',
        modelId: model,
        baseUrl: baseUrl,
        apiKey: key,
        // Endpoint-reported limits (the /models quick-select fetch) win
        // over the catalog, the pinned fallback last (gh-1077 AC3).
        contextWindow:
            _models.contextWindows[model] ??
            resolveAppContextWindow(providerKind: 'openai-completions'),
        maxTokens: _models.maxTokens[model] ?? fallbackMaxTokens,
        supportsImages: _vision,
      ),
    );
    _onHostedConnectSuccess(key);
  }

  /// Connected: keep the key for this session so reopening settings (or
  /// re-picking the provider) prefills it. Never persisted.
  void _onHostedConnectSuccess(String key) {
    AppAnalytics.instance.connectResult(
      success: true,
      providerKind: 'openai-completions',
      isCustomProvider: _selection is CustomProvider,
      isOnDevice: false,
    );
    final selection = _selection;
    if (selection is CustomProvider) {
      _registry.rememberKey(selection.id, key);
    }
  }

  void _showHostedConnectFailure(Object e) {
    AppAnalytics.instance.connectResult(
      success: false,
      providerKind: 'openai-completions',
      isCustomProvider: _selection is CustomProvider,
      isOnDevice: false,
    );
    if (mounted) _formSetState(() => _error = e.toString());
  }
}
