// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/github_account_section.dart';
import 'package:fa/ui/widgets/widget_publish_sheet.dart';
import 'package:flutter/material.dart';

/// One-tap "save as app" (issue #102 AC7), shared by EVERY dynamic-widget
/// construction path (issue #457 AC3): installs the widget under a fresh
/// app id (storage COPIED by the service), then opens the launcher's
/// publish sheet so the user can optionally share it. Free function, not
/// a chat-screen method, so the launcher sheet, the app overlay, and the
/// chat screen all wire the same graduation instead of diverging paths
/// that left "Save as app" greyed out on some surfaces.
Future<void> graduateDynamicWidget(
  BuildContext context,
  AgentService service,
  DynamicMessageDefinition definition,
) async {
  final appId = await installGraduatedWidget(service, definition);
  if (!context.mounted) return;
  showGraduationSnackbar(context, appId);
  if (appId == null) return;
  final (account, ledger, publish) = await _graduationPublishTargets(
    context,
    service,
  );
  if (!context.mounted) return;
  await showWidgetPublishSheet(
    context,
    app: JsAppInfo.fromManifest(
      {
        'id': appId,
        'name': definition.title,
        'description': DynamicMessagesService.graduatedDescription(
          definition.title,
        ),
        'version': '1.0.0',
      },
      bundled: false,
      fallbackId: appId,
    ),
    account: account,
    service: publish,
    ledger: ledger,
  );
}

/// Installs [definition] under a fresh app id: [DynamicMessagesService]
/// refuses an id that already exists (returns null), so numbered title
/// suffixes 2..9 retry the install before the flow gives up.
@visibleForTesting
Future<String?> installGraduatedWidget(
  AgentService service,
  DynamicMessageDefinition definition,
) async {
  String? appId = await service.dynamicMessages.saveAsApp(
    definition,
    definition.title,
  );
  for (var suffix = 2; appId == null && suffix <= 9; suffix++) {
    appId = await service.dynamicMessages.saveAsApp(
      definition,
      '${definition.title} $suffix',
    );
  }
  return appId;
}

/// The saved/failed feedback for the graduation install.
@visibleForTesting
void showGraduationSnackbar(BuildContext context, String? appId) {
  final l10n = context.l10n;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        appId == null
            ? l10n.dynamicMessagesSaveFailed
            : l10n.dynamicMessagesSaved(appId),
      ),
    ),
  );
}

/// The publish-sheet collaborators for a freshly graduated app: the GitHub
/// account (session-keys scope first, else a store over a fresh load) and
/// the shared publication ledger.
Future<(GithubAccountStore, WidgetPublicationStore, WidgetPublishService)>
_graduationPublishTargets(BuildContext context, AgentService service) async {
  final keys = SessionKeysScope.maybeOf(context);
  final account = sharedGithubAccountStore(
    keys ?? await SessionKeysStore.load(service.env),
  );
  final ledger = await initSharedWidgetPublicationStore(service.env);
  return (
    account,
    ledger,
    WidgetPublishService(env: service.env, account: account, ledger: ledger),
  );
}
