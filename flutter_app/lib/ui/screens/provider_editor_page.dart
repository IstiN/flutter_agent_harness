// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/screens/settings.dart';

/// The secure-store key name backing a hosted preset's API key (the same
/// names the Keys section lists and [settingsKeyEnv] resolves). `null` for
/// presets without an endpoint key (custom, on-device).
String? hostedProviderKeyName(ProviderPreset preset) => switch (preset) {
  ProviderPreset.openrouter => 'OPENROUTER_API_KEY',
  ProviderPreset.ollamaCloud => 'OLLAMA_API_KEY',
  _ => null,
};

/// The hosted endpoint presets listed by the Providers section, the
/// default-chat-model picker, and the media slot editor (the ad-hoc
/// `custom` preset is covered by "Add provider"; on-device presets have no
/// endpoint to manage).
const hostedProviderPresets = [
  ProviderPreset.openrouter,
  ProviderPreset.ollamaCloud,
];

/// The display name of a provider entry (a [ProviderPreset] or a
/// [CustomProvider]) for list rows and summaries.
String providerDisplayName(BuildContext context, Object provider) =>
    switch (provider) {
      ProviderPreset preset => preset.labelFor(context),
      CustomProvider custom => custom.name,
      _ => provider.toString(),
    };

/// The hosted preset or saved custom provider serving [baseUrl], if any
/// (presets win over custom providers on an exact match).
Object? providerForBaseUrl(String baseUrl, ProviderRegistry? registry) {
  for (final preset in hostedProviderPresets) {
    if (preset.baseUrl == baseUrl) return preset;
  }
  for (final provider in registry?.providers ?? const <CustomProvider>[]) {
    if (provider.baseUrl == baseUrl) return provider;
  }
  return null;
}

/// The API key a connection through [provider] resolves to, exactly like
/// the connection form: custom providers use the remembered session key
/// (Keychain-backed where supported), hosted presets resolve their named
/// key from dart-defines / the saved-keys store / `.env`. Empty means
/// "no credential" — fine for keyless local endpoints.
String resolveProviderKey(
  Object provider, {
  ProviderRegistry? registry,
  SessionKeysStore? keysStore,
}) {
  return switch (provider) {
    CustomProvider custom => registry?.keyFor(custom.id) ?? '',
    ProviderPreset preset => () {
      final name = hostedProviderKeyName(preset);
      return name == null ? '' : settingsKeyEnv(name, keysStore);
    }(),
    _ => '',
  };
}

/// The host part of [baseUrl] for row summaries (the raw string when it
/// does not parse as a URI with a host).
String providerHostOf(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host ?? '';
  return host.isEmpty ? baseUrl : host;
}

/// Pushes the [ProviderEditorPage] in create mode and saves the result to
/// [registry] (definition + session key). Returns the added provider, or
/// null when cancelled. Shared by the Providers section, the
/// default-chat-model picker, and the media slot editor.
Future<CustomProvider?> pushProviderEditor(
  BuildContext context,
  ProviderRegistry registry, {
  required String title,
}) async {
  final result = await Navigator.of(context).push<ProviderEditorResult>(
    MaterialPageRoute(builder: (_) => ProviderEditorPage(title: title)),
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
/// setup form's add/edit actions (replacing the old dialog).
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
/// - **preset** ([preset] set): a hosted preset (OpenRouter, Ollama Cloud)
///   — name/URL/model are read-only, only the key is editable.
///
/// Pops with a [ProviderEditorResult], or `null` when cancelled.
class ProviderEditorPage extends StatefulWidget {
  const ProviderEditorPage({
    super.key,
    required this.title,
    this.preset,
    this.initial,
    this.hasSavedKey = false,
  });

  /// App bar title (`Add provider` / `Edit provider` / the preset label).
  final String title;

  /// Hosted-preset view mode: the fixed fields render read-only.
  final ProviderPreset? preset;

  /// The provider being edited; `null` when adding a new one.
  final CustomProvider? initial;

  /// Whether a key is already stored for this provider (edit/preset modes):
  /// the write-only key field shows a "leave empty to keep it" note.
  final bool hasSavedKey;

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

  bool get _isPreset => widget.preset != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _urlController = TextEditingController(text: initial?.baseUrl ?? '');
    _modelController = TextEditingController(text: initial?.modelId ?? '');
    // Write-only: the existing key is never shown.
    _keyController = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The preset's localized label needs the inherited l10n, unavailable in
    // initState.
    if (!_presetSeeded) {
      _presetSeeded = true;
      final preset = widget.preset;
      if (preset != null) {
        _nameController.text = preset.labelFor(context);
        _urlController.text = preset.baseUrl ?? '';
        _modelController.text = preset.defaultModel;
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
    final name = _nameController.text.trim();
    final baseUrl = _urlController.text.trim();
    final modelId = _modelController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.settingsNameRequired);
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _error = context.l10n.settingsBaseUrlRequired);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.settingsDeleteProviderTitle(initial.name)),
        content: Text(context.l10n.settingsDeleteProviderBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.settingsCancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.settingsDeleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(const ProviderEditorResult.delete());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                enabled: !_isPreset,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsProviderNameLabel,
                  hintText: context.l10n.settingsProviderNameHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                enabled: !_isPreset,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsBaseUrlLabel,
                  hintText: _isPreset ? null : 'https://example.com/v1',
                  helperText: _isPreset
                      ? null
                      : context.l10n.settingsBaseUrlHelper,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                enabled: !_isPreset,
                decoration: InputDecoration(
                  labelText: _isPreset
                      ? context.l10n.settingsModelIdLabel
                      : context.l10n.settingsModelIdOptionalLabel,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsApiKeyOptionalLabel,
                  helperText: widget.hasSavedKey
                      ? context.l10n.settingsEditorKeepKeyNote
                      : context.l10n.settingsApiKeyLocalHelper,
                  helperMaxLines: 3,
                ),
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
              ),
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
                          ? settingsKeyNoteHostedFor(context.l10n)
                          : settingsEditorKeyNoteFor(context.l10n),
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
                      child: Text(context.l10n.settingsDeleteButton),
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
