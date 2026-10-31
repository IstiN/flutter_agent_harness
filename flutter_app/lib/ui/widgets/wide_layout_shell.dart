import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;

import 'package:path/path.dart' as p;

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/project_mount_flow.dart';
import 'package:fa/services/dap_binding_store.dart';
import 'package:fa/services/session_ui_prefs_store.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';

import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/network/network_center.dart';
import 'package:fa/ui/network/network_mode_chip.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:fa/ui/network/quick_switcher.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/quick_model_chip.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/boot_oversize_notice.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv, SessionMetadata, leaseOwnerLabel;

/// The responsive messenger shell: phones get a conversation list with
/// Chats / Activity / Apps bottom navigation; wider layouts get a collapsible
/// sidebar beside one selected center surface. Session state and actions are
/// shared by both forms.
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
    this.sessionPrefsStore,
    this.networkMode,
    this.networkSessions,
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

  /// Per-parent expand/collapse persistence for the sessions tree (issue
  /// #426). Null → the shell lazily loads one from the shared env.
  final SessionUiPrefsStore? sessionPrefsStore;

  /// Network mode (issue #955): when both are provided, the brand header
  /// carries the Local | Network mode chip — the entry into the network
  /// surface. Null (tests, non-network hosts) keeps the classic header.
  final NetworkModeController? networkMode;
  final NetworkSessionManager? networkSessions;

  @override
  State<WideLayoutShell> createState() => _WideLayoutShellState();
}

/// Whether we're on macOS desktop (traffic lights float over content).
bool get faIsMacOSDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// The sessions sidebar's resize handle (tests find it by this key).
const Key kSidebarDragHandleKey = ValueKey('sidebar-drag-handle');

/// An [AppBar] with the macOS traffic-light clearance baked in. Pushed
/// routes (Settings, Files, provider editor, …) otherwise render their
/// back button/title under the floating traffic lights — the window uses
/// fullSizeContentView and only the shell screens reserve their own strip.
PreferredSizeWidget faAppBar({
  Widget? title,
  List<Widget>? actions,
  Widget? leading,
  bool? centerTitle,
}) {
  final bar = AppBar(
    title: title,
    actions: actions,
    leading: leading,
    centerTitle: centerTitle,
  );
  if (!faIsMacOSDesktop) return bar;
  const inset = 32.0;
  return PreferredSize(
    preferredSize: const Size.fromHeight(kToolbarHeight + inset),
    child: Padding(
      padding: const EdgeInsets.only(top: inset),
      child: bar,
    ),
  );
}

enum _WideShellSection { chats, activity, apps }

class _WideLayoutShellState extends State<WideLayoutShell> {
  bool _sidebarCollapsed = false;
  _WideShellSection _section = _WideShellSection.chats;

  /// The Apps section's nested Navigator — registered on [FaChatHost] so
  /// JS apps open inside the shell instead of replacing the whole screen.
  final GlobalKey<NavigatorState> _appsNavigatorKey =
      GlobalKey<NavigatorState>();

  /// On-disk sessions (newest first) backing the sidebar's persisted tail —
  /// reloaded whenever the manager changes (create/open/close).
  List<SessionMetadata> _persistedSessions = const [];

  /// The CLI-written `session_info` names for [_persistedSessions] (and the
  /// live ones sharing their ids), reloaded together with the metadata.
  Map<String, String> _jsonlNames = const {};

  /// Lazily loaded session-title store when the host did not inject one
  /// (the wide shell's boot path doesn't) — powers custom titles + rename.
  SessionNamesStore? _namesStore;

  /// Lazily loaded sessions-tree prefs (issue #426) when the host did not
  /// inject one — per-parent expand/collapse survives an app restart.
  SessionUiPrefsStore? _uiPrefs;

  /// The sessions sidebar's width (issue #426 item 4): user-resizable via
  /// a drag handle on its divider, clamped to the store's
  /// [SessionUiPrefsStore.minSidebarWidth]..[maxSidebarWidth] and
  /// persisted through the prefs store. Starts at the stock 240 until the
  /// store loads (or the host injects one).
  double _sidebarWidth = SessionUiPrefsStore.defaultSidebarWidth;

  /// True while the sidebar divider is mid-drag: the collapse animation
  /// is suppressed so the width tracks the pointer 1:1.
  bool _sidebarDragging = false;

  /// Whether we're on macOS desktop (traffic lights float over content).
  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// The session whose open is in flight (see [SidebarSessionsList
  /// .pendingSessionId]) — cleared once the manager's active slot catches
  /// up with the attach broadcast.
  String? _pendingOpenId;

  /// The ONE selected id every row compares against: the click's pending
  /// id wins while in flight, then the SW's live id (hosted), then the
  /// manager's active slot (local). Pending is REPLACEMENT, not additive —
  /// exactly one row can ever be highlighted.
  String? get _selectedSessionId {
    final pending = _pendingOpenId;
    if (pending != null) return pending;
    return widget.manager.hostedLiveId.value ?? widget.manager.active?.id;
  }

  void _onManagerChanged() {
    _subscribeToActiveService();
    unawaited(_reloadPersistedSessions());
    unawaited(_ensureNamesStore());
    unawaited(_ensureUiPrefs());
    if (_pendingOpenId != null &&
        widget.manager.hostedLiveId.value == _pendingOpenId) {
      _pendingOpenId = null; // the broadcast landed — the live id took over
    }
    if (mounted) setState(() {});
  }

  /// Refreshes the sidebar's persisted-sessions tail from disk.
  Future<void> _reloadPersistedSessions() async {
    final all = await widget.manager.listPersistedSessions();
    // The CLI's /rename names live in the session JSONL itself — read them
    // alongside the metadata so CLI-named sessions show their titles here.
    final names = await widget.manager.readSessionNames(all);
    if (!mounted) return;
    setState(() {
      _persistedSessions = all;
      _jsonlNames = names;
    });
  }

  /// The host path of the current project mount (null = Personal / no mount).
  String? get _mountedPath {
    final env = widget.manager.active?.service.env;
    if (env == null) return null;
    return currentMountedPath(env);
  }

  /// Chip label: the basename of the ACTIVE SESSION's folder (its origin
  /// cwd from the session's own metadata — NOT the shared env, which
  /// reflects the current mount for every session). No folder (the
  /// personal sandbox) → "Personal". Switching sessions switches the
  /// label.
  String _sessionFolderLabel() {
    final cwd = widget.manager.active?.service.currentSessionCwd;
    if (cwd != null) {
      final name = p.basename(cwd);
      if (name.isNotEmpty && name != '/' && name != '.') return name;
    }
    return context.l10n.sessionFolderPersonal;
  }

  /// Whether the active session has a real project folder (drives the
  /// chip icon color: indigo when bound to a folder, dim when personal).
  bool get _sessionHasFolder {
    final cwd = widget.manager.active?.service.currentSessionCwd;
    if (cwd == null) return false;
    final name = p.basename(cwd);
    return name.isNotEmpty && name != '/' && name != '.';
  }

  /// The absolute mailbox address another Fa instance uses to deliver an
  /// `agent_message` to this session over the shared messaging fabric.
  /// Falls back to a placeholder when the service hasn't materialized its
  /// session id yet (e.g. the placeholder home before the user connects).
  String _mailboxAddress(AgentService? service) {
    final id = service?.currentSessionId;
    if (id == null || id.isEmpty) return '—';
    return '$id/main';
  }

  /// Loads the session-title store from the shared env when the host did
  /// not inject one — custom titles and the rename action need it.
  Future<void> _ensureNamesStore() async {
    if (widget.sessionNamesStore != null || _namesStore != null) return;
    final service = widget.manager.active?.service;
    if (service == null) return;
    final store =
        service.namesStoreOverride ??
        await SessionNamesStore.shared(service.env);
    if (!mounted) return;
    setState(() => _namesStore = store);
  }

  /// Loads the sessions-tree prefs store from the shared env when the
  /// host did not inject one (issue #426).
  Future<void> _ensureUiPrefs() async {
    if (widget.sessionPrefsStore != null || _uiPrefs != null) return;
    final prefs = await SessionUiPrefsStore.load(widget.manager.env);
    if (!mounted) return;
    setState(() {
      _uiPrefs = prefs;
      final stored = prefs.sidebarWidth;
      if (stored != null) {
        _sidebarWidth = stored.clamp(
          SessionUiPrefsStore.minSidebarWidth,
          SessionUiPrefsStore.maxSidebarWidth,
        );
      }
    });
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
    unawaited(_reloadPersistedSessions());
    unawaited(_ensureNamesStore());
    unawaited(_ensureUiPrefs());
    // Issue #381: boot skipped an oversized last-active session — say so
    // instead of the old silent swap; windowed open stays on the sidebar.
    showBootOversizeNotice(
      context,
      manager: widget.manager,
      names: widget.sessionNamesStore,
      onOpen: (metadata) => _openPersistedSession(metadata),
    );
    FaChatHost.jsAppNavigatorKey = _appsNavigatorKey;
    FaChatHost.revealJsApps = _revealApps;
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _listenedService?.removeListener(_onServiceChanged);
    if (FaChatHost.jsAppNavigatorKey == _appsNavigatorKey) {
      FaChatHost.jsAppNavigatorKey = null;
    }
    if (FaChatHost.revealJsApps == _revealApps) {
      FaChatHost.revealJsApps = null;
    }
    super.dispose();
  }

  /// True when the network mode is active and wired (issue #955): the
  /// shell swaps the sidebar's sessions list for the networks list and
  /// the center chat for the network center — never the whole screen.
  bool get _inNetworkMode {
    final mode = widget.networkMode;
    return mode != null &&
        widget.networkSessions != null &&
        mode.mode == AppMode.network;
  }

  bool get _isNarrow =>
      faWindowClassForWidth(MediaQuery.sizeOf(context).width) ==
      FaWindowClass.small;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final narrow = _isNarrow;
    // Scaffold supplies both the required Material ancestor and a snack
    // host now that no permanent launcher pane owns one.
    final mode = widget.networkMode;
    final sessions = widget.networkSessions;
    Widget buildBody() =>
        narrow ? _buildNarrowBody(colors) : _buildBody(colors);
    return Scaffold(
      backgroundColor: colors.bg,
      body: mode == null || sessions == null
          ? buildBody()
          : ListenableBuilder(
              // Wide mode toggles local ⇄ network in place. Narrow local
              // mode keeps this shell; faHomeScreen owns its full-tree gate.
              listenable: mode,
              builder: (context, _) {
                final body = buildBody();
                return _inNetworkMode && !narrow
                    ? NetworkQuickSwitcher(
                        controller: mode,
                        manager: sessions,
                        child: body,
                      )
                    : body;
              },
            ),
      bottomNavigationBar: narrow ? _buildNarrowNavigation(colors) : null,
      floatingActionButton:
          narrow && _section == _WideShellSection.chats && !_inNetworkMode
          ? FloatingActionButton(
              key: const ValueKey('narrowShellNewChat'),
              onPressed: () => unawaited(_newSession()),
              tooltip: context.l10n.wideChatFallbackTitle,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
    );
  }

  Widget _buildNarrowNavigation(FahColors colors) {
    return NavigationBar(
      key: const ValueKey('narrowShellNavigation'),
      selectedIndex: _section.index,
      onDestinationSelected: (index) =>
          _selectSection(_WideShellSection.values[index]),
      backgroundColor: colors.panel,
      indicatorColor: colors.panelAlt,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          selectedIcon: const Icon(Icons.chat_bubble_rounded),
          label: context.l10n.wideNavChats,
        ),
        NavigationDestination(
          icon: const Icon(Icons.notifications_none_rounded),
          selectedIcon: const Icon(Icons.notifications_rounded),
          label: context.l10n.wideNavActivity,
        ),
        NavigationDestination(
          icon: const Icon(Icons.grid_view_outlined),
          selectedIcon: const Icon(Icons.grid_view_rounded),
          label: context.l10n.appsGridTitle,
        ),
      ],
    );
  }

  Widget _buildNarrowBody(FahColors colors) {
    return switch (_section) {
      _WideShellSection.chats => SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildNarrowChatsHeader(colors),
            Expanded(child: _buildNarrowConversationList()),
          ],
        ),
      ),
      _WideShellSection.activity => SafeArea(
        bottom: false,
        child: _WideActivitySurface(
          manager: widget.manager,
          namesStore: widget.sessionNamesStore ?? _namesStore,
          onOpenSession: _openActivitySession,
        ),
      ),
      _WideShellSection.apps => _buildAppsArea(),
    };
  }

  Widget _buildNarrowChatsHeader(FahColors colors) {
    final mode = widget.networkMode;
    final sessions = widget.networkSessions;
    return Container(
      height: 58,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          const FaBrandTile(size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.wideNavChats,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (mode != null && sessions != null)
            NetworkModeChip(controller: mode, manager: sessions),
          IconButton(
            key: const ValueKey('narrowShellProfile'),
            onPressed: () => unawaited(_openNarrowProfile()),
            icon: const Icon(Icons.account_circle_outlined),
            color: colors.dim,
            tooltip: context.l10n.settingsTitle,
          ),
        ],
      ),
    );
  }

  Widget _buildNarrowConversationList() {
    return ListenableBuilder(
      listenable: DapBindingStore.instance,
      builder: (context, _) => SidebarSessionsList(
        manager: widget.manager,
        sessionNamesStore: widget.sessionNamesStore ?? _namesStore,
        prefsStore: widget.sessionPrefsStore ?? _uiPrefs,
        showHeader: false,
        onNewSession: _newSession,
        persistedSessions: _persistedSessions,
        sessionInfoNames: _jsonlNames,
        onOpenPersisted: (metadata) =>
            unawaited(_openNarrowPersistedSession(metadata)),
        onOpenLiveSession: (sessionId) =>
            unawaited(_openNarrowLiveSession(sessionId)),
        hubBoundSessionId: DapBindingStore.instance.boundSessionId,
        pendingSessionId: _pendingOpenId,
        selectedSessionId: _selectedSessionId,
        headerLabel: context.l10n.wideNavChats,
        searchHint: context.l10n.wideChatsSearchHint,
        unnamedTitle: context.l10n.wideChatFallbackTitle,
      ),
    );
  }

  Future<void> _openNarrowProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          key: const ValueKey('narrowShellProfileRoute'),
          appBar: faAppBar(title: Text(context.l10n.appTitle)),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: FaBrandTile(size: 64),
                  ),
                ),
                ListTile(
                  key: const ValueKey('narrowProfileFiles'),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(context.l10n.chatFilesTooltip),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => unawaited(_openFiles()),
                ),
                ListTile(
                  key: const ValueKey('narrowProfileSettings'),
                  leading: const Icon(Icons.settings_outlined),
                  title: Text(context.l10n.settingsTitle),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => unawaited(_openSettings()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(FahColors colors) {
    final tokens = FaDesignTokens.of(context);
    return Row(
      children: [
        // Left: collapsible sidebar (width user-resizable, issue #426).
        AnimatedContainer(
          duration: _sidebarDragging
              ? Duration.zero
              : FaMotion.duration(context, tokens.base),
          curve: Curves.easeInOut,
          width: _sidebarCollapsed ? 60 : _sidebarWidth,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: colors.border)),
          ),
          child: _buildSidebar(colors),
        ),
        // Drag handle: resizes the sessions sidebar.
        if (!_sidebarCollapsed)
          _PaneDragHandle(
            key: kSidebarDragHandleKey,
            onDrag: (dx) => setState(() {
              _sidebarDragging = true;
              _sidebarWidth = (_sidebarWidth + dx).clamp(
                SessionUiPrefsStore.minSidebarWidth,
                SessionUiPrefsStore.maxSidebarWidth,
              );
            }),
            onDragEnd: (_) => _onSidebarDragEnd(),
          ),
        Expanded(child: _buildCenterSurface(colors)),
      ],
    );
  }

  Widget _buildCenterSurface(FahColors colors) {
    if (_inNetworkMode) return _buildChatArea(colors);
    return switch (_section) {
      _WideShellSection.chats => _buildChatArea(colors),
      _WideShellSection.activity => _WideActivitySurface(
        manager: widget.manager,
        namesStore: widget.sessionNamesStore ?? _namesStore,
        onOpenSession: _openActivitySession,
      ),
      _WideShellSection.apps => _buildAppsArea(),
    };
  }

  void _selectSection(_WideShellSection section) {
    setState(() => _section = section);
    if (section != _WideShellSection.chats && _inNetworkMode) {
      unawaited(widget.networkMode!.exitToLocal());
    }
  }

  void _openActivitySession(String sessionId) {
    setState(() => _section = _WideShellSection.chats);
    unawaited(
      _isNarrow
          ? _openNarrowLiveSession(sessionId)
          : _openLiveSession(sessionId),
    );
  }

  Future<void> _revealApps() async {
    if (!mounted) return;
    if (_inNetworkMode) await widget.networkMode!.exitToLocal();
    if (!mounted) return;
    if (_section != _WideShellSection.apps ||
        _appsNavigatorKey.currentState == null) {
      setState(() => _section = _WideShellSection.apps);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Persists the settled sidebar width (drag end — one write per gesture,
  /// not per pixel).
  void _onSidebarDragEnd() {
    _sidebarDragging = false;
    final store = widget.sessionPrefsStore ?? _uiPrefs;
    if (store != null) {
      unawaited(store.setSidebarWidth(_sidebarWidth));
    }
    setState(() {});
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
            _buildPrimaryNavItems(),
            Expanded(
              child: _inNetworkMode
                  // Network mode swaps the SIDEBAR CONTENT, not the
                  // screen (owner feedback on #955): the memberships list
                  // takes the sessions list's place; the brand row (with
                  // the mode chip) and the Files/Settings nav stay.
                  ? _sidebarCollapsed
                        ? const SizedBox.shrink()
                        : NetworksSidebar(
                            controller: widget.networkMode!,
                            manager: widget.networkSessions!,
                          )
                  : ListenableBuilder(
                      // The DAP inbound binding badge re-renders the list
                      // when the binding loads/changes (settings page,
                      // first load).
                      listenable: DapBindingStore.instance,
                      builder: (context, _) => SidebarSessionsList(
                        manager: widget.manager,
                        sessionNamesStore:
                            widget.sessionNamesStore ?? _namesStore,
                        prefsStore: widget.sessionPrefsStore ?? _uiPrefs,
                        collapsed: _sidebarCollapsed,
                        onNewSession: _newSession,
                        onSessionTap: () => setState(() {}),
                        persistedSessions: _persistedSessions,
                        sessionInfoNames: _jsonlNames,
                        onOpenPersisted: _openPersistedSession,
                        onOpenLiveSession: _openLiveSession,
                        hubBoundSessionId:
                            DapBindingStore.instance.boundSessionId,
                        pendingSessionId: _pendingOpenId,
                        selectedSessionId: _selectedSessionId,
                        headerLabel: context.l10n.wideNavChats,
                        searchHint: context.l10n.wideChatsSearchHint,
                        unnamedTitle: context.l10n.wideChatFallbackTitle,
                      ),
                    ),
            ),
            Divider(height: 1, thickness: 1, color: colors.border),
            _buildNavItems(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandHeader(FahColors colors) {
    // The Fa brand mark: sparkle SVG without any background (matching the
    // prototype's clean icon style). The entry gesture contract (#864):
    // long-press mints a fresh session (haptic, no dialog); a tap needs
    // no action here — the wide layout always shows the active chat.
    final brandIcon = Tooltip(
      // Hover-only hint: triggerMode manual — the touch long-press is
      // deliberately yielded to the InkWell below so it ALWAYS mints
      // (#864); the hint still reaches screen readers via semantics.
      message: context.l10n.faEntryHintTooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: InkWell(
        key: const ValueKey('wideShellFaBrand'),
        borderRadius: BorderRadius.circular(8),
        onLongPress: () => unawaited(_mintSessionFromBrand()),
        child: const SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: FaBrandTile(size: 24),
            ),
          ),
        ),
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

    final mode = widget.networkMode;
    final sessions = widget.networkSessions;
    // With the network wiring present the brand row also carries the mode
    // chip — it gets its own row (the chip does not fit beside the brand
    // mark at the default sidebar width).
    if (mode != null && sessions != null) {
      return Padding(
        // macOS: extra top padding to clear the floating traffic lights
        // (the content now extends to the window top — no global strip).
        padding: EdgeInsets.fromLTRB(16, _isMacOS ? 32 : 16, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: 'Collapse', // l10n:ignore
                ),
              ],
            ),
            const SizedBox(height: 8),
            NetworkModeChip(controller: mode, manager: sessions),
          ],
        ),
      );
    }

    return Padding(
      // macOS: extra top padding to clear the floating traffic lights
      // (the content now extends to the window top — no global strip).
      padding: EdgeInsets.fromLTRB(16, _isMacOS ? 32 : 16, 8, 12),
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
          if (widget.networkMode != null && widget.networkSessions != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: NetworkModeChip(
                controller: widget.networkMode!,
                manager: widget.networkSessions!,
              ),
            ),
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

  Widget _buildPrimaryNavItems() {
    return Row(
      children: [
        Expanded(
          child: SidebarNavItem(
            icon: Icons.chat_bubble_outline_rounded,
            label: context.l10n.wideNavChats,
            selected: _section == _WideShellSection.chats,
            collapsed: _sidebarCollapsed,
            compact: true,
            onTap: () => _selectSection(_WideShellSection.chats),
          ),
        ),
        Expanded(
          child: SidebarNavItem(
            icon: Icons.notifications_none_rounded,
            label: context.l10n.wideNavActivity,
            selected: _section == _WideShellSection.activity,
            collapsed: _sidebarCollapsed,
            compact: true,
            onTap: () => _selectSection(_WideShellSection.activity),
          ),
        ),
        Expanded(
          child: SidebarNavItem(
            icon: Icons.grid_view_rounded,
            label: context.l10n.appsGridTitle,
            selected: _section == _WideShellSection.apps,
            collapsed: _sidebarCollapsed,
            compact: true,
            onTap: () => _selectSection(_WideShellSection.apps),
          ),
        ),
      ],
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

  // ---------------------------------------------------------------------------
  // Chat (center)
  // ---------------------------------------------------------------------------

  Widget _buildChatArea(FahColors colors, {bool narrowRoute = false}) {
    // Network mode (issue #955): the center shows the network surface —
    // the welcome empty state (join/create) or the channel rail beside
    // the channel chat — inside THIS shell, never a takeover. The top
    // inset clears the macOS window-drag strip exactly like the chat
    // header below.
    final networkMode = widget.networkMode;
    final networkSessions = widget.networkSessions;
    if (_inNetworkMode && networkMode != null && networkSessions != null) {
      return Padding(
        padding: EdgeInsets.only(top: _isMacOS ? 28 : 0),
        child: NetworkCenterPane(
          controller: networkMode,
          manager: networkSessions,
        ),
      );
    }
    final active = widget.manager.active;
    if (active == null) {
      return _buildPlaceholder(colors);
    }
    return MediaQuery(
      // The ONE adaptive header (issue #225): the old session row
      // (folder + label + model chip) merged into the chat bar — the
      // shell hands the project identity + chip to the chat screen and
      // the chat renders everything in a single row above the
      // transcript. On macOS the traffic lights float over the bar, so
      // the header insets by the same top padding the session row used.
      data: MediaQuery.of(context).copyWith(
        padding:
            MediaQuery.paddingOf(context) +
            EdgeInsets.only(top: _isMacOS ? 28 : 0),
      ),
      child: ChatScreen(
        manager: widget.manager,
        registry: widget.registry,
        lastConnectionStore: widget.lastConnectionStore,
        uploadPicker: widget.uploadPicker,
        asr: widget.asr,
        asrTranscriber: widget.asrTranscriber,
        audioControllerFactory: widget.audioControllerFactory,
        videoControllerFactory: widget.videoControllerFactory,
        projectIcon: Icons.folder_outlined,
        projectIconColor: _sessionHasFolder ? colors.indigo : colors.dim,
        projectLabel: _sessionFolderLabel(),
        onProjectTap: _openSessionInfoDialog,
        modelChip: QuickModelChip(
          key: const ValueKey('wideModelChip'),
          modelId: active.service.modelId,
          tooltip: context.l10n.chatModelSwitchTooltip,
          maxWidth: 132,
          onTap: () => _openModelPicker(active),
        ),
        onModelChipTap: () => _openModelPicker(active),
        chipMenuLabel: active.service.modelId,
        onAppsToggle: narrowRoute
            ? () => _selectSection(_WideShellSection.apps)
            : null,
      ),
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
  // Apps section — nested Navigator
  // ---------------------------------------------------------------------------

  Widget _buildAppsArea() {
    // The nested Navigator ensures that calls to Navigator.of(context)
    // from within Apps (app launches via pushJsApp, Settings/Files tiles)
    // push within the center surface rather than replacing the shell.
    //
    // The MOBILE launcher is the single panel implementation on every
    // form factor (drag&drop folders, live tiles, search, the Widgets /
    // Get widgets tabs); conversation UI stays in the shell's chat route.
    return Navigator(
      key: _appsNavigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (context) => AppLauncherScreen(
          manager: widget.manager,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          layoutStore: widget.layoutStore,
          appsStore: widget.appsStore,
          tileEngineFactory: widget.tileEngineFactory,
          networkMode: _isNarrow ? widget.networkMode : null,
          networkSessions: _isNarrow ? widget.networkSessions : null,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// New session: asks which folder it belongs to first — the current
  /// folder (the active mount), a freshly picked one (the picker mounts
  /// it for the whole app, like the info dialog's change button), or the
  /// Personal sandbox. The created session's cwd (and its drawer group)
  /// follows the folder.
  Future<void> _newSession() async {
    final target = _newSessionTarget;
    if (target == null) return;
    // Relay sessions (extension panel) live in the service worker: reset
    // there instead of cloning a local config.
    if (await _resetViaRelay(target.service)) return;
    final choice = await _pickNewSessionFolder(target.service);
    if (choice == null) return;
    // Fire-and-forget: the dialog flow controls nothing downstream.
    unawaited(_createSessionInChosenFolder(target.service, target.config));
  }

  /// Everything a local new-session clone needs from the active session,
  /// or null when there is nothing to clone from.
  ({AgentService service, AgentConfig config})? get _newSessionTarget {
    final service = widget.manager.active?.service;
    if (service == null) return null;
    final config = service.configForClone;
    if (config == null) return null;
    return (service: service, config: config);
  }

  /// Runs the relay's new-session action when the surface has one;
  /// true = handled (the local clone path must not run).
  Future<bool> _resetViaRelay(AgentService service) async {
    final relayReset = service.newSessionAction;
    if (relayReset == null) return false;
    await relayReset();
    return true;
  }

  /// New session: asks which folder it belongs to first — the current
  /// folder (the active mount), a freshly picked one (the picker mounts
  /// it for the whole app, like the info dialog's change button), or the
  /// Personal sandbox. Null = aborted, no session.
  Future<String?> _pickNewSessionFolder(AgentService service) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _newSessionFolderDialog(dialogContext, context.l10n, _mountedPath),
    );
    if (choice == null || !mounted) return null;
    return choice != 'choose' ? choice : await _chooseNewSessionFolder(service);
  }

  Future<String?> _chooseNewSessionFolder(AgentService service) async =>
      (await _applyPickedMount(service)) ? 'choose' : null;

  /// The macOS folder picker: applies the picked mount to the whole app
  /// (like the info dialog's change button); false = cancelled/failed.
  Future<bool> _applyPickedMount(AgentService service) async {
    final l10n = context.l10n;
    final String? picked;
    try {
      picked = await pickAndApplyProjectMount(
        env: service.env,
        onApplied: () => service.refreshProjectMountPrompt(),
        onAccessDenied: () {
          if (mounted) {
            showFahErrorSnack(context, l10n.filesFolderAccessDenied);
          }
        },
      );
    } on Object catch (e) {
      _showMountPickerError(l10n, e);
      return false;
    }
    return picked != null;
  }

  /// The mount picker's failure snack (picker channel unavailable etc.)
  /// — only while the shell lives (gh-1848 split).
  void _showMountPickerError(AppLocalizations l10n, Object error) {
    if (mounted) {
      showFahErrorSnack(context, l10n.filesFolderPickerError(error.toString()));
    }
  }

  /// The folder question dialog: the current mount (or the Personal
  /// sandbox) and, on macOS, the pick-another-folder option.
  Widget _newSessionFolderDialog(
    BuildContext dialogContext,
    AppLocalizations l10n,
    String? mountedPath,
  ) => SimpleDialog(
    title: Text(l10n.newSessionFolderTitle),
    children: [
      SimpleDialogOption(
        key: const ValueKey('newSessionCurrentFolder'),
        onPressed: () => Navigator.pop(dialogContext, 'current'),
        child: _newSessionCurrentFolderTile(l10n, mountedPath),
      ),
      if (!kIsWeb && Platform.isMacOS)
        SimpleDialogOption(
          key: const ValueKey('newSessionChooseFolder'),
          onPressed: () => Navigator.pop(dialogContext, 'choose'),
          child: ListTile(
            title: Text(l10n.workspaceDialogChangeFolder),
            leading: const Icon(Icons.create_new_folder_outlined),
          ),
        ),
    ],
  );

  Widget _newSessionCurrentFolderTile(
    AppLocalizations l10n,
    String? mountedPath,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(
      mountedPath != null
          ? l10n.newSessionCurrentFolder(p.basename(mountedPath))
          : l10n.sessionFolderPersonal,
    ),
    subtitle: mountedPath != null ? Text(mountedPath) : null,
    leading: const Icon(Icons.folder_outlined),
  );

  /// The Fa brand mark's long-press (#864): mint one new session straight
  /// from the active config — no folder dialog (the owner ruling is
  /// long-press = new; the sidebar's explicit flow keeps its dialog).
  /// Single-flight like the sheet's [mintAndOpenNewSession]: createSession
  /// is not internally serialized, so a rapid second long-press inside the
  /// clone window would double-mint (ticket E3).
  bool _mintingFromBrand = false;

  Future<void> _mintSessionFromBrand() async {
    if (_mintingFromBrand) return;
    _mintingFromBrand = true;
    try {
      final target = _newSessionTarget;
      if (target == null) return;
      if (await _resetViaRelay(target.service)) return;
      // Fire-and-forget: the ack is flow control for nobody.
      unawaited(HapticFeedback.mediumImpact());
      await _createSessionInChosenFolder(target.service, target.config);
    } on Object catch (error) {
      // The long-press fires through unawaited(...) — a raw clone or
      // initialize failure would surface as an unhandled zone error with
      // zero user feedback (review #1144 follow-up). Log + snack; the
      // active session stays untouched.
      AppLog.i('sessions', 'Fa-brand mint failed: $error');
      if (mounted) {
        showFahErrorSnack(context, context.l10n.sessionMintFailed);
      }
    } finally {
      _mintingFromBrand = false;
    }
  }

  /// The folder is already set ('current' or a freshly applied pick);
  /// the created session's cwd (and its drawer group) follows it.
  Future<void> _createSessionInChosenFolder(
    AgentService service,
    AgentConfig config,
  ) => widget.manager.createSession(
    config: config,
    serviceFactory: () async => service.clone(),
  );

  Future<void> _openNarrowLiveSession(String sessionId) async {
    await _openLiveSession(sessionId);
    if (mounted) await _pushNarrowChat();
  }

  Future<void> _openNarrowPersistedSession(SessionMetadata metadata) async {
    await _openPersistedSession(metadata);
    if (!mounted) return;
    if (widget.manager.active?.id == metadata.id ||
        _pendingOpenId == metadata.id) {
      await _pushNarrowChat();
    }
  }

  Future<void> _pushNarrowChat() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: service,
          builder: (routeContext, _) =>
              _buildChatArea(FahColors.of(routeContext), narrowRoute: true),
        ),
      ),
    );
  }

  /// A tap on an already-live sidebar row. Hosted surfaces re-dispatch
  /// through the relay (the local slot holds only the boot attach — a
  /// bare switchTo would be a silent no-op); desktop falls back to it.
  Future<void> _openLiveSession(String sessionId) async {
    final active = widget.manager.active;
    if (active == null) return;
    final relayOpen = active.service.openSessionAction;
    if (relayOpen != null) {
      debugPrint('[fah][shell] open live session $sessionId via relay');
      setState(() => _pendingOpenId = sessionId);
      await relayOpen(sessionId);
      return;
    }
    widget.manager.switchTo(sessionId);
  }

  /// Opens a persisted session row from the sidebar. On a hosted
  /// relay surface (browser extension) the session files live in the
  /// service worker — the open is a `session_open` dispatch there, exactly
  /// like the narrow drawer; cloning locally would fail (the page-side
  /// service has no config to clone). Desktop clones the active service.
  Future<void> _openPersistedSession(SessionMetadata metadata) async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    final relayOpen = service.openSessionAction;
    if (relayOpen != null) {
      debugPrint(
        '[fah][shell] open session ${metadata.id} via relay (session_open)',
      );
      setState(() => _pendingOpenId = metadata.id);
      await relayOpen(metadata.id);
      return;
    }
    debugPrint('[fah][shell] open session ${metadata.id} via local clone');
    await _clonePersistedSession(service, metadata);
  }

  /// Opens a persisted session by cloning the active service locally;
  /// per-failure surfaces (oversize, live lease elsewhere, torn file)
  /// degrade to snackbars/log lines, never a shell crash.
  Future<void> _clonePersistedSession(
    AgentService service,
    SessionMetadata metadata,
  ) async {
    try {
      await widget.manager.openSession(
        metadata,
        config: service.configForClone ?? _fallbackCloneConfig(service),
        serviceFactory: () => service.clone(),
      );
    } on SessionTooLargeException {
      _showSessionTooLarge(metadata);
    } on SessionDrivenElsewhereException catch (error) {
      // Live lease (#428): never a second writer. The wide shell has no
      // attach surface — say so instead of silently doing nothing.
      _showDrivenElsewhere(metadata, error);
    } on Object catch (error) {
      // A torn/corrupt session file must not crash the shell — the entry
      // just stays in the list.
      debugPrint('[fah] open persisted session ${metadata.id} failed: $error');
    }
  }

  /// The open fallback when the service holds no clonable config.
  AgentConfig _fallbackCloneConfig(AgentService service) => AgentConfig(
    providerKind: service.providerKind,
    modelId: service.modelId,
    baseUrl: '',
    apiKey: '',
  );

  void _showSessionTooLarge(SessionMetadata metadata) {
    if (!mounted) return;
    final sizeMb = (metadata.sizeBytes ?? 0) / (1024 * 1024);
    showFahErrorSnack(
      context,
      context.l10n.sessionTooLargeTitle(sizeMb.toStringAsFixed(0)),
    );
  }

  void _showDrivenElsewhere(
    SessionMetadata metadata,
    SessionDrivenElsewhereException error,
  ) {
    debugPrint('[fah][shell] ${metadata.id} driven elsewhere: $error');
    if (!mounted) return;
    showFahErrorSnack(
      context,
      context.l10n.sessionDrivenElsewhere(
        leaseOwnerLabel(error.lease.host),
        error.lease.pid,
      ),
    );
  }

  /// Opens the shared quick model picker (the same two-step provider →
  /// model flow the settings "Default chat model" row uses) — see
  /// [openQuickModelPicker].
  Future<void> _openModelPicker(FlutterManagedSession session) async {
    final registry = widget.registry;
    if (registry == null) return;
    await openQuickModelPicker(
      context,
      service: session.service,
      registry: registry,
      lastConnectionStore: widget.lastConnectionStore,
    );
  }

  /// Session info dialog: the active session's name (renameable — same
  /// store the CLI's rename writes), its folder (read-only display: the
  /// folder is chosen at session creation, not switchable here), the
  /// restrict-access toggle, and the cross-instance mailbox address.
  Future<void> _openSessionInfoDialog() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    final sessionId = service.currentSessionId;
    final names = widget.sessionNamesStore ?? _namesStore;
    final nameController = TextEditingController(
      text: sessionId == null ? '' : names?.titleFor(sessionId) ?? '',
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _sessionInfoDialog(
        dialogContext,
        service,
        sessionId,
        names,
        nameController,
      ),
    );
    nameController.dispose();
  }

  /// The session info dialog: the active session's name (renameable —
  /// same store the CLI's rename writes), its folder (read-only display:
  /// the folder is chosen at session creation, not switchable here), the
  /// restrict-access toggle, and the cross-instance mailbox address.
  Widget _sessionInfoDialog(
    BuildContext dialogContext,
    AgentService service,
    String? sessionId,
    SessionNamesStore? names,
    TextEditingController nameController,
  ) => AlertDialog(
    title: Text(dialogContext.l10n.workspaceDialogTitle),
    content: _sessionInfoContent(
      dialogContext,
      service,
      sessionId,
      names,
      nameController,
    ),
    actions: _sessionInfoActions(
      dialogContext,
      service,
      sessionId,
      names,
      nameController,
    ),
  );

  Widget _sessionInfoContent(
    BuildContext dialogContext,
    AgentService service,
    String? sessionId,
    SessionNamesStore? names,
    TextEditingController nameController,
  ) {
    final l10n = dialogContext.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Session name (rename): the same store the CLI's rename
        // writes, so a title set here shows in `fa --resume` too.
        if (sessionId != null && names != null)
          ..._sessionInfoNameSection(l10n, names, sessionId, nameController),
        ..._sessionInfoFolderSections(dialogContext, service, l10n),
        // Cross-instance messaging address — other instances of Fa
        // (the CLI, a phone, another Mac window) can deliver an
        // `agent_message` to this exact session by addressing
        // `<sessionId>/main` over the shared messaging root.
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Text(
          l10n.workspaceDialogMailbox,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          _mailboxAddress(service),
          style: Theme.of(dialogContext).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.workspaceDialogMailboxHint,
          style: Theme.of(dialogContext).textTheme.bodySmall,
        ),
      ],
    );
  }

  List<Widget> _sessionInfoNameSection(
    AppLocalizations l10n,
    SessionNamesStore names,
    String sessionId,
    TextEditingController nameController,
  ) => [
    Text(
      l10n.sessionInfoNameLabel,
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 4),
    TextField(
      controller: nameController,
      decoration: InputDecoration(
        hintText: l10n.sidebarRenameHint,
        isDense: true,
      ),
      onSubmitted: (value) => _saveSessionName(names, sessionId, value),
    ),
    const SizedBox(height: 12),
  ];

  /// The current-folder label plus, when the session has one, its host
  /// path and the restrict-tools toggle.
  List<Widget> _sessionInfoFolderSections(
    BuildContext dialogContext,
    AgentService service,
    AppLocalizations l10n,
  ) {
    final sessionFolder = service.currentSessionCwd;
    return [
      Text(
        l10n.workspaceDialogCurrentFolder,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(
        _sessionHasFolder && sessionFolder != null
            ? p.basename(sessionFolder)
            : l10n.workspaceDialogPersonal,
        style: Theme.of(dialogContext).textTheme.bodyMedium,
      ),
      if (_sessionHasFolder && sessionFolder != null)
        ..._sessionInfoFolderDetails(
          dialogContext,
          service,
          l10n,
          sessionFolder,
        ),
    ];
  }

  List<Widget> _sessionInfoFolderDetails(
    BuildContext dialogContext,
    AgentService service,
    AppLocalizations l10n,
    String sessionFolder,
  ) => [
    const SizedBox(height: 2),
    Text(
      l10n.workspaceDialogHostPath,
      style: Theme.of(dialogContext).textTheme.bodySmall,
    ),
    const SizedBox(height: 2),
    Text(sessionFolder, style: Theme.of(dialogContext).textTheme.bodySmall),
    const SizedBox(height: 8),
    // 'Restrict tools to this folder' — gates read/write/bash
    // outside the session's folder root.
    _sessionInfoRestrictTile(dialogContext, service, l10n),
  ];

  Widget _sessionInfoRestrictTile(
    BuildContext dialogContext,
    AgentService service,
    AppLocalizations l10n,
  ) => StatefulBuilder(
    builder: (innerContext, setLocal) {
      final env = service.env;
      final scoped = currentMountedScoped(env) ?? false;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: scoped,
            title: Text(l10n.workspaceDialogRestrictTools),
            onChanged: (value) async {
              if (value == null) return;
              await setProjectMountScoped(
                env: env,
                scoped: value,
                onApplied: () => service.refreshProjectMountPrompt(),
              );
              if (dialogContext.mounted) {
                setLocal(() {});
                setState(() {});
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 2),
            child: Text(
              l10n.workspaceDialogRestrictToolsHint,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ),
        ],
      );
    },
  );

  List<Widget> _sessionInfoActions(
    BuildContext dialogContext,
    AgentService service,
    String? sessionId,
    SessionNamesStore? names,
    TextEditingController nameController,
  ) {
    final l10n = dialogContext.l10n;
    return [
      if (sessionId != null && names != null)
        TextButton(
          onPressed: () =>
              _saveSessionName(names, sessionId, nameController.text),
          child: Text(l10n.settingsSaveButton),
        ),
      TextButton(
        onPressed: () async {
          final address = _mailboxAddress(service);
          await Clipboard.setData(ClipboardData(text: address));
          if (!dialogContext.mounted) return;
          showFahSnack(dialogContext, l10n.workspaceDialogMailboxCopied);
        },
        child: Text(l10n.workspaceDialogMailboxCopy),
      ),
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: Text(l10n.workspaceDialogClose),
      ),
    ];
  }

  /// Saves the session title from the info dialog (empty clears → the
  /// derived title), writing through the shared names store.
  Future<void> _saveSessionName(
    SessionNamesStore names,
    String sessionId,
    String value,
  ) async {
    await names.rename(sessionId, value.trim().isEmpty ? null : value.trim());
    if (mounted) setState(() {});
  }

  Future<void> _openSettings() async {
    AppAnalytics.instance.settingsOpened();
    if (!mounted) return;
    // SettingsScreen handles service == null itself (renders a
    // provider-first CTA at the top), so the post-onboarding
    // empty-manager home opens Settings directly — no detour through
    // OnboardingScreen.
    await pushFaPage<void>(
      context,
      SettingsScreen(
        service: widget.manager.active?.service,
        env: widget.manager.env,
        registry: widget.registry,
        lastConnectionStore: widget.lastConnectionStore,
        layoutStore: widget.layoutStore,
      ),
    );
  }

  Future<void> _openFiles() async {
    AppAnalytics.instance.filesOpened('sidebar');
    if (!mounted) return;
    final service = widget.manager.active?.service;
    // Without an active service we still have an env (post-onboarding
    // empty manager creates one for the home screen), so the file
    // browser renders against the sandbox cwd.
    final env = service?.env ?? await _resolveHomeEnv();
    if (!mounted) return;
    final fsRevision = service?.fsRevision;
    await pushFaPage<void>(
      context,
      Scaffold(
        appBar: faAppBar(title: Text(context.l10n.chatFilesTooltip)),
        body: FileBrowser(
          env: env,
          inlinePreview: false,
          fsRevision: fsRevision,
          onProjectMountChanged: service?.refreshProjectMountPrompt,
        ),
      ),
    );
  }

  /// Cached env for routes that need a sandbox root but not an active
  /// service (the post-onboarding empty-manager home). Resolved once
  /// per shell instance; the platform env creation is cheap (memory
  /// or ProjectMount) but the route shouldn't repeatedly pay for it.
  Future<ExecutionEnv>? _cachedHomeEnv;
  Future<ExecutionEnv> _resolveHomeEnv() {
    return _cachedHomeEnv ??= _createPlatformEnv();
  }

  Future<ExecutionEnv> _createPlatformEnv() async {
    return createPlatformEnv();
  }
}

class _WideActivitySurface extends StatefulWidget {
  const _WideActivitySurface({
    required this.manager,
    required this.namesStore,
    required this.onOpenSession,
  });

  final FlutterSessionManager manager;
  final SessionNamesStore? namesStore;
  final ValueChanged<String> onOpenSession;

  @override
  State<_WideActivitySurface> createState() => _WideActivitySurfaceState();
}

class _WideActivitySurfaceState extends State<_WideActivitySurface> {
  final Set<AgentService> _listenedServices = <AgentService>{};

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    widget.namesStore?.addListener(_onActivityChanged);
    _syncServiceListeners();
  }

  @override
  void didUpdateWidget(covariant _WideActivitySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager) {
      oldWidget.manager.removeListener(_onManagerChanged);
      widget.manager.addListener(_onManagerChanged);
    }
    if (oldWidget.namesStore != widget.namesStore) {
      oldWidget.namesStore?.removeListener(_onActivityChanged);
      widget.namesStore?.addListener(_onActivityChanged);
    }
    _syncServiceListeners();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    widget.namesStore?.removeListener(_onActivityChanged);
    for (final service in _listenedServices) {
      service.removeListener(_onActivityChanged);
    }
    super.dispose();
  }

  void _onManagerChanged() {
    _syncServiceListeners();
    _onActivityChanged();
  }

  void _onActivityChanged() {
    if (mounted) setState(() {});
  }

  void _syncServiceListeners() {
    final current = widget.manager.sessions
        .map((session) => session.service)
        .toSet();
    for (final service in _listenedServices.difference(current)) {
      service.removeListener(_onActivityChanged);
    }
    for (final service in current.difference(_listenedServices)) {
      service.addListener(_onActivityChanged);
    }
    _listenedServices
      ..removeWhere((service) => !current.contains(service))
      ..addAll(current);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final sessions = widget.manager.sessions;
    final running = sessions
        .where((session) => session.service.isStreaming)
        .toList();
    final recent = sessions
        .where((session) => !session.service.isStreaming)
        .toList();
    return ColoredBox(
      color: tokens.background,
      child: Padding(
        padding: EdgeInsets.only(top: faIsMacOSDesktop ? 28 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
              child: Text(
                context.l10n.wideNavActivity,
                style: typography.headline.copyWith(color: tokens.ink1),
              ),
            ),
            Expanded(
              child: sessions.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.monitor_heart_outlined,
                            size: 36,
                            color: tokens.ink3,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            context.l10n.activityEmpty,
                            style: typography.body.copyWith(color: tokens.ink2),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                      children: [
                        ..._sessionGroup(
                          context,
                          label: context.l10n.activityRunning,
                          sessions: running,
                          running: true,
                        ),
                        ..._sessionGroup(
                          context,
                          label: context.l10n.activityRecent,
                          sessions: recent,
                          running: false,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _sessionGroup(
    BuildContext context, {
    required String label,
    required List<FlutterManagedSession> sessions,
    required bool running,
  }) {
    if (sessions.isEmpty) return const [];
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(
          label,
          style: typography.label.copyWith(color: tokens.ink2),
        ),
      ),
      for (final session in sessions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: tokens.surface1,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              side: BorderSide(color: tokens.hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: FaSettingsTile(
              key: ValueKey('wideActivitySession-${session.id}'),
              onTap: () => widget.onOpenSession(session.id),
              leading: Icon(
                running
                    ? Icons.play_circle_outline_rounded
                    : Icons.chat_bubble_outline_rounded,
                color: running ? tokens.accent : tokens.ink2,
              ),
              title: Text(
                widget.namesStore?.titleFor(session.id) ??
                    context.l10n.wideChatFallbackTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typography.body.copyWith(color: tokens.ink1),
              ),
              trailing: Icon(Icons.chevron_right_rounded, color: tokens.ink3),
            ),
          ),
        ),
    ];
  }
}

/// A draggable vertical divider between the sidebar and center surface.
/// Renders a 1px line that thickens on hover with a subtle color change.
class _PaneDragHandle extends StatefulWidget {
  const _PaneDragHandle({super.key, required this.onDrag, this.onDragEnd});

  /// Called with the horizontal delta of each drag update.
  final void Function(double dx) onDrag;

  /// Called when the drag gesture settles (pointer up/cancel) — the
  /// sidebar uses it to persist the settled width once per gesture.
  final void Function(DragEndDetails details)? onDragEnd;

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
        onHorizontalDragEnd: widget.onDragEnd == null
            ? null
            : (details) => widget.onDragEnd!(details),
        onHorizontalDragCancel: widget.onDragEnd == null
            ? null
            : () => widget.onDragEnd!(DragEndDetails()),
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
