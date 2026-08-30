import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:path/path.dart' as p;

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/project_mount_flow.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';

import 'package:fa/ui/screens/app_launcher_screen.dart';
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
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv, SessionMetadata;

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

/// Whether we're on macOS desktop (traffic lights float over content).
bool get faIsMacOSDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

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

class _WideLayoutShellState extends State<WideLayoutShell> {
  bool _sidebarCollapsed = false;

  /// The apps panel's nested Navigator — registered on [FaChatHost] so the
  /// agent's `open_app` tool launches apps inside the panel instead of
  /// pushing a full-screen route over the shell.
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
    unawaited(_reloadPersistedSessions());
    unawaited(_ensureNamesStore());
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
    return 'Personal'; // l10n:ignore — matches the drawer group label
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
    final store = await SessionNamesStore.load(service.env);
    if (!mounted) return;
    setState(() => _namesStore = store);
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
    FaChatHost.jsAppNavigatorKey = _appsNavigatorKey;
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _listenedService?.removeListener(_onServiceChanged);
    if (FaChatHost.jsAppNavigatorKey == _appsNavigatorKey) {
      FaChatHost.jsAppNavigatorKey = null;
    }
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
                sessionNamesStore: widget.sessionNamesStore ?? _namesStore,
                collapsed: _sidebarCollapsed,
                onNewSession: _newSession,
                onSessionTap: () => setState(() {}),
                persistedSessions: _persistedSessions,
                sessionInfoNames: _jsonlNames,
                onOpenPersisted: _openPersistedSession,
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
    // prototype's clean icon style).
    const brandIcon = SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: SizedBox(width: 24, height: 24, child: FaBrandTile(size: 24)),
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
        // Session header: the active session's FOLDER (its origin cwd) —
        // not a workspace/mount picker. Tap opens the session info dialog
        // (rename, restrict, folder).
        // No bottom border — the vertical dividers between panels run full height.
        Container(
          // Chip inner padding (8h) is compensated here so the label/icon
          // glyphs keep their old 20px edge alignment while the hover/focus
          // pill hugs each chip instead of smearing across the header.
          padding: EdgeInsets.fromLTRB(12, _isMacOS ? 28 : 8, 12, 4),
          decoration: BoxDecoration(
            color: isLight ? colors.panel : colors.panel,
          ),
          child: Row(
            children: [
              // The Expanded keeps the model chip pushed to the right edge
              // (a Flexible + Spacer combo breaks hot-reload layouts); the
              // Align loosens the width so the InkWell pill shrink-wraps the
              // chip instead of smearing across the whole header.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: _openSessionInfoDialog,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 16,
                              color: _sessionHasFolder
                                  ? colors.indigo
                                  : colors.dim,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _sessionFolderLabel(),
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Quick model switch: current model name → tap opens the
              // unified model picker (all providers, filter). The chip
              // is wrapped in a [Material] so the [InkWell] ripple has
              // somewhere to paint — a plain Container ancestor would
              // swallow the gesture highlight.
              Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
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
    // The nested Navigator ensures that calls to Navigator.of(context)
    // from within the apps area (app launches via pushJsApp,
    // Settings/Files tiles) push within this panel rather than replacing
    // the whole shell.
    //
    // The MOBILE launcher is the single panel implementation on every
    // form factor (drag&drop folders, live tiles, search, the Widgets /
    // Get widgets tabs); the chat sheet stays off here — the wide shell
    // owns chat itself.
    return Navigator(
      key: _appsNavigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (context) => AppLauncherScreen(
          manager: widget.manager,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          appsStore: widget.appsStore,
          sessionNamesStore: widget.sessionNamesStore,
          hideChatSheet: true,
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
    final active = widget.manager.active;
    if (active == null) return;
    final service = active.service;
    final config = service.configForClone;
    if (config == null) return;
    final l10n = context.l10n;
    final env = service.env;
    final mountedPath = _mountedPath;
    final supportsPicking = !kIsWeb && Platform.isMacOS;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.newSessionFolderTitle),
        children: [
          SimpleDialogOption(
            key: const ValueKey('newSessionCurrentFolder'),
            onPressed: () => Navigator.pop(dialogContext, 'current'),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                mountedPath != null
                    ? l10n.newSessionCurrentFolder(p.basename(mountedPath))
                    : l10n.sessionFolderPersonal,
              ),
              subtitle: mountedPath != null ? Text(mountedPath) : null,
              leading: const Icon(Icons.folder_outlined),
            ),
          ),
          if (supportsPicking)
            SimpleDialogOption(
              key: const ValueKey('newSessionChooseFolder'),
              onPressed: () => Navigator.pop(dialogContext, 'choose'),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.workspaceDialogChangeFolder),
                leading: const Icon(Icons.create_new_folder_outlined),
              ),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'choose') {
      final messenger = ScaffoldMessenger.of(context);
      final String? picked;
      try {
        picked = await pickAndApplyProjectMount(
          env: env,
          onApplied: () => service.refreshProjectMountPrompt(),
          onAccessDenied: () => messenger.showSnackBar(
            SnackBar(content: Text(l10n.filesFolderAccessDenied)),
          ),
        );
      } on Object catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.filesFolderPickerError(e.toString()))),
        );
        return;
      }
      if (picked == null) return; // cancelled the picker — no session
    }
    unawaited(
      widget.manager.createSession(
        config: config,
        serviceFactory: () async => service.clone(),
      ),
    );
  }

  /// Opens a persisted-only session from disk (the sidebar's history tail),
  /// cloning the active service's connection — the same pattern the JS-app
  /// session binding uses.
  Future<void> _openPersistedSession(SessionMetadata metadata) async {
    final active = widget.manager.active;
    if (active == null) return;
    final service = active.service;
    try {
      await widget.manager.openSession(
        metadata,
        config:
            service.configForClone ??
            AgentConfig(
              providerKind: service.providerKind,
              modelId: service.modelId,
              baseUrl: '',
              apiKey: '',
            ),
        serviceFactory: () => service.clone(),
      );
    } on Object catch (error) {
      // A torn/corrupt session file must not crash the shell — the entry
      // just stays in the list.
      debugPrint('[fah] open persisted session ${metadata.id} failed: $error');
    }
  }

  /// Opens the same two-step provider → model picker the settings
  /// "Default chat model" row uses — keeping the chat header's quick
  /// model switch in lockstep with the settings flow.
  Future<void> _openModelPicker(FlutterManagedSession session) async {
    final service = session.service;
    final registry = widget.registry;
    final lastConnectionStore = widget.lastConnectionStore;
    if (registry == null) return;
    final result = await pushFaPage<MediaSlotEditorResult>(
      context,
      MediaSlotProviderPickerPage(
        slot: null,
        title: context.l10n.settingsDefaultChatModelTitle,
        initial: null,
        mainBaseUrl: service.activeBaseUrl,
        registry: registry,
        // Connected providers only — same as the role/media rows.
        connectedOnly: true,
        // Editing the main connection: no "Same as main" row.
        allowMainConnection: false,
      ),
    );
    if (result == null || result.cleared) return;
    if (!mounted) return;
    final override = result.override!;
    String? resolvedKey;
    if (override.apiKeyName != null && override.apiKeyName!.isNotEmpty) {
      resolvedKey = registry.keyValueForName(override.apiKeyName!) ?? '';
      if (resolvedKey.isEmpty) {
        resolvedKey = FaUiHost.resolveKey(override.apiKeyName!, () => '');
      }
    }
    final config = FaChatModelConfig(
      providerKind: override.providerKind,
      modelId: override.modelId,
      baseUrl: override.baseUrl,
      apiKey: resolvedKey ?? '',
      providerId: override.providerId,
    );
    final agentConfig = agentConfigFrom(config);
    await service.reconfigure(agentConfig);
    await lastConnectionStore?.saveFromConfig(agentConfig);
  }

  /// Session info dialog: the active session's name (renameable — same
  /// store the CLI's rename writes), its folder (read-only display: the
  /// folder is chosen at session creation, not switchable here), the
  /// restrict-access toggle, and the cross-instance mailbox address.
  Future<void> _openSessionInfoDialog() async {
    final l10n = context.l10n;
    final service = widget.manager.active?.service;
    final env = service?.env;
    if (env == null) return;
    // The session's OWN folder (from its metadata), not the shared env.
    final sessionFolder = service?.currentSessionCwd;
    final hasFolder = _sessionHasFolder;
    final sessionId = service?.currentSessionId;
    final names = widget.sessionNamesStore ?? _namesStore;
    final nameController = TextEditingController(
      text: sessionId == null ? '' : names?.titleFor(sessionId) ?? '',
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.workspaceDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Session name (rename): the same store the CLI's rename
            // writes, so a title set here shows in `fa --resume` too.
            if (sessionId != null && names != null) ...[
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
                onSubmitted: (value) =>
                    _saveSessionName(names, sessionId, value),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              l10n.workspaceDialogCurrentFolder,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              hasFolder && sessionFolder != null
                  ? p.basename(sessionFolder)
                  : l10n.workspaceDialogPersonal,
              style: Theme.of(dialogContext).textTheme.bodyMedium,
            ),
            if (hasFolder && sessionFolder != null) ...[
              const SizedBox(height: 2),
              Text(
                l10n.workspaceDialogHostPath,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                sessionFolder,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              // 'Restrict tools to this folder' — gates read/write/bash
              // outside the session's folder root.
              StatefulBuilder(
                builder: (innerContext, setLocal) {
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
                            onApplied: () =>
                                service?.refreshProjectMountPrompt(),
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
              ),
            ],
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
        ),
        actions: [
          if (sessionId != null && names != null)
            TextButton(
              onPressed: () =>
                  _saveSessionName(names, sessionId, nameController.text),
              child: Text(l10n.settingsSaveButton),
            ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(dialogContext);
              final address = _mailboxAddress(service);
              await Clipboard.setData(ClipboardData(text: address));
              messenger.showSnackBar(
                SnackBar(content: Text(l10n.workspaceDialogMailboxCopied)),
              );
            },
            child: Text(l10n.workspaceDialogMailboxCopy),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.workspaceDialogClose),
          ),
        ],
      ),
    );
    nameController.dispose();
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
