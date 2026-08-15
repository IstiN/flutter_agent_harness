// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
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
  const FaOnDeviceRoute({required this.label, required this.pageBuilder});

  /// The picker tile's label (resolve localization before building — the
  /// route itself is context-free).
  final String label;

  /// Builds the on-device connect page.
  final FaOnDevicePageBuilder pageBuilder;
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
                await pushFaPage<void>(
                  context,
                  UnifiedModelPickerPage(
                    connection: connection,
                    onApply: onApply,
                    registry: registry,
                    modelsFetcher: modelsFetcher,
                    providerModelFetcher: providerModelFetcher,
                    onDeviceProviders: onDeviceProviders,
                    providerKindLabels: providerKindLabels,
                    addProviderPage: addProviderPage,
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
