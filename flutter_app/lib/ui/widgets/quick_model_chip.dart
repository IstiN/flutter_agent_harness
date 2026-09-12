// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/providers_section.dart' show agentConfigFrom;
import 'package:fa_ui/fa_ui.dart'
    show
        FahColors,
        FaChatModelConfig,
        FaUiHost,
        MediaSlotEditorResult,
        MediaSlotProviderPickerPage,
        pushFaPage;

/// The quick model-switch chip shared by BOTH layout headers (issue #167):
/// the wide shell's chat header and the mobile session panel render the
/// SAME compact chip (memory glyph + current model name), and a tap opens
/// the SAME unified model picker behind [openQuickModelPicker] — placement
/// and presentation differ per layout, never the switch logic.
///
/// The chip is wrapped in a [Material] so the [InkWell] ripple has
/// somewhere to paint — a plain Container ancestor would swallow the
/// gesture highlight.
class QuickModelChip extends StatelessWidget {
  const QuickModelChip({
    super.key,
    required this.modelId,
    required this.onTap,
    this.onLongPress,
    this.tooltip,
    this.maxWidth,
  });

  /// The active session's model id (the label).
  final String modelId;

  /// Opens the quick model picker.
  final VoidCallback onTap;

  /// Optional long-press action (the mobile chip jumps to model settings).
  final VoidCallback? onLongPress;

  /// Accessibility/hover label; renders nothing in the frame.
  final String? tooltip;

  /// Caps the chip width so very long model ids ellipsis-clamp instead of
  /// overflowing the header (narrow layouts).
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    Widget chip = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.memory, size: 14, color: colors.indigo),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  modelId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.dim,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (maxWidth != null) {
      chip = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: chip,
      );
    }
    if (tooltip != null) {
      chip = Tooltip(message: tooltip!, child: chip);
    }
    return chip;
  }
}

/// The unified picker page BOTH headers open (issue #167 parity): the
/// exact same two-step provider → model flow and config the settings
/// "Default chat model" row uses — desktop and mobile share this factory,
/// so the flows can never drift.
MediaSlotProviderPickerPage quickModelPickerPage(
  BuildContext context, {
  required AgentService service,
  required ProviderRegistry registry,
}) {
  return MediaSlotProviderPickerPage(
    slot: null,
    title: context.l10n.settingsDefaultChatModelTitle,
    initial: null,
    mainBaseUrl: service.activeBaseUrl,
    registry: registry,
    // Connected providers only — same as the role/media rows.
    connectedOnly: true,
    // Editing the main connection: no "Same as main" row.
    allowMainConnection: false,
  );
}

/// Presents [page] as a tall modal bottom sheet — the narrow-canvas
/// presentation of the quick model picker (wide keeps [pushFaPage]'s
/// dialog). The page pops its navigator with the result; the sheet route
/// carries it back to the caller.
Future<T?> pushQuickModelSheet<T>(BuildContext context, Widget page) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * 0.8,
      child: page,
    ),
  );
}

/// Opens the quick model picker and applies the choice to [service] — the
/// ONE code path behind both headers' chips (issue #167). Presentation
/// adapts to the canvas: [pushFaPage] (dialog on wide) unless
/// [asBottomSheet] (the mobile session panel). The apply path — key
/// resolution, [AgentService.reconfigure], last-connection persist — is
/// identical on every layout, so mid-run switch semantics match desktop
/// exactly.
Future<void> openQuickModelPicker(
  BuildContext context, {
  required AgentService service,
  required ProviderRegistry registry,
  LastConnectionStore? lastConnectionStore,
  bool asBottomSheet = false,
}) async {
  final page = quickModelPickerPage(
    context,
    service: service,
    registry: registry,
  );
  final result = asBottomSheet
      ? await pushQuickModelSheet<MediaSlotEditorResult>(context, page)
      : await pushFaPage<MediaSlotEditorResult>(context, page);
  if (result == null || result.cleared) return;
  if (!context.mounted) return;
  final override = result.override!;
  String? resolvedKey;
  if (override.apiKeyName != null && override.apiKeyName!.isNotEmpty) {
    resolvedKey = registry.keyValueForName(override.apiKeyName!) ?? '';
    if (resolvedKey.isEmpty) {
      resolvedKey = FaUiHost.resolveKey(override.apiKeyName!, () => '');
    }
  }
  final config = FaChatModelConfig(
    providerKind: override.providerKind,
    modelId: override.modelId,
    baseUrl: override.baseUrl,
    apiKey: resolvedKey ?? '',
    providerId: override.providerId,
  );
  final agentConfig = agentConfigFrom(config);
  await service.reconfigure(agentConfig);
  await lastConnectionStore?.saveFromConfig(agentConfig);
}
