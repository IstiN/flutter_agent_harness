// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_navigation.dart';
import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/widgets.dart';

/// Opens the existing transcription-model configuration flow.
///
/// A mounted [fa_ui.MediaModelsScope] goes straight to the
/// [fa_ui.MediaSlot.transcription] provider/model editor and persists the
/// result in that same store. Lightweight embedders without a media store
/// still land on the Providers & Models settings surface rather than a dead
/// Settings button.
Future<void> openAsrTranscriptionSettings(
  BuildContext context, {
  required AgentService service,
  ProviderRegistry? registry,
  LastConnectionStore? lastConnectionStore,
}) async {
  AppAnalytics.instance.screenOpened('asr_transcription_settings');
  const slot = fa_ui.MediaSlot.transcription;
  final store = fa_ui.MediaModelsScope.maybeOf(context);
  if (store == null) {
    await fa_ui.pushFaPage<void>(
      context,
      SettingsScreen(
        service: service,
        env: service.env,
        registry: registry,
        lastConnectionStore: lastConnectionStore,
        categorized: true,
        category: SettingsCategory.providersModels,
      ),
      dialogMaxWidth: 840,
    );
    return;
  }

  final result = await fa_ui.pushFaPage<fa_ui.MediaSlotEditorResult>(
    context,
    fa_ui.MediaSlotProviderPickerPage(
      slot: slot,
      title: context.l10n.mediaModelsEditTitle(
        context.l10n.mediaModelsSlotTranscription,
      ),
      initial: store.overrideFor(slot),
      mainBaseUrl: service.activeBaseUrl,
      registry: registry,
      connectedOnly: true,
    ),
  );
  if (result == null) return;
  await store.setOverride(slot, result.cleared ? null : result.override);
}
