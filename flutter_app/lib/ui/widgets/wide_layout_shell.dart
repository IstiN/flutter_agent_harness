import 'dart:async';

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The wide-screen adaptive shell: a 3-pane layout with a collapsible
/// sidebar (sessions list + Settings/Files nav) on the left, the active
/// session's chat in the center, and the apps launcher panel (with its own
/// nested [Navigator] so JS apps open inline within the panel) on the right.
/// Used at widths `>=` [kWideLayoutBreakpoint] (900 px).
class WideLayoutShell extends StatefulWidget {
  const WideLayoutShell({
    super.key,
    required this.manager,
    this.registry,
    this.lastConnectionStore,
    this.sessionNamesStore,
    this.layoutStore,
    this.appsStore,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
    this.audioControllerFactory,
    this.videoControllerFactory,
    this.tileEngineFactory,
  });

  final FlutterSessionManager manager;
  final ProviderRegistry? registry;
  final LastConnectionStore? lastConnectionStore;
  final SessionNamesStore? sessionNamesStore;
  final LauncherLayoutStore? layoutStore;
  final AppsStore? appsStore;
  final UploadPicker? uploadPicker;
  final AsrApi? asr;
  final AsrTranscriber? asrTranscriber;
  final SandboxAudioControllerFactory? audioControllerFactory;
  final SandboxVideoControllerFactory? videoControllerFactory;
  final TileEngineFactory? tileEngineFactory;

  @override
  State<WideLayoutShell> createState() => _WideLayoutShellState();
}

class _WideLayoutShellState extends State<WideLayoutShell> {
  bool _sidebarCollapsed = false;

  /// Width of the right-side apps panel.
  static const double _appsPanelWidth = 380;

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Row(
      children: [
        // Left: collapsible sidebar.
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          width: _sidebarCollapsed ? 60 : 240,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: colors.border)),
          ),
          child: _buildSidebar(colors),
        ),
        // Center: chat (always visible when a session is active).
        Expanded(child: _buildChatArea(colors)),
        // Right: apps panel — a nested Navigator so launched apps push
        // within the panel instead of replacing the whole screen.
        Container(
          width: _appsPanelWidth,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: colors.border)),
          ),
          child: _buildAppsArea(),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sidebar
  // ---------------------------------------------------------------------------

  Widget _buildSidebar(FahColors colors) {
    return Container(
      color: colors.panel,
      child: Column(
        children: [
          _buildBrandHeader(colors),
          Divider(height: 1, thickness: 1, color: colors.border),
          Expanded(
            child: SidebarSessionsList(
              manager: widget.manager,
              sessionNamesStore: widget.sessionNamesStore,
              collapsed: _sidebarCollapsed,
              onNewSession: _newSession,
              onSessionTap: () => setState(() {}),
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.border),
          _buildNavItems(colors),
          _buildModelFooter(colors),
        ],
      ),
    );
  }

  Widget _buildBrandHeader(FahColors colors) {
    final brandIcon = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: colors.brandGradient,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          context.l10n.appTitle,
          style: TextStyle(
            color: colors.onAccent,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );

    if (_sidebarCollapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            brandIcon,
            const SizedBox(height: 8),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(() => _sidebarCollapsed = false),
              iconSize: 20,
              color: colors.dim,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: 'Expand', // l10n:ignore
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      child: Row(
        children: [
          brandIcon,
          const SizedBox(width: 10),
          Text(
            'Fa', // l10n:ignore
            style: TextStyle(
              color: colors.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _sidebarCollapsed = true),
            iconSize: 20,
            color: colors.dim,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Collapse', // l10n:ignore
          ),
        ],
      ),
    );
  }

  Widget _buildNavItems(FahColors colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SidebarNavItem(
            icon: Icons.folder_outlined,
            label: context.l10n.chatFilesTooltip,
            selected: false,
            collapsed: _sidebarCollapsed,
            onTap: _openFiles,
          ),
          SidebarNavItem(
            icon: Icons.settings_outlined,
            label: context.l10n.settingsTitle,
            selected: false,
            collapsed: _sidebarCollapsed,
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildModelFooter(FahColors colors) {
    final modelId = widget.manager.active?.service.modelId;
    if (_sidebarCollapsed) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Center(child: Icon(Icons.memory, size: 16, color: colors.dim)),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.memory, size: 16, color: colors.dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              modelId ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.dim, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Chat (center)
  // ---------------------------------------------------------------------------

  Widget _buildChatArea(FahColors colors) {
    final active = widget.manager.active;
    if (active == null) {
      return _buildPlaceholder(colors);
    }
    return ChatScreen(
      manager: widget.manager,
      registry: widget.registry,
      lastConnectionStore: widget.lastConnectionStore,
      uploadPicker: widget.uploadPicker,
      asr: widget.asr,
      asrTranscriber: widget.asrTranscriber,
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
    );
  }

  Widget _buildPlaceholder(FahColors colors) {
    return Center(
      child: Text(
        'No active session', // l10n:ignore
        style: TextStyle(color: colors.dim, fontSize: 14),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Apps panel (right) — nested Navigator
  // ---------------------------------------------------------------------------

  Widget _buildAppsArea() {
    // The nested Navigator ensures that calls to Navigator.of(context) from
    // within AppLauncherScreen (app launches via pushJsApp, Settings/Files
    // tiles) push within this panel rather than replacing the whole shell.
    return Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (context) => AppLauncherScreen(
          manager: widget.manager,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          layoutStore: widget.layoutStore,
          appsStore: widget.appsStore,
          sessionNamesStore: widget.sessionNamesStore,
          uploadPicker: widget.uploadPicker,
          asr: widget.asr,
          asrTranscriber: widget.asrTranscriber,
          audioControllerFactory: widget.audioControllerFactory,
          videoControllerFactory: widget.videoControllerFactory,
          tileEngineFactory: widget.tileEngineFactory,
          hideChatSheet: true,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _newSession() {
    final active = widget.manager.active;
    if (active == null) return;
    final service = active.service;
    final config = service.configForClone;
    if (config == null) return;
    unawaited(
      widget.manager.createSession(
        config: config,
        serviceFactory: () async => service.clone(),
      ),
    );
  }

  Future<void> _openSettings() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    AppAnalytics.instance.settingsOpened();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          service: service,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          layoutStore: widget.layoutStore,
        ),
      ),
    );
  }

  Future<void> _openFiles() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    AppAnalytics.instance.filesOpened('sidebar');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(context.l10n.chatFilesTooltip)),
          body: FileBrowser(
            env: service.env,
            inlinePreview: false,
            fsRevision: service.fsRevision,
            onProjectMountChanged: service.refreshProjectMountPrompt,
          ),
        ),
      ),
    );
  }
}
