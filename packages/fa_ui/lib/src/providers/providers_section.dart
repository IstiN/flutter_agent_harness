// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/providers/connection.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// The settings "Providers" section: every hosted preset and saved
/// [CustomProvider], the one backing the active connection marked with a
/// check. Tapping a row pushes the full-screen [ProviderEditorPage]
/// (presets: key only; custom providers: name/URL/model/key + Delete); the
/// "Add provider" row opens the same page in create mode.
class ProvidersSection extends StatelessWidget {
  const ProvidersSection({super.key, this.service, this.registry});

  /// The active connection, for the current-provider mark. `null` renders
  /// the list without marks (tests, hosts without a live connection).
  final FaChatConnection? service;

  /// The user-added providers; `null` falls back to a non-persisting
  /// in-memory registry (tests, previews).
  final ProviderRegistry? registry;

  bool _isCurrent(Object provider) {
    final service = this.service;
    if (service == null || service.providerKind != 'openai-completions') {
      return false;
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
            for (final preset in hostedProviderPresets)
              _buildRow(
                context,
                theme,
                label: preset.labelFor(context),
                subtitle: providerHostOf(preset.baseUrl!),
                current: _isCurrent(preset),
                onTap: () => _editPreset(context, preset),
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
          ],
        );
      },
    );
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

  Future<void> _editPreset(BuildContext context, ProviderPreset preset) async {
    final keysStore = SessionKeysScope.maybeOf(context);
    final registry = this.registry;
    final keyName = hostedProviderKeyName(preset);
    final hasSavedKey =
        keyName != null &&
        FaUiHost.resolveKey(
          keyName,
          () => keysStore?.valueOf(keyName) ?? '',
        ).isNotEmpty;
    final result = await pushFaPage<ProviderEditorResult>(
      context,
      ProviderEditorPage(
        title: preset.labelFor(context),
        preset: preset,
        hasSavedKey: hasSavedKey,
        registry: registry,
      ),
    );
    if (result == null) return;
    // The preset's default model is user-editable: persist the override,
    // clearing it when the field is empty or back to the built-in default.
    if (registry != null) {
      final model = result.modelId;
      await registry.setPresetModelOverride(
        preset.name,
        model.isEmpty || model == preset.defaultModel ? null : model,
      );
    }
    if (result.apiKey.isEmpty || keyName == null) return;
    await keysStore?.set(keyName, result.apiKey);
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
    await pushProviderEditor(
      context,
      registry,
      title: FaUiStrings.of(context).settingsAddProvider,
    );
  }
}
