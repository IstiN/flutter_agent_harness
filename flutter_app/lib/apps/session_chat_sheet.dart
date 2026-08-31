// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/chat_text_store.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/attached_session_controller.dart';
import 'package:fa/services/cli_session_presence.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/ui/screens/attached_session_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa/ui/widgets/chat_message_tile.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:fa/ui/widgets/rename_session_dialog.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart' show faIsMacOSDesktop;

/// The session chat overlay floating over the apps launcher, iMessage-style.
/// Three layers bottom→top (above the app grid):
///
/// - **Session panel**: the active session's transcript (the shared
///   [ChatMessageTile] renderer) under a slim header (drag handle, a
///   sessions-drawer button with the stacked-bubbles glyph, title via
///   [SessionNamesStore], 3-dots menu: New session / Rename / Open full
///   chat / Copy / Close). Slides up from the bottom to 92% and parks
///   UNDER the input bar; a pull-down on the header zone or the menu's
///   Close dismisses it. Focusing the input field opens the panel
///   immediately (typing never happens blind).
/// - **Sessions drawer**: the session list (live first, then
///   disk-persisted) sliding in from the LEFT — a New-session tile on top,
///   then rows rendered with the SAME [SessionTile] the wide sidebar uses
///   (active dot, title, relative-time subtitle, working-folder label,
///   3-dot rename/delete menu); tapping a row switches (persisted sessions
///   open lazily). It slides out under the input bar too: layer-wise both
///   the panel and the drawer sit between the app grid and the bar.
/// - **Input bar** (always visible, docked to the bottom edge): the shared
///   [ChatComposer] — leading slot is the sessions-drawer toggle while no
///   session is open and turns into the attach button once the panel is
///   up; the trailing slot is exactly ONE action (mic / stop / send,
///   scale+fade swap) — `hideMicWhenNotEmpty`. While the agent streams
///   with the panel closed, a slim [FaWorkBar] status row sits above the
///   composer.
///
/// Sending a message from the bar opens the panel automatically (the user
/// just asked something — the answer should be visible).
class SessionChatSheet extends StatefulWidget {
  const SessionChatSheet({
    super.key,
    required this.manager,
    this.registry,
    this.lastConnectionStore,
    this.sessionNamesStore,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
    this.audioControllerFactory,
    this.videoControllerFactory,
    this.panelFraction = SessionChatSheetState.defaultPanelFraction,
  });

  /// The multi-session manager the drawer and the panel are driven by.
  final FlutterSessionManager manager;

  /// Forwarded to the full chat screen ("Open full chat" menu action).
  final ProviderRegistry? registry;

  /// Forwarded to the full chat screen ("Open full chat" menu action).
  final LastConnectionStore? lastConnectionStore;

  /// The user-given session titles shown in the header; `null` loads the
  /// store from the env.
  final SessionNamesStore? sessionNamesStore;

  /// Forwarded to the composer (and the full chat screen).
  final UploadPicker? uploadPicker;

  /// Open panel height as a fraction of the sheet's laid-out height.
  /// Hosts that want the expanded panel to park lower (e.g. to keep an
  /// app's own header or hero content visible above it) pass a smaller
  /// fraction; defaults to [SessionChatSheetState.defaultPanelFraction].
  final double panelFraction;

  /// Microphone backend override for the composer (tests).
  final AsrApi? asr;

  /// Transcriber override for the composer (tests).
  final AsrTranscriber? asrTranscriber;

  /// Playback engine factory for inline audio players in the transcript.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video players in the transcript.
  final SandboxVideoControllerFactory? videoControllerFactory;

  @override
  State<SessionChatSheet> createState() => SessionChatSheetState();
}

class SessionChatSheetState extends State<SessionChatSheet>
    with TickerProviderStateMixin {
  /// Default open panel height as a fraction of the sheet's height.
  static const double defaultPanelFraction = 0.92;

  /// Fling velocity (px/s) that completes a panel drag.
  static const double _flingVelocity = 300;

  /// The sessions drawer width cap; narrow screens get 82% instead.
  static const double _drawerWidth = 320;

  late final AnimationController _panelAnim;
  late final AnimationController _drawerAnim;
  SessionNamesStore? _namesStore;

  /// Live-session presence (sessions a running `fa` CLI owns).
  CliSessionPresence? _presence;

  /// Disk-listing poll: new CLI sessions appear without manager events.
  Timer? _persistedTimer;

  /// Disk-persisted sessions minus the live ones, listed in the drawer.
  List<SessionMetadata> _persisted = const [];

  /// Session id → creation time from the last listing, driving the
  /// date-based derived titles (see [derivedSessionTitle]).
  Map<String, DateTime> _createdAtById = const {};

  /// Session id → the cwd the session was created in, from the last
  /// listing. A live session's env reports the app's CURRENT mount for
  /// every session, so the tile's folder label must come from here —
  /// otherwise it flips when the session opens.
  Map<String, String?> _cwdById = const {};

  /// Persisted sessions with an open in flight (drawer double-tap guard).
  final Set<String> _opening = {};

  /// Last seen live-session count — drives the persisted-list resync in
  /// [_onManagerChanged].
  var _lastLiveCount = -1;

  /// Key on the always-rendered bar column — its natural height is measured
  /// live into [_barHeight] so the drawer list and the panel transcript can
  /// pad their bottoms by the REAL bar height (composer + safe area +
  /// optional streaming status row) in the current environment.
  final GlobalKey _barKey = GlobalKey();

  /// Last measured natural bar height; seeded with an estimate.
  double _barHeight = 96;

  List<FlutterManagedSession> get _liveSessions => widget.manager.sessions;

  AgentService? get _activeService => widget.manager.active?.service;

  @override
  void initState() {
    super.initState();
    _panelAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _drawerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _namesStore = widget.sessionNamesStore;
    _namesStore?.addListener(_onChanged);
    if (_namesStore == null) unawaited(_loadNamesStore());
    widget.manager.addListener(_onManagerChanged);
    unawaited(_reloadPersisted());
    // Live-session presence: sessions a `fa` CLI currently owns show a
    // green dot and attach (read-only view + input hand-over) on tap.
    _presence = CliSessionPresence.start(
      widget.manager.env,
      widget.manager.sessionsRoot,
    );
    // A presence change (a CLI started or exited) must resync the drawer:
    // new CLI sessions come from disk, exited ones lose their dot.
    _presence?.addListener(_onPresenceChanged);
    // Disk sessions appear (a CLI created one) without any manager event
    // — poll the listing so the drawer stays current while the app runs.
    _persistedTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) unawaited(_reloadPersisted());
    });
    // SizeChangedLayoutNotifier does NOT fire for the FIRST layout — it
    // only reports changes against the baseline — so measure the bar once
    // up front; later changes (streaming row, multiline field) come through
    // the notification.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureBarHeight());
  }

  /// Reads the bar's real laid-out height into [_barHeight] (no-op when
  /// unchanged). Must run post-frame — during layout the render object is
  /// still dirty.
  void _measureBarHeight() {
    if (!mounted) return;
    final h = _barKey.currentContext?.size?.height;
    if (h != null && (h - _barHeight).abs() > 0.5) {
      setState(() => _barHeight = h);
    }
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _namesStore?.removeListener(_onChanged);
    _presence?.removeListener(_onPresenceChanged);
    _presence?.dispose();
    _persistedTimer?.cancel();
    _panelAnim.dispose();
    _drawerAnim.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Presence transitions resync both the live dots and the disk listing
  /// (a CLI session appears on start; an exited one may reappear as a
  /// persisted entry).
  void _onPresenceChanged() {
    if (!mounted) return;
    unawaited(_reloadPersisted());
    setState(() {});
  }

  Future<void> _loadNamesStore() async {
    final service = _activeService;
    if (service == null) return;
    final store = await SessionNamesStore.load(service.env);
    if (!mounted || _namesStore != null) return;
    setState(() => _namesStore = store..addListener(_onChanged));
  }

  /// The disk-persisted sessions minus the live ones, for the drawer list.
  Future<void> _reloadPersisted() async {
    final service = _activeService;
    if (service == null) return;
    try {
      final all = await service.listSessions();
      final liveIds = _liveSessions.map((s) => s.id).toSet();
      final persisted = [
        for (final metadata in all)
          if (!liveIds.contains(metadata.id)) metadata,
      ];
      if (mounted) {
        setState(() {
          _persisted = persisted;
          _createdAtById = {for (final m in all) m.id: m.createdAt};
          _cwdById = {for (final m in all) m.id: m.cwd};
        });
      }
    } on Object {
      // A broken sessions dir must not break the sheet.
    }
  }

  /// External session changes (drawer open, another surface's switch):
  /// drop persisted entries that went live, resync the list on live-count
  /// changes (closed sessions reappear there) and rebuild.
  void _onManagerChanged() {
    if (!mounted) return;
    final liveIds = _liveSessions.map((s) => s.id).toSet();
    final filtered = [
      for (final m in _persisted)
        if (!liveIds.contains(m.id)) m,
    ];
    if (filtered.length != _persisted.length) {
      _persisted = filtered;
      _opening.removeAll(liveIds);
    }
    if (liveIds.length != _lastLiveCount) {
      _lastLiveCount = liveIds.length;
      unawaited(_reloadPersisted());
    }
    setState(() {});
  }

  // --- panel open/close ------------------------------------------------------

  /// Opens the session panel programmatically (the launcher's session chip,
  /// the composer's onSent, the streaming status row).
  void expand() => unawaited(_openPanel());

  Future<void> _openPanel() {
    AppAnalytics.instance.chatSheetState('expanded');
    if (_drawerAnim.value > 0) {
      unawaited(
        _drawerAnim.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInCubic,
        ),
      );
    }
    return _panelAnim.animateTo(1, curve: Curves.easeOutCubic);
  }

  Future<void> _closePanel() {
    AppAnalytics.instance.chatSheetState('collapsed');
    // Dismiss the keyboard together with the panel: a still-focused
    // composer in the docked bar would keep the keyboard floating over the
    // app grid with no visible way to get rid of it.
    FocusManager.instance.primaryFocus?.unfocus();
    return _panelAnim.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInCubic,
    );
  }

  /// The laid-out height of the sheet's stack (below the status bar, above
  /// the keyboard), updated from the [LayoutBuilder] on every layout. Drives
  /// the drag math via [_panelPixels].
  double _stackHeight = 0;

  double get _panelPixels => _stackHeight * widget.panelFraction;

  void _onPanelDragUpdate(DragUpdateDetails details) {
    final pixels = _panelPixels;
    if (pixels <= 0) return; // not laid out yet — ignore the drag
    _panelAnim.stop();
    _panelAnim.value = (_panelAnim.value - details.delta.dy / pixels).clamp(
      0.0,
      1.0,
    );
  }

  void _onPanelDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (velocity >= _flingVelocity) {
      unawaited(_closePanel());
    } else if (velocity <= -_flingVelocity) {
      unawaited(_openPanel());
    } else {
      unawaited(_panelAnim.value < 0.5 ? _closePanel() : _openPanel());
    }
  }

  void _onPanelDragCancel() {
    // A canceled gesture (the arena was lost mid-drag) must still settle on
    // a real state — never leave the panel hanging between states.
    unawaited(_panelAnim.value < 0.5 ? _closePanel() : _openPanel());
  }

  // --- drawer ----------------------------------------------------------------

  Future<void> _toggleDrawer() {
    if (_drawerAnim.value > 0.5) {
      return _drawerAnim.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInCubic,
      );
    }
    unawaited(_reloadPersisted());
    return _drawerAnim.animateTo(1, curve: Curves.easeOutCubic);
  }

  /// Drawer row tap: live sessions switch in place, persisted ones open
  /// lazily — either way the drawer closes and the panel opens.
  Future<void> _openSessionFromDrawer(String id) async {
    unawaited(_toggleDrawer());
    // A live CLI session attaches (read-only view + input hand-over)
    // instead of opening a second writer on the same JSONL.
    if (_presence?.isLive(id) ?? false) {
      await _attachToCliSession(id);
      if (mounted) unawaited(_openPanel());
      return;
    }
    if (_liveSessions.any((s) => s.id == id)) {
      widget.manager.switchTo(id);
    } else {
      final metadata = _persisted.where((m) => m.id == id).firstOrNull;
      if (metadata != null) await _openPersisted(metadata);
    }
    if (mounted) unawaited(_openPanel());
  }

  /// Attaches to a session owned by a running `fa` CLI: the transcript
  /// follows the session JSONL 1:1 and composer input is handed to the
  /// CLI process through the messaging fabric.
  Future<void> _attachToCliSession(String sessionId) async {
    final metadata = _persisted.where((m) => m.id == sessionId).firstOrNull;
    final title =
        _namesStore?.titleFor(sessionId) ??
        derivedSessionTitle(
          context,
          id: sessionId,
          createdAt: metadata?.createdAt ?? DateTime.now(),
        );
    // Root + slug come from the session file's own path so the fabric
    // mailboxes hit the EXACT root the owning CLI colocated them under —
    // never a guessed default (App Group vs ~/.fah/sessions fallback,
    // multi-root listings, other-workspace sessions).
    final (attachRoot, attachSlug) = sessionRootAndSlugForPath(
      defaultRoot: widget.manager.sessionsRoot,
      sessionPath: metadata?.path,
      fallbackCwd: widget.manager.env.sessionCwd,
    );
    final transport = fileAttachTransport(
      env: widget.manager.env,
      sessionsRoot: attachRoot,
      cwdSlug: attachSlug,
      resolvePath: (id) async => id == sessionId ? metadata?.path : null,
    );
    final controller = AttachedSessionController(
      sessionId: sessionId,
      title: title,
      transport: transport,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttachedSessionScreen(controller: controller),
      ),
    );
    controller.dispose();
  }

  /// Lazily opens a persisted session (same config path the old pager used).
  /// `loadSession` restores the session's own effective model (its last
  /// `model_change` record) on top of this config.
  Future<void> _openPersisted(SessionMetadata metadata) async {
    if (!_opening.add(metadata.id)) return;
    try {
      final active = _activeService;
      if (active == null) return;
      await widget.manager.openSession(
        metadata,
        config:
            active.configForClone ??
            AgentConfig(
              providerKind: active.providerKind,
              modelId: active.modelId,
              baseUrl: '',
              apiKey: '',
            ),
        serviceFactory: () async => active.clone(),
      );
    } finally {
      _opening.remove(metadata.id);
    }
  }

  Future<void> _newSession() async {
    final manager = widget.manager;
    final source = manager.active?.service;
    final config =
        source?.configForClone ??
        manager.sessions.firstOrNull?.service.configForClone;
    if (source == null || config == null) return;
    await manager.createSession(
      config: config,
      serviceFactory: () async => source.clone(),
    );
  }

  /// Drawer "New session" tile: create, then open the panel on it.
  Future<void> _newSessionFromDrawer() async {
    unawaited(_toggleDrawer());
    await _newSession();
    if (mounted) unawaited(_openPanel());
  }

  Future<void> _openFullChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
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
    );
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final service = _activeService;
    if (service == null) return const SizedBox.shrink();
    final colors = FahColors.of(context);
    final size = MediaQuery.sizeOf(context);
    final drawerW = math.min(_drawerWidth, size.width * 0.82);
    return SafeArea(
      // Never let the panel/drawer slide under the status bar.
      bottom: false,
      // LayoutBuilder, NOT MediaQuery/view insets: the host Scaffold's
      // resizeToAvoidBottomInset shrinks the body around the keyboard, so
      // the laid-out height already excludes it — and constraint changes
      // REBUILD us, while `View.of(context)` never notifies on viewInsets
      // changes (`_ViewScope.updateShouldNotify` compares the view instance
      // only). Reading the inset statically kept the keyboard-less panel
      // height after the keyboard opened and pushed the panel header off
      // the top edge.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final panelH = constraints.maxHeight * widget.panelFraction;
          _stackHeight = constraints.maxHeight;
          return AnimatedBuilder(
            animation: Listenable.merge([_panelAnim, _drawerAnim]),
            builder: (context, _) {
              final panelV = _panelAnim.value;
              final drawerV = _drawerAnim.value;
              final scrimV = math.max(panelV, drawerV);
              return Stack(
                children: [
                  // Scrim over the app grid while a layer is open; a tap on
                  // the exposed part dismisses the top layer. The bar sits
                  // ABOVE the scrim and stays interactive.
                  if (scrimV > 0)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onScrimTap,
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.30 * scrimV),
                        ),
                      ),
                    ),
                  // The session panel slides up from the bottom and parks
                  // under the input bar (the bar overlaps its bottom edge).
                  if (panelV > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: panelH,
                      child: Transform.translate(
                        offset: Offset(0, (1 - panelV) * panelH),
                        child: _buildPanel(colors, service),
                      ),
                    ),
                  // The sessions drawer slides in from the left, under the
                  // bar. Its scrim sits ABOVE the panel: the grid-level
                  // scrim is unreachable while the panel covers it, so
                  // without this layer an outside tap would hit the panel
                  // and leave the drawer open.
                  if (drawerV > 0)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_toggleDrawer()),
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.15 * drawerV),
                        ),
                      ),
                    ),
                  if (drawerV > 0)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: drawerW,
                      child: Transform.translate(
                        offset: Offset(-(1 - drawerV) * drawerW, 0),
                        child: _buildDrawer(colors),
                      ),
                    ),
                  // The always-visible input bar — the top layer.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildBar(colors, service),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _onScrimTap() {
    if (_drawerAnim.value > 0.5) {
      unawaited(_toggleDrawer());
    } else if (_panelAnim.value > 0.5) {
      unawaited(_closePanel());
    }
  }

  /// The docked input bar: the streaming status row (panel closed only)
  /// over the composer — one continuous surface into the home-indicator zone.
  Widget _buildBar(FahColors colors, AgentService service) {
    final panelOpen = _panelAnim.value > 0.5;
    return Container(
      key: const ValueKey('sessionChatBar'),
      decoration: BoxDecoration(
        color: colors.panelAlt.withValues(alpha: 0.97),
        border: Border(top: BorderSide(color: colors.border)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 12,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        // Measure the natural bar height on every layout: the panel
        // transcript and the drawer list pad their bottoms by this exact
        // value, so content never hides under the floating bar.
        child: NotificationListener<SizeChangedLayoutNotification>(
          onNotification: (_) {
            // The notification fires DURING layout — defer the read.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _measureBarHeight(),
            );
            return true;
          },
          child: SizeChangedLayoutNotifier(
            key: _barKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The streaming status row belongs to the closed-panel bar;
                // the open panel shows the progress inside the transcript.
                if (!panelOpen)
                  FaWorkBar(service: service, onExpand: expand, embedded: true),
                ChatComposer(
                  // The status row above appears/disappears with the panel
                  // and the streaming state — WITHOUT a stable key the
                  // column child matching would recreate the composer on
                  // every toggle, killing its FocusNode (the field lost
                  // focus right after send, forcing a re-tap per message).
                  key: const ValueKey('sessionChatComposer'),
                  service: service,
                  uploadPicker: widget.uploadPicker,
                  asr: widget.asr,
                  asrTranscriber: widget.asrTranscriber,
                  hideMicWhenNotEmpty: true,
                  // The always-visible bar must not pop the keyboard at
                  // app start — focus comes from a deliberate tap.
                  autofocus: false,
                  onSent: expand,
                  // Typing never happens blind: focusing the field opens
                  // the current session's panel right away.
                  onFocusChanged: (focused) {
                    if (focused) expand();
                  },
                  // Panel closed: the leading slot opens the sessions
                  // drawer. Panel open: null → the composer's own attach
                  // button (the "+" of the iMessage bar).
                  leadingBuilder: panelOpen
                      ? null
                      : (context) => IconButton(
                          key: const ValueKey('sessionChatDrawerButton'),
                          icon: _drawerAnim.value > 0.5
                              ? const Icon(Icons.close)
                              : SessionsGlyph(
                                  color: colors.dim,
                                  background: colors.panelAlt,
                                ),
                          tooltip: context.l10n.sidebarSessionsHeader,
                          onPressed: () => unawaited(_toggleDrawer()),
                        ),
                ),
                // The composer's own SafeArea lifts the field above the home
                // indicator; the bar's panel color runs through the
                // indicator zone — one continuous surface.
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The session panel: drag handle + header (draggable), divider, and the
  /// active session's transcript padded above the floating bar.
  Widget _buildPanel(FahColors colors, AgentService service) {
    final activeId = widget.manager.activeId ?? '';
    return Container(
      key: const ValueKey('sessionChatPanel'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.panelAlt.withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(top: BorderSide(color: colors.border)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 12,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: _onPanelDragUpdate,
              onVerticalDragEnd: _onPanelDragEnd,
              onVerticalDragCancel: _onPanelDragCancel,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Center(child: _handle(colors)),
                  ),
                  _buildHeader(colors, service),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: _SessionTranscript(
                key: ValueKey('sessionTranscript:$activeId'),
                service: service,
                bottomPadding: _barHeight,
                audioControllerFactory: widget.audioControllerFactory,
                videoControllerFactory: widget.videoControllerFactory,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The sessions drawer: a "New session" tile over the live + persisted
  /// session list (the SAME [SessionTile] the wide sidebar renders),
  /// sliding in from the left under the input bar.
  Widget _buildDrawer(FahColors colors) {
    final l10n = context.l10n;
    final activeId = widget.manager.activeId;
    final entries =
        <
            ({
              String id,
              DateTime createdAt,
              DateTime lastUpdatedAt,
              String? cwd,
              FlutterManagedSession? live,
              SessionMetadata? persisted,
            })
          >[
            for (final s in _liveSessions)
              (
                id: s.id,
                createdAt: s.createdAt,
                lastUpdatedAt: s.lastUpdatedAt,
                // The DISK cwd (the session's origin folder) wins: a live
                // session stays grouped under the folder it belongs to,
                // even when the app's current mount moved elsewhere.
                cwd: _cwdById[s.id] ?? s.service.env.sessionCwd,
                live: s,
                persisted: null,
              ),
            for (final m in _persisted)
              (
                id: m.id,
                createdAt: m.createdAt,
                lastUpdatedAt: m.lastUpdatedAt ?? m.createdAt,
                cwd: m.cwd,
                live: null,
                persisted: m,
              ),
            // Presence-only rows: a `fa` CLI just started and its session
            // file does not exist yet (the CLI materializes the JSONL on
            // the first message) — the live dot must show regardless.
            for (final id in (_presence?.live.keys ?? const <String>[]))
              if (!_liveSessions.any((s) => s.id == id) &&
                  !_persisted.any((m) => m.id == id))
                (
                  id: id,
                  createdAt:
                      DateTime.tryParse(_presence!.live[id]!.startedAt) ??
                      DateTime.now(),
                  lastUpdatedAt: DateTime.now(),
                  cwd: _cwdById[id],
                  live: null,
                  persisted: null,
                ),
          ]
          ..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
    // Folder-grouped rows (headers + tiles): the sessions of one project
    // stay together under the folder basename, most recently active
    // project first (entries are activity-sorted, groups follow).
    final drawerRows = <_DrawerRow>[
      for (final group in _groupDrawerEntries(entries, l10n)) ...[
        _DrawerRow.header(group.label),
        for (final e in group.entries) _DrawerRow.tile(e),
      ],
    ];
    return Container(
      key: const ValueKey('sessionChatDrawer'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.panelAlt.withValues(alpha: 0.97),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
        border: Border(right: BorderSide(color: colors.border)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 12,
            offset: Offset(2, 0),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // macOS: the unified titlebar's traffic lights float over the
              // drawer's top edge — clear them (each screen handles its own
              // clearance, see main.dart's _MacOSDragStrip).
              padding: EdgeInsets.fromLTRB(
                16,
                faIsMacOSDesktop ? 30 : 12,
                8,
                4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.sidebarSessionsHeader,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: l10n.appsCollapseChatTooltip,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(_toggleDrawer()),
                  ),
                ],
              ),
            ),
            ListTile(
              key: const ValueKey('sessionChatNewSession'),
              leading: const Icon(Icons.add),
              title: Text(l10n.sidebarNewSessionTooltip),
              onTap: () => unawaited(_newSessionFromDrawer()),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          l10n.sidebarNoSessions,
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: colors.dim),
                        ),
                      ),
                    )
                  : ListView.builder(
                      // The drawer slides out UNDER the input bar: pad the
                      // list tail so the last row clears it. Horizontal
                      // insets match the wide sidebar's list.
                      padding: EdgeInsets.fromLTRB(8, 4, 8, _barHeight + 8),
                      // Rows = folder group headers + session tiles: the
                      // sessions of one project stay together under their
                      // folder name.
                      itemCount: drawerRows.length,
                      itemBuilder: (context, index) {
                        final row = drawerRows[index];
                        if (row.isHeader) {
                          return Padding(
                            key: ValueKey(
                              'sessionChatDrawerHeader:${row.label}',
                            ),
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                            child: Text(
                              row.label!,
                              style: TextStyle(
                                color: colors.dim,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }
                        final entry = row.entry!;
                        final isActive =
                            entry.live != null && entry.id == activeId;
                        final title =
                            _namesStore?.titleFor(entry.id) ??
                            derivedSessionTitle(
                              context,
                              id: entry.id,
                              createdAt: entry.createdAt,
                            );
                        return SessionTile(
                          key: ValueKey('sessionChatDrawerEntry:${entry.id}'),
                          title: title,
                          subtitle: sessionTileSubtitle(entry.lastUpdatedAt),
                          // The folder basename IS the group header — a
                          // per-tile cwd label would duplicate it.
                          cwd: null,
                          isActive: isActive,
                          // A running fa CLI owns this session: green dot,
                          // tap attaches to it instead of opening it here.
                          live: _presence?.isLive(entry.id) ?? false,
                          onTap: () =>
                              unawaited(_openSessionFromDrawer(entry.id)),
                          onMenu: (anchor) => unawaited(
                            showSessionActionsMenu(
                              context,
                              anchor: anchor,
                              manager: widget.manager,
                              namesStore: _namesStore,
                              sessionId: entry.id,
                              createdAt: entry.createdAt,
                              live: entry.live,
                              persisted: entry.persisted,
                              // Persisted-only deletes don't notify the
                              // manager — resync the drawer's list.
                              onDeleted: () => unawaited(_reloadPersisted()),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Groups drawer entries by their project folder (the session's origin
  /// cwd basename); groups follow the entries' activity order.
  List<({String label, List entries})> _groupDrawerEntries(
    List entries,
    AppLocalizations l10n,
  ) {
    final groups = <String, List<dynamic>>{};
    final order = <String>[];
    for (final entry in entries) {
      final label = sessionFolderGroupLabel(
        entry.cwd as String?,
        l10n.sessionFolderPersonal,
      );
      if (!groups.containsKey(label)) {
        groups[label] = [];
        order.add(label);
      }
      groups[label]!.add(entry);
    }
    return [for (final label in order) (label: label, entries: groups[label]!)];
  }

  /// Opens the shared rename dialog for the active session (Save / Clear /
  /// Cancel), writing through the names store so the header updates live.
  Future<void> _renameActive() async {
    final store = _namesStore;
    final activeId = widget.manager.activeId;
    if (store == null || activeId == null) return;
    // The dialog writes through the store itself (and returns void), so a
    // title change before/after is the "a rename was saved" signal.
    final before = store.titleFor(activeId);
    await showRenameSessionDialog(
      context,
      store: store,
      sessionId: activeId,
      createdAt: _createdAtById[activeId],
    );
    if (store.titleFor(activeId) != before) {
      AppAnalytics.instance.sessionAction('rename');
    }
  }

  /// "Copy session" menu action: the visible transcript as Markdown into the
  /// clipboard (same text the full chat's copy action produces).
  Future<void> _copyActiveSession() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    await Clipboard.setData(ClipboardData(text: service.transcriptMarkdown()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.chatCopiedToClipboard),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildHeader(FahColors colors, AgentService service) {
    final activeId = widget.manager.activeId ?? '';
    final title =
        _namesStore?.titleFor(activeId) ??
        derivedSessionTitle(
          context,
          id: activeId,
          createdAt: _createdAtById[activeId],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Sessions button — opens the drawer over the panel so the
              // user can switch conversations without closing the session.
              IconButton(
                key: const ValueKey('sessionChatPanelSessions'),
                icon: SessionsGlyph(
                  color: colors.dim,
                  background: colors.panelAlt,
                ),
                tooltip: context.l10n.sidebarSessionsHeader,
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(_toggleDrawer()),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('sessionChatMenu'),
                icon: const Icon(Icons.more_vert, size: 20),
                tooltip: context.l10n.launcherChatActionsTooltip,
                color: colors.panelAlt,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'new',
                    child: Text(context.l10n.sidebarNewSessionTooltip),
                  ),
                  // The rename affordance
                  // appears once the titles store is available.
                  if (_namesStore != null)
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(context.l10n.sidebarRenameSessionTooltip),
                    ),
                  PopupMenuItem(
                    value: 'full',
                    child: Text(context.l10n.appsOpenFullChatTooltip),
                  ),
                  PopupMenuItem(
                    value: 'copy',
                    child: Text(context.l10n.chatCopySessionTooltip),
                  ),
                  PopupMenuItem(
                    value: 'close',
                    child: Text(context.l10n.appsCollapseChatTooltip),
                  ),
                ],
                onSelected: (value) {
                  switch (value) {
                    case 'new':
                      unawaited(_newSession());
                    case 'rename':
                      unawaited(_renameActive());
                    case 'full':
                      unawaited(_openFullChat());
                    case 'copy':
                      unawaited(_copyActiveSession());
                    case 'close':
                      unawaited(_closePanel());
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _handle(FahColors colors) {
    return Container(
      key: const ValueKey('sessionChatSheetHandle'),
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: colors.dim.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// One session's transcript inside the panel: the shared [ChatMessageTile]
/// renderer, pinned to the tail on new content.
class _SessionTranscript extends StatefulWidget {
  const _SessionTranscript({
    super.key,
    required this.service,
    this.bottomPadding = 0,
    this.audioControllerFactory,
    this.videoControllerFactory,
  });

  final AgentService service;

  /// Extra bottom clearance lifting the messages above the floating input
  /// bar that overlaps the panel's bottom edge.
  final double bottomPadding;

  final SandboxAudioControllerFactory? audioControllerFactory;
  final SandboxVideoControllerFactory? videoControllerFactory;

  @override
  State<_SessionTranscript> createState() => _SessionTranscriptState();
}

class _SessionTranscriptState extends State<_SessionTranscript>
    with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();

  /// Loads sandbox images referenced from Markdown through the session's
  /// env (memoized — see [SandboxImageResolver]).
  SandboxImageResolver? _sandboxImages;

  SandboxImageResolver get _images {
    final env = widget.service.env;
    final resolver = _sandboxImages;
    if (resolver == null || resolver.env != env) {
      return _sandboxImages = SandboxImageResolver(env);
    }
    return resolver;
  }

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_scrollToEnd);
    // First build (e.g. the panel just opened): land on the LATEST
    // message, not the top of the transcript.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void dispose() {
    widget.service.removeListener(_scrollToEnd);
    _scrollController.dispose();
    super.dispose();
  }

  /// New transcript content keeps the view pinned to the latest message —
  /// with `reverse: true` that is the list's START (min extent), not its end.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.pixels > position.minScrollExtent) {
        position.jumpTo(position.minScrollExtent);
      }
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final messages = widget.service.messages;
        if (messages.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                24 + widget.bottomPadding,
              ),
              child: Text(
                context.l10n.launcherChatEmptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
              ),
            ),
          );
        }
        return ListView.builder(
          controller: _scrollController,
          // reverse: content stays pinned to the BOTTOM (the input bar) — a
          // short transcript no longer flies up and out of view when the
          // keyboard opens and shrinks the viewport.
          reverse: true,
          padding: EdgeInsets.fromLTRB(12, 12, 12, 8 + widget.bottomPadding),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[messages.length - 1 - index];
            return ChatMessageTile(
              message: message,
              images: _images,
              compact: true,
              messageFontSize: ChatTextScope.maybeOf(context)?.fontSize,
              audioControllerFactory: widget.audioControllerFactory,
              videoControllerFactory: widget.videoControllerFactory,
            );
          },
        );
      },
    );
  }
}

/// The sessions-list glyph: a deck of two chat bubbles — a dimmer one
/// behind, the current conversation in front with a speech tail and two
/// text lines. Used wherever a "list of sessions" affordance appears (the
/// input bar's drawer toggle, the panel header). Deliberately NOT a stock
/// list/forum icon.
class SessionsGlyph extends StatelessWidget {
  const SessionsGlyph({
    super.key,
    required this.color,
    required this.background,
    this.size = 22,
  });

  /// The stroke color of the front bubble and text lines.
  final Color color;

  /// The fill of the front bubble — pass the surface the glyph sits on so
  /// the back bubble's edge does not show through.
  final Color background;

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SessionsGlyphPainter(color, background),
    );
  }
}

class _SessionsGlyphPainter extends CustomPainter {
  const _SessionsGlyphPainter(this.color, this.background);

  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 24x24 design grid, scaled to the requested size.
    canvas.save();
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..color = color;
    // The back bubble: dimmer, peeking out top-left.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(1.6, 2.6, 13, 9.4),
        const Radius.circular(3.4),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..color = color.withValues(alpha: 0.5),
    );
    // The front bubble: filled first so it reads as ON TOP of the deck.
    final front = RRect.fromRectAndRadius(
      const Rect.fromLTWH(8.8, 9.4, 13.6, 10.2),
      const Radius.circular(3.6),
    );
    canvas.drawRRect(front, Paint()..color = background);
    canvas.drawRRect(front, stroke);
    // Speech tail, bottom-left of the front bubble.
    canvas.drawPath(
      Path()
        ..moveTo(11.4, 19.4)
        ..lineTo(9.8, 22.6)
        ..lineTo(14.2, 19.4),
      stroke,
    );
    // Two text lines inside the front bubble.
    canvas.drawLine(const Offset(12.2, 13.2), const Offset(19.2, 13.2), stroke);
    canvas.drawLine(const Offset(12.2, 16.2), const Offset(17, 16.2), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SessionsGlyphPainter old) =>
      old.color != color || old.background != background;
}

/// One row of the sessions drawer: a folder-group header or a session
/// tile. The drawer groups sessions by their project folder (the origin
/// cwd basename) — the sessions of one project stay together.
final class _DrawerRow {
  const _DrawerRow.header(String this.label) : entry = null, isHeader = true;

  const _DrawerRow.tile(this.entry) : label = null, isHeader = false;

  final String? label;
  final dynamic entry;
  final bool isHeader;
}
