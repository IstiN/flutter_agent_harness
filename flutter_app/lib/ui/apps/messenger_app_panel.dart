// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/apps/presentation_panel_card.dart';
import 'package:fa_ui/fa_ui.dart';
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
///
/// Docked (side panel / floating overlay) the app lives on a floating glass
/// card — 8pt margins and rounded corners, the same chrome language as the
/// sidebar and the chat pane's floating surfaces; the Full overlay stays
/// edge-to-edge for the immersive canvas.
final class MessengerAppPanel extends StatelessWidget {
  const MessengerAppPanel({
    super.key,
    required this.presentation,
    required this.manager,
    required this.onFullScreen,
    required this.onPin,
    required this.onClose,
    this.onMinimize,
    this.onBack,
    this.onQuickApps,
  });

  final MessengerAppPresentation presentation;
  final FlutterSessionManager manager;
  final VoidCallback onFullScreen;
  final VoidCallback onPin;
  final VoidCallback onClose;
  final VoidCallback? onMinimize;
  final VoidCallback? onBack;
  final VoidCallback? onQuickApps;

  @override
  Widget build(BuildContext context) {
    final service = presentation.service;
    final view = JsAppView(
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
        onMinimize: onMinimize,
        onBack: onBack,
        onQuickApps: onQuickApps,
      ),
    );
    if (presentation.fullScreen) {
      return ColoredBox(
        key: const ValueKey('messengerAppPanel'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: view,
      );
    }
    final wide =
        faWindowClassForWidth(MediaQuery.sizeOf(context).width) !=
        FaWindowClass.small;
    if (!wide) {
      // Phone apps keep a full-bleed canvas: no desktop card, outer margin or
      // resize substrate. The glass app chrome itself still applies.
      return KeyedSubtree(
        key: const ValueKey('messengerAppPanel'),
        child: view,
      );
    }
    return FaPresentationPanelCard(
      key: const ValueKey('messengerAppPanel'),
      cardKey: const ValueKey('messengerAppPanelCard'),
      contentPadding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
      child: view,
    );
  }
}
