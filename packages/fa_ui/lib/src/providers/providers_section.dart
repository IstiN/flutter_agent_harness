// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ModelsEndpointFetcher, isCodeMieBaseUrl, isCopilotBaseUrl;

import 'package:fa_ui/src/providers/add_provider_picker.dart';
import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/default_chat_model.dart';
import 'package:fa_ui/src/providers/openrouter_oauth_button.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/providers/provider_marks.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// The settings "Providers" section: saved providers only, plus an
/// "Add provider" row that opens the [AddProviderPresetPickerPage].
///
/// Unlike the old design, built-in presets (OpenRouter, Ollama Cloud, Gemini)
/// are NOT shown until they are actually configured — they are only
/// reachable from the add flow. This mirrors the CLI's `/provider` command:
/// the list reflects what is connected, not what is available.
///
/// Each saved [CustomProvider] row pushes the [ProviderEditorPage] in edit
/// mode (name/URL/model/key + Delete). On-device rows push the host-supplied
/// [FaOnDeviceRoute] page and report the resulting [FaChatModelConfig]
/// through [onDeviceConnected].
class ProvidersSection extends StatelessWidget {
  const ProvidersSection({
    super.key,
    this.registry,
    this.onDeviceProviders = const [],
    this.onDeviceRowVisible,
    this.onDeviceConnected,
    this.openRouterOAuthCallbackUrl,
    this.openRouterOAuthCapture,
    this.onCodeMieSso,
    this.onChatGptOAuth,
    this.onAiinConnect,
    this.onCopilotConnect,
    this.onProviderReauthenticate,
    this.modelsFetcher,
  });

  /// The user-added providers; `null` falls back to a non-persisting
  /// in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// On-device provider routes (Gemma, WebLLM, transformers.js, …). Shown
  /// after the custom providers when non-empty.
  final List<FaOnDeviceRoute> onDeviceProviders;

  /// Gates an on-device route's row in the Providers list by engine kind
  /// (see [FaOnDeviceRoute.id]): null shows all (previews); the app passes
  /// the on-device config store so a never-configured engine stays
  /// discoverable through "Add provider" instead of cluttering the list.
  final bool Function(String kind)? onDeviceRowVisible;

  /// Called when an on-device route applies a [FaChatModelConfig] (the user
  /// connected a local model). The host should reconfigure its service.
  final ValueChanged<FaChatModelConfig>? onDeviceConnected;

  /// `callback_url` passed to the OpenRouter OAuth authorization URL when the
  /// user edits the OpenRouter preset. Used with [openRouterOAuthCapture].
  final String? openRouterOAuthCallbackUrl;

  /// Automatic callback capture for the OpenRouter OAuth flow in the preset
  /// editor. When null the button falls back to the manual code-paste sheet.
  final OpenRouterOAuthCaptureCallback? openRouterOAuthCapture;

  /// Called when the user picks CodeMie from the add-provider preset
  /// picker. When null, CodeMie is not offered. The host should open the
  /// CodeMie WebView SSO flow.
  final VoidCallback? onCodeMieSso;

  /// Called when the user picks ChatGPT from the add-provider preset
  /// picker. When null, ChatGPT is not offered. The host should open the
  /// ChatGPT OAuth flow.
  final VoidCallback? onChatGptOAuth;

  /// Called when the user picks AIIN (aiin.by) from the add-provider
  /// preset picker. When null, AIIN is not offered. The host should run
  /// the aiin.by auth-page flow (sign-in in the browser, automatic API-key
  /// registration).
  final VoidCallback? onAiinConnect;

  /// Called when the user picks Copilot from the add-provider preset
  /// picker. When null, Copilot is not offered. The host should run the
  /// GitHub Copilot connect flow.
  final VoidCallback? onCopilotConnect;

  /// Re-authentication for SSO-backed providers (CodeMie) in the edit
  /// editor: the host re-runs the sign-in flow for [provider] (refreshing
  /// its stored key) and returns whether it completed. Only consulted for
  /// providers whose base URL matches a known SSO endpoint (CodeMie's
  /// `/code-assistant-api`); null hides the button everywhere.
  final Future<bool> Function(BuildContext context, CustomProvider provider)?
  onProviderReauthenticate;

  /// `/models` fetch override (tests), forwarded to the provider editor's
  /// model selector (preset, edit, and add flows).
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.settingsProvidersSectionTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (registry.providers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No providers configured. Tap "Add provider" to get started.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            // Connected hosted presets (a key resolves through the CLI's
            /// chain) list like providers; a custom provider on the same
            // endpoint covers its preset (never both).
            for (final preset in hostedProviderPresets)
              if (hostedProviderConnected(preset) &&
                  !registry.providers.any(
                    (custom) => custom.baseUrl == preset.baseUrl,
                  ))
                _buildRow(
                  context,
                  theme,
                  label: preset.labelFor(context),
                  subtitle:
                      '${registry.presetModelOverride(preset.name) ?? preset.defaultModel} · '
                      '${providerHostOf(preset.baseUrl!)}',
                  // The same branded mark the add-provider picker shows.
                  leading: ProviderMark(providerMarkKey(preset)),
                  onTap: () => _editPreset(context, registry, preset),
                ),
            for (final provider in registry.providers)
              _buildRow(
                context,
                theme,
                label: provider.name,
                subtitle: provider.modelId.isEmpty
                    ? providerHostOf(provider.baseUrl)
                    : strings.mediaModelsOverrideSummary(
                        provider.modelId,
                        providerHostOf(provider.baseUrl),
                      ),
                // The picker-matching branded mark, keyed by the baseUrl
                // host (CodeMie/DIAL/OpenRouter/… detected by URL).
                leading: ProviderMark(
                  providerMarkKeyForBaseUrl(provider.baseUrl),
                ),
                onTap: () => _editCustom(context, registry, provider),
              ),
            // On-device engines are provider types too — plain rows in the
            // same list, not a separate "Local models" section.
            for (final route in onDeviceProviders)
              if (onDeviceRowVisible?.call(route.id) ?? true)
                _buildRow(
                  context,
                  theme,
                  label: route.label,
                  leading: ProviderMark(route.id),
                  onTap: () {
                    unawaited(_openOnDeviceRoute(context, route));
                  },
                ),
            _buildRow(
              context,
              theme,
              label: strings.settingsAddProvider,
              leadingIcon: Icons.add,
              onTap: () => _addProvider(context, registry),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openOnDeviceRoute(
    BuildContext context,
    FaOnDeviceRoute route,
  ) async {
    final config = await pushFaPage<FaChatModelConfig?>(
      context,
      route.pageBuilder(context, (config) async {
        onDeviceConnected?.call(config);
        if (context.mounted) Navigator.of(context).pop(config);
      }),
    );
    if (config != null) onDeviceConnected?.call(config);
    return;
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme, {
    required String label,
    String? subtitle,
    Widget? leading,
    IconData? leadingIcon = Icons.cloud_outlined,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child:
                  leading ??
                  Icon(leadingIcon, size: 20, color: theme.colorScheme.primary),
            ),
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

  /// A connected hosted preset opens its preset-mode editor (fixed
  /// endpoint; the user re-keys or re-models it). Saving lands as the
  /// custom provider on that endpoint (same as the add-provider flow) —
  /// the custom row then covers the preset everywhere.
  Future<void> _editPreset(
    BuildContext context,
    ProviderRegistry registry,
    ProviderPreset preset,
  ) async {
    final result = await pushFaPage<ProviderEditorResult>(
      context,
      ProviderEditorPage(
        title: preset.labelFor(context),
        preset: preset,
        hasSavedKey: hostedProviderConnected(preset),
        registry: registry,
        openRouterOAuthCallbackUrl: openRouterOAuthCallbackUrl,
        openRouterOAuthCapture: openRouterOAuthCapture,
        modelsFetcher: modelsFetcher,
      ),
    );
    if (result == null || result.deleted) return;
    final existing = registry.providers
        .where((p) => p.baseUrl == preset.baseUrl)
        .firstOrNull;
    if (existing != null) {
      await registry.update(
        CustomProvider(
          id: existing.id,
          name: result.name,
          baseUrl: existing.baseUrl,
          modelId: result.modelId,
        ),
      );
      if (result.apiKey.isNotEmpty) {
        registry.rememberKey(existing.id, result.apiKey);
      }
      return;
    }
    final added = await registry.add(
      name: result.name,
      baseUrl: result.baseUrl.isEmpty ? preset.baseUrl! : result.baseUrl,
      modelId: result.modelId,
    );
    if (result.apiKey.isNotEmpty) {
      registry.rememberKey(added.id, result.apiKey);
    }
  }

  Future<void> _editCustom(
    BuildContext context,
    ProviderRegistry registry,
    CustomProvider provider,
  ) async {
    final reauth = onProviderReauthenticate;
    final result = await pushFaPage<ProviderEditorResult>(
      context,
      ProviderEditorPage(
        title: FaUiStrings.of(context).settingsEditProviderTitle,
        initial: provider,
        hasSavedKey: (registry.keyFor(provider.id) ?? '').isNotEmpty,
        // The model selector resolves the provider's stored key through it.
        registry: registry,
        // SSO-backed providers (CodeMie) get a Re-authenticate button:
        // the cookie key expires and cannot be refreshed by re-typing.
        onReauthenticate:
            reauth != null &&
                (isCodeMieBaseUrl(provider.baseUrl) ||
                    isCopilotBaseUrl(provider.baseUrl))
            ? (ctx) => reauth(ctx, provider)
            : null,
        modelsFetcher: modelsFetcher,
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
    await pushFaPage<void>(
      context,
      AddProviderPresetPickerPage(
        registry: registry,
        onCopilotConnect: onCopilotConnect,
        onCodeMieSso: onCodeMieSso,
        onChatGptOAuth: onChatGptOAuth,
        onAiinConnect: onAiinConnect,
        openRouterOAuthCallbackUrl: openRouterOAuthCallbackUrl,
        openRouterOAuthCapture: openRouterOAuthCapture,
        onDeviceRoutes: onDeviceProviders,
        onOnDeviceConnected: onDeviceConnected,
        modelsFetcher: modelsFetcher,
      ),
    );
  }
}
