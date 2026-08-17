// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/media_slot_picker_page.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/media_models_store.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// The settings "Media models" section: one row per [MediaSlot] showing the
/// effective endpoint — the slot's override (`model · provider`) or the main
/// connection fallback. Tapping a row pushes the two-step flow
/// ([MediaSlotProviderPickerPage] → [MediaSlotModelPage]); picking "Same as
/// main connection" removes the override, restoring the fallback.
///
/// The store comes from [store] or the nearest [MediaModelsScope]; the whole
/// section hides when no store is available (tests pumping the bare form).
/// [mainBaseUrl] supplies the main connection's base URL for the editor's
/// placeholder/default; host instrumentation (analytics) rides the
/// [onSlotEditorOpened]/[onSlotOverrideSaved] callbacks.
class MediaModelsSection extends StatelessWidget {
  const MediaModelsSection({
    super.key,
    this.store,
    this.mainBaseUrl = '',
    this.registry,
    this.modelsFetcher,
    this.onSlotEditorOpened,
    this.onSlotOverrideSaved,
  });

  /// Store override; falls back to the nearest [MediaModelsScope].
  final MediaModelsStore? store;

  /// The main connection's base URL, shown under the editor's "Same as main
  /// connection" row. Empty when no connection is active.
  final String mainBaseUrl;

  /// The provider registry: slot rows summarize overrides with the
  /// provider NAME (never the URL), and the slot editor lists the saved
  /// custom providers. `null` summarizes unknown URLs by host.
  final ProviderRegistry? registry;

  /// `/models` fetch override (tests), forwarded to the editor page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// Host hook fired when a slot's editor is opened (analytics).
  final void Function(String slot)? onSlotEditorOpened;

  /// Host hook fired after a slot override was saved or cleared (analytics).
  final void Function(String slot)? onSlotOverrideSaved;

  /// The icon each slot's row (and the model preset combo summary) shows.
  static const slotIcons = <String, IconData>{
    MediaSlot.imageGeneration: Icons.image_outlined,
    MediaSlot.audioTts: Icons.record_voice_over_outlined,
    MediaSlot.musicGeneration: Icons.music_note_outlined,
    MediaSlot.videoGeneration: Icons.videocam_outlined,
    MediaSlot.vision: Icons.visibility_outlined,
    MediaSlot.transcription: Icons.transcribe_outlined,
  };

  /// The localized label for [slot] (the raw name for unknown slots).
  static String slotLabelFor(FaUiStrings strings, String slot) =>
      faMediaSlotLabel(strings, slot);

  /// The host part of [baseUrl] for the row summary (the raw string when it
  /// does not parse as a URI with a host).
  static String _hostOf(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    return host.isEmpty ? baseUrl : host;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final store = this.store ?? MediaModelsScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.mediaModelsSectionTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              strings.mediaModelsSectionNote,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final slot in MediaSlot.all)
              _buildSlotRow(context, theme, strings, store, slot),
          ],
        );
      },
    );
  }

  Widget _buildSlotRow(
    BuildContext context,
    ThemeData theme,
    FaUiStrings strings,
    MediaModelsStore store,
    String slot,
  ) {
    final override = store.overrideFor(slot);
    // Overrides are summarized with the provider NAME, never the raw URL;
    // an override whose URL matches no known provider falls back to the
    // host (a hand-edited store file).
    final provider = override == null
        ? null
        : providerForBaseUrl(override.baseUrl, registry);
    final summary = override == null
        ? strings.mediaModelsFallbackSummary
        : strings.mediaModelsOverrideSummary(
            provider != null
                ? providerDisplayName(context, provider)
                : _hostOf(override.baseUrl),
            override.modelId,
          );
    return InkWell(
      onTap: () => _editSlot(context, store, slot),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              slotIcons[slot] ?? Icons.tune,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(slotLabelFor(strings, slot)),
                  Text(
                    summary,
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

  Future<void> _editSlot(
    BuildContext context,
    MediaModelsStore store,
    String slot,
  ) async {
    onSlotEditorOpened?.call(slot);
    final strings = FaUiStrings.of(context);
    // pushFaPage shows a dialog on wide screens, a full page on narrow.
    final result = await pushFaPage<MediaSlotEditorResult>(
      context,
      MediaSlotProviderPickerPage(
        slot: slot,
        title: strings.mediaModelsEditTitle(slotLabelFor(strings, slot)),
        initial: store.overrideFor(slot),
        mainBaseUrl: mainBaseUrl,
        registry: registry,
        modelsFetcher: modelsFetcher,
        // Media slots choose among connected providers only.
        connectedOnly: true,
      ),
    );
    if (result == null) return;
    await store.setOverride(slot, result.cleared ? null : result.override);
    onSlotOverrideSaved?.call(slot);
  }
}
