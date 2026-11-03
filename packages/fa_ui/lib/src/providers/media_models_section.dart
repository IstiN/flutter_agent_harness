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
import 'package:fa_ui/src/theme/fa2_tokens.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';
import 'package:fa_ui/src/widgets/fa2_controls.dart';

/// The settings "Media models" section: one row per [MediaSlot] showing the
/// slot's override (`model · provider`), the explicit "Same as main
/// connection" opt-in (gh-1844), or "Not configured" — the main connection
/// is never shown as an inherited default. Tapping a row pushes the
/// two-step flow ([MediaSlotProviderPickerPage] → [MediaSlotModelPage]);
/// picking "Same as main connection" saves the opt-in override.
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
    final tokens = FaDesignTokens.of(context);
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
            // The section eyebrow: the shared dim label treatment so the
            // card reads as one settings group.
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Text(
                strings.mediaModelsSectionTitle,
                style: TextStyle(
                  color: tokens.ink2,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                strings.mediaModelsSectionNote,
                style: TextStyle(
                  color: tokens.ink2,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            // One grouped card: 44px+ token rows with hairline separators
            // (the bare list-with-chevrons idiom leaked stock M3 ink).
            FaSurface(
              borderRadius: BorderRadius.circular(14),
              child: Column(
                children: [
                  for (final (i, slot) in MediaSlot.all.indexed) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: 48,
                        color: tokens.hairline,
                      ),
                    _buildSlotRow(context, theme, strings, store, slot),
                  ],
                ],
              ),
            ),
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
    final tokens = FaDesignTokens.of(context);
    final override = store.overrideFor(slot);
    // Overrides are summarized with the provider NAME, never the raw URL;
    // an override whose URL matches no known provider falls back to the
    // host (a hand-edited store file).
    final provider = override == null
        ? null
        : providerForBaseUrl(override.baseUrl, registry);
    final unconfigured = override == null;
    final summary = unconfigured
        // gh-1844: no override = UNCONFIGURED — never an inherited main
        // endpoint.
        ? strings.mediaModelsUnconfiguredSummary
        : override.useMainConnection
        ? strings.mediaModelsFallbackSummary
        : strings.mediaModelsOverrideSummary(
            provider != null
                ? providerDisplayName(context, provider)
                : _hostOf(override.baseUrl),
            override.modelId,
          );
    // Hierarchy: a configured slot's summary is secondary ink; the dim
    // tertiary ink is reserved for the unconfigured callout.
    final summaryColor = unconfigured ? tokens.ink3 : tokens.ink2;
    return InkWell(
      onTap: () => _editSlot(context, store, slot),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(slotIcons[slot] ?? Icons.tune, size: 20, color: tokens.ink2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slotLabelFor(strings, slot),
                      style: TextStyle(
                        color: tokens.ink1,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                    Text(
                      summary,
                      style: TextStyle(
                        color: summaryColor,
                        fontSize: 12,
                        height: 1.35,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right, size: 18, color: tokens.ink3),
            ],
          ),
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
