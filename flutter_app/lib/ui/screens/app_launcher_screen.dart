// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/session_names_store.dart'
    show SessionNamesStore, derivedSessionTitle;
import 'package:fa/services/upload.dart';
import 'package:fa/ui/widgets/my_apps_shell.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import '../../apps/app_tile_host.dart';

/// The mobile home (narrow layouts < [kWideLayoutBreakpoint]). Hosts the
/// shared [MyAppsShell] (mobile mode) with the floating [SessionChatSheet]
/// stacked above. The old iOS-grid drag-and-drop launcher (folders,
/// reorder, tile engines) was retired when MyAppsShell unified the panel +
/// mobile layout — see [MyAppsShell].
///
/// [LauncherLayoutStore] / [TileEngineFactory] are kept as accepted
/// parameters so legacy callers and tests don't break; they're simply
/// unused now. Drop them in a follow-up when the layout-store migration
/// is finalised.
class AppLauncherScreen extends StatefulWidget {
  const AppLauncherScreen({
    super.key,
    required this.manager,
    this.registry,
    this.lastConnectionStore,
    this.layoutStore,
    this.appsStore,
    this.sessionNamesStore,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
    this.audioControllerFactory,
    this.videoControllerFactory,
    this.tileEngineFactory,
    this.hideChatSheet = false,
  });

  final FlutterSessionManager manager;

  /// The custom-provider registry handed to the settings screen.
  final ProviderRegistry? registry;

  /// The last-connection store handed to the settings screen.
  final LastConnectionStore? lastConnectionStore;

  /// Legacy param — kept for API compatibility. The unified MyAppsShell
  /// doesn't persist tile order.
  final LauncherLayoutStore? layoutStore;

  /// App discovery/seeding; tests inject one with canned assets.
  final AppsStore? appsStore;

  /// The user-given session titles shown in the chat sheet header.
  final SessionNamesStore? sessionNamesStore;

  /// File chooser for the chat sheet's composer.
  final UploadPicker? uploadPicker;

  /// Microphone backend override for the chat sheet's composer (tests).
  final AsrApi? asr;

  /// Transcriber override for the chat sheet's composer (tests).
  final AsrTranscriber? asrTranscriber;

  /// Playback engine factory for inline audio in the chat sheet transcript.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video in the chat sheet transcript.
  final SandboxVideoControllerFactory? videoControllerFactory;

  /// Legacy param — kept for API compatibility.
  final TileEngineFactory? tileEngineFactory;

  /// When true the [SessionChatSheet] floating overlay is NOT rendered —
  /// the wide-screen [WideLayoutShell] owns chat instead.
  final bool hideChatSheet;

  @override
  State<AppLauncherScreen> createState() => _AppLauncherScreenState();
}

class _AppLauncherScreenState extends State<AppLauncherScreen> {
  /// Key into the session chat sheet so the optional session-chip overlay
  /// can expand it.
  final _sheetKey = GlobalKey<SessionChatSheetState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Bottom false: the stack reaches the screen's bottom edge so the
      // floating mini chat bar hovers over the MyAppsShell surface (not
      // over an empty scaffold-colored band) and the expanded sheet docks
      // edge-to-edge; MyAppsShell keeps its own bottom clearance.
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            ManagerScope(
              manager: widget.manager,
              child: MyAppsShell(
                manager: widget.manager,
                appsStore: widget.appsStore,
                mode: MyAppsShellMode.mobile,
              ),
            ),
            if (!widget.hideChatSheet)
              SessionChatSheet(
                key: _sheetKey,
                manager: widget.manager,
                registry: widget.registry,
                lastConnectionStore: widget.lastConnectionStore,
                sessionNamesStore: widget.sessionNamesStore,
                uploadPicker: widget.uploadPicker,
                asr: widget.asr,
                asrTranscriber: widget.asrTranscriber,
                audioControllerFactory: widget.audioControllerFactory,
                videoControllerFactory: widget.videoControllerFactory,
              ),
            // The header session chip (active session title) — tap
            // expands the chat sheet. Optional; matches the prototype's
            // "header → sheet" affordance.
            Positioned(
              top: 8,
              right: 16,
              child: _SessionChip(
                manager: widget.manager,
                sessionNamesStore: widget.sessionNamesStore,
                onTap: () => _sheetKey.currentState?.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The active-session indicator in the header — tap to expand the chat
/// sheet. Rebuilds on manager changes (switch/rename).
class _SessionChip extends StatelessWidget {
  const _SessionChip({
    required this.manager,
    required this.sessionNamesStore,
    required this.onTap,
  });

  final FlutterSessionManager manager;
  final SessionNamesStore? sessionNamesStore;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = manager.active;
    if (active == null) return const SizedBox.shrink();
    final colors = FahColors.of(context);
    final title =
        sessionNamesStore?.titleFor(active.id) ??
        derivedSessionTitle(
          context,
          id: active.id,
          createdAt: active.createdAt,
        );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: colors.panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 14, color: colors.dim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.dim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}