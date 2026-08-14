import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:fa_ui/fa_ui.dart';

/// A list-based provider picker shared by the setup wizard and the settings
/// screen. Shows all hosted presets and saved custom providers as rows with
/// a check mark on the selected one, plus an "Add provider" row at the
/// bottom that opens the preset picker.
///
/// Tapping a row calls [onSelect]; tapping "Add provider" calls [onAdd].
/// Both the setup wizard and the settings Providers section render the same
/// list so the two screens never drift apart visually.
class ProviderSelectionList extends StatelessWidget {
  const ProviderSelectionList({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onAdd,
    this.registry,
    this.onEdit,
    this.isWeb,
  });

  /// The currently selected provider (a [ProviderPreset] or [CustomProvider]).
  final Object selected;

  /// Called when the user taps a provider row.
  final ValueChanged<Object> onSelect;

  /// Called when the user taps "Add provider".
  final VoidCallback onAdd;

  /// The provider registry (for saved custom providers).
  final ProviderRegistry? registry;

  /// Called when the user taps the edit action on a custom provider.
  /// When null, the edit button is hidden.
  final ValueChanged<CustomProvider>? onEdit;

  /// Overrides `kIsWeb` for platform visibility filtering (tests).
  final bool? isWeb;

  bool _isSelected(Object provider) {
    final sel = selected;
    if (sel is ProviderPreset && provider is ProviderPreset) {
      return sel == provider;
    }
    if (sel is CustomProvider && provider is CustomProvider) {
      return sel.id == provider.id;
    }
    return false;
  }

  /// Platform visibility filter matching the old dropdown's logic: on-device
  /// presets are hidden when the platform doesn't support them.
  static bool _isPresetVisible(ProviderPreset preset, {bool? isWeb}) {
    final web = isWeb ?? kIsWeb;
    return switch (preset) {
      ProviderPreset.webllm => webLlmProviderVisible(isWeb: web),
      ProviderPreset.gemma => gemmaProviderVisible(
        isWeb: web,
        platform: defaultTargetPlatform,
      ),
      ProviderPreset.transformersJs => transformersJsProviderVisible(
        isWeb: web,
      ),
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    final registry = this.registry ?? ProviderRegistry.inMemory();
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // All presets (hosted + custom + on-device), filtered by
            // platform visibility — same set as the old dropdown had.
            for (final preset in ProviderPreset.values)
              if (_isPresetVisible(preset, isWeb: isWeb))
                _buildRow(
                  context,
                  theme,
                  colors,
                  label: preset.labelFor(context),
                  subtitle: preset.baseUrl != null
                      ? providerHostOf(preset.baseUrl!)
                      : null,
                  selected: _isSelected(preset),
                  onTap: () => onSelect(preset),
                ),
            // Saved custom providers.
            for (final provider in registry.providers)
              _buildRow(
                context,
                theme,
                colors,
                label: provider.name,
                subtitle: provider.modelId.isEmpty
                    ? providerHostOf(provider.baseUrl)
                    : '${provider.modelId} · ${providerHostOf(provider.baseUrl)}',
                selected: _isSelected(provider),
                onTap: () => onSelect(provider),
                onEdit: onEdit != null ? () => onEdit!(provider) : null,
              ),
            // Add provider row.
            _buildRow(
              context,
              theme,
              colors,
              label: 'Add provider',
              leading: Icons.add,
              onTap: onAdd,
            ),
          ],
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme,
    FahColors colors, {
    required String label,
    String? subtitle,
    bool selected = false,
    IconData leading = Icons.cloud_outlined,
    VoidCallback? onTap,
    VoidCallback? onEdit,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? (theme.brightness == Brightness.light
                  ? const Color(0xFFEEF2FF)
                  : colors.panelAlt)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(leading, size: 20, color: colors.indigo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? colors.text : colors.dim,
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.dim,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (onEdit != null)
              InkWell(
                onTap: onEdit,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colors.dim,
                  ),
                ),
              )
            else if (selected)
              Icon(Icons.check, size: 20, color: colors.indigo)
            else
              Icon(
                Icons.chevron_right,
                size: 18,
                color: colors.borderBright,
              ),
          ],
        ),
      ),
    );
  }
}
