// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/providers/openrouter_oauth_button.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/providers/provider_marks.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// A quick-add template shown in the [AddProviderPresetPickerPage].
///
/// Each template carries enough context (name, description, base URL, icon)
/// to render a tile and route the selection to the right setup flow.
final class AddProviderPreset {
  /// Creates a preset tile.
  const AddProviderPreset({
    required this.key,
    required this.name,
    required this.description,
    required this.icon,
    this.baseUrl,
    this.keyHelpUrl,
  });

  /// Stable identifier for the tile (routing key).
  final String key;

  /// Display name.
  final String name;

  /// One-line description shown under [name].
  final String description;

  /// Leading icon.
  final IconData icon;

  /// Pre-fill base URL for key-based presets; `null` for auth-flow presets
  /// (CodeMie SSO, OpenRouter OAuth) and Custom.
  final String? baseUrl;

  /// A "where do I get the key" page for key-based presets (key console
  /// link shown next to the key field in the editor); null hides the link.
  final String? keyHelpUrl;
}

/// The built-in quick-add presets shown when the user taps "Add provider".
///
/// Host apps may extend or replace this list. Order matters: the most
/// common presets first, `Custom` always last.
const defaultAddProviderPresets = <AddProviderPreset>[
  AddProviderPreset(
    key: 'openrouter',
    name: 'OpenRouter',
    description: 'OAuth or API key — 300+ models',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://openrouter.ai/api/v1',
  ),
  AddProviderPreset(
    key: 'chatgpt',
    name: 'ChatGPT (Codex)',
    description: 'Account sign-in via OAuth',
    icon: Icons.login,
  ),
  AddProviderPreset(
    key: 'codemie',
    name: 'CodeMie',
    description: 'Enterprise SSO sign-in',
    icon: Icons.security_outlined,
  ),
  AddProviderPreset(
    key: 'openai',
    name: 'OpenAI',
    description: 'api.openai.com — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.openai.com/v1',
  ),
  AddProviderPreset(
    key: 'anthropic',
    name: 'Anthropic',
    description: 'api.anthropic.com — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.anthropic.com',
  ),
  AddProviderPreset(
    key: 'google',
    name: 'Google Gemini',
    description: 'Gemini models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  ),
  AddProviderPreset(
    key: 'dial',
    name: 'DIAL',
    description: 'EPAM DIAL Core — Api key + deployment',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://ai-proxy.lab.epam.com',
  ),
  AddProviderPreset(
    key: 'kimi',
    name: 'Kimi Code',
    description: 'Kimi Code models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.kimi.com/coding/v1',
    keyHelpUrl: 'https://www.kimi.com/code/console',
  ),
  AddProviderPreset(
    key: 'zai',
    name: 'Z.AI',
    description: 'GLM models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.z.ai/api/coding/paas/v4',
    keyHelpUrl: 'https://z.ai/manage-apikey/apikey-list',
  ),
  AddProviderPreset(
    key: 'ollama',
    name: 'Ollama Cloud',
    description: 'api.ollama.com — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://ollama.com/v1',
  ),
  AddProviderPreset(
    key: 'custom',
    name: 'Custom',
    description: 'Any OpenAI-compatible endpoint',
    icon: Icons.dns_outlined,
  ),
];

/// The "Add provider" preset picker: a list of quick-add templates that
/// route to the matching setup flow.
///
/// Tapping a key-based preset (OpenRouter, Ollama, Gemini, …) opens the
/// [ProviderEditorPage] pre-filled with the preset's base URL — the user
/// enters their API key and saves. Tapping CodeMie calls [onCodeMieSso]
/// (host-provided, because the WebView SSO flow is app-specific). Custom
/// opens [ProviderEditorPage] in create mode.
///
/// The page pops when a provider was added (returns `true`) or the user
/// cancels (returns `null`).
class AddProviderPresetPickerPage extends StatelessWidget {
  /// Creates the picker.
  const AddProviderPresetPickerPage({
    super.key,
    this.registry,
    this.presets = defaultAddProviderPresets,
    this.onCodeMieSso,
    this.onChatGptOAuth,
    this.openRouterOAuthCallbackUrl,
    this.openRouterOAuthCapture,
  });

  /// The provider registry: needed so the editor can save the new provider.
  final ProviderRegistry? registry;

  /// The preset tiles to show. Defaults to [defaultAddProviderPresets].
  final List<AddProviderPreset> presets;

  /// Called when the user picks the CodeMie preset. The host should launch
  /// its CodeMie SSO flow (WebView in the app). When null, the CodeMie tile
  /// is hidden.
  final VoidCallback? onCodeMieSso;

  /// Called when the user picks the ChatGPT preset. The host should launch
  /// its ChatGPT OAuth flow (local server + browser on macOS, WebView on
  /// iOS). When null, the ChatGPT tile is hidden.
  final VoidCallback? onChatGptOAuth;

  /// `callback_url` for the OpenRouter OAuth flow (forwarded to the editor).
  final String? openRouterOAuthCallbackUrl;

  /// Automatic callback capture for OpenRouter OAuth (forwarded to the
  /// editor).
  final OpenRouterOAuthCaptureCallback? openRouterOAuthCapture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final visiblePresets = presets.where((p) {
      if (p.key == 'codemie' && onCodeMieSso == null) return false;
      if (p.key == 'chatgpt' && onChatGptOAuth == null) return false;
      return true;
    }).toList();
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsAddProvider)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final preset in visiblePresets)
              ListTile(
                leading: ProviderMark(preset.key, size: 32),
                title: Text(preset.name),
                subtitle: Text(preset.description),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onTap: () => _onPresetTap(context, preset),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _onPresetTap(
    BuildContext context,
    AddProviderPreset preset,
  ) async {
    switch (preset.key) {
      case 'codemie':
        Navigator.of(context).pop();
        onCodeMieSso?.call();
        return;
      case 'chatgpt':
        Navigator.of(context).pop();
        onChatGptOAuth?.call();
        return;
      case 'custom':
        await pushProviderEditor(
          context,
          registry ?? ProviderRegistry.inMemory(),
          title: FaUiStrings.of(context).settingsAddProvider,
        );
        if (context.mounted) Navigator.of(context).pop(true);
        return;
      default:
        // Key-based preset. The dial preset keeps its fixed endpoint
        // (read-only URL); other quick-adds (Kimi Code, Z.AI) open the
        // editor with editable prefills — several instances of the same
        // provider with custom names are a first-class use case.
        final providerPreset = _matchProviderPreset(preset.key);
        final editable =
            preset.key != 'dial' && providerPreset == ProviderPreset.custom;
        // A key resolved through the host's chain (env / secure store /
        // saved keys) counts as saved — the editor shows the keep-note.
        final namedKey = editable
            ? null
            : hostedProviderKeyName(providerPreset);
        final hasSavedKey =
            namedKey != null &&
            FaUiHost.resolveKey(namedKey, () => '').isNotEmpty;
        final result = await pushFaPage<ProviderEditorResult>(
          context,
          ProviderEditorPage(
            title: preset.name,
            preset: editable ? null : providerPreset,
            prefillName: editable ? preset.name : null,
            prefillBaseUrl: editable ? preset.baseUrl : null,
            hasSavedKey: hasSavedKey,
            keyHelpUrl: preset.keyHelpUrl,
            registry: registry,
            openRouterOAuthCallbackUrl: openRouterOAuthCallbackUrl,
            openRouterOAuthCapture: openRouterOAuthCapture,
          ),
        );
        if (result == null || result.deleted) return;
        // Persist the new provider.
        final reg = registry;
        if (reg != null) {
          await reg.add(
            name: result.name,
            baseUrl: result.baseUrl,
            modelId: result.modelId,
          );
          if (result.apiKey.isNotEmpty) {
            // The registry assigns the id; re-read the last-added.
            final added = reg.providers.last;
            reg.rememberKey(added.id, result.apiKey);
          }
        }
        if (context.mounted) Navigator.of(context).pop(true);
    }
  }

  /// Maps a [AddProviderPreset.key] to the matching [ProviderPreset] for
  /// the editor's preset-mode (read-only URL). Falls back to [custom]
  /// (editable URL) for unknown keys.
  static ProviderPreset _matchProviderPreset(String key) {
    switch (key) {
      case 'openrouter':
        return ProviderPreset.openrouter;
      case 'ollama':
        return ProviderPreset.ollamaCloud;
      case 'google':
        return ProviderPreset.gemini;
      case 'dial':
        return ProviderPreset.dial;
      default:
        return ProviderPreset.custom;
    }
  }
}
