import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
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

/// The tabs switchable from the sidebar.
enum WideLayoutTab { home, chat, files, settings }

/// The wide-screen adaptive shell: a 240 px sidebar (sessions list + nav
/// items + model footer) on the left, and the active tab's content
/// (launcher grid, chat, files, or settings) on the right. Used at widths
/// `>=` [kWideLayoutBreakpoint] (900 px).
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
  WideLayoutTab _tab = WideLayoutTab.home;

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
        SizedBox(width: 240, child: _buildSidebar(colors)),
        Expanded(child: _buildContent(colors)),
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
              onNewSession: () => setState(() => _tab = WideLayoutTab.chat),
              onSessionTap: () => setState(() => _tab = WideLayoutTab.chat),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          Container(
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
          ),
          const SizedBox(width: 10),
          Text(
            'fa1.dev', // l10n:ignore
            style: TextStyle(
              color: colors.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
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
            icon: Icons.grid_view_rounded,
            label: 'Home', // l10n:ignore
            selected: _tab == WideLayoutTab.home,
            onTap: () => setState(() => _tab = WideLayoutTab.home),
          ),
          SidebarNavItem(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Chat', // l10n:ignore
            selected: _tab == WideLayoutTab.chat,
            onTap: () => setState(() => _tab = WideLayoutTab.chat),
          ),
          SidebarNavItem(
            icon: Icons.folder_outlined,
            label: 'Files', // l10n:ignore
            selected: _tab == WideLayoutTab.files,
            onTap: () => setState(() => _tab = WideLayoutTab.files),
          ),
          SidebarNavItem(
            icon: Icons.settings_outlined,
            label: 'Settings', // l10n:ignore
            selected: _tab == WideLayoutTab.settings,
            onTap: () => setState(() => _tab = WideLayoutTab.settings),
          ),
        ],
      ),
    );
  }

  Widget _buildModelFooter(FahColors colors) {
    final modelId = widget.manager.active?.service.modelId;
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
  // Content
  // ---------------------------------------------------------------------------

  Widget _buildContent(FahColors colors) {
    switch (_tab) {
      case WideLayoutTab.home:
        return AppLauncherScreen(
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
        );
      case WideLayoutTab.chat:
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
      case WideLayoutTab.files:
        final service = widget.manager.active?.service;
        if (service == null) return _buildPlaceholder(colors);
        return FileBrowser(
          env: service.env,
          fsRevision: service.fsRevision,
          uploadPicker: widget.uploadPicker,
        );
      case WideLayoutTab.settings:
        final service = widget.manager.active?.service;
        if (service == null) return _buildPlaceholder(colors);
        return SettingsScreen(
          service: service,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          layoutStore: widget.layoutStore,
        );
    }
  }

  Widget _buildPlaceholder(FahColors colors) {
    return Center(
      child: Text(
        'No active session', // l10n:ignore
        style: TextStyle(color: colors.dim, fontSize: 14),
      ),
    );
  }
}
