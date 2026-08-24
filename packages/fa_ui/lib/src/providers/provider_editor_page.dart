// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ModelsEndpointFetcher;
import 'package:url_launcher/url_launcher.dart';

import 'package:fa_ui/src/chat/fa_glyphs.dart';
import 'package:fa_ui/src/providers/media_slot_picker_page.dart';
import 'package:fa_ui/src/providers/openrouter_oauth_button.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// Pushes the [ProviderEditorPage] in create mode and saves the result to
/// [registry] (definition + session key). Returns the added provider, or
/// null when cancelled. Shared by the Providers section, the
/// default-chat-model picker, and the media slot editor.
Future<CustomProvider?> pushProviderEditor(
  BuildContext context,
  ProviderRegistry registry, {
  required String title,
  ModelsEndpointFetcher? modelsFetcher,
}) async {
  final result = await pushFaPage<ProviderEditorResult>(
    context,
    ProviderEditorPage(title: title, modelsFetcher: modelsFetcher),
  );
  if (result == null || result.deleted) return null;
  final provider = await registry.add(
    name: result.name,
    baseUrl: result.baseUrl,
    modelId: result.modelId,
  );
  if (result.apiKey.isNotEmpty) {
    registry.rememberKey(provider.id, result.apiKey);
  }
  return provider;
}

/// The values collected by the [ProviderEditorPage].
///
/// [apiKey] is optional and write-only: when given it is remembered in
/// memory for the session (custom providers, see
/// [ProviderRegistry.rememberKey]) or written to the saved-keys store
/// (hosted presets) by the caller — the page itself stores nothing.
/// [deleted] marks the editor's Delete action (custom providers only).
final class ProviderEditorResult {
  /// Creates an editor result.
  const ProviderEditorResult({
    required this.name,
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
    this.deleted = false,
  });

  /// The Delete action result; all other fields are empty.
  const ProviderEditorResult.delete()
    : name = '',
      baseUrl = '',
      modelId = '',
      apiKey = '',
      deleted = true;

  /// Display name in the provider picker.
  final String name;

  /// OpenAI-compatible endpoint.
  final String baseUrl;

  /// Default model id (may be empty — a provider may have no model yet).
  final String modelId;

  /// The API key typed into the editor (may be empty = "keep/none").
  final String apiKey;

  /// True when the user chose Delete.
  final bool deleted;
}

/// The full-screen provider editor pushed from the settings Providers
/// section, the default-chat-model picker, the media slot editor, and the
/// setup form's add/edit actions.
///
/// Three modes:
///
/// - **create** ([preset] and [initial] null): collects a new
///   [CustomProvider] — name and base URL required, model id optional (a
///   provider may have no model yet), key optional.
/// - **edit** ([initial] set): edits that provider; the key field is
///   write-only — it starts empty and an empty save keeps the current key
///   ([hasSavedKey] shows a note). A Delete action pops
///   [ProviderEditorResult.delete].
/// - **preset** ([preset] set): a hosted preset (OpenRouter, Ollama Cloud,
///   Google Gemini)
///   — name/URL are read-only; the default model (seeded from the
///   registry's preset override when [registry] is given, falling back to
///   the preset's built-in default) and the key are editable.
///
/// Pops with a [ProviderEditorResult], or `null` when cancelled.
class ProviderEditorPage extends StatefulWidget {
  const ProviderEditorPage({
    super.key,
    required this.title,
    this.preset,
    this.initial,
    this.hasSavedKey = false,
    this.registry,
    this.onOAuthSuccess,
    this.openRouterOAuthCallbackUrl,
    this.openRouterOAuthCapture,
    this.prefillName,
    this.prefillBaseUrl,
    this.prefillModelId,
    this.keyHelpUrl,
    this.onReauthenticate,
    this.modelsFetcher,
  });

  /// App bar title (`Add provider` / `Edit provider` / the preset label).
  final String title;

  /// Hosted-preset view mode: the name field stays editable (the user names
  /// each instance — the same preset may be added several times) and the
  /// base-URL field is editable too, prefilled with the preset endpoint
  /// (self-hosted DIAL/Ollama/… instances point at their own URL).
  final ProviderPreset? preset;

  /// The provider being edited; `null` when adding a new one.
  final CustomProvider? initial;

  /// Whether a key is already stored for this provider (edit/preset modes):
  /// the write-only key field shows a "leave empty to keep it" note.
  final bool hasSavedKey;

  /// The provider registry: in preset mode the model field seeds from its
  /// preset-model override when one was saved.
  final ProviderRegistry? registry;

  /// Called when the OpenRouter OAuth flow succeeds. Only used when
  /// [preset] is [ProviderPreset.openrouter].
  final ValueChanged<String>? onOAuthSuccess;

  /// `callback_url` passed to the OpenRouter OAuth authorization URL. Used
  /// together with [openRouterOAuthCapture] for automatic callback capture.
  final String? openRouterOAuthCallbackUrl;

  /// Automatic callback capture for the OpenRouter OAuth flow. When provided,
  /// the button calls this instead of showing the manual code-paste sheet.
  final OpenRouterOAuthCaptureCallback? openRouterOAuthCapture;

  /// Editable prefills for key-based quick-add presets that are NOT a
  /// [ProviderPreset] member (Kimi Code, Z.AI — arbitrary custom dialect
  /// endpoints): the user renames each instance and may adjust the URL.
  final String? prefillName;

  /// See [prefillName].
  final String? prefillBaseUrl;

  /// See [prefillName].
  final String? prefillModelId;

  /// The provider's key console page, shown as a tappable "get the key"
  /// hint next to the API-key field; null hides it.
  final String? keyHelpUrl;

  /// Re-authentication action for SSO-backed providers (CodeMie), shown in
  /// edit mode only: re-runs the host's sign-in flow, which itself persists
  /// the refreshed credentials. Returns true when the flow completed — the
  /// editor then closes (its fields are stale by definition: the flow owns
  /// the save). Null hides the button.
  final Future<bool> Function(BuildContext context)? onReauthenticate;

  /// `/models` fetch override (tests), forwarded to the model selector the
  /// model row opens.
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<ProviderEditorPage> createState() => _ProviderEditorPageState();
}

class _ProviderEditorPageState extends State<ProviderEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _modelController;
  late final TextEditingController _keyController;

  String? _error;
  var _presetSeeded = false;
  var _reauthRunning = false;

  bool get _isPreset => widget.preset != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(
      text: initial?.name ?? widget.prefillName ?? '',
    );
    _urlController = TextEditingController(
      text: initial?.baseUrl ?? widget.prefillBaseUrl ?? '',
    );
    _modelController = TextEditingController(
      text: initial?.modelId ?? widget.prefillModelId ?? '',
    );
    // Write-only: the existing key is never shown.
    _keyController = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The preset's localized label needs the inherited strings, unavailable
    // in initState. Prefills in initState win over the preset defaults.
    if (!_presetSeeded) {
      _presetSeeded = true;
      final preset = widget.preset;
      if (preset != null) {
        if (_nameController.text.isEmpty) {
          _nameController.text = preset.labelFor(context);
        }
        if (_urlController.text.isEmpty) {
          _urlController.text = preset.baseUrl ?? '';
        }
        if (_modelController.text.isEmpty) {
          _modelController.text =
              widget.registry?.presetModelOverride(preset.name) ??
              preset.defaultModel;
        }
      }
    }
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
    final strings = FaUiStrings.of(context);
    final name = _nameController.text.trim();
    final baseUrl = _urlController.text.trim();
    final modelId = _modelController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = strings.settingsNameRequired);
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _error = strings.settingsBaseUrlRequired);
      return;
    }
    // The model id is optional: a provider may have no model yet (the
    // default-chat-model flow picks one later).
    Navigator.of(context).pop(
      ProviderEditorResult(
        name: name,
        baseUrl: baseUrl,
        modelId: modelId,
        apiKey: _keyController.text.trim(),
      ),
    );
  }

  Future<void> _delete() async {
    final initial = widget.initial;
    if (initial == null) return;
    final strings = FaUiStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.settingsDeleteProviderTitle(initial.name)),
        content: Text(strings.settingsDeleteProviderBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.settingsCancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.settingsDeleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(const ProviderEditorResult.delete());
  }

  Future<void> _reauthenticate() async {
    final action = widget.onReauthenticate;
    if (action == null || _reauthRunning) return;
    setState(() => _reauthRunning = true);
    try {
      final ok = await action(context);
      // The flow persisted the refreshed credentials itself; the editor's
      // fields are stale now, so a successful re-auth closes the page.
      if (ok && mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _reauthRunning = false);
    }
  }

  /// The key the model selector's `/models` fetch should authorize with:
  /// the freshly typed (unsaved) key wins; in preset mode an empty field
  /// means "the stored preset key", which the transient provider entry
  /// could not resolve on its own. Edit-mode custom providers resolve
  /// through their kept id inside the selector page, so no override.
  String? _modelFetchKeyOverride() {
    final typed = _keyController.text.trim();
    if (typed.isNotEmpty) return typed;
    final preset = widget.preset;
    if (preset == null) return null;
    final stored = resolveProviderKey(
      preset,
      registry: widget.registry,
      keysStore: SessionKeysScope.maybeOf(context),
    );
    return stored.isEmpty ? null : stored;
  }

  /// Opens the shared model selector for the CURRENT form values: the row
  /// never requires saving the provider first, so the page gets a transient
  /// entry built from the typed name/URL (keeping the edited provider's id
  /// so its stored key still resolves). Only the picked model id flows back
  /// into the form.
  Future<void> _pickModel() async {
    final result = await pushFaPage<MediaSlotEditorResult>(
      context,
      MediaSlotModelPage(
        slot: null,
        provider: CustomProvider(
          id: widget.initial?.id ?? 'editor-preview',
          name: _nameController.text.trim(),
          baseUrl: _urlController.text.trim(),
          modelId: _modelController.text.trim(),
        ),
        registry: widget.registry,
        initialModel: _modelController.text.trim(),
        apiKeyOverride: _modelFetchKeyOverride(),
        modelsFetcher: widget.modelsFetcher,
      ),
    );
    final picked = result?.override;
    if (!mounted || picked == null) return;
    setState(() => _modelController.text = picked.modelId);
  }

  /// The model row: a button-style entry (like the agent-role rows) showing
  /// the chosen model — or the choose hint — and opening the model selector.
  Widget _buildModelRow(ThemeData theme, FaUiStrings strings) {
    final model = _modelController.text.trim();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _pickModel,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            FaModelGlyph(size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isPreset
                        ? strings.settingsModelIdLabel
                        : strings.settingsModelIdOptionalLabel,
                  ),
                  Text(
                    model.isEmpty ? strings.settingsDefaultModelHint : model,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: model.isEmpty
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final preset = widget.preset;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: strings.settingsProviderNameLabel,
                  hintText: strings.settingsProviderNameHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: strings.settingsBaseUrlLabel,
                  hintText: 'https://example.com/v1',
                  helperText: strings.settingsBaseUrlHelper,
                ),
              ),
              const SizedBox(height: 12),
              _buildModelRow(theme, strings),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                decoration: InputDecoration(
                  labelText: strings.settingsApiKeyOptionalLabel,
                  helperText: widget.hasSavedKey
                      ? strings.settingsEditorKeepKeyNote
                      : strings.settingsApiKeyLocalHelper,
                  helperMaxLines: 3,
                ),
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
              ),
              if (widget.keyHelpUrl != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: () => launchUrl(Uri.parse(widget.keyHelpUrl!)),
                    child: Text(
                      widget.keyHelpUrl!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ],
              if (preset == ProviderPreset.openrouter) ...[
                const SizedBox(height: 12),
                OpenRouterOAuthButton(
                  callbackUrl: widget.openRouterOAuthCallbackUrl,
                  onCapture: widget.openRouterOAuthCapture,
                  onSuccess: (key) {
                    _keyController.text = key;
                    widget.onOAuthSuccess?.call(key);
                  },
                ),
              ],
              if (widget.initial != null &&
                  widget.onReauthenticate != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _reauthRunning ? null : _reauthenticate,
                  icon: _reauthRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(strings.settingsReauthenticateButton),
                ),
              ],
              const SizedBox(height: 12),
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
                      _isPreset
                          ? faKeyNoteHosted(strings)
                          : faEditorKeyNote(strings),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (preset?.corsNote(context) case final note?) ...[
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
                      child: Text(note, style: theme.textTheme.bodySmall),
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
                      onPressed: _delete,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: Text(strings.settingsDeleteButton),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
                    child: Text(strings.settingsSaveButton),
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
