// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa_ui/src/providers/add_provider_picker.dart';
import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/default_chat_model.dart';
import 'package:fa_ui/src/providers/openrouter_oauth_button.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
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
    this.service,
    this.registry,
    this.onDeviceProviders = const [],
    this.onDeviceConnected,
    this.openRouterOAuthCallbackUrl,
    this.openRouterOAuthCapture,
    this.onCodeMieSso,
    this.onChatGptOAuth,
  });

  /// The active connection, for the current-provider mark. `null` renders
  /// the list without marks (tests, hosts without a live connection).
  final FaChatConnection? service;

  /// The user-added providers; `null` falls back to a non-persisting
  /// in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  /// On-device provider routes (Gemma, WebLLM, transformers.js, …). Shown
  /// after the custom providers when non-empty.
  final List<FaOnDeviceRoute> onDeviceProviders;

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

  bool _isCurrent(Object provider) {
    final service = this.service;
    if (service == null || service.providerKind != 'openai-completions') {
      return false;
    }
    // A host that tracks provider ids disambiguates providers sharing one
    // base URL (two custom endpoints on one host); others match by URL.
    final activeId = service.activeProviderId;
    if (activeId != null) {
      return switch (provider) {
        CustomProvider custom => custom.id == activeId,
        ProviderPreset preset => preset.name == activeId,
        _ => false,
      };
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
                current: _isCurrent(provider),
                onTap: () => _editCustom(context, registry, provider),
              ),
            _buildRow(
              context,
              theme,
              label: strings.settingsAddProvider,
              leading: Icons.add,
              onTap: () => _addProvider(context, registry),
            ),
            if (onDeviceProviders.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                strings.settingsLocalProvidersSectionTitle,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (final route in onDeviceProviders)
                _buildRow(
                  context,
                  theme,
                  label: route.label,
                  leading: Icons.memory_outlined,
                  onTap: () {
                    unawaited(_openOnDeviceRoute(context, route));
                  },
                ),
            ],
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

  Future<void> _editCustom(
    BuildContext context,
    ProviderRegistry registry,
    CustomProvider provider,
  ) async {
    final result = await pushFaPage<ProviderEditorResult>(
      context,
      ProviderEditorPage(
        title: FaUiStrings.of(context).settingsEditProviderTitle,
        initial: provider,
        hasSavedKey: (registry.keyFor(provider.id) ?? '').isNotEmpty,
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
        onCodeMieSso: onCodeMieSso,
        onChatGptOAuth: onChatGptOAuth,
        openRouterOAuthCallbackUrl: openRouterOAuthCallbackUrl,
        openRouterOAuthCapture: openRouterOAuthCapture,
      ),
    );
  }
}
