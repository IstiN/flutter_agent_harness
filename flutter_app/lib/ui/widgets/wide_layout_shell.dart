import 'dart:async';

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';

import 'package:fa/ui/widgets/apps_panel.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/providers_section.dart' show agentConfigFrom;
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
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

  /// Width of the right-side apps panel (user-resizable via drag handle).
  double _appsPanelWidth = 380;

  /// Minimum/maximum width for the apps panel drag handle.
  static const double _appsPanelMinWidth = 240;
  static const double _appsPanelMaxWidth = 640;

  /// Whether we're on macOS desktop (traffic lights float over content).
  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  void _onManagerChanged() {
    _subscribeToActiveService();
    if (mounted) setState(() {});
  }

  /// Rebuilds when the active service notifies (model change, reconfigure).
  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  /// The service we're currently listening to (for model-change rebuilds).
  AgentService? _listenedService;

  void _subscribeToActiveService() {
    final active = widget.manager.active?.service;
    if (active == _listenedService) return;
    _listenedService?.removeListener(_onServiceChanged);
    _listenedService = active;
    active?.addListener(_onServiceChanged);
  }

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    _subscribeToActiveService();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _listenedService?.removeListener(_onServiceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    // Material ancestor is REQUIRED — without it, Text widgets get the
    // debug-mode yellow double-underline style.
    return Material(
      color: colors.bg,
      child: Row(
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
          // Drag handle: resizes the apps panel.
          _PaneDragHandle(
            onDrag: (dx) => setState(() {
              _appsPanelWidth = (_appsPanelWidth - dx).clamp(
                _appsPanelMinWidth,
                _appsPanelMaxWidth,
              );
            }),
          ),
          // Right: apps panel — a nested Navigator so launched apps push
          // within the panel instead of replacing the whole screen.
          SizedBox(width: _appsPanelWidth, child: _buildAppsArea()),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sidebar
  // ---------------------------------------------------------------------------

  Widget _buildSidebar(FahColors colors) {
    // SelectionContainer.disabled prevents macOS spell-check squiggly
    // underlines from appearing on sidebar text widgets.
    return SelectionContainer.disabled(
      child: Container(
        // Light theme: sidebar uses bg (#F8F9FC) for the subtle gray look
        // matching the prototype; dark theme: uses panel for the dark look.
        color: Theme.of(context).brightness == Brightness.light
            ? colors.bg
            : colors.panel,
        child: Column(
          children: [
            _buildBrandHeader(colors),
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
      ),
    );
  }

  Widget _buildBrandHeader(FahColors colors) {
    // The Fa brand mark: sparkle SVG without any background (matching the
    // prototype's clean icon style).
    const brandIcon = SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: SizedBox(width: 24, height: 24, child: FaMark(size: 24)),
      ),
    );

    if (_sidebarCollapsed) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: _isMacOS ? 28 : 16),
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
      // macOS: extra top padding to clear the floating traffic lights
      // (the content now extends to the window top — no global 28px strip).
      padding: EdgeInsets.fromLTRB(16, _isMacOS ? 28 : 16, 8, 12),
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
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    return Column(
      children: [
        // Workspace header matching the prototype: name + dropdown arrow + edit icon.
        // No bottom border — the vertical dividers between panels run full height.
        Container(
          padding: EdgeInsets.fromLTRB(20, _isMacOS ? 28 : 12, 12, 8),
          decoration: BoxDecoration(
            color: isLight ? colors.panel : colors.panel,
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () {}, // Workspace picker placeholder
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Personal Workspace',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 16,
                        color: colors.dim,
                      ),
                    ],
                  ),
                ),
              ),
              // Quick model switch: current model name → tap opens the
              // unified model picker (all providers, filter).
              InkWell(
                onTap: () => _openModelPicker(active),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.memory, size: 14, color: colors.indigo),
                      const SizedBox(width: 4),
                      Text(
                        active.service.modelId,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.dim,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () {}, // Edit workspace placeholder
                iconSize: 18,
                color: colors.dim,
                tooltip: 'Edit workspace', // l10n:ignore — prototype redesign ships en-only copy for now
              ),
            ],
          ),
        ),
        // Chat area (fills the rest).
        Expanded(
          child: ChatScreen(
            manager: widget.manager,
            registry: widget.registry,
            lastConnectionStore: widget.lastConnectionStore,
            uploadPicker: widget.uploadPicker,
            asr: widget.asr,
            asrTranscriber: widget.asrTranscriber,
            audioControllerFactory: widget.audioControllerFactory,
            videoControllerFactory: widget.videoControllerFactory,
          ),
        ),
      ],
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
    // within the apps panel (app launches via pushJsApp, Settings/Files
    // tiles) push within this panel rather than replacing the whole shell.
    return Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (context) => ManagerScope(
          manager: widget.manager,
          child: AppsPanel(
            manager: widget.manager,
            appsStore: widget.appsStore,
            sessionNamesStore: widget.sessionNamesStore,
          ),
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

  /// Opens the unified model picker so the user can quickly switch models
  /// across all configured providers without leaving the chat.
  Future<void> _openModelPicker(FlutterManagedSession session) async {
    final service = session.service;
    final registry = widget.registry;
    final lastConnectionStore = widget.lastConnectionStore;
    if (registry == null) return;
    await pushFaPage<void>(
      context,
      UnifiedModelPickerPage(
        connection: service,
        onApply: (config) async {
          final agentConfig = agentConfigFrom(config);
          await service.reconfigure(agentConfig);
          await lastConnectionStore?.saveFromConfig(agentConfig);
        },
        registry: registry,
      ),
    );
  }

  Future<void> _openSettings() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    AppAnalytics.instance.settingsOpened();
    if (!mounted) return;
    // pushFaPage shows a dialog (maxWidth 560) on wide screens, a full-page
    // route on narrow — matches the prototype's popup style.
    await pushFaPage<void>(
      context,
      SettingsScreen(
        service: service,
        registry: widget.registry,
        lastConnectionStore: widget.lastConnectionStore,
        layoutStore: widget.layoutStore,
      ),
    );
  }

  Future<void> _openFiles() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    AppAnalytics.instance.filesOpened('sidebar');
    if (!mounted) return;
    await pushFaPage<void>(
      context,
      Scaffold(
        appBar: AppBar(title: Text(context.l10n.chatFilesTooltip)),
        body: FileBrowser(
          env: service.env,
          inlinePreview: false,
          fsRevision: service.fsRevision,
          onProjectMountChanged: service.refreshProjectMountPrompt,
        ),
      ),
    );
  }
}

/// A draggable vertical divider between panes. The user grabs it and drags
/// horizontally to resize the adjacent panel. Renders a 1px line that
/// thickens on hover with a subtle color change.
class _PaneDragHandle extends StatefulWidget {
  const _PaneDragHandle({required this.onDrag});

  /// Called with the horizontal delta of each drag update.
  final void Function(double dx) onDrag;

  @override
  State<_PaneDragHandle> createState() => _PaneDragHandleState();
}

class _PaneDragHandleState extends State<_PaneDragHandle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 6,
          color: _hovering
              ? colors.indigo.withValues(alpha: 0.3)
              : colors.border,
          child: Center(
            child: Container(
              width: 2,
              height: 32,
              decoration: BoxDecoration(
                color: _hovering ? colors.indigo : colors.dim,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
