// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/providers/media_slot_picker_page.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/providers/unified_model_picker.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// Builds the connect page of an on-device provider (engine download,
/// progress, token field — all host territory). The page must call
/// [onApply] with the assembled [FaChatModelConfig] and pop `true` on success.
typedef FaOnDevicePageBuilder =
    Widget Function(
      BuildContext context,
      Future<void> Function(FaChatModelConfig config) onApply,
    );

/// One on-device provider entry of the default-chat-model picker (WebLLM,
/// Gemma, transformers.js — whatever the host supports). fa_ui knows
/// nothing about engines; the host supplies the tile label and the page
/// builder, and pre-filters the list by platform visibility.
final class FaOnDeviceRoute {
  /// Creates a route. [label] is the picker tile's text; [pageBuilder]
  /// builds the pushed connect page.
  const FaOnDeviceRoute({
    required this.label,
    required this.pageBuilder,
    this.id = '',
  });

  /// The engine/provider kind this route configures (webllm/gemma/...) —
  /// hosts use it to gate the tile's visibility (a configured engine keeps
  /// its row; a never-used one stays discoverable via "Add provider").
  final String id;

  /// The picker tile's label (resolve localization before building — the
  /// route itself is context-free).
  final String label;

  /// Builds the on-device connect page.
  final FaOnDevicePageBuilder pageBuilder;
}

/// Resolves a stored key NAME to its value for the main-connection apply:
/// the registry's custom-provider session keys first, then the host chain
/// (env / secure store / saved keys).
String _resolveKeyByName(ProviderRegistry? registry, String? apiKeyName) {
  if (apiKeyName == null || apiKeyName.isEmpty) return '';
  final fromRegistry = registry?.keyValueForName(apiKeyName);
  if (fromRegistry != null && fromRegistry.isNotEmpty) return fromRegistry;
  return FaUiHost.resolveKey(apiKeyName, () => '');
}

/// The settings "Default chat model" section — one row showing the active
/// provider + model. Tapping pushes the two-step flow
/// ([DefaultModelProviderPickerPage] → model page); applying runs
/// [onApply] (the host reconfigures its service and persists the choice).
class DefaultChatModelSection extends StatelessWidget {
  const DefaultChatModelSection({
    super.key,
    required this.connection,
    required this.onApply,
    this.registry,
    this.modelsFetcher,
    this.providerModelFetcher,
    this.onDeviceProviders = const [],
    this.providerKindLabels = const {},
    this.addProviderPage,
  });

  /// The active connection, displayed and listened to.
  final FaChatConnection connection;

  /// Applies the chosen config as the main connection (reconfigure +
  /// persist). Throw to surface an error on the model page.
  final Future<void> Function(FaChatModelConfig config) onApply;

  /// The user-added providers listed in the picker.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// Provider-specific model-list fetcher for non-standard endpoints (e.g.
  /// CodeMie). Forwarded to the [UnifiedModelPickerPage].
  final ProviderModelFetcher? providerModelFetcher;

  /// The on-device provider entries appended to the picker (already
  /// filtered for the platform by the host).
  final List<FaOnDeviceRoute> onDeviceProviders;

  /// Display labels for non-endpoint provider kinds (on-device backends),
  /// keyed by [FaChatConnection.providerKind] — a connection whose kind is
  /// listed here summarizes with the label instead of its (empty) base URL.
  final Map<String, String> providerKindLabels;

  /// Host-provided builder for the "Add provider" page (preset picker).
  /// When null, the fallback [pushProviderEditor] is used.
  final WidgetBuilder? addProviderPage;

  String _activeProviderLabel(BuildContext context) {
    final kindLabel = providerKindLabels[connection.providerKind];
    if (kindLabel != null) return kindLabel;
    final provider = providerForBaseUrl(connection.activeBaseUrl, registry);
    if (provider != null) return providerDisplayName(context, provider);
    return providerHostOf(connection.activeBaseUrl);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.settingsDefaultChatModelTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                // The SAME two-step flow the role/media pickers use
                // (provider → model), editing the main connection.
                final result = await pushFaPage<MediaSlotEditorResult>(
                  context,
                  MediaSlotProviderPickerPage(
                    slot: null,
                    title: strings.settingsDefaultChatModelTitle,
                    initial: null,
                    mainBaseUrl: connection.activeBaseUrl,
                    registry: registry,
                    modelsFetcher: modelsFetcher,
                    // Connected providers only — like every other picker.
                    connectedOnly: true,
                    // Editing the main connection: no "same as main" row.
                    allowMainConnection: false,
                    onDeviceRoutes: onDeviceProviders,
                    addProviderPage: addProviderPage,
                  ),
                );
                if (result == null || result.cleared) return;
                final override = result.override!;
                if (!context.mounted) return;
                await onApply(
                  FaChatModelConfig(
                    providerKind: override.providerKind,
                    modelId: override.modelId,
                    baseUrl: override.baseUrl,
                    apiKey: _resolveKeyByName(registry, override.apiKeyName),
                    providerId: override.providerId,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        strings.settingsProviderModelSummary(
                          connection.modelId,
                          _activeProviderLabel(context),
                        ),
                        overflow: TextOverflow.ellipsis,
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
            ),
          ],
        );
      },
    );
  }
}
