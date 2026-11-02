// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter/material.dart';

/// A live app presented by the messenger shell. The global key preserves the
/// JS runtime when the same surface moves between side panel and Full.
final class MessengerAppPresentation {
  MessengerAppPresentation({
    required this.app,
    required this.service,
    required this.appService,
    required this.permissionsStore,
  });

  final JsAppInfo app;
  final AgentService service;
  final AgentService appService;
  final AppPermissionsStore permissionsStore;
  final GlobalKey viewKey = GlobalKey();
  bool pinned = false;
  bool fullScreen = false;
}

/// Hosts one app without a route change, matching the PoC side/overlay model.
final class MessengerAppPanel extends StatelessWidget {
  const MessengerAppPanel({
    super.key,
    required this.presentation,
    required this.manager,
    required this.onFullScreen,
    required this.onPin,
    required this.onClose,
  });

  final MessengerAppPresentation presentation;
  final FlutterSessionManager manager;
  final VoidCallback onFullScreen;
  final VoidCallback onPin;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final service = presentation.service;
    return ColoredBox(
      key: const ValueKey('messengerAppPanel'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: JsAppView(
        key: presentation.viewKey,
        app: presentation.app,
        env: service.env,
        permissionsStore: presentation.permissionsStore,
        llmHandler: service.completeOnce,
        onSendToAgent: (message) => forwardAppMessageToAgent(manager, message),
        fsRevision: service.fsRevision,
        agentService: presentation.appService,
        embeddedInPanel: !presentation.fullScreen,
        panelChrome: JsAppPanelChrome(
          fullScreen: presentation.fullScreen,
          pinned: presentation.pinned,
          onFullScreen: onFullScreen,
          onPin: onPin,
          onClose: onClose,
        ),
      ),
    );
  }
}
