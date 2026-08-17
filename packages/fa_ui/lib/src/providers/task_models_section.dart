// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/media_slot_picker_page.dart';
import 'package:fa_ui/src/providers/unified_model_picker.dart';
import 'package:fa_ui/src/stores/media_models_store.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/task_models_store.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// The settings "Task models" section: one row per [TaskRole.all] entry
/// showing the effective endpoint — the role's override (`modelId`) or the
/// main connection fallback ("Same as main"). Tapping a row opens the SAME
/// two-step flow the media slots use: [MediaSlotProviderPickerPage]
/// (provider list: main connection, hosted presets, saved providers, add
/// provider) → [MediaSlotModelPage] (the endpoint's model list with quick
/// search + manual entry). "Main connection" clears the override.
///
/// The store comes from [store] or the nearest [TaskModelsScope]; the whole
/// section hides when no store is available (tests pumping the bare form).
/// [mainBaseUrl] / [mainModelId] supply the current connection for the
/// picker.
class TaskModelsSection extends StatelessWidget {
  const TaskModelsSection({
    super.key,
    this.store,
    this.mainBaseUrl = '',
    this.mainModelId = '',
    this.registry,
    this.modelsFetcher,
  });

  /// Store override; falls back to the nearest [TaskModelsScope].
  final TaskModelsStore? store;

  /// The main connection's base URL (shown under the main-connection row).
  final String mainBaseUrl;

  /// The main connection's model id (the row's fallback subtitle).
  final String mainModelId;

  /// The user-added providers listed in the picker.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// The icon each role's row shows.
  static const roleIcons = <String, IconData>{
    TaskRole.smol: Icons.bolt_outlined,
    TaskRole.subagent: Icons.groups_outlined,
  };

  /// Display labels for known roles (the rest fall back to the raw id).
  static const roleTitles = <String, String>{
    TaskRole.smol: 'Quick model', // l10n:ignore
    TaskRole.subagent: 'Subagents model', // l10n:ignore
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = this.store ?? TaskModelsScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final role in TaskRole.all)
              _buildRoleRow(context, theme, store, role),
          ],
        );
      },
    );
  }

  Widget _buildRoleRow(
    BuildContext context,
    ThemeData theme,
    TaskModelsStore store,
    String role,
  ) {
    final override = store.overrideFor(role);
    final title = roleTitles[role] ?? role;
    final subtitle = override?.modelId.isNotEmpty == true
        ? override!.modelId
        : 'Same as main'; // l10n:ignore
    return InkWell(
      onTap: () => _editRole(context, store, role),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              roleIcons[role] ?? Icons.tune,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
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

  Future<void> _editRole(
    BuildContext context,
    TaskModelsStore store,
    String role,
  ) async {
    // The SAME picker the default-chat-model row opens, in override mode:
    // the connected providers' live model lists with search; "Same as main
    // connection" clears the role override.
    final current = store.overrideFor(role);
    final result = await pushFaPage<MediaSlotEditorResult>(
      context,
      UnifiedModelPickerPage(
        connection: FaStaticChatConnection(
          providerKind: 'openai-completions',
          activeBaseUrl: mainBaseUrl,
          modelId: mainModelId,
        ),
        onApply: (_) async {}, // unused in override mode
        registry: registry,
        modelsFetcher: modelsFetcher,
        overrideMode: true,
        overrideTitle: roleTitles[role] ?? role,
        currentModelId: current?.modelId,
        currentBaseUrl: current?.baseUrl,
      ),
    );
    if (result == null) return;
    if (result.cleared) {
      await store.setOverride(role, null);
      return;
    }
    final override = result.override!;
    await store.setOverride(
      role,
      TaskRoleConfig(
        providerKind: override.providerKind,
        baseUrl: override.baseUrl,
        modelId: override.modelId,
        apiKeyName: override.apiKeyName,
      ),
    );
  }
}
