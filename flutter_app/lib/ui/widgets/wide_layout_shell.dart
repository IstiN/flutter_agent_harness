import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;

import 'package:path/path.dart' as p;

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
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

import 'package:fa/ui/activity/activity_surface.dart';
import 'package:fa/ui/apps/app_launcher_controller.dart';
import 'package:fa/ui/apps/apps_directory_panel.dart';
import 'package:fa/ui/apps/files_presentation_panel.dart';
import 'package:fa/ui/apps/messenger_app_panel.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa/ui/widgets/messenger_navigation_controls.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/ui/chats/network_inbox_http_adapter.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/quick_model_chip.dart';
import 'package:fa/ui/screens/models_settings_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/boot_oversize_notice.dart';
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
    this.chatPinStore,
    this.chatReadCursorStore,
    this.networkInboxAdapter,
    this.localChatAdapterFactory,
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

  /// Focused chat-list seams; production loads per-account stores from the
  /// shared env and uses the unavailable aggregate adapter until HTTP lands.
  final ChatPinStore? chatPinStore;
  final ChatReadCursorStore? chatReadCursorStore;
  final NetworkInboxAdapter? networkInboxAdapter;

  /// Optional host/test projection seam. The default reads real live and
  /// persisted sessions; injected sources must preserve that contract.
  final LocalChatListSource Function()? localChatAdapterFactory;

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
  bool trafficLightClearance = true,
}) {
  final bar = AppBar(
    title: title,
    actions: actions,
    leading: leading,
    centerTitle: centerTitle,
  );
  if (!faIsMacOSDesktop || !trafficLightClearance) return bar;
  const inset = 32.0;
  return PreferredSize(
    preferredSize: const Size.fromHeight(kToolbarHeight + inset),
    child: Padding(
      padding: const EdgeInsets.only(top: inset),
      child: bar,
    ),
  );
}

enum _WideShellSection { chats, local, activity, apps }

class _WideLayoutShellState extends State<WideLayoutShell>
    with TickerProviderStateMixin {
  static const _collapsedSidebarWidth = 96.0;
  static const _sidebarCollapseDuration = Duration(milliseconds: 200);

  /// The presented-surface reveal: JS apps AND Files dock in the right
  /// pane through one animated entrance/exit (~200ms, FaMotion ease) —
  /// never an instant pop.
  static const _presentationRevealDuration = Duration(milliseconds: 200);

  /// The docked presentation slot's width (the card inside keeps 8pt
  /// floating margins, matching the sidebar's panel margins).
  static const _presentationSlotWidth = 340.0;

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
  SessionNamesStore? _listenedNamesStore;
  late final ChatListController _chatController;
  late final ActivityController _activityController;
  late final AppLauncherController _appLauncherController;
  final TextEditingController _activitySearchController =
      TextEditingController();
  late final AppsStore _appsStore;
  MessengerAppPresentation? _appPresentation;

  /// The native Files presentation — a parallel of [_appPresentation]:
  /// the same right-pane surface flow, real (non-JS) content. Exactly one
  /// presentation is on screen at a time; opening either replaces the
  /// other.
  FilesAppPresentation? _filesPresentation;

  /// Drives the presented surface's entrance/exit. Content fields above
  /// swap instantly; this controller animates the pane's geometry.
  late final AnimationController _presentationReveal = AnimationController(
    vsync: this,
    duration: _presentationRevealDuration,
    value: 0,
  );

  /// Bumped on every present/dismiss so a close animation that completes
  /// after a NEW surface opened never clears the new content.
  int _presentationEpoch = 0;

  /// Whether any presented content is mounted (mid-animation included).
  bool get _presentationMounted =>
      _appPresentation != null || _filesPresentation != null;

  ChatListEntry? _activeNetworkEntry;
  late bool _networkInboxEnabled;
  bool _narrowChatRouteVisible = false;
  Route<void>? _narrowChatRoute;
  bool? _wasNarrow;
  bool _narrowActivityDetailVisible = false;

  /// The Local section's open folder (cwd, '' = Personal; null = the
  /// folder list). Shell-owned so it survives section switches and sidebar
  /// collapse, like the chats panel's drill-down directory.
  String? _localFolderId;

  /// Lazily built resolver for folders' well-known icon files (cached
  /// per folder in memory).
  FolderIconResolver? _folderIconResolver;
  FolderIconResolver get _folderIcons =>
      _folderIconResolver ??= FolderIconResolver(widget.manager.env);
  String? _chatAccountKey;
  String? _chatDirectory;
  final Set<String> _localExpandedParents = <String>{};
  final Set<String> _localCollapsedParents = <String>{};

  /// Lazily loaded sessions-tree prefs (issue #426) when the host did not
  /// inject one — per-parent expand/collapse survives an app restart.
  SessionUiPrefsStore? _uiPrefs;

  /// The sessions sidebar's width (issue #426 item 4): user-resizable via
  /// a drag handle on its divider, clamped to the store's
  /// [SessionUiPrefsStore.minSidebarWidth]..[maxSidebarWidth] and
  /// persisted through the prefs store. Starts at a compact desktop
  /// messenger width of 260 until a stored width loads.
  double _sidebarWidth = 260;

  /// True while the sidebar divider is mid-drag: the collapse animation
  /// is suppressed so the width tracks the pointer 1:1.

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

  Map<String, String> _networkNames() {
    final manager = widget.networkSessions;
    if (manager == null) return const {};
    return {
      for (final network in manager.wallet.networks.entries)
        network.key: network.value.name,
    };
  }

  LocalChatListSource _makeLocalChatAdapter() {
    final factory = widget.localChatAdapterFactory;
    if (factory != null) return factory();
    return LocalChatListAdapter(
      manager: widget.manager,
      sessionInfoNames: _jsonlNames,
      readPersistedNames: false,
      namesStore: widget.sessionNamesStore ?? _namesStore,
      titleBuilder: (id, createdAt, isSubagent) {
        if (!mounted) return id;
        final shortId = id.length > 8 ? id.substring(0, 8) : id;
        if (isSubagent) {
          return context.l10n.sidebarSubagentTitle(shortId);
        }
        return derivedSessionTitle(context, id: id, createdAt: createdAt);
      },
    );
  }

  void _subscribeToNamesStore() {
    final store = widget.sessionNamesStore ?? _namesStore;
    if (identical(store, _listenedNamesStore)) return;
    _listenedNamesStore?.removeListener(_onNamesChanged);
    _listenedNamesStore = store;
    store?.addListener(_onNamesChanged);
  }

  void _onNamesChanged() {
    unawaited(_refreshChatProjection());
    // The centered header shows the same live display name as the list.
    if (mounted) setState(() {});
  }

  void _onNetworkSessionsChanged() {
    _chatController.updateNetworkNames(_networkNames());
    final manager = widget.networkSessions;
    final enabled = manager?.hasJwt == true;
    if (widget.networkInboxAdapter == null && enabled != _networkInboxEnabled) {
      _networkInboxEnabled = enabled;
      unawaited(
        _chatController.replaceNetworkAdapter(
          enabled ? NetworkInboxHttpAdapter(sessionManager: manager!) : null,
        ),
      );
    }
    unawaited(_ensureChatStores());
    if (mounted) setState(() {});
  }

  Future<void> _refreshChatProjection() async {
    if (!mounted) return;
    await _chatController.replaceLocalAdapter(_makeLocalChatAdapter());
  }

  Future<void> _ensureChatStores() async {
    final network = widget.networkSessions;
    final key = network?.accountLogin ?? 'local';
    if (widget.chatPinStore != null && widget.chatReadCursorStore != null) {
      _chatAccountKey = key;
      return;
    }
    final env = widget.manager.active?.service.env;
    if (env == null) return;
    final pins =
        widget.chatPinStore ?? await ChatPinStore.load(env, accountId: key);
    final reads =
        widget.chatReadCursorStore ??
        await ChatReadCursorStore.load(env, accountId: key);
    if (!mounted || key != _chatAccountKey && _chatAccountKey != null) return;
    _chatAccountKey = key;
    _chatController.replaceStores(pinStore: pins, readCursorStore: reads);
  }

  void _onManagerChanged() {
    _subscribeToActiveService();
    unawaited(_reloadPersistedSessions());
    unawaited(_ensureNamesStore());
    unawaited(_ensureChatStores());
    unawaited(_ensureUiPrefs());
    if (_pendingOpenId != null &&
        widget.manager.hostedLiveId.value == _pendingOpenId) {
      _pendingOpenId = null; // the broadcast landed — the live id took over
    }
    if (mounted) setState(() {});
  }

  /// Refreshes the sidebar's persisted-sessions tail from disk.
  ///
  /// Issue #2053: the listing rides the manager's single-flight pass (the
  /// chat-list adapter shares it), and names come from the lazily-known
  /// snapshot — ZERO name-probe window reads here. The bounded background
  /// fill ([FlutterSessionManager.warmSessionNames]) lands the CLI /rename
  /// names after the first frame and repaints through the manager
  /// listener; this method then runs again and picks them up.
  Future<void> _reloadPersistedSessions() async {
    final all = await widget.manager.listPersistedSessions();
    final names = widget.manager.knownSessionNames;
    if (!mounted) return;
    setState(() {
      _persistedSessions = all;
      _jsonlNames = names;
    });
    unawaited(widget.manager.warmSessionNames(all));
    unawaited(_refreshChatProjection());
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
    final service = widget.manager.active?.service;
    final cwd = service?.currentSessionCwd ?? widget.manager.env.cwd;
    if (cwd.isNotEmpty) {
      final name = p.basename(cwd);
      if (name.isNotEmpty && name != '/' && name != '.') return name;
    }
    return context.l10n.sessionFolderPersonal;
  }

  /// Display name of the selected local/hosted session. Custom UI names win,
  /// then the CLI's session_info name, then the same derived title used by
  /// the conversation list. No generic application-name placeholder.
  String _sessionDisplayTitle() {
    final active = widget.manager.active;
    if (active == null) return context.l10n.wideChatFallbackTitle;
    final names = widget.sessionNamesStore ?? _namesStore;
    final custom = names?.titleFor(active.id)?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final jsonl = _jsonlNames[active.id]?.trim();
    if (jsonl != null && jsonl.isNotEmpty) return jsonl;
    return derivedSessionTitle(
      context,
      id: active.id,
      createdAt: active.createdAt,
    );
  }

  /// Whether the active session has a real project folder (drives the
  /// chip icon color: indigo when bound to a folder, dim when personal).
  bool get _sessionHasFolder {
    final service = widget.manager.active?.service;
    final cwd = service?.currentSessionCwd ?? widget.manager.env.cwd;
    if (cwd.isEmpty) return false;
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
    _activityController.updateNamesStore(store);
    _subscribeToNamesStore();
    unawaited(_refreshChatProjection());
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

  /// Rebuilds on run boundaries and non-streaming configuration changes.
  /// ChatScreen owns partial-token rendering; rebuilding the whole shell and
  /// reloading every persisted preview for each token only multiplies disk
  /// and JSON work without improving the visible transcript.
  void _onServiceChanged() {
    final streaming = widget.manager.active?.service.isStreaming ?? false;
    final runBoundary = _lastServiceStreaming != streaming;
    _lastServiceStreaming = streaming;
    if (streaming && !runBoundary) return;
    unawaited(_refreshChatProjection());
    if (mounted) setState(() {});
  }

  /// The service we're currently listening to (for model-change rebuilds).
  AgentService? _listenedService;
  bool? _lastServiceStreaming;

  void _subscribeToActiveService() {
    final active = widget.manager.active?.service;
    if (active == _listenedService) return;
    _listenedService?.removeListener(_onServiceChanged);
    _listenedService = active;
    _lastServiceStreaming = active?.isStreaming ?? false;
    active?.addListener(_onServiceChanged);
  }

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    widget.networkSessions?.addListener(_onNetworkSessionsChanged);
    _subscribeToActiveService();
    _subscribeToNamesStore();
    _networkInboxEnabled = widget.networkSessions?.hasJwt == true;
    _activityController = ActivityController(
      manager: widget.manager,
      namesStore: widget.sessionNamesStore ?? _namesStore,
    );
    _appLauncherController = AppLauncherController();
    _appsStore = widget.appsStore ?? AppsStore(widget.manager.env);
    _chatController = ChatListController(
      localAdapter: _makeLocalChatAdapter(),
      pinStore:
          widget.chatPinStore ?? ChatPinStore.inMemory(accountId: 'local'),
      readCursorStore:
          widget.chatReadCursorStore ??
          ChatReadCursorStore.inMemory(accountId: 'local'),
      networkAdapter:
          widget.networkInboxAdapter ??
          (_networkInboxEnabled
              ? NetworkInboxHttpAdapter(sessionManager: widget.networkSessions!)
              : null),
      networkNames: _networkNames(),
    );
    unawaited(_chatController.load());
    unawaited(_reloadPersistedSessions());
    unawaited(_ensureNamesStore());
    unawaited(_ensureChatStores());
    unawaited(_ensureUiPrefs());
    // Issue #381: boot skipped an oversized last-active session — say so
    // instead of the old silent swap; windowed open stays on the sidebar.
    showBootOversizeNotice(
      context,
      manager: widget.manager,
      names: widget.sessionNamesStore,
      onOpen: (metadata) => _openPersistedSession(metadata),
    );
    jsAppPanelPresenter = _presentJsApp;
    FaChatHost.jsAppNavigatorKey = _appsNavigatorKey;
    FaChatHost.revealJsApps = _revealApps;
    FaChatHost.revealActiveChat = _revealActiveChat;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final narrow = _isNarrow;
    final wasNarrow = _wasNarrow;
    _wasNarrow = narrow;
    if (wasNarrow == true && !narrow && _narrowChatRoute != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _foldNarrowChatIntoWide();
      });
    }
  }

  /// A phone chat is a route above the shell. Once the same window becomes
  /// wide, that route would otherwise keep covering the newly visible sidebar
  /// and center. Fold it (and any narrow-only routes above it) back into the
  /// shared wide chat instead of leaving a phone-sized screen stretched wide.
  void _foldNarrowChatIntoWide() {
    if (!mounted || _isNarrow) return;
    final route = _narrowChatRoute;
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (!route.isCurrent) {
      navigator.popUntil((candidate) => identical(candidate, route));
    }
    if (route.isActive && route.isCurrent) navigator.pop();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    widget.networkSessions?.removeListener(_onNetworkSessionsChanged);
    _listenedService?.removeListener(_onServiceChanged);
    _listenedNamesStore?.removeListener(_onNamesChanged);
    _activityController.dispose();
    _chatController.dispose();
    _appLauncherController.dispose();
    _activitySearchController.dispose();
    _presentationReveal.dispose();
    if (jsAppPanelPresenter == _presentJsApp) jsAppPanelPresenter = null;
    if (FaChatHost.jsAppNavigatorKey == _appsNavigatorKey) {
      FaChatHost.jsAppNavigatorKey = null;
    }
    if (FaChatHost.revealJsApps == _revealApps) {
      FaChatHost.revealJsApps = null;
    }
    if (FaChatHost.revealActiveChat == _revealActiveChat) {
      FaChatHost.revealActiveChat = null;
    }
    super.dispose();
  }

  bool get _isNarrow =>
      faWindowClassForWidth(MediaQuery.sizeOf(context).width) ==
      FaWindowClass.small;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final narrow = _isNarrow;
    // A presented surface covers the narrow shell (and animates out over
    // its exit), hiding the bottom chrome while it is on screen.
    final presentationCoversNarrow =
        narrow && (_presentationMounted || _presentationReveal.value > 0);
    // Scaffold supplies both the required Material ancestor and a snack
    // host now that no permanent launcher pane owns one.
    Widget buildBody() =>
        narrow ? _buildNarrowBody(colors) : _buildBody(colors);
    final scaffold = Scaffold(
      backgroundColor: colors.bg,
      extendBody: !presentationCoversNarrow && narrow,
      body: buildBody(),
      bottomNavigationBar: presentationCoversNarrow
          ? null
          : (narrow ? _buildNarrowNavigation() : null),
      floatingActionButton:
          narrow &&
              !presentationCoversNarrow &&
              _section == _WideShellSection.chats
          ? MessengerNewChatButton(
              key: const ValueKey('narrowShellNewChat'),
              onTap: () => unawaited(_newSession()),
              label: context.l10n.wideChatFallbackTitle,
            )
          : null,
    );
    if (tokens.direction != FaVisualDirection.glass) return scaffold;
    return BackdropGroup(child: scaffold);
  }

  Widget _buildNarrowNavigation() {
    final labels = [
      context.l10n.wideNavChats,
      context.l10n.wideNavLocal,
      context.l10n.wideNavActivity,
      context.l10n.appsGridTitle,
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MessengerBottomNavigation.horizontalMargin,
          0,
          MessengerBottomNavigation.horizontalMargin,
          MessengerBottomNavigation.bottomGap,
        ),
        child: MessengerBottomNavigation(
          key: const ValueKey('narrowShellNavigation'),
          selectedIndex: _section.index,
          children: [
            for (var index = 0; index < labels.length; index++)
              MessengerBottomNavigationItem(
                key: ValueKey(
                  'messengerPrimaryNav-${_WideShellSection.values[index].name}',
                ),
                icon: switch (_WideShellSection.values[index]) {
                  _WideShellSection.chats => Icons.chat_bubble_outline_rounded,
                  _WideShellSection.local => Icons.folder_outlined,
                  _WideShellSection.activity =>
                    Icons.notifications_none_rounded,
                  _WideShellSection.apps => Icons.grid_view_rounded,
                },
                label: labels[index],
                selected: _section.index == index,
                onTap: () => _selectSection(_WideShellSection.values[index]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatPanel({bool compact = false, bool collapsed = false}) {
    final dapStore = DapBindingStore.instance;
    return ListenableBuilder(
      listenable: _chatController,
      builder: (context, _) => ListenableBuilder(
        listenable: dapStore,
        builder: (context, _) => _chatPanel(
          dapBound: dapStore.boundSessionId != null,
          compact: compact,
          collapsed: collapsed,
        ),
      ),
    );
  }

  Widget _chatPanel({
    required bool dapBound,
    required bool compact,
    required bool collapsed,
  }) {
    return ChatListPanel(
      controller: _chatController,
      compact: compact,
      selectedEntryId:
          _activeNetworkEntry?.id ??
          (_selectedSessionId == null
              ? null
              : ChatEntryId.local(_selectedSessionId!)),
      didOpen: (entry) =>
          entry.kind == ChatListEntryKind.localAgent &&
          widget.manager.active?.id == entry.id.value,
      hubBoundSessionId: dapBound
          ? DapBindingStore.instance.boundSessionId
          : null,
      networkManager: widget.networkSessions,
      networkMode: widget.networkMode,
      onOpen: _openChatEntry,
      onNew: _newSession,
      onProfile: _openNarrowProfile,
      onBrandTap: compact ? () => unawaited(_pushNarrowChat()) : null,
      onBrandLongPress: () => unawaited(_mintSessionFromBrand()),
      onCollapse: () => setState(() => _sidebarCollapsed = true),
      onLocalMenu: _showChatEntryMenu,
      expandedParents:
          widget.sessionPrefsStore?.expandedParents ??
          _uiPrefs?.expandedParents ??
          _localExpandedParents,
      collapsedParents:
          widget.sessionPrefsStore?.collapsedParents ??
          _uiPrefs?.collapsedParents ??
          _localCollapsedParents,
      onToggleParent: _toggleChatParent,
      currentDirectory: _chatDirectory,
      onDirectoryChanged: (path) => setState(() => _chatDirectory = path),
      headerBottom: null,
      // The wide shell's vertical rail owns the section destinations and
      // chat filters; the narrow shell keeps the horizontal bar.
      showFilterToolbar: compact || collapsed,
      searchController: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => _activitySearchController,
        _WideShellSection.apps => _appLauncherController.searchController,
      },
      searchFocusNode: _section == _WideShellSection.apps
          ? _appLauncherController.searchFocusNode
          : null,
      searchHint: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => context.l10n.activitySearchHint,
        _WideShellSection.apps => context.l10n.launcherSearchHint,
      },
      onSearch: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => _activityController.setSearch,
        _WideShellSection.apps => (_) {},
      },
      bodyKey: _section == _WideShellSection.chats
          ? null
          : ValueKey('wide-sidebar-${_section.name}'),
      bodyBuilder: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => _buildActivitySidebarBody,
        _WideShellSection.apps => _buildAppsSidebarBody,
      },
      showCurrentDirectory: _section == _WideShellSection.chats,
    );
  }

  Widget _buildActivitySidebarBody(double topPadding) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: ActivityListPanel(controller: _activityController),
    );
  }

  Widget _buildAppsSidebarBody(double topPadding) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: ListenableBuilder(
        listenable: _appLauncherController,
        builder: (context, _) => AppsDirectoryPanel(
          controller: _appLauncherController,
          appsStore: _appsStore,
          runningAppName: _appPresentation?.app.name,
          showSearch: false,
          onOpenRunning: () => setState(() {
            _appPresentation?.fullScreen = false;
          }),
          onOpenFiles: _openFiles,
        ),
      ),
    );
  }

  void _toggleChatParent(String parentId, bool expand) {
    final prefs = widget.sessionPrefsStore ?? _uiPrefs;
    if (prefs != null) {
      unawaited(prefs.setExpanded(parentId, expand));
    }
    setState(() {
      if (expand) {
        _localExpandedParents.add(parentId);
        _localCollapsedParents.remove(parentId);
      } else {
        _localCollapsedParents.add(parentId);
        _localExpandedParents.remove(parentId);
      }
    });
  }

  /// Opens a Local-section row through the existing open flow (live via
  /// the relay/switch, persisted via the clone path), then clears the
  /// row's unread count the same way the chat list does.
  Future<void> _openLocalEntry(ChatListEntry entry) async {
    if (entry.kind != ChatListEntryKind.localAgent) return;
    await _openChatEntry(entry);
    await _chatController.markOpened(entry);
  }

  Future<void> _openChatEntry(ChatListEntry entry) async {
    if (entry.kind == ChatListEntryKind.localAgent) {
      final live = widget.manager.sessions
          .where((session) => session.id == entry.id.value)
          .firstOrNull;
      if (live != null) {
        if (_isNarrow) {
          await _openNarrowLiveSession(entry.id.value);
        } else {
          _openLiveSession(entry.id.value);
        }
        return;
      }
      final persisted = _persistedSessions
          .where((session) => session.id == entry.id.value)
          .firstOrNull;
      if (persisted != null) {
        if (_isNarrow) {
          await _openNarrowPersistedSession(persisted);
        } else {
          await _openPersistedSession(persisted);
        }
      }
      return;
    }
    final manager = widget.networkSessions;
    if (manager == null) return;
    final mode = widget.networkMode;
    final networkId = entry.networkId;
    if (entry.kind == ChatListEntryKind.networkChannel &&
        mode != null &&
        networkId != null) {
      await _openNetworkChannel(entry, manager, mode);
      return;
    }
    // Network-agent detail is separate; management remains a secondary
    // flow and never changes the messenger home or its filter.
    await showChatNetworksDialog(context, manager: manager, networkMode: mode);
  }

  Future<void> _openNetworkChannel(
    ChatListEntry entry,
    NetworkSessionManager manager,
    NetworkModeController mode,
  ) async {
    final networkId = entry.networkId!;
    await mode.enterNetwork(networkId);
    if (!manager.sessions.containsKey(networkId)) {
      if (manager.wallet.networks[networkId]?.password == null) {
        if (!mounted) return;
        await showJoinSheet(
          context,
          controller: mode,
          manager: manager,
          initialNetworkId: networkId,
        );
      } else {
        try {
          await manager.resume(networkId);
        } on Object catch (error) {
          if (mounted) showFahErrorSnack(context, error.toString());
        }
      }
    }
    if (!mounted || !manager.sessions.containsKey(networkId)) return;
    await mode.selectChannel(entry.id.value);
    if (!mounted) return;
    setState(() => _activeNetworkEntry = entry);
    if (_isNarrow) await _pushNarrowChat();
  }

  Future<void> _showChatEntryMenu(ChatListEntry entry, Rect anchor) async {
    if (entry.kind != ChatListEntryKind.localAgent) return;
    final live = widget.manager.sessions
        .where((session) => session.id == entry.id.value)
        .firstOrNull;
    final persisted = _persistedSessions
        .where((session) => session.id == entry.id.value)
        .firstOrNull;
    if (live == null && persisted == null) return;
    await showSessionActionsMenu(
      context,
      manager: widget.manager,
      namesStore: widget.sessionNamesStore ?? _namesStore,
      live: live,
      persisted: persisted,
      anchor: anchor,
      sessionId: entry.id.value,
      createdAt:
          entry.lastActivity ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      onDeleted: _reloadPersistedSessions,
    );
  }

  Widget _buildNarrowBody(FahColors colors) {
    final base = switch (_section) {
      // Top clearance comes from the single narrow-body wrap below — no
      // per-branch SafeArea (it would double the inset on macOS).
      _WideShellSection.chats => _buildChatPanel(compact: true),
      _WideShellSection.local => _buildLocalPanel(compact: true),
      _WideShellSection.activity =>
        _narrowActivityDetailVisible
            ? ActivityDetailPanel(
                controller: _activityController,
                compact: true,
                onOpenSession: _openActivitySession,
                onBack: () {
                  _activityController.clearSelection();
                  setState(() => _narrowActivityDetailVisible = false);
                },
              )
            : Column(
                children: [
                  MessengerSectionHeader(
                    title: context.l10n.wideNavActivity,
                    searchController: _activitySearchController,
                    searchHint: context.l10n.activitySearchHint,
                    onSearch: _activityController.setSearch,
                    onProfile: _openNarrowProfile,
                    onNew: _newSession,
                    compact: true,
                  ),
                  Expanded(
                    child: ActivityListPanel(
                      controller: _activityController,
                      compact: true,
                      onSelect: (_) =>
                          setState(() => _narrowActivityDetailVisible = true),
                    ),
                  ),
                ],
              ),
      _WideShellSection.apps => _buildAppsArea(),
    };
    // One shared titlebar inset for every narrow section (the wide sidebar
    // panels are flush with the window edge and clear it themselves —
    // ChatListPanel adds the same inset when not compact).
    final inset = math.max(8.0, MediaQuery.paddingOf(context).top);
    final positioned = Padding(
      padding: EdgeInsets.only(top: inset),
      child: base,
    );
    if (!(_presentationMounted || _presentationReveal.value > 0)) {
      return positioned;
    }
    // The presented surface (app or Files) fades in/out over the section.
    Widget surface = _buildPresentedSurface();
    return Stack(
      children: [
        positioned,
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _presentationReveal,
            builder: (context, _) {
              final t = Curves.easeInOutCubic.transform(
                _presentationReveal.value,
              );
              return IgnorePointer(
                ignoring: t < .02,
                child: Opacity(opacity: t, child: surface),
              );
            },
          ),
        ),
      ],
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
                if (widget.networkSessions != null)
                  ListTile(
                    key: const ValueKey('narrowProfileNetworks'),
                    leading: const Icon(Icons.hub_outlined),
                    title: Text(context.l10n.networkNetworksTitle),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => unawaited(
                      showChatNetworksDialog(
                        context,
                        manager: widget.networkSessions!,
                      ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        return TweenAnimationBuilder<double>(
          tween: Tween(end: _sidebarCollapsed ? 1.0 : 0.0),
          duration: FaMotion.duration(context, _sidebarCollapseDuration),
          curve: Curves.easeInOutCubic,
          builder: (context, progress, _) {
            // One value drives all visible geometry. TweenAnimationBuilder
            // starts at its end on first mount, and an unchanged zero target
            // makes persisted divider resize direct rather than animated.
            final sidebarWidth =
                _sidebarWidth +
                (_collapsedSidebarWidth - _sidebarWidth) * progress;
            final contentCollapsed = progress >= .5;
            // The glass card keeps 8pt floating margins on BOTH sides —
            // the content must live INSIDE them, never under the clip
            // (the old -8 let rows bleed 8px past the card's right edge).
            final contentWidth =
                (contentCollapsed ? _collapsedSidebarWidth : _sidebarWidth) -
                16;
            final contentOpacity = contentCollapsed
                ? (progress - .5) * 2
                : 1 - progress * 2;
            final contentInTransition = progress > 0 && progress < 1;
            // On macOS the collapsed toggle moves just outside the rail. The
            // shift is tuned so the collapsed extreme lands at the same
            // 8pt-outside-the-rail spot as before (left edge 104 at the
            // 96px rail): 44 = the 48px rail travel + the circle's growth
            // (+2px per side over the old 32pt circle) MINUS the 8pt right
            // gutter the open panel now keeps. Other platforms stay inside
            // the panel.
            final toggleShift = _isMacOS ? 60 * progress : 0.0;
            // The vertical rail (left edge of the wide shell) + its 8pt
            // seam precede the sidebar column, so floating chrome anchored
            // to the sidebar's edges must clear the rail's footprint.
            final railLeading = MessengerNavRail.width + MessengerNavRail.seam;
            // The 36pt circle keeps the panel's 8pt gutter contract on
            // BOTH sides: 8pt card margin + 8pt gutter put its right edge
            // 16pt inside the sidebar's right edge (owner call: the open
            // panel's toggle must not hug the panel edge).
            final toggleLeft = railLeading + sidebarWidth - 52 + toggleShift;
            final sidebarContent = _buildSidebar(
              colors,
              collapsed: contentCollapsed,
            );
            return AnimatedBuilder(
              animation: _presentationReveal,
              builder: (context, _) {
                final presentation = _appPresentation;
                final revealRaw = _presentationReveal.value;
                final reveal = Curves.easeInOutCubic.transform(revealRaw);
                final full = presentation?.fullScreen == true;
                // Presence (not the animation value) gates the slot: the
                // content mounts on the presenting frame itself and the
                // reveal only animates the pane's geometry afterwards.
                final slotVisible = _presentationMounted && !full;
                final floatingPanel =
                    slotVisible && constraints.maxWidth <= 1080;
                return Stack(
                  children: [
                    Row(
                      children: [
                        _buildNavRail(),
                        const SizedBox(width: MessengerNavRail.seam),
                        SizedBox(
                          key: const ValueKey('desktopSidebarContainer'),
                          width: sidebarWidth,
                          child: _desktopPanelFrame(
                            key: const ValueKey('glassSidebarPanel'),
                            // Equal floating margins (8pt all around) — a
                            // rounded card; the seam gutter to the center pane
                            // matches the outer margin.
                            padding: const EdgeInsets.all(8),
                            borderRadius: BorderRadius.circular(18),
                            tokens: tokens,
                            glass: true,
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.topLeft,
                                minWidth: contentWidth,
                                maxWidth: contentWidth,
                                child: SizedBox(
                                  width: contentWidth,
                                  child: IgnorePointer(
                                    ignoring: contentInTransition,
                                    child: ExcludeFocus(
                                      excluding: contentInTransition,
                                      child: Opacity(
                                        opacity: contentOpacity,
                                        child: sidebarContent,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _desktopPanelFrame(
                            key: const ValueKey('glassCenterPanel'),
                            // Composer owns its floating margins; its separate
                            // environmental fade reaches the actual window edge.
                            // The Apps overview paints its own full-bled slab,
                            // so it keeps square corners — a rounded clip would
                            // slice its header at the window's right edge.
                            padding: EdgeInsets.zero,
                            tokens: tokens,
                            borderRadius: _section == _WideShellSection.apps
                                ? BorderRadius.zero
                                : const BorderRadius.horizontal(
                                    right: Radius.circular(18),
                                  ),
                            // The collapsed toggle is floating chrome, never a
                            // participant in the transcript/header layout.
                            child: _buildCenterSurface(colors),
                          ),
                        ),
                        if (slotVisible && !floatingPanel)
                          _buildDockedPresentationSlot(reveal),
                      ],
                    ),
                    // One action follows the animated boundary; the header trees
                    // only crossfade content and never duplicate the toggle.
                    Positioned(
                      left: toggleLeft,
                      // The header band's shared action centerline: the
                      // 36pt toggle's center (17 + 18 = 35) sits on the
                      // chat header action row's center.
                      top: 17,
                      child: MessengerSidebarToggle(
                        key: const ValueKey('wideShellSidebarToggle'),
                        expanded: !_sidebarCollapsed,
                        // The glass flag tracks the ICON in the circle, not
                        // the animation phase: the docked collapse icon (the
                        // toggle sits ON the panel) is the flat token state;
                        // the floating expand icon (the panel is gone under
                        // it) carries the glass underlay. The old
                        // `progress > 0` kept glass on the expand icon
                        // through the whole re-opening animation — an
                        // on-surface circle wearing a floating state.
                        floating: _sidebarCollapsed,
                        tooltip: _sidebarCollapsed
                            ? context.l10n.chatExpand
                            : context.l10n.chatCollapse,
                        onPressed: () => setState(
                          () => _sidebarCollapsed = !_sidebarCollapsed,
                        ),
                      ),
                    ),
                    if (!_sidebarCollapsed && progress == 0)
                      // The shared pane handle, CENTERED on the panel edge:
                      // the glass card keeps an 8pt outer margin, so its
                      // right edge sits at sidebarWidth - 8 — the old handle
                      // hung 12pt off that edge, floating over the seam
                      // (owner call). The hit surface still straddles the
                      // card's padding band and the gutter; the drag
                      // contract (delta → clamp → persist on settle) is
                      // untouched.
                      Positioned(
                        left: railLeading + sidebarWidth - 16,
                        top: 0,
                        bottom: 0,
                        child: FaPaneResizeHandle(
                          key: kSidebarDragHandleKey,
                          onDragUpdate: (dx) => setState(() {
                            _sidebarWidth = (_sidebarWidth + dx).clamp(
                              SessionUiPrefsStore.minSidebarWidth,
                              SessionUiPrefsStore.maxSidebarWidth,
                            );
                          }),
                          onDragEnd: _onSidebarDragEnd,
                          onDragCancel: _onSidebarDragEnd,
                        ),
                      ),
                    if (floatingPanel) _buildFloatingPresentationSlot(reveal),
                    if (presentation != null && full)
                      Positioned.fill(child: _buildPresentedApp(presentation)),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// The docked right-pane slot: its WIDTH animates (0 → 340) while the
  /// card inside keeps its fixed size — a JS app must not reflow its
  /// canvas mid-animation, so the pane reveals rather than squeezes.
  Widget _buildDockedPresentationSlot(double reveal) {
    return SizedBox(
      key: const ValueKey('wideShellPresentationSlot'),
      width: _presentationSlotWidth * reveal,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerRight,
          minWidth: _presentationSlotWidth,
          maxWidth: _presentationSlotWidth,
          child: SizedBox(
            width: _presentationSlotWidth,
            child: IgnorePointer(
              ignoring: reveal < .02,
              child: Opacity(
                opacity: reveal,
                child: Transform.translate(
                  offset: Offset(32 * (1 - reveal), 0),
                  child: _buildPresentedSurface(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The floating overlay presentation for tighter widths: slides in
  /// from the window's right edge over the center surface.
  Widget _buildFloatingPresentationSlot(double reveal) {
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      width: _presentationSlotWidth,
      child: IgnorePointer(
        ignoring: reveal < .02,
        child: Opacity(
          opacity: reveal,
          child: Transform.translate(
            offset: Offset(_presentationSlotWidth * (1 - reveal), 0),
            child: _buildPresentedSurface(),
          ),
        ),
      ),
    );
  }

  /// The single presented surface: a JS app or the native Files browser.
  Widget _buildPresentedSurface() {
    final presentation = _appPresentation;
    if (presentation != null) return _buildPresentedApp(presentation);
    final files = _filesPresentation;
    if (files == null) return const SizedBox.shrink();
    return FilesAppPanel(
      presentation: files,
      // The docked pane sits beside the chat header: its band X rides the
      // header's shared action centerline (the collapse toggle's center).
      topCenterline: true,
      onClose: () => unawaited(_dismissPresentedSurface()),
    );
  }

  /// Only navigation chrome refracts. The transcript stays on an opaque,
  /// inexpensive center surface; the sidebar/center join has no rail.
  Widget _desktopPanelFrame({
    required Key key,
    required EdgeInsets padding,
    required BorderRadius borderRadius,
    required FaDesignTokens tokens,
    required Widget child,
    bool glass = false,
  }) {
    return Padding(
      padding: padding,
      child: glass
          ? FaSurface(
              key: key,
              glass: true,
              useBackdropGroup: true,
              color: tokens.surface1,
              borderRadius: borderRadius,
              child: child,
            )
          : Container(
              key: key,
              decoration: BoxDecoration(
                color: tokens.background,
                borderRadius: borderRadius,
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
    );
  }

  Widget _buildPresentedApp(MessengerAppPresentation presentation) {
    return MessengerAppPanel(
      presentation: presentation,
      manager: widget.manager,
      onFullScreen: () => setState(() {
        presentation.fullScreen = !presentation.fullScreen;
      }),
      onPin: () => setState(() {
        presentation.pinned = !presentation.pinned;
      }),
      onClose: () => unawaited(_dismissPresentedSurface()),
    );
  }

  Widget _buildCenterSurface(FahColors colors) {
    return switch (_section) {
      _WideShellSection.chats => _buildChatArea(colors),
      _WideShellSection.local => _buildChatArea(colors),
      _WideShellSection.activity => ActivityDetailPanel(
        controller: _activityController,
        onOpenSession: _openActivitySession,
        showFirstWhenUnselected: true,
      ),
      _WideShellSection.apps => _buildAppsArea(),
    };
  }

  void _selectSection(_WideShellSection section) {
    final changed = section != _section;
    var dismissPresentation = false;
    setState(() {
      final presentation = _appPresentation;
      if (presentation != null) {
        presentation.fullScreen = false;
        if (changed && !presentation.pinned) dismissPresentation = true;
      }
      if (changed && _filesPresentation != null) dismissPresentation = true;
      _section = section;
      if (section == _WideShellSection.activity) {
        _narrowActivityDetailVisible = false;
      }
    });
    // Unpinned surfaces ride out with the section change (animated).
    if (dismissPresentation) unawaited(_dismissPresentedSurface());
  }

  void _openActivitySession(String sessionId) {
    setState(() => _section = _WideShellSection.chats);
    unawaited(
      _isNarrow
          ? _openNarrowLiveSession(sessionId)
          : _openLiveSession(sessionId),
    );
  }

  Future<bool> _presentJsApp({
    required BuildContext context,
    required JsAppInfo app,
    required AgentService service,
    required AgentService appService,
    required AppPermissionsStore permissionsStore,
  }) async {
    if (!mounted) return false;
    // A narrow chat/settings route covers the shell; retain the root-route
    // fallback there. On the Apps list the shell itself owns the full surface.
    if (_isNarrow && Navigator.of(context, rootNavigator: true).canPop()) {
      return false;
    }
    setState(() {
      final current = _appPresentation;
      if (current?.app.id == app.id) {
        current!.fullScreen = false;
      } else {
        _filesPresentation = null;
        _appPresentation = MessengerAppPresentation(
          app: app,
          service: service,
          appService: appService,
          permissionsStore: permissionsStore,
        );
      }
    });
    _presentSurface();
    return true;
  }

  /// Arms the presented surface's animated entrance. A surface already on
  /// screen (pin/Full toggles, app swaps) must not replay it.
  void _presentSurface() {
    if (!mounted) return;
    _presentationEpoch++;
    if (FaMotion.reduceMotionOf(context)) {
      _presentationReveal.value = 1;
      return;
    }
    unawaited(_presentationReveal.forward());
  }

  /// Animates the presented surface out (~200ms), then clears it — JS
  /// apps and Files close through the same motion. Reopening mid-flight
  /// cancels the clear (the epoch guard).
  Future<void> _dismissPresentedSurface() async {
    if (!_presentationMounted && _presentationReveal.value == 0) return;
    _presentationEpoch++;
    final epoch = _presentationEpoch;
    if (FaMotion.reduceMotionOf(context)) {
      _presentationReveal.value = 0;
    } else {
      await _presentationReveal.reverse();
    }
    if (!mounted || _presentationEpoch != epoch) return;
    setState(() {
      _appPresentation = null;
      _filesPresentation = null;
    });
  }

  Future<void> _revealApps() async {
    if (!mounted) return;
    if (_section != _WideShellSection.apps ||
        _appsNavigatorKey.currentState == null) {
      setState(() => _section = _WideShellSection.apps);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _revealActiveChat() async {
    if (!mounted || widget.manager.active == null) return;
    final narrow = _isNarrow;
    if (_section != _WideShellSection.chats || _presentationMounted) {
      setState(() {
        _section = _WideShellSection.chats;
        if (narrow) {
          // The narrow presentation covers everything — animate it out.
          unawaited(_dismissPresentedSurface());
        } else {
          _appPresentation?.fullScreen = false;
        }
      });
      await WidgetsBinding.instance.endOfFrame;
    }
    if (mounted && narrow && !_narrowChatRouteVisible) {
      await _pushNarrowChat();
    }
  }

  /// Persists the settled sidebar width (drag end — one write per gesture,
  /// not per pixel).
  void _onSidebarDragEnd() {
    final store = widget.sessionPrefsStore ?? _uiPrefs;
    if (store != null) {
      unawaited(store.setSidebarWidth(_sidebarWidth));
    }
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Sidebar
  // ---------------------------------------------------------------------------

  Color _sidebarSurfaceColor(FahColors colors) =>
      FaDesignTokens.of(context).direction == FaVisualDirection.glass
      ? Colors.transparent
      : colors.panel;

  Widget _buildSidebar(FahColors colors, {required bool collapsed}) {
    // SelectionContainer.disabled prevents macOS spell-check squiggly
    // underlines from appearing on sidebar text widgets. Section navigation
    // lives in the vertical rail; the sidebar is per-section content.
    return SelectionContainer.disabled(
      child: ColoredBox(
        color: _sidebarSurfaceColor(colors),
        child: Column(
          children: [
            if (collapsed) _buildCollapsedChatHeader(),
            Expanded(
              child: collapsed
                  ? _section == _WideShellSection.chats
                        ? ListenableBuilder(
                            listenable: DapBindingStore.instance,
                            builder: (context, _) => SidebarSessionsList(
                              manager: widget.manager,
                              sessionNamesStore:
                                  widget.sessionNamesStore ?? _namesStore,
                              prefsStore: widget.sessionPrefsStore ?? _uiPrefs,
                              collapsed: true,
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
                          )
                        : const SizedBox.shrink()
                  : switch (_section) {
                      _WideShellSection.chats ||
                      _WideShellSection.activity ||
                      _WideShellSection.apps => _buildChatPanel(
                        collapsed: collapsed,
                      ),
                      _WideShellSection.local => _buildLocalPanel(),
                    },
            ),
          ],
        ),
      ),
    );
  }

  /// The Local section's sidebar: folder-first navigation (folders, then a
  /// folder's Telegram-style session list), shell-owned drill-down state.
  Widget _buildLocalPanel({bool compact = false}) {
    return LocalSessionsPanel(
      controller: _chatController,
      compact: compact,
      selectedFolderId: _localFolderId,
      onSelectFolder: (folderId) => setState(() => _localFolderId = folderId),
      selectedSessionId: _selectedSessionId,
      onOpenSession: (entry) => unawaited(_openLocalEntry(entry)),
      onNew: _newSession,
      iconResolver: _folderIcons,
    );
  }

  Widget _buildCollapsedChatHeader() {
    return MessengerSectionHeader(
      title: context.l10n.wideNavChats,
      searchController: null,
      searchHint: context.l10n.wideChatsSearchHint,
      onProfile: _openNarrowProfile,
      onNew: _newSession,
      onBrandLongPress: () => unawaited(_mintSessionFromBrand()),
      collapsed: true,
      onExpand: () => setState(() => _sidebarCollapsed = false),
    );
  }

  /// The vertical rail's destinations (the horizontal bar's section set,
  /// re-ordered Telegram-style): the Chats filters first, then Local,
  /// Activity, Apps and the identity (networks) row; Settings is the
  /// pinned bottom slot.
  List<MessengerRailDestination> _railDestinations() {
    final filter = _chatController.filter;
    final chatsSelected = _section == _WideShellSection.chats;
    var unreadChats = 0;
    var runningSessions = 0;
    for (final entry in _chatController.localEntries) {
      if ((entry.unreadCount ?? 0) > 0) unreadChats++;
      if (entry.isStreaming) runningSessions++;
    }
    MessengerRailDestination filterRow(
      ChatListFilter value,
      IconData icon,
      String label, {
      int? badge,
    }) => MessengerRailDestination(
      rowKey: ValueKey('chatFilter-${value.name}'),
      icon: icon,
      label: label,
      selected: chatsSelected && filter == value,
      onTap: (_) {
        _chatController.setFilter(value);
        _selectSection(_WideShellSection.chats);
      },
      badge: badge,
    );
    MessengerRailDestination sectionRow(
      _WideShellSection section,
      IconData icon,
      String label,
    ) => MessengerRailDestination(
          rowKey: ValueKey('messengerPrimaryNav-${section.name}'),
          icon: icon,
          label: label,
          selected: _section == section,
          onTap: (_) => _selectSection(section),
        );
    return [
      filterRow(
        ChatListFilter.all,
        Icons.inbox_outlined,
        context.l10n.chatFilterAll,
      ),
      filterRow(
        ChatListFilter.unread,
        Icons.chat_bubble_outline_rounded,
        context.l10n.chatFilterUnread,
        badge: unreadChats,
      ),
      filterRow(
        ChatListFilter.agents,
        Icons.people_outline_rounded,
        context.l10n.chatFilterAgents,
      ),
      filterRow(
        ChatListFilter.channels,
        Icons.tag_rounded,
        context.l10n.chatFilterChannels,
      ),
      MessengerRailDestination(
        rowKey: const ValueKey('messengerPrimaryNav-local'),
        icon: Icons.folder_outlined,
        label: context.l10n.wideNavLocal,
        selected: _section == _WideShellSection.local,
        badge: runningSessions,
        badgeMuted: true,
        onTap: (_) => _selectSection(_WideShellSection.local),
      ),
      sectionRow(
        _WideShellSection.activity,
        Icons.notifications_none_rounded,
        context.l10n.wideNavActivity,
      ),
      sectionRow(
        _WideShellSection.apps,
        Icons.grid_view_rounded,
        context.l10n.appsGridTitle,
      ),
      MessengerRailDestination(
        rowKey: const ValueKey('chatNetworkFilter'),
        icon: Icons.public_outlined,
        label: context.l10n.networkNetworksTitle,
        selected: false,
        onTap: _showRailNetworkMenu,
      ),
    ];
  }

  /// The identity globe stays its own rail row: tapping it opens the same
  /// network-filter menu the chat panel's trailing globe showed, anchored
  /// at the row.
  Future<void> _showRailNetworkMenu(BuildContext rowContext) async {
    if (!mounted) return;
    final box = rowContext.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final overlay =
        Overlay.of(rowContext).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );
    final selection = await showMenu<String>(
      context: rowContext,
      position: position,
      items: chatNetworkFilterMenuItems(
        context,
        controller: _chatController,
        manager: widget.networkSessions,
      ),
    );
    if (selection == null || !mounted) return;
    await selectChatNetworkFilter(
      context,
      value: selection,
      controller: _chatController,
      manager: widget.networkSessions,
      networkMode: widget.networkMode,
    );
  }

  /// The wide shell's left rail surface + the 8pt seam before the content
  /// column (Telegram pattern). Badges: unread chats on the Unread row,
  /// running sessions (muted) on the Local row.
  Widget _buildNavRail() {
    return ListenableBuilder(
      listenable: _chatController,
      builder: (context, _) => MessengerNavRail(
        key: const ValueKey('messengerNavRail'),
        destinations: _railDestinations(),
        settingsLabel: context.l10n.settingsTitle,
        onSettingsTap: () => unawaited(_openSettings()),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Chat (center)
  // ---------------------------------------------------------------------------

  Widget _buildChatArea(FahColors colors, {bool narrowRoute = false}) {
    final active = widget.manager.active;
    final networkEntry = _activeNetworkEntry;
    if (active == null && networkEntry == null) {
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
            EdgeInsets.only(top: _isMacOS && narrowRoute ? 28 : 0),
      ),
      child: networkEntry != null
          ? _buildNetworkChatArea(networkEntry)
          : ChatScreen(
              manager: widget.manager,
              sessionTitle: _sessionDisplayTitle(),
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
                modelId: active!.service.modelId,
                tooltip: context.l10n.chatModelSwitchTooltip,
                maxWidth: 132,
                onTap: () => _openModelPicker(active),
                onLongPress: () =>
                    unawaited(_openModelSettings(active.service)),
              ),
              onModelChipTap: () => _openModelPicker(active),
              chipMenuLabel: active.service.modelId,
              onAppsToggle: narrowRoute
                  ? () => _selectSection(_WideShellSection.apps)
                  : null,
            ),
    );
  }

  Widget _buildNetworkChatArea(ChatListEntry entry) {
    final manager = widget.networkSessions!;
    return NetworkChatPage(
      controller: widget.networkMode!,
      manager: manager,
      showAppBar: true,
      showChannelHeader: false,
      projectLabel: entry.networkName ?? entry.networkId,
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
          controller: _appLauncherController,
          fullScreen: !_isNarrow,
          onProfile: _openNarrowProfile,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          layoutStore: widget.layoutStore,
          appsStore: _appsStore,
          tileEngineFactory: widget.tileEngineFactory,
          networkMode: _isNarrow ? widget.networkMode : null,
          networkSessions: _isNarrow ? widget.networkSessions : null,
          onOpenNetworks: widget.networkSessions == null
              ? null
              : () => unawaited(
                  showChatNetworksDialog(
                    context,
                    manager: widget.networkSessions!,
                    networkMode: widget.networkMode,
                  ),
                ),
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
    if (_activeNetworkEntry != null) {
      setState(() => _activeNetworkEntry = null);
    }
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
    if ((service == null && _activeNetworkEntry == null) ||
        _narrowChatRouteVisible) {
      return;
    }
    _narrowChatRouteVisible = true;
    final route = MaterialPageRoute<void>(
      builder: (routeContext) => service == null
          ? _buildChatArea(FahColors.of(routeContext), narrowRoute: true)
          : ListenableBuilder(
              listenable: service,
              builder: (routeContext, _) =>
                  _buildChatArea(FahColors.of(routeContext), narrowRoute: true),
            ),
    );
    _narrowChatRoute = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      _narrowChatRouteVisible = false;
      if (identical(_narrowChatRoute, route)) _narrowChatRoute = null;
    }
  }

  /// A tap on an already-live sidebar row. Hosted surfaces re-dispatch
  /// through the relay (the local slot holds only the boot attach — a
  /// bare switchTo would be a silent no-op); desktop falls back to it.
  Future<void> _openLiveSession(String sessionId) async {
    final active = widget.manager.active;
    if (active == null) return;
    if (_activeNetworkEntry != null) {
      setState(() => _activeNetworkEntry = null);
    }
    if (_appPresentation?.pinned != true) {
      unawaited(_dismissPresentedSurface());
    }
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
    if (_activeNetworkEntry != null) {
      setState(() => _activeNetworkEntry = null);
    }
    if (_appPresentation?.pinned != true) {
      unawaited(_dismissPresentedSurface());
    }
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

  Future<void> _openModelSettings(AgentService service) async {
    await pushFaPage<void>(
      context,
      ModelsSettingsPage(
        service: service,
        registry: widget.registry,
        lastConnectionStore: widget.lastConnectionStore,
      ),
    );
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
    if (_isNarrow) {
      final fsRevision = service?.fsRevision;
      // The SAME Files card every other entry uses — the shared chrome
      // band, never a legacy Scaffold + app-bar duplicate.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FilesAppPage(
            presentation: FilesAppPresentation(
              env: env,
              // The active session's folder rides along: the browser
              // gates on it (allow-access flow) instead of silently
              // listing the active mount when the env cannot open it.
              sessionFolder: service?.currentSessionCwd,
              fsRevision: fsRevision,
              onProjectMountChanged: service?.refreshProjectMountPrompt,
            ),
          ),
        ),
      );
      return;
    }
    // Wide: Files presents through the same right-pane surface as JS
    // apps — native content, one animated entrance, never an instant pop.
    setState(() {
      _appPresentation = null;
      _filesPresentation = FilesAppPresentation(
        env: env,
        // The active session's folder rides along (the gate seam — see
        // the narrow branch above).
        sessionFolder: service?.currentSessionCwd,
        fsRevision: service?.fsRevision,
        onProjectMountChanged: service?.refreshProjectMountPrompt,
      );
    });
    _presentSurface();
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
