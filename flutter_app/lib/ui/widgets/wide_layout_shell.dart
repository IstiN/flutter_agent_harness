import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;

import 'package:path/path.dart' as p;

import 'package:fa/apps/app_icon.dart';
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
import 'package:fa/services/project_folder_channel.dart';
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
import 'package:fa/ui/apps/running_apps_dock.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/fa_route_header.dart';
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
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/network/models.dart' show Channel;
import 'package:fa/ui/chats/network_inbox_http_adapter.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/quick_model_chip.dart';
import 'package:fa/ui/widgets/subagent_chat_badge.dart';
import 'package:fa/ui/screens/models_settings_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_navigation.dart';
import 'package:fa/ui/widgets/boot_oversize_notice.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        CwdOverrideEnv,
        ExecutionEnv,
        SessionMetadata,
        createSessionId,
        isSubagentSession,
        leaseOwnerLabel,
        subagentParentId;

export 'package:fa/ui/widgets/fa_route_header.dart'
    show faAppBar, faIsMacOSDesktop;

part 'wide_layout_shell_settings.dart';
part 'wide_layout_shell_panels.dart';
part 'wide_layout_shell_navigation.dart';
part 'wide_layout_shell_session_actions.dart';

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

/// The sessions sidebar's resize handle (tests find it by this key).
const Key kSidebarDragHandleKey = ValueKey('sidebar-drag-handle');

enum _WideShellSection { chats, local, activity, apps, settings }

class _WideLayoutShellState extends State<WideLayoutShell>
    with TickerProviderStateMixin {
  static const _collapsedSidebarWidth = 96.0;
  static const _sidebarCollapseDuration = Duration(milliseconds: 200);

  /// The presented-surface reveal: JS apps AND Files dock in the right
  /// pane through one animated entrance/exit (~200ms, FaMotion ease) —
  /// never an instant pop.
  static const _presentationRevealDuration = Duration(milliseconds: 200);

  /// The desktop's untouched docked-presentation width; doubles as the
  /// sentinel distinguishing a never-resized slot from a user-sized one.
  static const _defaultPresentationWidth = 340.0;

  /// The docked presentation slot's current width. Apps can resize it with
  /// the shared leading-edge [FaPaneResizeHandle]; Files keeps its own panel
  /// behavior and the reveal still uses a fixed inner canvas per frame.
  double _presentationWidth = _defaultPresentationWidth;

  /// Lets panel part-extensions update this [State] without calling the
  /// protected [setState] member outside the concrete state subclass.
  void _updateShell(VoidCallback update) => setState(update);

  bool _sidebarCollapsed = false;

  /// The chats-list state saved when a Duo app presentation auto-collapsed
  /// the sidebar (null = no auto-collapse in flight). A manual toggle during
  /// the presentation clears it, so closing never fights the user's latest
  /// intent.
  bool? _sidebarStateBeforePresentation;

  /// Whether the chat's docked files panel is driving a presentation run
  /// (the [FaChatHost] `onFilesPanelChanged` hook). See
  /// [_onChatFilesPanelChanged].
  bool _chatFilesPanelActive = false;
  _WideShellSection _section = _WideShellSection.chats;
  SettingsCategory _settingsCategory = SettingsCategory.providersModels;

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

  /// Every launched app stays mounted until its explicit Close action.
  /// Minimizing or opening another app only changes the active presentation;
  /// each [MessengerAppPresentation.viewKey] preserves its JS runtime while
  /// the IndexedStack moves between visible and offstage hosts.
  final List<MessengerAppPresentation> _runningApps = [];

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

  /// The chats sidebar's NETWORKS surface (Telegram pattern): when open,
  /// the SIDEBAR swaps to [ChatNetworksPanel] — the identity globe's
  /// networks strip with the in-place channel drill-down, in the same slot
  /// the Local drill-down uses. The message column keeps the chat.
  /// Section switches close it, like a route pop.
  bool _networksSurfaceOpen = false;

  /// Lazily built resolver for folders' well-known icon files (cached
  /// per folder in memory).
  FolderIconResolver? _folderIconResolver;
  FolderIconResolver get _folderIcons =>
      _folderIconResolver ??= FolderIconResolver(widget.manager.env);
  String? _chatAccountKey;

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
  /// listener; this method then runs again and picks them up. The visible
  /// ListView rows — not this whole-corpus reload — request the lazy fill.
  Future<void> _reloadPersistedSessions() async {
    final all = await widget.manager.listPersistedSessions();
    final names = widget.manager.knownSessionNames;
    if (!mounted) return;
    setState(() {
      _persistedSessions = all;
      _jsonlNames = names;
    });
    unawaited(_refreshChatProjection());
  }

  /// The host path of the current project mount (null = Personal / no mount).
  String? get _mountedPath {
    final env = widget.manager.active?.service.env;
    if (env == null) return null;
    return currentMountedPath(env);
  }

  /// Effective project path for the active session. A live folder mount is
  /// authoritative: the session's origin cwd still describes the sandbox it
  /// came from, while the user is now working in the mounted host project.
  String? get _sessionFolderPath {
    final mounted = _mountedPath?.trim();
    if (mounted != null && mounted.isNotEmpty) return mounted;
    final service = widget.manager.active?.service;
    final cwd =
        service?.currentSessionCwd ??
        service?.env.cwd ??
        widget.manager.env.cwd;
    return cwd.isEmpty ? null : cwd;
  }

  /// Chip label: basename of the live mounted project, else the active
  /// session's origin folder. No real folder means the personal sandbox.
  String _sessionFolderLabel() {
    final cwd = _sessionFolderPath;
    if (cwd != null) {
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
    final entry = _chatController.localEntryFor(active.id);
    if (entry != null && entry.isSubagent) return entry.title;
    return derivedSessionTitle(
      context,
      id: active.id,
      createdAt: active.createdAt,
    );
  }

  /// Whether the active session has a real project folder (drives the
  /// chip icon color: indigo when bound to a folder, dim when personal).
  bool get _sessionHasFolder {
    final cwd = _sessionFolderPath;
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
    // Activity/config changes can update persisted stamps and ordering;
    // decoration-only manager notifications deliberately reuse the short
    // listing result cache instead.
    widget.manager.invalidateListing();
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
    FaChatHost.onFilesPanelChanged = _onChatFilesPanelChanged;
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
    if (FaChatHost.onFilesPanelChanged == _onChatFilesPanelChanged) {
      FaChatHost.onFilesPanelChanged = null;
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
    final duoRailWidth = FaDuoControlRail.widthOf(context);
    final duoNewChat =
        duoRailWidth > 0 &&
        !_presentationMounted &&
        const {
          _WideShellSection.chats,
          _WideShellSection.local,
          _WideShellSection.activity,
        }.contains(_section);
    // Scaffold supplies both the required Material ancestor and a snack
    // host now that no permanent launcher pane owns one. List/Activity
    // panels need an explicit content lane for their New-chat rail. Apps
    // and standalone Settings own their SafeArea and must not be inset twice.
    Widget buildBody() {
      final child = narrow ? _buildNarrowBody(colors) : _buildBody(colors);
      if (!narrow || !duoNewChat) return child;
      return Padding(
        padding: EdgeInsets.only(right: duoRailWidth),
        child: SizedBox.expand(
          key: const ValueKey('narrowDuoContentLane'),
          child: child,
        ),
      );
    }

    final scaffold = Scaffold(
      backgroundColor: colors.bg,
      extendBody: !presentationCoversNarrow && narrow,
      body: Stack(
        children: [
          Positioned.fill(child: buildBody()),
          if (duoNewChat)
            Positioned(
              top: FaDuoControlRail.topOf(context),
              right: 0,
              bottom: FaDuoControlRail.topOf(context),
              width: duoRailWidth,
              child: FaDuoControlRail(
                leading: [
                  MessengerNewChatButton(
                    key: ValueKey(
                      narrow ? 'narrowShellNewChat' : 'messengerNewButton',
                    ),
                    onTap: () => unawaited(_newSession()),
                    label: context.l10n.wideChatFallbackTitle,
                  ),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: presentationCoversNarrow
          ? null
          : (narrow ? _buildNarrowNavigation() : null),
      floatingActionButton:
          narrow &&
              !duoNewChat &&
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
    // The dock keeps the full between-margins span: SafeArea's right
    // inset (the folded Duo's 84pt camera-lane profile) is NOT consumed
    // here — the camera hardware sits top-right, the bottom-right glass
    // is free, and consuming it squeezed the 6 phone slots below the
    // full-label minimum ("Netw…"/"Activ…").
    return SafeArea(
      top: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MessengerBottomNavigation.horizontalMargin,
          0,
          MessengerBottomNavigation.horizontalMargin,
          MessengerBottomNavigation.bottomGap,
        ),
        child: ListenableBuilder(
          listenable: _chatController,
          builder: (context, _) {
            final destinations = _railDestinations();
            const primaryKeys = <String>{
              'chatFilter-all',
              'messengerPrimaryNav-local',
              'messengerPrimaryNav-network',
              'messengerPrimaryNav-activity',
              'messengerPrimaryNav-apps',
            };
            const overflowOrder = <String>[
              'chatFilter-channels',
              'chatFilter-unread',
              'messengerPrimaryNav-settings',
            ];
            final screenWidth = MediaQuery.sizeOf(context).width;
            // The dock spans the full width between its side margins so the
            // 6 phone slots get even slices: ~53pt of text width at 390pt
            // keeps "Networks"/"Activity" whole, and a 320pt screen still
            // fits without overflowing (labels may truncate there).
            final widthLimit = MessengerBottomNavigation.expandedMaxWidth;
            final dockWidth = math.min(
              widthLimit,
              screenWidth - 2 * MessengerBottomNavigation.horizontalMargin,
            );
            // Five primary destinations plus More are the phone contract;
            // wider narrow screens promote Channels from overflow before
            // Unread and Settings as capacity grows.
            final slotCapacity = (dockWidth / 64).floor().clamp(
              6,
              destinations.length,
            );
            final visibleOverflowCount = slotCapacity >= destinations.length
                ? overflowOrder.length
                : slotCapacity - primaryKeys.length - 1;
            final visibleKeys = <String>{
              ...primaryKeys,
              ...overflowOrder.take(visibleOverflowCount),
            };
            String nameOf(MessengerRailDestination destination) =>
                (destination.rowKey as ValueKey<String>).value;
            final direct = [
              for (final destination in destinations)
                if (visibleKeys.contains(nameOf(destination))) destination,
            ];
            final overflow = [
              for (final destination in destinations)
                if (!visibleKeys.contains(nameOf(destination))) destination,
            ];
            final moreSelected = overflow.any(
              (destination) => destination.selected,
            );
            var selectedIndex = direct.indexWhere(
              (destination) => destination.selected,
            );
            if (selectedIndex < 0) {
              selectedIndex = moreSelected ? direct.length : 0;
            }
            final moreBadge = overflow.fold<int>(
              0,
              (total, destination) =>
                  total + (destination.badgeMuted ? 0 : destination.badge ?? 0),
            );
            return MessengerBottomNavigation(
              key: const ValueKey('narrowShellNavigation'),
              widthLimit: widthLimit,
              selectedIndex: selectedIndex,
              children: [
                for (final destination in direct)
                  MessengerBottomNavigationItem(
                    key: destination.rowKey,
                    icon: destination.icon,
                    label: destination.label,
                    selected: destination.selected,
                    badge: destination.badge,
                    badgeMuted: destination.badgeMuted,
                    onTap: () => destination.onTap?.call(context),
                  ),
                if (overflow.isNotEmpty)
                  MessengerBottomNavigationItem(
                    key: const ValueKey('messengerPrimaryNav-more'),
                    icon: FaIconThemeData.of(
                      context,
                    ).resolve(FaSemanticIcon.more),
                    label: context.l10n.commonMore,
                    selected: moreSelected,
                    badge: moreBadge == 0 ? null : moreBadge,
                    onTap: () => _showNarrowMoreSheet(overflow),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Opens a Local-section row through the existing open flow (live via
  /// the relay/switch, persisted via the clone path), then clears the
  /// row's unread count the same way the chat list does.
  Future<void> _openLocalEntry(ChatListEntry entry) async {
    if (entry.kind != ChatListEntryKind.localAgent) return;
    await _openCollapsedChatEntry(entry);
  }

  Future<void> _openCollapsedChatEntry(ChatListEntry entry) async {
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
      _WideShellSection.chats =>
        _networksSurfaceOpen
            ? _buildNetworksSidebar()
            : _buildChatPanel(compact: true),
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
            : _buildChatPanel(compact: true),
      _WideShellSection.apps => _buildAppsArea(),
      _WideShellSection.settings => _buildSettingsPanel(),
    };
    // One shared titlebar inset for every narrow section (the wide sidebar
    // panels are flush with the window edge and clear it themselves —
    // ChatListPanel adds the same inset when not compact).
    final inset = math.max(8.0, MediaQuery.paddingOf(context).top);
    final positioned = Padding(
      padding: EdgeInsets.only(top: inset),
      child: base,
    );
    final showPresentation =
        _presentationMounted || _presentationReveal.value > 0;
    // The presented surface (app or Files) fades in/out over the section.
    final surface = showPresentation ? _buildPresentedSurface() : null;
    return Stack(
      children: [
        positioned,
        if (_appPresentation == null && _runningApps.isNotEmpty)
          Positioned.fill(child: Offstage(child: _buildRunningAppsStack())),
        if (surface != null)
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
        if (_runningApps.isNotEmpty)
          Positioned(
            right: 0,
            top: 88,
            bottom: 88,
            child: Center(child: _buildRunningAppsDock()),
          ),
      ],
    );
  }

  Future<void> _openNarrowProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          key: const ValueKey('narrowShellProfileRoute'),
          appBar: faAppBar(
            context: context,
            title: Text(context.l10n.appTitle),
          ),
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
            // The glass card keeps 8pt floating margins on the window edges
            // (top, bottom, right) — the content must live INSIDE them,
            // never under the clip (the old -8 let rows bleed 8px past the
            // card's right edge). The LEADING margin is shared with the
            // rail: its trailing 8pt margin-as-seam IS the card gutter
            // (owner: the rail↔sidebar gap halves to 8pt total), so the
            // leading margin is 0 and the content fills the rest.
            final contentWidth =
                (contentCollapsed ? _collapsedSidebarWidth : _sidebarWidth) - 8;
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
            // The rail's floating glass card (8pt margins on every side,
            // 1:1 with the collapsed chats panel) + its trailing 8pt
            // margin-as-seam precede the sidebar column, so floating
            // chrome anchored to the sidebar's edges must clear the
            // rail's footprint.
            final railLeading =
                MessengerNavRail.width + MessengerNavRail.seam * 2;
            // The 36pt circle keeps the panel's 8pt gutter contract on
            // BOTH sides: 8pt card margin + 8pt gutter put its right edge
            // 16pt inside the sidebar's right edge (owner call: the open
            // panel's toggle must not hug the panel edge).
            final duoCollapsed =
                FaDuoControlRail.isActive(context) && _sidebarCollapsed;
            final toggleLeft = duoCollapsed
                // glassSidebarPanel excludes the card's 8pt trailing margin;
                // center in that VISIBLE 88pt pane, not the 96pt layout slot.
                ? railLeading + (sidebarWidth - 8 - 36) / 2
                : railLeading + sidebarWidth - 52 + toggleShift;
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
                // Expanded Duo docks the presented surface right like the
                // desktop (owner call: no centered dialog) — the chat owns
                // the left area and the chats list collapses for the run.
                // Expanded Duo always docks right; the slide-over floating
                // panel stays a desktop tight-window behavior.
                final floatingPanel =
                    slotVisible &&
                    !FaDuoControlRail.isActive(context) &&
                    constraints.maxWidth <= 1080;
                return Stack(
                  children: [
                    Row(
                      children: [
                        _buildNavRail(),
                        SizedBox(
                          key: const ValueKey('desktopSidebarContainer'),
                          width: sidebarWidth,
                          child: _desktopPanelFrame(
                            key: const ValueKey('glassSidebarPanel'),
                            // Floating margins: 8pt on the window edges
                            // (top/right/bottom); the leading edge is 0 —
                            // the rail's trailing 8pt margin-as-seam is the
                            // shared rail↔sidebar gutter (owner: 8pt total,
                            // both cards keep their outer window margins).
                            padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
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
                                  // Geometry may be mid-flight, but the
                                  // visible controls remain live. Blocking
                                  // the whole sidebar until an animation
                                  // completes made startup/collapse clicks
                                  // silently disappear on slow first frames.
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
                      // One shared action centerline in expanded and
                      // collapsed states: y=35 with the chat trajectory/copy
                      // and the docked Files X/search/overflow controls.
                      top: _isMacOS ? 17 : 19,
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
                        onPressed: () => setState(() {
                          _sidebarCollapsed = !_sidebarCollapsed;
                          _sidebarStateBeforePresentation = null;
                        }),
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
                    if (presentation == null && _runningApps.isNotEmpty)
                      Positioned.fill(
                        child: Offstage(child: _buildRunningAppsStack()),
                      ),
                    if (presentation != null && full)
                      Positioned.fill(child: _buildRunningAppsStack()),
                    if (_runningApps.isNotEmpty)
                      Positioned(
                        right: FaDuoControlRail.widthOf(context),
                        top: 72,
                        bottom: 72,
                        child: Center(child: _buildRunningAppsDock()),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// The single presented surface: a JS app or the native Files browser.
  Widget _buildPresentedSurface() {
    final presentation = _appPresentation;
    if (presentation != null) return _buildRunningAppsStack();
    final files = _filesPresentation;
    if (files == null) return const SizedBox.shrink();
    return FilesAppPanel(
      presentation: files,
      // The docked pane sits beside the chat header: its band X rides the
      // header's shared action centerline (the collapse toggle's center).
      topCenterline: true,
      duoRailInset: true,
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
          ? tokens.direction == FaVisualDirection.glass
                ? DecoratedBox(
                    key: key,
                    decoration: BoxDecoration(
                      color: tokens.surface1,
                      borderRadius: borderRadius,
                      border: Border.all(color: tokens.hairline),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: ClipRRect(
                        borderRadius: borderRadius - BorderRadius.circular(1),
                        // LightweightLiquidGlass lays its FittedBox child out
                        // beyond the glass render box by the frame inset. Clip
                        // at the inner boundary so no pixel reaches the border.
                        child: FaSurface(
                          glass: true,
                          useBackdropGroup: true,
                          color: tokens.surface1,
                          borderRadius: borderRadius - BorderRadius.circular(1),
                          child: child,
                        ),
                      ),
                    ),
                  )
                : FaSurface(
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
      onMinimize: () => unawaited(_minimizePresentedApp()),
      onQuickApps: () => unawaited(_showQuickApps()),
      // A root phone Apps destination has no Back-to-Chats chrome. Desktop
      // docked and Full presentations always expose the same return action.
      onBack: _isNarrow
          ? null
          : () => unawaited(_backToChatsFromPresentedApp()),
    );
  }

  Widget _buildRunningAppsStack() {
    final active = _appPresentation;
    final activeIndex = active == null
        ? 0
        : _runningApps.indexWhere(
            (presentation) => identical(presentation, active),
          );
    return IndexedStack(
      key: const ValueKey('runningAppsStack'),
      index: activeIndex < 0 ? 0 : activeIndex,
      children: [for (final app in _runningApps) _buildPresentedApp(app)],
    );
  }

  Widget _buildRunningAppsDock() {
    return RunningAppsDock(
      key: const ValueKey('runningAppsDock'),
      apps: [for (final presentation in _runningApps) presentation.app],
      activeAppId: _appPresentation?.app.id,
      env: widget.manager.env,
      onOpen: (app) => unawaited(_activateRunningApp(app.id)),
    );
  }

  Widget _buildCenterSurface(FahColors colors) {
    return switch (_section) {
      _WideShellSection.chats => _buildChatArea(colors),
      _WideShellSection.local => _buildChatArea(colors),
      _WideShellSection.activity => SafeArea(
        key: const ValueKey('wideDuoActivitySafeArea'),
        top: false,
        bottom: false,
        left: false,
        child: ActivityDetailPanel(
          controller: _activityController,
          onOpenSession: _openActivitySession,
          showFirstWhenUnselected: true,
        ),
      ),
      _WideShellSection.apps => _buildAppsArea(),
      // Settings owns its floating Duo rail just like the standalone route.
      // Insetting here as well would move Back one rail-width to the left.
      _WideShellSection.settings => SafeArea(
        key: const ValueKey('wideDuoSettingsSafeArea'),
        top: false,
        bottom: false,
        left: false,
        right: false,
        child: _buildSettingsArea(),
      ),
    };
  }

  /// All is the chats-home reset, not merely another list facet. In
  /// particular it must unwind a drilled network/channel even when Chats
  /// already owns the rail (so the ordinary section-change reset is a no-op).
  void _selectAllChats() {
    _chatController.setFilter(ChatListFilter.all);
    _chatController.setNetworkFilter(const ChatNetworkFilter.all());
    _selectSection(_WideShellSection.chats);
    setState(() {
      _networksSurfaceOpen = false;
      _activeNetworkEntry = null;
      _localFolderId = null;
    });
    final mode = widget.networkMode;
    if (mode != null) unawaited(mode.exitToLocal());
  }

  void _selectSection(_WideShellSection section) {
    final changed = section != _section;
    var dismissPresentation = false;
    var minimizeApp = false;
    setState(() {
      final presentation = _appPresentation;
      if (presentation != null) {
        presentation.fullScreen = false;
        if (changed && !presentation.pinned) minimizeApp = true;
      }
      if (changed && _filesPresentation != null) dismissPresentation = true;
      if (changed) {
        // The section-owned surfaces reset together (owner pass): the
        // networks sidebar AND the Local drill — returning to Local shows
        // the level-1 folder list, never the drilled folder.
        _networksSurfaceOpen = false;
        _localFolderId = null;
      }
      _section = section;
      if (section == _WideShellSection.activity) {
        _narrowActivityDetailVisible = false;
      }
    });
    // Section navigation minimizes a JS runtime; only Close disposes it.
    // Files has no persistent runtime and keeps the legacy dismissal.
    if (minimizeApp) {
      unawaited(_minimizePresentedApp());
    } else if (dismissPresentation) {
      unawaited(_dismissPresentedSurface());
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
      // On Duo the running app owns the right surface. Do not leave the
      // cramped Apps directory in the center after launching from it; the
      // rail chooser switches apps while the center returns to Chats.
      if (_section == _WideShellSection.apps &&
          FaDuoControlRail.widthOf(context) > 0) {
        _section = _WideShellSection.chats;
      }
      final current = _appPresentation;
      if (current?.app.id == app.id) {
        current!.fullScreen = _isNarrow;
      } else {
        current?.fullScreen = false;
        _filesPresentation = null;
        final existing = _runningApps
            .where((presentation) => presentation.app.id == app.id)
            .firstOrNull;
        final presentation =
            existing ??
            MessengerAppPresentation(
              app: app,
              service: service,
              appService: appService,
              permissionsStore: permissionsStore,
            );
        if (existing == null) _runningApps.add(presentation);
        presentation.fullScreen = _isNarrow;
        _appPresentation = presentation;
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
    _bumpPresentationWidthForDuo();
    _collapseSidebarForDuoPresentation();
    if (FaMotion.reduceMotionOf(context)) {
      _presentationReveal.value = 1;
      return;
    }
    unawaited(_presentationReveal.forward());
  }

  /// First Duo presentation sizes the dock to the window (the desktop
  /// default of [_defaultPresentationWidth] reads cramped beside the
  /// expanded chat). A user drag overwrites [_presentationWidth], so the
  /// untouched-default sentinel never re-fires.
  void _bumpPresentationWidthForDuo() {
    if (_presentationWidth != _defaultPresentationWidth ||
        _isNarrow ||
        !FaDuoControlRail.isActive(context)) {
      return;
    }
    final windowWidth = MediaQuery.sizeOf(context).width;
    _presentationWidth = (windowWidth * .42).clamp(
      _defaultPresentationWidth,
      math.min(720.0, windowWidth * .65),
    );
  }

  /// Owner call (Duo): a presented surface (a JS app OR the native Files
  /// browser — both dock right) owns the right dock, so the chats list
  /// collapses and the chat fills the left area. The pre-presentation state
  /// is saved once per presentation run and restored on close/minimize; a
  /// manual toggle in between clears the save (the user's intent wins).
  void _collapseSidebarForDuoPresentation() {
    if (!_presentationMounted ||
        _sidebarStateBeforePresentation != null ||
        _isNarrow ||
        !FaDuoControlRail.isActive(context)) {
      return;
    }
    _sidebarStateBeforePresentation = _sidebarCollapsed;
    if (!_sidebarCollapsed) _sidebarCollapsed = true;
  }

  /// Restores the sidebar state saved by
  /// [_collapseSidebarForDuoPresentation] when the presented surface (app
  /// or Files) goes away. A chat files panel still open keeps owning the
  /// collapse — its own close restores instead.
  void _restoreSidebarAfterPresentation() {
    if (_chatFilesPanelActive) return;
    final saved = _sidebarStateBeforePresentation;
    if (saved == null) return;
    _sidebarStateBeforePresentation = null;
    if (_sidebarCollapsed != saved) _sidebarCollapsed = saved;
  }

  /// The chat's docked files panel toggled (the [FaChatHost]
  /// `onFilesPanelChanged` hook): opening it is a presentation run of its
  /// own — collapse the chats list for the run, restore on close. Shares
  /// the save slot with presented surfaces so an app opened on top never
  /// expands the list mid-run, and a manual toggle still wins. The
  /// collapse starts on the NEXT frame: starting it in the same frame the
  /// panel reveal mounts made the chat body relayout mid-build and
  /// transiently squeezed the panel's search band below the field's
  /// minimum (a 5px RenderFlex overflow on the transition frame).
  void _onChatFilesPanelChanged(bool open) {
    if (!mounted) return;
    if (open) {
      if (_chatFilesPanelActive ||
          _isNarrow ||
          !FaDuoControlRail.isActive(context)) {
        return;
      }
      _chatFilesPanelActive = true;
      _sidebarStateBeforePresentation ??= _sidebarCollapsed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_chatFilesPanelActive ||
            _presentationMounted ||
            _sidebarCollapsed) {
          return;
        }
        setState(() => _sidebarCollapsed = true);
      });
    } else {
      if (!_chatFilesPanelActive) return;
      _chatFilesPanelActive = false;
      if (!_presentationMounted) {
        setState(_restoreSidebarAfterPresentation);
      }
    }
  }

  Future<void> _activateRunningApp(String appId) async {
    final presentation = _runningApps
        .where((candidate) => candidate.app.id == appId)
        .firstOrNull;
    if (presentation == null || !mounted) return;
    if (identical(_appPresentation, presentation)) {
      await _minimizePresentedApp();
      return;
    }
    setState(() {
      if (_section == _WideShellSection.apps &&
          FaDuoControlRail.widthOf(context) > 0) {
        _section = _WideShellSection.chats;
      }
      _appPresentation?.fullScreen = false;
      _filesPresentation = null;
      presentation.fullScreen = _isNarrow;
      _appPresentation = presentation;
    });
    _presentSurface();
  }

  /// Hides only the visible app. Its presentation stays in [_runningApps]
  /// and its GlobalKey-mounted JS view moves offstage without losing state.
  Future<void> _minimizePresentedApp() async {
    final presentation = _appPresentation;
    if (presentation == null) return;
    _presentationEpoch++;
    final epoch = _presentationEpoch;
    presentation.fullScreen = false;
    if (FaMotion.reduceMotionOf(context)) {
      _presentationReveal.value = 0;
    } else {
      await _presentationReveal.reverse();
    }
    if (!mounted || _presentationEpoch != epoch) return;
    if (identical(_appPresentation, presentation)) {
      setState(() {
        _appPresentation = null;
        _restoreSidebarAfterPresentation();
      });
    }
  }

  /// Animates the presented surface out (~200ms), then clears it. Closing
  /// a JS app also removes it from [_runningApps]; minimizing never calls
  /// this method. Reopening mid-flight cancels the clear (the epoch guard).
  Future<void> _dismissPresentedSurface() async {
    if (!_presentationMounted && _presentationReveal.value == 0) return;
    final closingApp = _appPresentation;
    _presentationEpoch++;
    final epoch = _presentationEpoch;
    if (FaMotion.reduceMotionOf(context)) {
      _presentationReveal.value = 0;
    } else {
      await _presentationReveal.reverse();
    }
    if (!mounted || _presentationEpoch != epoch) return;
    setState(() {
      if (closingApp != null) _runningApps.remove(closingApp);
      _appPresentation = null;
      _filesPresentation = null;
      _restoreSidebarAfterPresentation();
    });
  }

  Future<void> _backToChatsFromPresentedApp() async {
    await _minimizePresentedApp();
    if (!mounted) return;
    _selectSection(_WideShellSection.chats);
  }

  /// Quick installed/running app chooser hosted by Duo's vertical rail.
  /// Selecting an app changes only the presented surface: the center pane
  /// stays on its current destination instead of becoming a cramped Apps
  /// directory beside the open app.
  Future<void> _showQuickApps() async {
    final installed = await _appsStore.listApps();
    if (!mounted) return;
    final runningIds = _runningApps.map((entry) => entry.app.id).toSet();
    final apps = <JsAppInfo>[
      for (final presentation in _runningApps) presentation.app,
      for (final app in installed)
        if (!runningIds.contains(app.id)) app,
    ];
    if (apps.isEmpty) return;
    final size = MediaQuery.sizeOf(context);
    final duoRailWidth = FaDuoControlRail.widthOf(context);
    final menuWidth = math.min(
      320.0,
      math.max(240.0, size.width - duoRailWidth - 24),
    );
    final left = math.max(8.0, size.width - duoRailWidth - menuWidth - 8);
    final top = math.min(FaDuoControlRail.topOf(context), size.height - 80);
    final selected = await showMenu<JsAppInfo>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(left, top, menuWidth, 1),
        Offset.zero & size,
      ),
      constraints: BoxConstraints(
        maxWidth: menuWidth,
        maxHeight: math.min(420.0, size.height * .65),
      ),
      items: [
        for (final app in apps)
          PopupMenuItem<JsAppInfo>(
            key: ValueKey('quickApp-${app.id}'),
            value: app,
            child: Row(
              children: [
                AppIcon(app: app, env: widget.manager.env, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (runningIds.contains(app.id))
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: FahColors.of(context).indigo,
                  ),
              ],
            ),
          ),
      ],
    );
    if (selected == null || !mounted) return;
    if (_appPresentation?.app.id == selected.id) return;
    if (runningIds.contains(selected.id)) {
      await _activateRunningApp(selected.id);
      return;
    }
    await pushJsApp(
      context,
      manager: widget.manager,
      app: selected,
      source: 'launcher',
    );
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
          // The narrow presentation covers everything — minimize its live
          // runtime rather than disposing it on a chat switch.
          unawaited(_minimizePresentedApp());
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
            if (collapsed && _section != _WideShellSection.settings)
              _buildCollapsedChatHeader(),
            Expanded(
              child: collapsed
                  ? _buildCollapsedSidebarBody()
                  : switch (_section) {
                      _WideShellSection.chats =>
                        _networksSurfaceOpen
                            ? _buildNetworksSidebar()
                            : _buildChatPanel(collapsed: collapsed),
                      _WideShellSection.activity || _WideShellSection.apps =>
                        _buildChatPanel(collapsed: collapsed),
                      _WideShellSection.local => _buildLocalPanel(),
                      _WideShellSection.settings => _buildSettingsPanel(),
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedChatHeader() {
    // Duo has one global, centered expand control in the collapsed pane.
    // Keeping the 30pt brand here as well squeezed both into 96pt and read
    // as a clipped icon rather than an intentional header.
    if (FaDuoControlRail.isActive(context)) {
      return const SizedBox(height: 64);
    }
    return MessengerSectionHeader(
      title: context.l10n.wideNavChats,
      searchController: null,
      searchHint: context.l10n.wideChatsSearchHint,
      onProfile: _openNarrowProfile,
      onNew: FaDuoControlRail.isActive(context)
          ? null
          : () => unawaited(_newSession()),
      onBrandLongPress: () => unawaited(_mintSessionFromBrand()),
      collapsed: true,
      onExpand: () => setState(() {
        _sidebarCollapsed = false;
        _sidebarStateBeforePresentation = null;
      }),
    );
  }

  /// Shared rail/dock destinations (Telegram pattern): the Chats filters
  /// All/Unread lead, then the Local section, the Network destination (the
  /// identity globe, opening the networks surface), the Channels filter, and
  /// the Activity/Apps sections. Agents have NO rail row — their sessions
  /// live in Local folders and the flat All list ([ChatListFilter.agents]
  /// stays a filter, the chats toolbar keeps it). The wide rail consumes
  /// Settings through its pinned bottom slot; the phone dock consumes the
  /// same descriptor as a direct destination.
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
      selected: chatsSelected && filter == value && !_networksSurfaceOpen,
      onTap: (_) {
        if (value == ChatListFilter.all) {
          _selectAllChats();
          return;
        }
        // _selectSection(chats) is a no-op while Networks owns the Chats
        // body. A facet tap must reveal that facet on every form factor and
        // leave exactly one rail destination selected.
        setState(() {
          _networksSurfaceOpen = false;
          if (_isNarrow) _activeNetworkEntry = null;
        });
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
      MessengerRailDestination(
        rowKey: const ValueKey('messengerPrimaryNav-local'),
        icon: Icons.folder_outlined,
        label: context.l10n.wideNavLocal,
        selected: _section == _WideShellSection.local,
        badge: runningSessions,
        badgeMuted: true,
        onTap: (_) => _selectSection(_WideShellSection.local),
      ),
      MessengerRailDestination(
        rowKey: const ValueKey('messengerPrimaryNav-network'),
        icon: Icons.public_outlined,
        label: context.l10n.networkNetworksTitle,
        selected: chatsSelected && _networksSurfaceOpen,
        onTap: (_) {
          // The networks surface lives IN the chats sidebar (the same slot
          // the Local drill-down uses); the message column keeps the chat.
          _selectSection(_WideShellSection.chats);
          setState(() => _networksSurfaceOpen = true);
        },
      ),
      filterRow(
        ChatListFilter.channels,
        Icons.tag_rounded,
        context.l10n.chatFilterChannels,
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
        rowKey: const ValueKey('messengerPrimaryNav-settings'),
        icon: Icons.settings_outlined,
        label: context.l10n.settingsTitle,
        selected: _section == _WideShellSection.settings,
        onTap: (_) => unawaited(_openSettings()),
      ),
    ];
  }

  /// The wide shell's left rail surface + the 8pt seam before the content
  /// column (Telegram pattern). Badges: unread chats on the Unread row,
  /// running sessions (muted) on the Local row.
  Widget _buildNavRail() {
    return ListenableBuilder(
      listenable: _chatController,
      builder: (context, _) => MessengerNavRail(
        key: const ValueKey('messengerNavRail'),
        destinations: [
          for (final destination in _railDestinations())
            if (destination.rowKey !=
                const ValueKey('messengerPrimaryNav-settings'))
              destination,
        ],
        settingsLabel: context.l10n.settingsTitle,
        settingsSelected: _section == _WideShellSection.settings,
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
    final pendingOpen = _pendingOpenId;
    if (pendingOpen != null &&
        pendingOpen != active?.id &&
        networkEntry == null &&
        (active?.service.messages.isEmpty ?? true)) {
      // With no current transcript an indicator communicates the open. When
      // real content is already visible, keep it stable until the new loaded
      // session activates — replacing it with a spinner reads as a flicker.
      return Center(
        child: SizedBox.square(
          key: const ValueKey('sessionOpeningIndicator'),
          dimension: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.indigo,
          ),
        ),
      );
    }
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
              inputHeader: SubagentChatBadge(
                // The subagent badge above the composer (subagent sessions
                // owner pass): one compact icon with the running count;
                // tapping it opens the anchored picker popover. Rows run
                // the SAME open flow a chat list row uses, and mark the
                // row read.
                controller: _chatController,
                sessionId: active?.id,
                onOpen: _openLocalEntry,
              ),
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
                providerBaseUrl: active.service.activeBaseUrl,
                tooltip: context.l10n.chatModelSwitchTooltip,
                maxWidth: 240,
                onTap: () => _openModelPicker(active),
                onLongPress: () =>
                    unawaited(_openModelSettings(active.service)),
              ),
              onModelChipTap: () => _openModelPicker(active),
              chipMenuLabel: active.service.modelId,
              onAppsToggle:
                  FaDuoControlRail.isActive(context) && _runningApps.isNotEmpty
                  ? () => unawaited(_showQuickApps())
                  : null,
            ),
    );
  }

  /// The chats sidebar's NETWORKS surface (Telegram pattern, owner pass):
  /// the identity globe swaps the SIDEBAR content to the networks strip
  /// with the in-place channel drill-down — the same slot the Local
  /// drill-down uses. Networks is a ROOT destination: only a drilled
  /// network's channel list has a back chevron; the manage action keeps the
  /// management dialog reachable. Opening a channel keeps the surface open:
  /// only the message column swaps to the channel's messages and the tapped
  /// row highlights.
  Widget _buildNetworksSidebar() {
    return ChatNetworksPanel(
      manager: widget.networkSessions,
      mode: widget.networkMode,
      chatList: _chatController,
      compact: _isNarrow,
      onCollapse: _isNarrow
          ? null
          : () => setState(() {
              _sidebarCollapsed = true;
              _sidebarStateBeforePresentation = null;
            }),
      onManageNetworks: () => unawaited(
        showChatNetworksDialog(
          context,
          manager: widget.networkSessions,
          networkMode: widget.networkMode,
        ),
      ),
      onOpenChannel: (networkId, channel) =>
          unawaited(_openSidebarNetworkChannel(networkId, channel)),
    );
  }

  /// The sidebar channel-row tap: membership first, then the channel
  /// entry (channel-rail contract).
  Future<void> _openSidebarNetworkChannel(
    String networkId,
    Channel channel,
  ) async {
    final manager = widget.networkSessions;
    final mode = widget.networkMode;
    if (manager == null || mode == null) {
      setState(() => _networksSurfaceOpen = false);
      return;
    }
    await _ensureSidebarNetworkMembership(manager, mode, networkId);
    await _openSidebarChannelEntry(manager, mode, networkId, channel);
  }

  /// Joins or resumes the network when the tapped channel's session is
  /// not live yet (open networks get the join sheet; password-protected
  /// ones resume straight from the saved credential).
  Future<void> _ensureSidebarNetworkMembership(
    NetworkSessionManager manager,
    NetworkModeController mode,
    String networkId,
  ) async {
    await mode.enterNetwork(networkId);
    if (manager.sessions.containsKey(networkId)) return;
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

  /// Select + open the tapped channel's messages right away. Deliberately
  /// NO setNetworkFilter here: a latched network filter narrowed the All
  /// facet to that network's rows only (owner bug).
  Future<void> _openSidebarChannelEntry(
    NetworkSessionManager manager,
    NetworkModeController mode,
    String networkId,
    Channel channel,
  ) async {
    final session = manager.sessions[networkId];
    if (session != null) {
      try {
        await session.openChannel(channel.id);
      } on Object catch (error) {
        if (mounted) showFahErrorSnack(context, error.toString());
      }
    }
    if (!mounted) return;
    await mode.selectChannel(channel.id);
    // Land the tap exactly like the chat-list row open does, but the
    // surface STAYS open (owner pass): ONLY the content pane swaps to
    // the channel's message view; the strip + channels list keep
    // their place and the tapped row highlights through
    // mode.selectChannel above. The projection row still becomes the
    // selected network entry so the All home carries the row's
    // selection once the back chevrons close the surface.
    // Session-snapshot fallback rows have no projection row; a
    // minimal stand-in entry keeps the content-pane contract there.
    final entry = _chatController.networkChannelEntries
        .where(
          (candidate) =>
              candidate.networkId == networkId &&
              candidate.id.value == channel.id,
        )
        .firstOrNull;
    if (!mounted) return;
    setState(() {
      _activeNetworkEntry =
          entry ??
          _standInNetworkChannelEntry(manager, networkId, channel);
    });
    // The row-open parity: the tap marks the projection row read.
    if (entry != null) await _chatController.markOpened(entry);
    if (mounted && _isNarrow) await _pushNarrowChat();
  }

  /// The fallback entry for session-snapshot rows with no projection row.
  ChatListEntry _standInNetworkChannelEntry(
    NetworkSessionManager manager,
    String networkId,
    Channel channel,
  ) {
    return ChatListEntry(
      id: ChatEntryId.network(
        ChatListEntryKind.networkChannel,
        networkId: networkId,
        id: channel.id,
      ),
      kind: ChatListEntryKind.networkChannel,
      networkId: networkId,
      networkName: manager.wallet.networks[networkId]?.name,
      title: channel.name ?? channel.id,
      createdAt: DateTime.now(),
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
    // from within Apps (app launches via pushJsApp, the Settings tile)
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
          showFilesTile: false,
          onProfile: _openNarrowProfile,
          onBack: _isNarrow
              ? null
              : () => _selectSection(_WideShellSection.chats),
          onOpenSettings: _openSettings,
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
    // Resolve the shared title overlay against the ORIGINAL root env before
    // a Personal session clone moves cwd into chats/<id>.
    await _ensureNamesStore();
    if (!mounted) return;
    final choice = await _pickNewSessionFolder(target.service);
    if (choice == null) return;
    if (_activeNetworkEntry != null) {
      setState(() => _activeNetworkEntry = null);
    }
    // Fire-and-forget: the dialog flow controls nothing downstream.
    unawaited(
      _createSessionInChosenFolder(
        target.service,
        target.config,
        sandboxFolderName: choice.sandboxName,
        sessionName: choice.sessionName,
      ),
    );
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
  /// folder (the active mount), a freshly picked Files folder, or a named
  /// folder inside the Personal sandbox. Null = aborted, no session.
  Future<({String? sandboxName, String? sessionName})?> _pickNewSessionFolder(
    AgentService service,
  ) async {
    final selection = await showDialog<_NewSessionFolderSelection>(
      context: context,
      builder: (_) => _NewSessionFolderDialog(mountedPath: _mountedPath),
    );
    if (selection == null || !mounted) return null;
    final sessionName = selection.sessionName;
    switch (selection.action) {
      case _NewSessionFolderAction.current:
        return (sandboxName: null, sessionName: sessionName);
      case _NewSessionFolderAction.choose:
        return await _applyPickedMount(service)
            ? (sandboxName: null, sessionName: sessionName)
            : null;
      case _NewSessionFolderAction.sandbox:
        final name = await _askNewSandboxFolderName();
        return name == null
            ? null
            : (sandboxName: name, sessionName: sessionName);
    }
  }

  Future<String?> _askNewSandboxFolderName() => showDialog<String>(
    context: context,
    builder: (_) => const _NewSandboxFolderDialog(),
  );

  /// The native Files/macOS folder picker: applies the picked mount to the
  /// whole app (like the info dialog's change button); false = cancelled.
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

  /// The parent session id when the ACTIVE session is a persisted
  /// subagent, else null (subagent sessions owner pass). The persisted
  /// listing is the SAME source the chat projection derives `parentId`
  /// from, so the close flow and the projection always agree.
  String? get _activeSubagentParentId {
    final activeId = widget.manager.active?.id;
    if (activeId == null) return null;
    final metadata = _persistedSessions
        .where((session) => session.id == activeId)
        .firstOrNull;
    if (metadata == null || !isSubagentSession(metadata)) return null;
    return subagentParentId(metadata);
  }

  /// The subagent chat's close (the narrow chat route's back): return to
  /// the PARENT session's chat — the active session switches in place and
  /// the still-open chat route rebuilds with the parent's transcript. A
  /// parent that is no longer openable (absent/ghost) leaves the pop to
  /// behave normally.
  Future<void> _revealSubagentParent() async {
    final parentId = _activeSubagentParentId;
    if (parentId == null) return;
    final live = widget.manager.sessions
        .where((session) => session.id == parentId)
        .firstOrNull;
    if (live != null) {
      await _openLiveSession(parentId);
      return;
    }
    final persisted = _persistedSessions
        .where((session) => session.id == parentId)
        .firstOrNull;
    if (persisted != null) {
      await _openPersistedSession(persisted);
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
              // The route tracks the MANAGER too: an active-session switch
              // under an open route (the subagent chips, or the subagent
              // close returning to its parent) must rebuild the chat area
              // around the new active session — the captured service alone
              // never notifies on a switch.
              listenable: Listenable.merge([service, widget.manager]),
              builder: (routeContext, _) {
                // The subagent chat's back is intercepted INSIDE the
                // rebuild: the predicate re-evaluates on every manager
                // notification (active-session switches), so once the
                // parent takes over, back pops normally.
                final interceptBack = _activeSubagentParentId != null;
                return PopScope(
                  canPop: !interceptBack,
                  onPopInvokedWithResult: (didPop, result) {
                    if (didPop) return;
                    unawaited(_revealSubagentParent());
                  },
                  child: _buildChatArea(
                    FahColors.of(routeContext),
                    narrowRoute: true,
                  ),
                );
              },
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
      unawaited(_minimizePresentedApp());
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
      unawaited(_minimizePresentedApp());
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
    if (_pendingOpenId != metadata.id) {
      setState(() => _pendingOpenId = metadata.id);
    }
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
    } finally {
      if (mounted && _pendingOpenId == metadata.id) {
        setState(() => _pendingOpenId = null);
      }
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
