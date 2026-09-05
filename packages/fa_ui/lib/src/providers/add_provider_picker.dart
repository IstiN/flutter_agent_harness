// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart' as harness;

import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/providers/connection.dart' show FaChatModelConfig;
import 'package:fa_ui/src/providers/default_chat_model.dart'
    show FaOnDeviceRoute;
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
    key: 'aiin',
    name: 'AIIN',
    description: 'aiin.by — sign in, key auto-registered',
    icon: Icons.bolt_outlined,
  ),
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
    key: 'copilot',
    name: 'GitHub Copilot',
    description: 'Account sign-in via device flow',
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
    key: 'minimax',
    name: 'MiniMax',
    description: 'MiniMax models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.minimax.io/v1',
    keyHelpUrl:
        'https://platform.minimax.io/user-center/basic-information/interface-key',
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

/// Whether a quick-add preset is offered to the user right now.
///
/// Presets backed by the CLI provider catalog ([harness.providerCatalog])
/// follow the catalog's visibility rules: a `visible: false` spec is
/// hidden, and the
/// `FA_PROVIDERS` build/runtime filter ([harness.providerEnabledInBuild])
/// drops filtered-out providers. App-only presets (Kimi, Z.AI, Ollama,
/// Custom — no catalog entry) are always enabled.
///
/// Every surface listing [defaultAddProviderPresets] (the Add-provider
/// picker, onboarding) must filter through this so the CLI and the app
/// never drift apart.
bool addProviderPresetEnabled(AddProviderPreset preset) {
  final spec = harness.providerCatalog[preset.key];
  if (spec == null) return true;
  return spec.visible && harness.providerEnabledInBuild(spec.name);
}

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
    this.onAiinConnect,
    this.onCodeMieSso,
    this.onChatGptOAuth,
    this.onCopilotConnect,
    this.openRouterOAuthCallbackUrl,
    this.openRouterOAuthCapture,
    this.onDeviceRoutes = const [],
    this.onOnDeviceConnected,
    this.modelsFetcher,
  });

  /// The provider registry: needed so the editor can save the new provider.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the provider editor's
  /// model selector.
  final harness.ModelsEndpointFetcher? modelsFetcher;

  /// The preset tiles to show. Defaults to [defaultAddProviderPresets].
  final List<AddProviderPreset> presets;

  /// Called when the user picks the AIIN preset. The host should run its
  /// aiin.by connect flow (browser sign-in + automatic API-key
  /// registration on desktop; WebView in mobile apps). When null, the
  /// AIIN tile is hidden.
  final VoidCallback? onAiinConnect;

  /// Called when the user picks the CodeMie preset. The host should launch
  /// its CodeMie SSO flow (WebView in the app). When null, the CodeMie tile
  /// is hidden.
  final VoidCallback? onCodeMieSso;

  /// Called when the user picks the ChatGPT preset. The host should launch
  /// its ChatGPT OAuth flow (local server + browser on macOS, WebView on
  /// iOS). When null, the ChatGPT tile is hidden.
  final VoidCallback? onChatGptOAuth;

  /// Called when the user picks the Copilot preset. The host should run
  /// the GitHub Copilot connect flow (device-flow sheet + provider setup).
  /// When null, the Copilot tile is hidden.
  final VoidCallback? onCopilotConnect;

  /// `callback_url` for the OpenRouter OAuth flow (forwarded to the editor).
  final String? openRouterOAuthCallbackUrl;

  /// Automatic callback capture for OpenRouter OAuth (forwarded to the
  /// editor).
  final OpenRouterOAuthCaptureCallback? openRouterOAuthCapture;

  /// On-device engine routes (Gemma/WebLLM/…): each renders a tile after
  /// the hosted presets so a never-configured engine is discoverable here
  /// instead of cluttering the Providers list.
  final List<FaOnDeviceRoute> onDeviceRoutes;

  /// A on-device route completed its connect flow (the host connects +
  /// marks the engine configured).
  final ValueChanged<FaChatModelConfig>? onOnDeviceConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final visiblePresets = presets.where((p) {
      if (!addProviderPresetEnabled(p)) return false;
      if (p.key == 'aiin' && onAiinConnect == null) return false;
      if (p.key == 'codemie' && onCodeMieSso == null) return false;
      if (p.key == 'chatgpt' && onChatGptOAuth == null) return false;
      if (p.key == 'copilot' && onCopilotConnect == null) return false;
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
            for (final route in onDeviceRoutes)
              ListTile(
                leading: Icon(
                  Icons.memory_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(route.label),
                subtitle: const Text('Runs on this device — download once'),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onTap: () => _onOnDeviceTap(context, route),
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
      case 'aiin':
        Navigator.of(context).pop();
        onAiinConnect?.call();
        return;
      case 'codemie':
        Navigator.of(context).pop();
        onCodeMieSso?.call();
        return;
      case 'chatgpt':
        Navigator.of(context).pop();
        onChatGptOAuth?.call();
        return;
      case 'copilot':
        Navigator.of(context).pop();
        onCopilotConnect?.call();
        return;
      case 'custom':
        await pushProviderEditor(
          context,
          registry ?? ProviderRegistry.inMemory(),
          title: FaUiStrings.of(context).settingsAddProvider,
          modelsFetcher: modelsFetcher,
        );
        if (context.mounted) Navigator.of(context).pop(true);
        return;
      default:
        // Key-based preset. Every quick-add keeps an editable base URL in
        // the editor (the user may point DIAL/Ollama/… at another
        // instance); the ProviderPreset-backed ones (OpenRouter, Ollama
        // Cloud, Gemini, DIAL, MiniMax) open in preset mode so the model
        // field seeds the preset default, the rest (Kimi Code, Z.AI)
        // open with editable prefills — several instances of the same
        // provider with custom names are a first-class use case.
        final providerPreset = _matchProviderPreset(preset.key);
        final editable = providerPreset == ProviderPreset.custom;
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
            modelsFetcher: modelsFetcher,
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

  /// On-device tile: pushes the route's connect page; a completed connect
  /// reports through [onOnDeviceConnected] and pops the picker.
  Future<void> _onOnDeviceTap(
    BuildContext context,
    FaOnDeviceRoute route,
  ) async {
    final config = await pushFaPage<FaChatModelConfig?>(
      context,
      route.pageBuilder(context, (config) async {
        if (context.mounted) Navigator.of(context).pop(config);
      }),
    );
    if (config == null || !context.mounted) return;
    onOnDeviceConnected?.call(config);
    Navigator.of(context).pop(true);
  }

  /// Maps a [AddProviderPreset.key] to the matching [ProviderPreset] for
  /// the editor's preset-mode (preset-seeded model, keep-key note). Falls
  /// back to [custom] (plain editable prefill) for unknown keys.
  static ProviderPreset _matchProviderPreset(String key) {
    switch (key) {
      case 'aiin':
        return ProviderPreset.aiin;
      case 'openrouter':
        return ProviderPreset.openrouter;
      case 'ollama':
        return ProviderPreset.ollamaCloud;
      case 'google':
        return ProviderPreset.gemini;
      case 'dial':
        return ProviderPreset.dial;
      case 'minimax':
        return ProviderPreset.minimax;
      default:
        return ProviderPreset.custom;
    }
  }
}
