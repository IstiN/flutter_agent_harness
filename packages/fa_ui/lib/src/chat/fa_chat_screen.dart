// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show ProgressiveBlur, ProgressiveBlurDirection;

import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        ApprovalDecision,
        ApprovalRequest,
        AskAnswer,
        AskQuestion,
        FollowMode,
        MemoryExecutionEnv,
        RequestSecretResult,
        TrajectorySnapshot,
        authExpiredProvider;
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';

import '../theme/app_theme.dart';
import '../theme/fa2_tokens.dart';
import '../theme/fa_ui_theme.dart';
import '../trajectory/trajectory_controller.dart';
import '../trajectory/trajectory_panel.dart';
import '../trajectory/trajectory_view.dart';
import '../trajectory/trajectory_strings.dart';
import '../widgets/fa2_controls.dart';
import '../widgets/fa_icon_action_band.dart';
import '../widgets/fa_icon_action_button.dart' show FaIconActionButton;
import '../widgets/pane_resize_handle.dart';
import '../widgets/snackbars.dart';
import 'approval_ui.dart';
import 'ask_ui.dart';
import 'chat_composer.dart';
import 'chat_message_projection.dart';
import 'chat_message_tile.dart';
import 'chat_strings.dart';
import 'fa_adaptive_header.dart';
import 'fa_chat_features.dart';
import 'fa_chat_host.dart';
import 'fa_chat_service.dart';
import 'fa_duo_control_rail.dart';
import 'fa_duo_layout.dart';
import 'fa_run_status_row.dart';
import 'markdown_style.dart';
import 'media_player.dart';
import 'secret_request_sheet.dart';

part 'fa_chat_screen_header.dart';

/// Minimum body width (logical px) at which the files panel becomes a
/// persistent, collapsible panel instead of an end drawer.
const double kWideLayoutBreakpoint = 900;

/// Width of the files side panel / end drawer.
const double kFaChatFilesPanelWidth = 300;

/// The host's close intent for a host-built files panel (the docked
/// in-chat panel slot): [FaChatScreen] provides it around the panel it
/// builds, and a band chrome ([FilesChrome]-shaped) whose surface has no
/// explicit `onClose` can fall back to it — so the panel's OWN X (left of
/// the search capsule) is the visible close affordance, not just the
/// header's folder toggle. The end drawer builds outside the scope: it
/// closes through its scrim, so its band keeps no X.
class FaFilesPanelScope extends InheritedWidget {
  const FaFilesPanelScope({
    super.key,
    required this.closePanel,
    required super.child,
  });

  /// Closes the files panel the scope wraps (toggling is the header
  /// folder icon's job; this is the panel band's X).
  final VoidCallback closePanel;

  static FaFilesPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FaFilesPanelScope>();

  @override
  bool updateShouldNotify(FaFilesPanelScope oldWidget) =>
      closePanel != oldWidget.closePanel;
}

/// Builds the composer's replacement / customization point; null uses the
/// default [ChatComposer] driven by [FaChatFeatures] and the host hooks.
/// Custom builders receive the surface's [FaChatDropBridge] (issue #465):
/// thread it into [ChatComposer.dropBridge] so OS drops over the chat area
/// stage into the custom composer's chips too.
typedef FaChatComposerBuilder =
    Widget Function(
      BuildContext context,
      FaChatService service,
      FaChatDropBridge drop,
    );

/// A chat UI over a single [FaChatService], built on top of
/// `flutter_chat_ui`.
///
/// Text messages are rendered as Markdown, tool calls/results are shown as
/// distinct cards, and image attachments are supported. Multi-session
/// management is the host's job: hand a different [service] and the screen
/// re-subscribes and re-syncs in place. The optional affordances (files
/// panel, settings gear, composer pickers/voice) come from [features], the
/// constructor overrides, and the [FaChatHost] hooks.
class FaChatScreen extends StatefulWidget {
  const FaChatScreen({
    super.key,
    required this.service,
    this.features = const FaChatFeatures(),
    this.title = 'Fa',
    this.showAppBar = true,
    this.settingsBuilder,
    this.fileBrowserBuilder,
    this.composerBuilder,
    this.mentionOptionsBuilder,
    this.noticeBanner,
    this.inputHeader,
    this.wallpaperBuilder,
    this.avatarBuilder,
    this.onAuthRecovery,
    this.onPermissionAction,
    this.audioControllerFactory,
    this.videoControllerFactory,
    this.dynamicWidgetTileBuilder,
    this.onOpenWidgetAsApp,
    this.imagePreviewCacheWidth = kDefaultImagePreviewCacheWidth,
    this.projectIcon,
    this.projectIconColor,
    this.projectLabel,
    this.onProjectTap,
    this.modelChip,
    this.onModelChipTap,
    this.chipMenuLabel,
  });

  /// The session this screen renders and sends to.
  final FaChatService service;

  /// Decode constraint for attached-image preview thumbnails (both the
  /// memory and the file path). Defaults to
  /// [kDefaultImagePreviewCacheWidth] — a display/memory optimization; the
  /// stored and sent bytes are always full fidelity. Pass `null` to decode
  /// previews at full resolution (issue #207: "High-quality image
  /// previews").
  final int? imagePreviewCacheWidth;

  /// Capability flags; everything optional degrades cleanly when off.
  final FaChatFeatures features;

  /// The app bar title.
  final String title;

  /// Whether the screen renders its own [AppBar] (title, stop/files/copy/
  /// settings actions). Hosts embedding the chat into their own chrome
  /// (e.g. a floating panel with a custom header) pass false; the abort
  /// action then lives on the composer's stop button only.
  final bool showAppBar;

  /// Builder of the settings route pushed by the app bar gear; null hides
  /// the gear.
  final WidgetBuilder? settingsBuilder;

  /// Builder of the files side panel (wide) / end drawer (narrow) content;
  /// overrides [FaChatHost.fileBrowserBuilder]. Null (with no host hook)
  /// hides the files button regardless of [FaChatFeatures.fileBrowser].
  final WidgetBuilder? fileBrowserBuilder;

  /// Replacement composer; null builds the default [ChatComposer] with
  /// [features].
  final FaChatComposerBuilder? composerBuilder;

  /// Optional `@` suggestions in the default shared composer.
  final FaChatMentionOptionsBuilder? mentionOptionsBuilder;

  /// A host notice banner docked above the transcript, under the
  /// auth-expired banner (issue #1889 R5: the aggregated image-drop chip).
  /// The HOST owns the widget's lifecycle and state — this screen only
  /// docks whatever is handed in; null docks nothing.
  final Widget? noticeBanner;

  /// A host widget docked between the transcript and the composer input —
  /// the slot under the bottom-overlay pills, just above the input row.
  /// The messenger's subagent switcher rides it (subagent sessions owner
  /// pass); the HOST owns the widget's lifecycle — null docks nothing.
  final Widget? inputHeader;

  /// Wallpaper layer painted under the transcript (theme packs): when
  /// non-null the chat surface paints transparent so the layer shows
  /// through, and the builder decides what renders (image at the pack's
  /// fit/opacity, color fallback). Null keeps the stock opaque surface.
  final WidgetBuilder? wallpaperBuilder;

  /// Leading-avatar builder for transcript messages (see
  /// [ChatMessageTile.avatarBuilder]); null renders no avatars — the stock
  /// look.
  final FaChatAvatarBuilder? avatarBuilder;

  /// Called when the user taps a permission card action button ("Open
  /// Settings" or "Try again"). The host should open system settings or
  /// retry the permission request.
  final FaPermissionActionCallback? onPermissionAction;

  /// Called when the user taps the "Authorize" button on an auth-expired
  /// card. The host should launch the provider's SSO/re-authorization flow.
  final FaAuthRecoveryCallback? onAuthRecovery;

  /// Playback engine factory for inline audio players; null uses the real
  /// `audioplayers`-backed controller. Tests/goldens inject fakes.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video players; null uses the real
  /// `video_player`-backed controller. Tests/goldens inject fakes.
  final SandboxVideoControllerFactory? videoControllerFactory;

  /// Renders `widget`-role transcript messages as the host's live
  /// dynamic-message tiles (issue #336); null renders the stock system
  /// tile for them.
  final FaDynamicWidgetTileBuilder? dynamicWidgetTileBuilder;

  /// Opens the current turn's live dynamic widget full-screen ephemerally
  /// when the bottom chip is tapped (issue #379 AC3, the #378
  /// open-without-saving contract). Returning false — or leaving null on
  /// surfaces without the ephemeral API — falls back to scroll-to-widget.
  final Future<bool> Function(FaChatMessage message)? onOpenWidgetAsApp;

  /// The project identity in the adaptive header (issue #225): the folder
  /// glyph + label ("Personal" or the folder basename) the host renders
  /// instead of a separate project bar row. Null renders no project slot.
  final IconData? projectIcon;

  /// The project icon color (indigo when the session has a folder).
  final Color? projectIconColor;

  /// The project identity label ("Personal" or the folder basename).
  final String? projectLabel;

  /// Invoked on the project pill's tap (the wide shell's session info).
  final VoidCallback? onProjectTap;

  /// The inline quick-model chip (host-built): a first-class header
  /// citizen that demotes into the ⋮ menu only under extreme width
  /// (issue #225).
  final Widget? modelChip;

  /// Invoked when the demoted model chip is picked from the ⋮ menu
  /// (issue #225 AC3 — model switching at widths that drop the chip).
  final VoidCallback? onModelChipTap;

  /// The ⋮-menu row label for the demoted model chip (the model id).
  final String? chipMenuLabel;

  @override
  State<FaChatScreen> createState() => _FaChatScreenState();
}

class _FaChatScreenState extends State<FaChatScreen>
    with TickerProviderStateMixin {
  late final InMemoryChatController _chatController;

  /// The screen's scaffold, so bar actions can open the files end drawer
  /// without needing a context below the [Scaffold] (the adaptive header
  /// builds its action closures at the screen level).
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// OS drag-and-drop over the chat area (issue #465): one [DropTarget]
  /// wraps the transcript + composer, forwards drops to the composer
  /// through the bridge, and shows the drop highlight while a drag hovers.
  final FaChatDropBridge _dropBridge = FaChatDropBridge();
  bool _dropHovering = false;

  /// Own scroll controller for the message list (injected via
  /// [Builders.chatAnimatedListBuilder]) so the follow-tail logic can track
  /// whether the user is at the bottom and keep up with streaming updates —
  /// the library only auto-scrolls on inserts, not on in-place updates.
  final _chatScrollController = ScrollController();
  bool _userNearBottom = true;

  /// Measured overlay extents keep the first/last message fully reachable
  /// while the reversed transcript paints beneath floating glass chrome.
  final GlobalKey _glassHeaderMeasureKey = GlobalKey();
  final GlobalKey _glassComposerMeasureKey = GlobalKey();
  double _glassHeaderExtent = 64;
  double _glassComposerExtent = 80;

  /// The follow-mode contract (gh-1439): the shared pure state machine
  /// (core `package:flutter_agent_harness`) owns live⇄held plus the
  /// counted-unseen the jump pill shows. Starts `live` at the newest row
  /// — boot/resume never restores held (AC5). Held = the user dragged the
  /// transcript away; programmatic scrolls — the tail follow and the
  /// live-widget clamp's own animateTo — never classify, so the clamp
  /// keeps working after it moves the viewport past the arm band, while a
  /// real user scroll always wins (issue #379 AC2).
  FollowMode _follow = const FollowMode.live();

  /// True once the USER dragged the transcript away (parked beyond the
  /// near-bottom arm band). Derived from the shared follow state so the
  /// #379 clamp and the #1159 banner rejoin read the ONE owner.
  bool get _userScrolledAway => _follow.isHeld;

  /// Loads sandbox images referenced from Markdown / `generate_image` tool
  /// results through the session's env (memoized — see
  /// [SandboxImageResolver]).
  SandboxImageResolver? _sandboxImages;

  /// Shared dummy env for hosts without a sandbox
  /// ([FaChatService.sandboxEnv] is null): every read fails, so sandbox
  /// images/media render their dim placeholders.
  static final MemoryExecutionEnv _noSandboxEnv = MemoryExecutionEnv();

  SandboxImageResolver get _images {
    final env = widget.service.sandboxEnv ?? _noSandboxEnv;
    final resolver = _sandboxImages;
    if (resolver == null || resolver.env != env) {
      return _sandboxImages = SandboxImageResolver(env);
    }
    return resolver;
  }

  final _user = const User(id: 'user', name: 'Me');
  final _assistant = const User(id: 'assistant', name: 'Fa');
  final _tool = const User(id: 'tool', name: 'tool');
  final _system = const User(id: 'system', name: 'system');

  List<Message> _lastSynced = [];

  /// Transcript row keys by message id (`msg-<index>`): jump-to-message
  /// targets (see [_scrollToMessage]); pruned on every sync.
  final Map<String, GlobalKey> _itemKeys = {};

  /// Issue #379 live-widget state, keyed by the widget id
  /// ([FaChatMessage.data] — stable across history-window index shifts,
  /// E4): chips the user dismissed with ×, widgets the user touched, and
  /// widgets whose scroll clamp was released (chip tap, turn end + the
  /// user scrolled away). A widget id entering the current turn afresh
  /// re-arms (E3) — see the sync in [_syncMessages].
  final Set<String> _dismissedWidgetChips = {};
  final Set<String> _interactedWidgets = {};
  final Set<String> _releasedClamps = {};

  /// The widget ids seen in the current turn: the baseline for the
  /// re-arm rule above.
  Set<String> _turnWidgetIds = {};

  /// The widget id the chip targeted at the last sync: the rebuild
  /// trigger for the chip's shell-level (non-list) rendering.
  String? _lastChipTargetId;

  /// Wraps a transcript row in its jump anchor.
  Widget _keyed(String id, Widget child) =>
      KeyedSubtree(key: _keyFor(id), child: child);

  GlobalKey _keyFor(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  /// True while the FIRST history sync is in flight: history inserts are
  /// rendered with a zero animation duration (a cascade of insert
  /// animations on a long transcript looks like glitchy bottom-up
  /// painting). Streaming/live inserts afterwards keep their animation.
  bool _suppressInsertAnimations = true;
  Timer? _syncDebounce;
  bool _isSyncing = false;

  /// Whether a USER gesture (drag or its momentum coast) is in flight —
  /// the non-drag relatch below may only act on those (gh-1439 E6,
  /// re-review). Content-driven repositions arrive as non-drag updates
  /// too: a big-diff setMessages re-anchor settles wherever the new
  /// layout anchors it (probe: a 25-row prepend glided a held window to
  /// 60px ≤ arm 80), and without this gate that settle wiped 3 counted
  /// arrivals by "relatching". The sync invalidates the gate; a real
  /// drag re-arms it; the ballistic end closes it.
  bool _userGestureInFlight = false;

  /// A wheel/trackpad tick arrived on the transcript (raw
  /// [PointerScrollEvent], gh-1439 re-review): the next depth-0 scroll
  /// update IS that user gesture — classify it like a drag. Wheel
  /// updates reach the classifier with dragDetails == null and could
  /// otherwise never hold (the #379 clamp kept yanking wheel users,
  /// exactly on the surfaces the ticket's capability table promises).
  /// Consumed by the first classified update; invalidated by content
  /// syncs.
  bool _wheelGesturePending = false;
  bool _isStreaming = false;
  String? _error;

  /// Mirrors [FaChatService.historyAboveCount] so a change (a count
  /// landing, a page loading) drives a rebuild.
  int? _historyAbove;

  /// Mirrors [FaChatService.historyLoadError] for the retry banner.
  String? _historyLoadError;

  /// Mirrors the in-flight page flag (spinner state, issue #135 E6) and
  /// the below-count driving the "Load newer" banner.
  bool _historyLoading = false;
  bool _historyHasNewer = false;
  int? _historyBelow;
  int? _historyTotal;

  /// Reveal-on-top gate (issue #974): the "Load earlier" sticker is a
  /// top-of-transcript affordance, so it renders only while the viewport
  /// sits at (or near) the oldest edge. Starts hidden: nothing renders
  /// until a measurement establishes where the viewport actually sits
  /// (kills the one-frame banner flash on windowed opens).
  bool _topBannerRevealed = false;

  /// How close to the oldest edge (px) the viewport must park for the
  /// top banner to reveal.
  static const double _topRevealSlack = 64;

  /// Start paging before the oldest edge is reached, so the next chunk is
  /// already arriving by the time the user sees the end of the window.
  static const double _historyPrefetchSlack = 320;

  /// One automatic page per approach to the older edge. Leaving the
  /// prefetch band rearms it; scroll notifications and layout settles in
  /// one gesture therefore cannot issue duplicate reads.
  bool _olderEdgeAutoLoadArmed = true;

  /// The live reveal computation: a REVERSED list keeps the oldest edge
  /// at maxScrollExtent, so "parked at the top" is pixels within the
  /// slack of it. A transcript that fits the viewport (or has no list at
  /// all yet) has no scroll range and always reveals; a client that
  /// attached but has not been laid out counts as measured-elsewhere
  /// (its extents are unreadable) and reveals for the same reason.
  bool get _revealedNow {
    if (!_chatScrollController.hasClients) return true;
    final position = _chatScrollController.position;
    // maxScrollExtent throws before applyContentDimensions runs — treat
    // the unmeasured client as trivially at top.
    if (!position.hasContentDimensions) return true;
    return position.pixels >= position.maxScrollExtent - _topRevealSlack;
  }

  /// Rebuilds when the reveal gate flips. Wired to the transcript's
  /// scroll position (drags, programmatic jumps) and — through the
  /// [ScrollMetricsNotification] listener in [build] — to layout-time
  /// extent changes (first attach, paged-in pages), which never produce
  /// a position change to listen to.
  void _updateTopReveal() {
    final revealed = _revealedNow;
    if (revealed != _topBannerRevealed && mounted) {
      setState(() => _topBannerRevealed = revealed);
    }
  }

  /// Whether the file browser side panel is expanded (wide layouts only).
  bool _filesPanelOpen = false;

  /// Drives the docked panel's entrance/exit — the SAME 200ms
  /// easeInOutCubic slide+fade the shell's sidebar collapse uses (user
  /// call: the Files view must not pop in and vanish on close while the
  /// sidebar glides). Content fields swap instantly; this controller
  /// animates the pane's geometry in BOTH directions. Width drags are
  /// NOT animated: [AnimationController.value] only drives the
  /// open/close reveal, never the panel width.
  late final AnimationController _filesPanelReveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  )..addStatusListener(_onFilesPanelRevealStatus);

  /// One rebuild at the exit's end: the last mounted frame leaves the
  /// screen (and the header's Files entry returns).
  void _onFilesPanelRevealStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  /// Whether the docked panel's content is on screen at all — opening,
  /// settled open, or mid-exit. Presence (not the target flag) mounts
  /// the slot so the exit animates out instead of vanishing.
  bool get _filesPanelMounted =>
      _filesPanelOpen ||
      _filesPanelReveal.status == AnimationStatus.forward ||
      (_filesPanelReveal.status == AnimationStatus.reverse &&
          _filesPanelReveal.value > 0);

  /// The curved reveal for the current tick (the sidebar's curve).
  double get _filesPanelRevealValue =>
      Curves.easeInOutCubic.transform(_filesPanelReveal.value);

  /// Screen-local desired inspector width. The live width is clamped to the
  /// viewport during layout; closing the panel never discards this value.
  double _filesPanelWidth = kFaChatFilesPanelWidth;
  static const double _minFilesPanelWidth = 240;
  static const double _maxFilesPanelWidth = 520;
  static const double _minChatBodyWidth = 320;

  double _liveFilesPanelWidth(double viewportWidth) =>
      _clampFilesPanelWidth(_filesPanelWidth, viewportWidth);

  double _clampFilesPanelWidth(double width, double viewportWidth) {
    final viewportMax = viewportWidth - _minChatBodyWidth - 1;
    // Below the usable panel + center threshold the inspector is hidden for
    // this layout, not allowed to over-constrain the floating header Stack.
    if (viewportMax < _minFilesPanelWidth) return 0;
    final upper = viewportMax.clamp(_minFilesPanelWidth, _maxFilesPanelWidth);
    return width.clamp(_minFilesPanelWidth, upper).toDouble();
  }

  /// Screen-level trajectory state (AC2/E6): one controller per service,
  /// alive for the screen's lifetime so switching Chat<->Trajectory and
  /// resizing wide<->narrow never lose scroll, selection, or filters.
  TrajectoryController? _trajectoryController;
  StreamSubscription<TrajectorySnapshot>? _trajectorySubscription;

  /// The pushed wide-trajectory route, tracked so the controller it
  /// renders is only disposed after the route has fully popped.
  Route<void>? _trajectoryRoute;

  bool _trajectoryLoaded = false;

  /// Whether the narrow layout currently shows the trajectory page.
  bool _showTrajectory = false;

  /// The screen-level trajectory controller, created (and subscribed to the
  /// service's snapshot stream) on first use.
  TrajectoryController get _trajectory {
    if (_trajectoryController == null) {
      final controller = TrajectoryController();
      controller.resolveHiddenRecords = widget.service.resolveHiddenRecords;
      _trajectoryController = controller;
      _trajectorySubscription = widget.service.trajectory.listen(
        _onTrajectorySnapshot,
      );
    }
    return _trajectoryController!;
  }

  void _onTrajectorySnapshot(TrajectorySnapshot snapshot) {
    _trajectoryController?.updateSnapshot(snapshot);
    if (_trajectoryLoaded) return;
    _trajectoryLoaded = true;
    if (mounted) setState(() {});
  }

  void _unbindTrajectory() {
    _trajectorySubscription?.cancel();
    _trajectorySubscription = null;
    final controller = _trajectoryController;
    final route = _trajectoryRoute;
    _trajectoryRoute = null;
    _trajectoryController = null;
    _trajectoryLoaded = false;
    if (controller == null) return;
    if (!mounted) {
      // Screen teardown: children have unmounted; dispose directly.
      controller.dispose();
      return;
    }
    if (route != null && route.isActive) {
      // A pushed wide-trajectory route still renders the old session:
      // close it outside the build phase, and dispose its controller
      // only once the pop has fully completed so it never listens to a
      // disposed ChangeNotifier.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive && route.isCurrent) route.navigator?.pop();
      });
      route.popped.whenComplete(controller.dispose);
    } else {
      // Post-frame: the in-flight build may still unmount a narrow
      // trajectory page bound to this controller.
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  /// Wide entry: pushes the full-screen master-detail route (AC1).
  void _openTrajectoryRoute() {
    final route = MaterialPageRoute<void>(
      builder: (_) => TrajectoryScreen(
        controller: _trajectory,
        loaded: _trajectoryLoaded,
        scope: TrajectoryProjectionScope(
          above: widget.service.historyAboveCount,
          below: widget.service.historyBelowCount,
          total: widget.service.historyTotalCount,
        ),
        onRecordActivate: (record) =>
            widget.service.jumpToMessage(record.recordId),
        onClose: () => Navigator.pop(context),
      ),
    );
    _trajectoryRoute = route;
    Navigator.push(context, route).whenComplete(() {
      if (_trajectoryRoute == route) _trajectoryRoute = null;
    });
  }

  /// The files panel content builder: the constructor override, else the
  /// host hook.
  WidgetBuilder? get _fileBrowserBuilder =>
      widget.fileBrowserBuilder ?? FaChatHost.fileBrowserBuilder;

  /// Opens the file browser: toggles the right side panel on wide layouts,
  /// opens the end drawer on narrow ones. The docked panel reveals through
  /// the sidebar's slide (never an instant pop).
  void _openFiles() {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      setState(() => _filesPanelOpen = !_filesPanelOpen);
      _filesPanelOpen
          ? _filesPanelReveal.forward()
          : _filesPanelReveal.reverse();
      // The shell gives the docked panel the same presentation run as a
      // presented app (chats list collapse + restore); notify on every
      // transition, not only opens.
      FaChatHost.onFilesPanelChanged?.call(_filesPanelOpen);
      if (_filesPanelOpen) {
        FaChatHost.track('files_opened', {'source': 'chat'});
      }
    } else {
      FaChatHost.track('files_opened', {'source': 'chat'});
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  /// The docked panel band's own X (the visible close affordance —
  /// [FaFilesPanelScope]); the header folder icon only toggles. The
  /// panel slides OUT through the same reveal — no instant vanish.
  void _closeFilesPanel() {
    if (_filesPanelOpen) {
      setState(() => _filesPanelOpen = false);
      _filesPanelReveal.reverse();
      FaChatHost.onFilesPanelChanged?.call(false);
    }
  }

  @override
  void initState() {
    super.initState();
    FaChatHost.track('screen_opened', {'screen_name': 'chat'});
    _chatController = InMemoryChatController();
    _chatScrollController.addListener(_trackNearBottom);
    _chatScrollController.addListener(_updateTopReveal);
    _subscribeToService(widget.service);
    if (widget.features.trajectory) _trajectory;
    _mirrorServiceState();
    _syncMessages();
    // SizeChangedLayoutNotifier does not guarantee an initial notification.
    // Measure the real floating header (including the trajectory row) and
    // composer after their first layout so overlays never start beneath them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateGlassChromeExtents();
    });
  }

  @override
  void didUpdateWidget(covariant FaChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      // The host swapped sessions (close/switch): re-subscribe and re-sync.
      _unsubscribeFromService(oldWidget.service);
      _subscribeToService(widget.service);
      // A new session is a new viewport: follow starts live at its newest
      // record — held never persists across a restart (gh-1439 AC5).
      _follow = const FollowMode.live();
      _userNearBottom = true;
      _olderEdgeAutoLoadArmed = true;
      _unbindTrajectory();
      if (widget.features.trajectory) _trajectory;
      _mirrorServiceState();
      _syncMessages();
      setState(() {});
    }
  }

  /// The follow-tail latch (YoLoIT's pattern): scrolling up unlatches,
  /// scrolling back to the bottom relatches. Streaming then keeps the tail
  /// pinned only while the user is at the bottom. REVERSED list: offset 0
  /// IS the bottom, so "near bottom" = small offset.
  void _trackNearBottom() {
    if (!_chatScrollController.hasClients) return;
    final position = _chatScrollController.position;
    _userNearBottom = position.pixels < _armExtent(position);
  }

  /// The near-bottom re-arm band for this viewport (gh-1439 open question
  /// 1): the shared ~10%-of-viewport fraction, one rule on every surface.
  int _armExtent(ScrollPosition position) =>
      FollowMode.nearBottomArmExtent(position.viewportDimension.round());

  /// Whether this notification reaches the follow classifier at all:
  /// depth 0 only (inner tool-output scrollables don't count) and only
  /// position-carrying activity (updates and ends).
  bool _isTrackableScroll(ScrollNotification notification) =>
      notification.depth == 0 &&
      (notification is ScrollUpdateNotification ||
          notification is ScrollEndNotification);

  /// Classifies scroll activity on the transcript's own scrollable
  /// through the shared [FollowMode] machine (gh-1439): a user drag
  /// parking beyond the near-bottom arm band holds (no more yank);
  /// landing inside the band re-arms live and flushes the count. E6
  /// debounce: only the USER's position classifies — programmatic moves
  /// (the tail follow and the #379 clamp's own animateTo) never hold and
  /// never re-arm; non-drag updates can only relatch at the near-bottom.
  void _trackUserScroll(ScrollNotification notification) {
    if (!_isTrackableScroll(notification)) return;
    if (!_chatScrollController.hasClients) return;
    final wasAway = _follow.isHeld;
    _classifyScroll(notification);
    if (wasAway && !_follow.isHeld) {
      // Landing back at the bottom with a deep-paged window rejoins the
      // live tail on its own — no stuck banner post-run (issue #1159
      // AC4).
      _followTailIfPinned();
    }
    _maybeLoadOlderHistory();
  }

  /// Infinite-scroll companion to the manual history banner. Only real
  /// transcript scroll activity calls this: opening a short tail or a
  /// layout settle never starts reading the session by itself.
  void _maybeLoadOlderHistory() {
    if (!_chatScrollController.hasClients) return;
    final position = _chatScrollController.position;
    if (!position.hasContentDimensions) return;
    final nearOlderEdge =
        position.pixels >= position.maxScrollExtent - _historyPrefetchSlack;
    if (!nearOlderEdge) {
      _olderEdgeAutoLoadArmed = true;
      return;
    }
    if (!_olderEdgeAutoLoadArmed ||
        _historyLoading ||
        _historyLoadError != null ||
        (_historyAbove != null && _historyAbove! <= 0) ||
        (_lastSynced.isEmpty && (_historyAbove ?? 0) <= 0)) {
      return;
    }
    _olderEdgeAutoLoadArmed = false;
    unawaited(widget.service.loadOlderHistory());
  }

  /// One trackable scroll update: measures the landing position, applies
  /// the user-gesture or momentum-coast rule, then settles the gesture
  /// gate on the ballistic end.
  void _classifyScroll(ScrollNotification notification) {
    final position = _chatScrollController.position;
    final distance = position.pixels.round();
    final arm = _armExtent(position);
    if (notification is ScrollUpdateNotification &&
        (notification.dragDetails != null || _wheelGesturePending)) {
      _applyUserGesture(notification, distance, arm);
    } else {
      _relatchMomentumCoast(distance, arm);
    }
    if (notification is ScrollEndNotification) {
      // The finger lifted → a coast may follow (the gate stays up); the
      // ballistic end → the gesture is over.
      _userGestureInFlight = notification.dragDetails != null;
    }
  }

  /// USER gesture: the landing position classifies — inside the band
  /// re-arms live (flushed), beyond it holds.
  void _applyUserGesture(
    ScrollUpdateNotification notification,
    int distance,
    int arm,
  ) {
    _userGestureInFlight = notification.dragDetails != null;
    _wheelGesturePending = false;
    final next = _follow.userScrolled(
      distanceFromLiveEdge: distance,
      armExtent: arm,
    );
    if (next != _follow && mounted) {
      setState(() => _follow = next);
    }
  }

  /// Whether a non-drag update may relatch the held follow at the
  /// near-bottom (E6 debounce): only a momentum coast of a real user
  /// gesture.
  bool _coastMayRelatch(int distance, int arm) =>
      _userGestureInFlight && distance <= arm && _follow.isHeld && mounted;

  /// Momentum-coast updates only ever RELATCH at the near-bottom — they
  /// never classify away (the #379 follow clamp's own animateTo must keep
  /// working, E6 debounce). Content-driven repositions (a big-diff
  /// re-anchor) arrive as non-drag updates too; for those the gate is
  /// false — the sync invalidated it.
  void _relatchMomentumCoast(int distance, int arm) {
    if (!_coastMayRelatch(distance, arm)) return;
    setState(() => _follow = _follow.jumpToLive());
    _userGestureInFlight = false;
  }

  /// The one-action re-engage (gh-1439): live again, count flushed, and
  /// the window lands at the newest row — a deep-paged window pages the
  /// tail in first (E4: jumping to live lands the newest window, never
  /// the whole backlog).
  Future<void> _jumpToLive() async {
    if (mounted) setState(() => _follow = _follow.jumpToLive());
    _userNearBottom = true;
    if (_historyHasNewer && !_historyLoading) {
      await widget.service.loadNewerHistory();
    }
    if (!mounted) return;
    if (_chatScrollController.hasClients) {
      _chatScrollController.jumpTo(0);
    }
  }

  /// User-at-bottom follow (issue #1159 AC2/AC4): a deep-paged window
  /// never strands a "Load newer" banner under a user parked at the
  /// bottom — the view rejoins the live tail on its own, mid-run
  /// included. A deliberately scrolled-away user is never auto-paged.
  void _followTailIfPinned() {
    if (!_historyHasNewer || _userScrolledAway || _historyLoading) return;
    widget.service.loadNewerHistory();
  }

  /// Pins the chat to the tail after a sync when the user hasn't scrolled
  /// away. The REVERSED list already sits at the bottom (offset 0) and new
  /// rows grow upwards without shifting the viewport — this is only needed
  /// when the user scrolled up a little during streaming. The live-widget
  /// clamp (issue #379) runs on the scrolled-away latch alone: its own
  /// scrolling carries the viewport past the near-bottom threshold by
  /// design, and that must not disarm it — only a real user drag does.
  void _scrollToTailIfFollowing() {
    if (_userScrolledAway) return;
    final clampActive =
        _clampTarget() != null &&
        MediaQuery.sizeOf(context).width < kWideLayoutBreakpoint;
    if (!clampActive && !_userNearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The screen may be gone by the time the frame lands (mode switch,
      // page swap) — a defunct State has no usable context.
      if (!mounted) return;
      // Issue #379: while the current turn holds a live (un-interacted)
      // widget, the follow clamps to keep the widget's leading edge
      // inside the viewport instead of pinning the tail. Manual scroll
      // still wins — this only runs while following (AC2).
      final target = _liveWidgetClampOffset() ?? 0.0;
      if ((target - _chatScrollController.offset).abs() >= 1) {
        _chatScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 150),
          curve: Curves.linearToEaseOut,
        );
      }
      // The animated list mounts the freshly inserted row one frame
      // later, so this frame's geometry (and the target above) lags one
      // chunk behind. Re-measure even when the first target was already 0;
      // otherwise that unchanged target skipped the only correction pass.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_chatScrollController.hasClients) return;
        if (_userScrolledAway) return;
        final corrected = _liveWidgetClampOffset();
        if (corrected == null) return;
        if ((corrected - _chatScrollController.offset).abs() < 1) return;
        _chatScrollController.animateTo(
          corrected,
          duration: const Duration(milliseconds: 100),
          curve: Curves.linearToEaseOut,
        );
      });
    });
  }

  /// Brings the transcript row [messageId] into view (jump-to-message).
  /// Exact via the row's key when it is built; otherwise the reversed
  /// list is positioned by index fraction first — the jump lands within
  /// the sliver's build extent, the row mounts, and the next pass is
  /// exact. A target ABOVE the loaded window is paged in first through
  /// [FaChatService.jumpToMessage] (issue #135 AC6) — the jump never
  /// silently gives up on out-of-window targets anymore.
  Future<void> _scrollToMessage(String messageId) async {
    final index = int.tryParse(messageId.replaceFirst('msg-', ''));
    if (index != null && index >= _lastSynced.length) {
      await widget.service.jumpToMessage(messageId);
    }
    for (var pass = 0; pass < 4; pass++) {
      final target = _itemKeys[messageId]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 250),
          alignment: 0.35,
        );
        return;
      }
      if (!_chatScrollController.hasClients) return;
      final total = _lastSynced.length;
      if (index == null || index < 0 || index >= total || total < 2) return;
      final fraction = (total - 1 - index) / (total - 1);
      _chatScrollController.jumpTo(
        fraction * _chatScrollController.position.maxScrollExtent,
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  // ---- Live dynamic-widget affordances (issue #379) --------------------

  /// The current turn: the messages after the last user-authored message
  /// in the synced window. Returns its `widget`-role entries as
  /// `(widgetId, rowId)`, newest first (E1 documents that order).
  List<(String, String)> _turnWidgets() {
    var lastUser = -1;
    for (var i = 0; i < _lastSynced.length; i++) {
      if (_lastSynced[i].authorId == 'user') lastUser = i;
    }
    final widgets = <(String, String)>[];
    for (var i = _lastSynced.length - 1; i > lastUser; i--) {
      final message = _lastSynced[i];
      if (message is! CustomMessage) continue;
      final metadata = message.metadata ?? const {};
      if (metadata['role'] != 'widget') continue;
      widgets.add(((metadata['data'] ?? message.id).toString(), message.id));
    }
    return widgets;
  }

  /// Newest current-turn widget the chip still shows (AC3): not touched,
  /// not dismissed. E1: newest-first targeting.
  (String, String)? _chipTarget() {
    for (final entry in _turnWidgets()) {
      if (!_interactedWidgets.contains(entry.$1) &&
          !_dismissedWidgetChips.contains(entry.$1)) {
        return entry;
      }
    }
    return null;
  }

  /// [_chipTarget] minus clamp-released ids (chip tap, turn end + the
  /// user scrolled away): the chip outlives the clamp (GOAL §2).
  (String, String)? _clampTarget() {
    for (final entry in _turnWidgets()) {
      if (!_interactedWidgets.contains(entry.$1) &&
          !_dismissedWidgetChips.contains(entry.$1) &&
          !_releasedClamps.contains(entry.$1)) {
        return entry;
      }
    }
    return null;
  }

  /// The clamped follow target for a live widget, or null (follow the
  /// tail exactly as before): the scroll offset that keeps the widget's
  /// leading (top) edge inside the viewport — never fully past it (E2: a
  /// widget taller than the viewport keeps its top visible). Narrow
  /// viewports only (AC4); render-object offsets only (E4): history
  /// insertion above can never skew the math.
  double? _liveWidgetClampOffset() {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      return null;
    }
    final target = _clampTarget();
    if (target == null) return null;
    final rowContext = _itemKeys[target.$2]?.currentContext;
    final row = rowContext?.findRenderObject();
    if (row is! RenderBox || !row.attached) return null;
    final position = _chatScrollController.position;
    final rowTop = row.localToGlobal(Offset.zero).dy;
    // ChatAnimatedList already reserves the 16px visual margin in topPadding;
    // adding it to this correction as well pushes the tile below the clamp
    // window after each animated insertion settles.
    final visibleTop = widget.showAppBar ? _glassHeaderExtent : 16.0;
    // This is a reversed transcript: increasing the offset moves an existing
    // row down. Use real render geometry rather than getOffsetToReveal's
    // physical viewport edge, which allowed the row beneath the header and
    // returned null until it had already disappeared above y=0.
    final scrollTarget = position.pixels + visibleTop - rowTop;
    if (scrollTarget <= 0) return null; // fully visible at the tail already
    return scrollTarget.clamp(0.0, position.maxScrollExtent).toDouble();
  }

  /// A touch anywhere on a live widget row is an interaction (AC3): the
  /// chip auto-hides and the clamp releases for that widget (E1: the
  /// targeting then falls back to an older live one).
  void _markWidgetInteracted(String widgetId) {
    if (_interactedWidgets.contains(widgetId)) return;
    setState(() => _interactedWidgets.add(widgetId));
  }

  /// The pinned bottom chip (GOAL §2): «✦ Open widget as app» while the
  /// newest current-turn widget is live and un-interacted; hidden on
  /// wide viewports (AC4). Tap opens it ephemerally through the host,
  /// falling back to scroll-to-widget when the surface has no ephemeral
  /// API.
  Widget? _buildWidgetOpenChip(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      return null;
    }
    final target = _chipTarget();
    if (target == null) return null;
    final strings = FaChatStrings.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Material(
          key: const Key('fa-widget-open-chip'),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openChipTarget(target),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    strings.chatOpenWidgetAsApp,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    key: const Key('fa-widget-open-chip-dismiss'),
                    tooltip: strings.chatOpenWidgetAsAppDismiss,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        setState(() => _dismissedWidgetChips.add(target.$1)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Chip tap (AC3): opens ephemerally through the host when available,
  /// otherwise scrolls the widget row back into view; either way the
  /// clamp releases for that widget (GOAL §1).
  Future<void> _openChipTarget((String, String) target) async {
    final opener = widget.onOpenWidgetAsApp;
    var opened = false;
    if (opener != null) {
      for (final message in _lastSynced) {
        if (message.id != target.$2) continue;
        opened = await opener(_faMessageFromMetadata(message));
        break;
      }
    }
    if (!mounted) return;
    setState(() => _releasedClamps.add(target.$1));
    if (!opened) await _scrollToMessage(target.$2);
  }

  /// Rebuilds the host-facing [FaChatMessage] of a synced custom message
  /// (the same fields [_buildCustomMessage] renders from).
  FaChatMessage _faMessageFromMetadata(Message message) {
    final metadata = message.metadata ?? const {};
    return FaChatMessage(
      role: (metadata['role'] as String?) ?? 'system',
      content: (metadata['content'] as String?) ?? '',
      toolName: metadata['toolName'] as String?,
      isError: (metadata['isError'] as bool?) ?? false,
      data: metadata['data'],
    );
  }

  void _subscribeToService(FaChatService service) {
    service.addListener(_onServiceChanged);
    service.scrollToMessageHandler = _scrollToMessage;
    // This screen renders approval prompts as Material dialogs; clearing the
    // handler on dispose restores the deny-by-default for headless runs.
    if (widget.features.approvals) {
      service.approvalPromptHandler = _handleApprovalPrompt;
    }
    // Same pattern for the ask tool: this screen renders the questions as a
    // modal bottom sheet; without a handler, ask calls resolve as cancelled.
    if (widget.features.askSheets) {
      service.askHandler = _handleAskQuestions;
    }
    // And for the request_secret tool: this screen renders the credential
    // prompt as a modal bottom sheet; without a handler, requests resolve as
    // declined. The service persists and activates a granted key itself.
    if (widget.features.secretRequests) {
      service.secretRequestHandler = _handleSecretRequest;
    }
    // Password asks (issue #367): masked sheet above the composer; the
    // value streams to the live process stdin, never into the composer.
    service.passwordPromptHandler = _handlePasswordPrompt;
  }

  void _unsubscribeFromService(FaChatService service) {
    service.removeListener(_onServiceChanged);
    if (service.scrollToMessageHandler == _scrollToMessage) {
      service.scrollToMessageHandler = null;
    }
    if (service.approvalPromptHandler == _handleApprovalPrompt) {
      service.approvalPromptHandler = null;
    }
    if (service.askHandler == _handleAskQuestions) {
      service.askHandler = null;
    }
    if (service.secretRequestHandler == _handleSecretRequest) {
      service.secretRequestHandler = null;
    }
    if (service.passwordPromptHandler == _handlePasswordPrompt) {
      service.passwordPromptHandler = null;
    }
  }

  Future<ApprovalDecision> _handleApprovalPrompt(ApprovalRequest request) {
    if (!mounted) return Future.value(ApprovalDecision.deny);
    return showApprovalPrompt(context, request, modeController: widget.service);
  }

  Future<List<AskAnswer>?> _handleAskQuestions(List<AskQuestion> questions) {
    if (!mounted) return Future.value(null);
    return showAskSheet(context, questions);
  }

  Future<RequestSecretResult?> _handleSecretRequest(
    String name,
    String reason,
  ) {
    if (!mounted) return Future.value(null);
    return showSecretRequestSheet(context, name, reason);
  }

  Future<String?> _handlePasswordPrompt(String prompt) {
    if (!mounted) return Future.value(null);
    return showPasswordPromptSheet(context, prompt);
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    // Going away with the panel open still ends its presentation run.
    if (_filesPanelOpen) FaChatHost.onFilesPanelChanged?.call(false);
    _chatScrollController.dispose();
    _unbindTrajectory();
    _unsubscribeFromService(widget.service);
    _chatController.dispose();
    _filesPanelReveal.dispose();
    super.dispose();
  }

  /// Re-syncs the transcript soon: the 50ms debounce coalesces a burst of
  /// service notifications (and a sync racing a new notification) into
  /// one sync pass.
  void _scheduleDeferredSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _syncMessages();
    });
  }

  /// Whether a mirrored service field moved (the rebuild trigger): one
  /// structural compare of the whole mirror row.
  bool _serviceStateMoved() {
    final s = widget.service;
    return (
          s.isStreaming,
          s.error,
          s.historyAboveCount,
          s.historyLoadError,
          s.historyLoading,
          s.historyHasNewer,
          s.historyBelowCount,
          s.historyTotalCount,
        ) !=
        (
          _isStreaming,
          _error,
          _historyAbove,
          _historyLoadError,
          _historyLoading,
          _historyHasNewer,
          _historyBelow,
          _historyTotal,
        );
  }

  /// Mirrors the service's user-facing state into the screen fields that
  /// drive the build (streaming flag, error, history paging state).
  void _mirrorServiceState() {
    final s = widget.service;
    _isStreaming = s.isStreaming;
    _error = s.error;
    _historyAbove = s.historyAboveCount;
    _historyLoadError = s.historyLoadError;
    _historyLoading = s.historyLoading;
    _historyHasNewer = s.historyHasNewer;
    _historyBelow = s.historyBelowCount;
    _historyTotal = s.historyTotalCount;
  }

  /// Issue #379: the turn ended while the user had scrolled away —
  /// release the clamp for the current target; returning to the tail
  /// later must not re-clamp it (GOAL §1).
  void _releaseClampOnStreamEnd(bool wasStreaming) {
    if (!wasStreaming || _isStreaming || !_userScrolledAway) return;
    _releaseCurrentClamp();
  }

  void _releaseCurrentClamp() {
    final target = _clampTarget();
    if (target != null) _releasedClamps.add(target.$1);
  }

  void _onServiceChanged() {
    _scheduleDeferredSync();
    if (!_serviceStateMoved()) return;
    final wasStreaming = _isStreaming;
    _mirrorServiceState();
    _releaseClampOnStreamEnd(wasStreaming);
    if (mounted) setState(() {});
    // A "newer" state arriving while the user is parked at the bottom
    // is followed immediately — the tail rejoin clears it (issue #1159
    // AC2).
    _followTailIfPinned();
  }

  Future<void> _syncMessages() async {
    if (_isSyncing) {
      _scheduleDeferredSync();
      return;
    }
    _isSyncing = true;

    try {
      final newList = projectFaChatMessages(widget.service.messages);
      // The top banner's empty-session escape (issue #223) reads the
      // synced window; an emptiness flip must repaint it even when no
      // service field changed (the initial history sync notifies nobody).
      final emptinessFlipped = _lastSynced.isEmpty != newList.isEmpty;
      final followCounted = await _applyDiff(newList);
      _finishSync(newList, followCounted, emptinessFlipped);
    } on Object catch (e, stack) {
      // _syncMessages runs from a Timer callback: an escape here is an
      // unhandled async error that repeats on every service notification
      // (the "Uncaught Error" console storm). Log it and leave
      // _lastSynced stale so the next notification retries the sync.
      debugPrint('chat sync failed: $e\n$stack');
    } finally {
      _isSyncing = false;
      _remeasureRevealPostFrame();
    }
  }

  /// Applies one transcript diff to the chat controller. Returns whether
  /// a held follow counted arrivals (the pill's rebuild trigger).
  Future<bool> _applyDiff(List<Message> newList) async {
    if (_lastSynced.isEmpty || newList.isEmpty) {
      // History load: instant, no set animation (messages are read from
      // disk; they must appear as one frame, not slide in).
      await _chatController.setMessages(newList, animated: false);
      return false;
    }
    final commonPrefix = _commonIdPrefix(newList);
    final followCounted = _countHeldArrivals(newList);
    final oldLen = _lastSynced.length;
    final changes =
        (commonPrefix - math.min(oldLen, commonPrefix)) +
        (oldLen - commonPrefix) +
        (newList.length - commonPrefix);
    // A big diff (a session switch, an external-history load) syncs in
    // ONE setMessages pass: per-message inserts rebuild the list per
    // row and stream in bottom-up, visibly slow on long transcripts.
    if (changes > 12) {
      await _replaceWholeList(newList);
    } else {
      await _applyIncrementalDiff(newList, commonPrefix);
    }
    return followCounted;
  }

  /// The id-based common prefix between the synced and the new list:
  /// in-place edits inside it must updateMessage, not remove+insert.
  int _commonIdPrefix(List<Message> newList) {
    final minLen = math.min(_lastSynced.length, newList.length);
    var commonPrefix = 0;
    while (commonPrefix < minLen &&
        _lastSynced[commonPrefix].id == newList[commonPrefix].id) {
      commonPrefix++;
    }
    return commonPrefix;
  }

  /// gh-1439: held appends are COUNTED (the model keeps everything —
  /// zero loss, AC4); the pill's counter is the affordance. Live
  /// appends never count (the viewport shows them — today's
  /// behavior). Counted for BOTH render paths (big-diff setMessages
  /// and the per-row insert loop alike).
  /// (re-review) Only pure tail growth is an arrival — and the prefix for
  /// COUNTING must be content-aware: ids are index-based
  /// (`msg-$index`), so a "Load earlier" PREPEND shifts every row's
  /// content while REUSING every id; the id-based `commonPrefix`
  /// stays == oldLen and `newLen - commonPrefix` billed the loaded
  /// page as arrivals. A length-preserving content edit must not
  /// count either. The render diff keeps the id-based prefix; only
  /// the count scans content.
  bool _countHeldArrivals(List<Message> newList) {
    final oldLen = _lastSynced.length;
    final isTailAppend =
        _countedContentPrefix(newList) == oldLen && newList.length > oldLen;
    if (isTailAppend && _follow.isHeld) {
      _follow = _follow.appended(newList.length - oldLen);
      return true;
    }
    return false;
  }

  /// The content-aware prefix for ARRIVAL COUNTING: an id match alone is
  /// not enough (prepends reuse index-based ids); a content edit breaks
  /// it too.
  int _countedContentPrefix(List<Message> newList) {
    final minLen = math.min(_lastSynced.length, newList.length);
    var countedPrefix = 0;
    while (countedPrefix < minLen &&
        _lastSynced[countedPrefix].id == newList[countedPrefix].id &&
        !_messageChanged(_lastSynced[countedPrefix], newList[countedPrefix])) {
      countedPrefix++;
    }
    return countedPrefix;
  }

  Future<void> _replaceWholeList(List<Message> newList) async {
    // (re-review) The replacement re-anchors the scrollable: its
    // corrections glide for several frames and are programmatic —
    // invalidate any in-flight gesture so the settle cannot flush
    // the held count by "landing" inside the arm band.
    _userGestureInFlight = false;
    _wheelGesturePending = false;
    await _chatController.setMessages(newList, animated: false);
  }

  Future<void> _applyIncrementalDiff(
    List<Message> newList,
    int commonPrefix,
  ) async {
    await _updateEditedPrefix(newList, commonPrefix);
    await _removeShrunkenTail(commonPrefix);
    await _insertAppendedRows(newList, commonPrefix);
  }

  Future<void> _updateEditedPrefix(
    List<Message> newList,
    int commonPrefix,
  ) async {
    for (var i = 0; i < commonPrefix; i++) {
      if (_messageChanged(_lastSynced[i], newList[i])) {
        await _chatController.updateMessage(_lastSynced[i], newList[i]);
      }
    }
  }

  Future<void> _removeShrunkenTail(int commonPrefix) async {
    for (var i = _lastSynced.length - 1; i >= commonPrefix; i--) {
      await _chatController.removeMessage(_lastSynced[i]);
    }
  }

  Future<void> _insertAppendedRows(
    List<Message> newList,
    int commonPrefix,
  ) async {
    // A big append (an external-history reload pulled many rows at
    // once) skips the per-row insert animations the same way.
    final appended = newList.length - commonPrefix;
    final oldSuppress = _suppressInsertAnimations;
    if (appended > 12) {
      _suppressInsertAnimations = true;
    }
    for (var i = commonPrefix; i < newList.length; i++) {
      await _chatController.insertMessage(newList[i], index: i);
    }
    _suppressInsertAnimations = oldSuppress;
  }

  /// Post-diff bookkeeping: swap the synced mirror, repaint the counted
  /// pill / emptiness flip, re-arm turn widgets, prune jump anchors, and
  /// re-pin the tail when following.
  void _finishSync(
    List<Message> newList,
    bool followCounted,
    bool emptinessFlipped,
  ) {
    _lastSynced = newList;
    if (followCounted && mounted) {
      setState(() {});
    }
    _rearmTurnWidgetIds();
    _rebuildChipShellIfTargetMoved();
    if (emptinessFlipped && mounted) setState(() {});
    // Drop jump anchors for ids the sync removed (edits rebuild ids).
    final liveIds = {for (final message in newList) message.id};
    _itemKeys.removeWhere((id, _) => !liveIds.contains(id));
    // The first completed sync was the history load — live inserts from
    // here on animate normally.
    _suppressInsertAnimations = false;
    _scrollToTailIfFollowing();
  }

  /// E3 (issue #379): a widget id entering the current turn afresh —
  /// a NEW dynamic message, or the same widget re-presented later —
  /// re-arms its chip/clamp state.
  void _rearmTurnWidgetIds() {
    final turnIds = {for (final (id, _) in _turnWidgets()) id};
    for (final id in turnIds) {
      if (_turnWidgetIds.contains(id)) continue;
      _dismissedWidgetChips.remove(id);
      _interactedWidgets.remove(id);
      _releasedClamps.remove(id);
    }
    _turnWidgetIds = turnIds;
  }

  /// The widget chip lives outside the animated list: rebuild the shell
  /// when a sync changed its target (a new widget appeared, or the
  /// current one aged out of the turn).
  void _rebuildChipShellIfTargetMoved() {
    final chipId = _chipTarget()?.$1;
    if (chipId == _lastChipTargetId) return;
    _lastChipTargetId = chipId;
    if (mounted) setState(() {});
  }

  /// The sync may have attached the list (first message) or changed
  /// the scroll extents (a paged-in page) — re-measure the reveal
  /// gate on the laid-out frame (issue #974).
  void _remeasureRevealPostFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateTopReveal();
    });
  }

  bool _messageChanged(Message a, Message b) {
    if (a.runtimeType != b.runtimeType) return true;
    return switch (a) {
      TextMessage textA => textA.text != (b as TextMessage).text,
      CustomMessage customA =>
        customA.metadata?.toString() !=
            (b as CustomMessage).metadata?.toString(),
      ImageMessage imageA =>
        // ignore: unnecessary_cast
        imageA.source != (b as ImageMessage).source ||
            // ignore: unnecessary_cast
            imageA.text != (b as ImageMessage).text,
      _ => true,
    };
  }

  Future<User?> _resolveUser(UserID id) async {
    return switch (id) {
      'user' => _user,
      'assistant' => _assistant,
      'tool' => _tool,
      'system' => _system,
      _ => User(id: id, name: id),
    };
  }

  /// Copies the whole session transcript to the clipboard as plain text.
  Future<void> _copySession() async {
    await Clipboard.setData(
      ClipboardData(text: widget.service.transcriptMarkdown()),
    );
    if (mounted) {
      showFahSnack(
        context,
        FaChatStrings.of(context).chatCopiedToClipboard,
        duration: const Duration(seconds: 2),
      );
    }
  }

  // Text and custom (tool/thinking/system) messages share one renderer —
  // see ChatMessageTile.
  Widget _buildTextMessage(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    return _keyed(
      message.id,
      ChatMessageTile(
        message: FaChatMessage(
          role: isSentByMe ? 'user' : 'assistant',
          content: message.text,
        ),
        images: _images,
        avatarBuilder: widget.avatarBuilder,
        onPermissionAction: widget.onPermissionAction,
        onAuthRecovery: widget.onAuthRecovery,
        audioControllerFactory: widget.audioControllerFactory,
        videoControllerFactory: widget.videoControllerFactory,
        imageCacheWidth: widget.imagePreviewCacheWidth,
      ),
    );
  }

  Widget _buildCustomMessage(
    BuildContext context,
    CustomMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final metadata = message.metadata ?? const {};
    final row = _keyed(
      message.id,
      ChatMessageTile(
        message: FaChatMessage(
          role: (metadata['role'] as String?) ?? 'system',
          content: (metadata['content'] as String?) ?? '',
          attachments:
              (metadata['attachments'] as List<Object?>?)
                  ?.cast<FaChatAttachment>() ??
              const <FaChatAttachment>[],
          toolName: metadata['toolName'] as String?,
          isError: (metadata['isError'] as bool?) ?? false,
          data: metadata['data'],
        ),
        images: _images,
        avatarBuilder: widget.avatarBuilder,
        onPermissionAction: widget.onPermissionAction,
        onAuthRecovery: widget.onAuthRecovery,
        audioControllerFactory: widget.audioControllerFactory,
        videoControllerFactory: widget.videoControllerFactory,
        imageCacheWidth: widget.imagePreviewCacheWidth,
        dynamicWidgetTileBuilder: widget.dynamicWidgetTileBuilder,
        // Only the LIVE thinking block animates (issue #1374 AC4): the
        // transcript's NEWEST thinking message, matched by its index —
        // finished thinking notes (every earlier turn) keep a frozen
        // face. The global isStreaming flag animated all of them.
        thinkingLive:
            (metadata['transcriptIndex'] as int?) ==
            liveThinkingMessageIndex(widget.service),
      ),
    );
    // Issue #379 AC3: a touch anywhere on a live widget row is an
    // interaction — the chip auto-hides and the clamp releases for it.
    if ((metadata['role'] as String?) == 'widget') {
      final widgetId = (metadata['data'] ?? message.id).toString();
      return Listener(
        onPointerDown: (_) => _markWidgetInteracted(widgetId),
        child: row,
      );
    }
    return row;
  }

  Widget _buildChatBody(BuildContext context) {
    final strings = FaChatStrings.of(context);
    // Pinned history banners (issue #135): "Load earlier" at the top of
    // the loaded range, "Load newer" at the bottom (the page-down path
    // back to the live tail after deep paging). Older pages prefetch on
    // a deliberate approach to the oldest edge; the banner remains the
    // manual fallback/retry. Both show a spinner while a page is in
    // flight, and the older one turns into the terminal
    // "Beginning of session (1 of N)" once the top is reached (E6).
    final historyAbove = _historyAbove;
    // The transcript always scrolls beneath the same floating chrome.
    // Visual directions only change how those surfaces are painted.
    return _buildFloatingGlassChatBody(context, strings, historyAbove);
  }

  Widget _buildFloatingGlassChatBody(
    BuildContext context,
    FaChatStrings strings,
    int? historyAbove,
  ) {
    final tokens = FaDesignTokens.of(context);
    final duoRailWidth = FaDuoControlRail.widthOf(context);
    final transcript = _wrapTranscriptKeyboardDismiss(context, _buildTranscript(context));
    final topOverlay = <Widget>[
      ?_buildErrorBanner(context, strings),
      ?widget.noticeBanner,
      ?_buildTopHistoryBanner(strings, historyAbove),
    ];
    final bottomOverlay = <Widget>[
      ?_buildWidgetOpenChip(context),
      if (_historyHasNewer) _buildNewerHistoryBanner(strings),
      if (_follow.isHeld && _follow.unseen > 0) _followLivePill(strings),
    ];
    Widget body = DropTarget(
      enable: widget.features.attachments,
      onDragEntered: (_) => setState(() => _dropHovering = true),
      onDragExited: (_) => setState(() => _dropHovering = false),
      onDragDone: _onDropDone,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: duoRailWidth == 0
                ? transcript
                : Padding(
                    padding: EdgeInsets.only(right: duoRailWidth),
                    child: SizedBox.expand(
                      key: const ValueKey('faChatDuoContentLane'),
                      child: transcript,
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _glassHeaderExtent + 12,
            child: IgnorePointer(
              child: tokens.direction == FaVisualDirection.glass
                  ? const ProgressiveBlur(
                      key: ValueKey('faChatTopMelt'),
                      maxSigma: 8,
                      direction: ProgressiveBlurDirection.topToBottom,
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, .68, 1],
                          colors: [
                            tokens.background.withValues(alpha: .96),
                            tokens.background.withValues(alpha: .78),
                            tokens.background.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          Positioned(
            key: const ValueKey('faChatBottomEnvironmentFade'),
            left: 0,
            right: 0,
            bottom: 0,
            height: _glassComposerExtent + 4,
            child: IgnorePointer(
              child: tokens.direction == FaVisualDirection.glass
                  ? const ProgressiveBlur(
                      key: ValueKey('faChatBottomMelt'),
                      maxSigma: 8,
                      direction: ProgressiveBlurDirection.bottomToTop,
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, .48, 1],
                          colors: [
                            tokens.background.withValues(alpha: 0),
                            tokens.background.withValues(alpha: .42),
                            tokens.background.withValues(alpha: .96),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          if (topOverlay.isNotEmpty)
            Positioned(
              top: _glassHeaderExtent + 4,
              left: 0,
              right: duoRailWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: topOverlay,
              ),
            ),
          if (bottomOverlay.isNotEmpty)
            Positioned(
              left: 0,
              right: duoRailWidth,
              bottom: _glassComposerExtent + 4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: bottomOverlay,
              ),
            ),
          Positioned(
            left: 0,
            // The composer shares the transcript's usable lane on Duo; it
            // never stretches underneath the native control rail.
            right: duoRailWidth,
            bottom: 0,
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: _onGlassChromeResized,
              child: SizeChangedLayoutNotifier(
                child: SizedBox(
                  key: _glassComposerMeasureKey,
                  child: _buildComposer(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    body = _wrapDropHighlight(body);
    return _wrapWallpaper(body);
  }

  // Issue #692 (friendly auth errors): an auth-expired service error
  // carries the raw CLI recovery hint plus the `[[auth-expired:…]]`
  // marker — render the friendly localized banner (with the host's
  // re-authorize action when wired) instead. Every other error keeps
  // the raw line below.
  Widget? _buildErrorBanner(BuildContext context, FaChatStrings strings) {
    final error = _error;
    if (error == null) return null;
    final expiredProvider = authExpiredProvider(error);
    if (expiredProvider == null) {
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.error, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              // Issue #869: one tap puts the full error on the
              // clipboard — errors are for pasting, not screenshots.
              FahErrorCopyButton(
                text: error,
                color: Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        ),
      );
    }
    return _AuthExpiredBanner(
      strings: strings,
      error: error,
      providerId: expiredProvider,
      onAuthorize: widget.onAuthRecovery,
    );
  }

  Widget? _buildTopHistoryBanner(FaChatStrings strings, int? historyAbove) {
    if (!_topBannerVisible(historyAbove)) return null;
    return _historyPinnedBanner(
      top: true,
      label: _topBannerLabel(strings, historyAbove),
      // An error banner IS the retry surface (round-1 behavior).
      tappable:
          !_historyLoading && !(historyAbove == 0 && _historyLoadError == null),
    );
  }

  Widget _buildNewerHistoryBanner(FaChatStrings strings) {
    final historyBelow = _historyBelow;
    return _historyPinnedBanner(
      top: false,
      label: _historyLoadError != null
          ? strings.chatLoadEarlierFailed
          : historyBelow == null || historyBelow <= 0
          ? strings.chatLoadNewer
          : strings.chatLoadNewerCount('$historyBelow'),
      tappable: !_historyLoading,
    );
  }

  bool _onGlassChromeResized(SizeChangedLayoutNotification notification) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateGlassChromeExtents();
    });
    return false;
  }

  void _updateGlassChromeExtents() {
    final header = _glassHeaderMeasureKey.currentContext?.size;
    final composer = _glassComposerMeasureKey.currentContext?.size;
    final headerExtent = header?.height ?? _glassHeaderExtent;
    final composerExtent = composer?.height ?? _glassComposerExtent;
    if ((headerExtent - _glassHeaderExtent).abs() < .5 &&
        (composerExtent - _glassComposerExtent).abs() < .5) {
      return;
    }
    setState(() {
      _glassHeaderExtent = headerExtent;
      _glassComposerExtent = composerExtent;
    });
  }

  Widget _buildComposer(BuildContext context) {
    final composerBuilder = widget.composerBuilder;
    final composer = composerBuilder != null
        ? composerBuilder(context, widget.service, _dropBridge)
        : ChatComposer(
            service: widget.service,
            features: widget.features,
            mentionOptionsBuilder: widget.mentionOptionsBuilder,
            dropBridge: _dropBridge,
          );
    // Measure the agents/header slot WITH the composer. The transcript's
    // bottom inset then reserves it automatically instead of letting the
    // floating header cover the newest message.
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.inputHeader case final header?)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: header),
        composer,
      ],
    );
    final duo =
        FaDuoLayoutScope.maybeOf(context)?.isDuo ??
        FaDuoControlRail.isActive(context);
    if (!duo) return content;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SizedBox(width: double.infinity, child: content),
      ),
    );
  }

  /// The transcript column child: scroll/metrics notification plumbing
  /// around the chat list (follow classifier, reveal gate, wheel gate).
  Widget _buildTranscript(BuildContext context) =>
      _buildScrollLayer(_buildChatList(context));

  /// Tap-to-dismiss for the on-screen keyboard (the iOS messenger
  /// contract): any pointer-down on the message area drops the composer's
  /// focus so the keyboard hides, exactly like the native chat apps.
  ///
  /// Gated on a VISIBLE keyboard: desktop pointer sessions never report
  /// view insets, so the gate is a no-op there and desktop focus behavior
  /// (clicking the transcript keeps the composer focused) is unchanged.
  /// A raw [Listener] — not a tap recognizer — keeps the gesture arena
  /// untouched: scrolling, long-press selection and message interactions
  /// all behave exactly as before while still dismissing the keyboard.
  Widget _wrapTranscriptKeyboardDismiss(BuildContext context, Widget child) {
    // Resolved at build time so the state depends on the ambient view
    // insets: the gate flips exactly when the keyboard appears/hides.
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Listener(
      onPointerDown: (event) {
        if (!keyboardVisible) return;
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: child,
    );
  }

  /// The three notification layers around the [Chat]:
  /// - layout-time extent changes never move the scroll position, so the
  ///   reveal-on-top gate (issue #974) listens for them on metrics; the
  ///   framework defers the dispatch until after the frame completes (a
  ///   mid-layout dispatch would be useless), and the post-frame
  ///   re-measure keeps the gate in sync regardless of when a given
  ///   Flutter version dispatches it;
  /// - scroll updates classify the follow mode;
  /// - raw pointer signals mark wheel/trackpad ticks as user gestures.
  Widget _buildScrollLayer(Widget child) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _updateTopReveal();
        });
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _trackUserScroll(notification);
          return false;
        },
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _wheelGesturePending = true;
            }
          },
          child: child,
        ),
      ),
    );
  }

  Widget _buildChatList(BuildContext context) {
    final wallpaper = widget.wallpaperBuilder;
    return Chat(
      currentUserId: 'user',
      resolveUser: _resolveUser,
      chatController: _chatController,
      // With a wallpaper layer the transcript surface paints
      // transparent so the layer underneath shows through (E2: the
      // layer itself owns the color fallback when the image is gone).
      backgroundColor: wallpaper == null ? null : const Color(0x00000000),
      builders: _chatBuilders(context),
      theme: _chatTheme(context),
    );
  }

  ChatTheme _chatTheme(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
      ? buildFahChatThemeLight(uiTheme: FaUiThemeProvider.of(context))
      : buildFahChatTheme(uiTheme: FaUiThemeProvider.of(context));

  Builders _chatBuilders(BuildContext context) {
    return Builders(
      textMessageBuilder: _buildTextMessage,
      customMessageBuilder: _buildCustomMessage,
      chatAnimatedListBuilder: (context, itemBuilder) => ChatAnimatedList(
        // Tests target the transcript's scrollable
        // through this key (E2E scroll-to-top for the
        // reveal-on-top banner) instead of tree order.
        key: const ValueKey('faChatTranscriptList'),
        itemBuilder: itemBuilder,
        scrollController: _chatScrollController,
        // Floating chrome overlays the viewport, not its layout. These
        // measured insets make both extremes fully scrollable into view.
        topPadding: (widget.showAppBar ? _glassHeaderExtent : 0) + 16,
        bottomPadding: _glassComposerExtent + 16,
        handleSafeArea: false,
        // Reversed list (the learn.ai pattern): index 0 is the
        // newest message, the list starts AT the bottom — no
        // initial scroll-to-end, no jump, or "stuck mid-list"
        // on long transcripts. New rows grow upwards, exactly
        // like a chat.
        reversed: true,
        // The initial history load (and big external reloads)
        // renders without the per-row insert animation cascade;
        // live messages keep the default animation. 1ms instead
        // of a true zero: a zero duration leaves the package's
        // initial-scroll timer unsettled inside fake_async
        // test bindings.
        insertAnimationDurationResolver: (_) => _suppressInsertAnimations
            ? const Duration(milliseconds: 1)
            : const Duration(milliseconds: 250),
        // The single transient status row lives IN the list
        // (issues #459, #1042): in a reversed scroll view
        // the bottom sliver renders visually LAST — below
        // the newest message, right above the composer —
        // and on completion it is replaced by the assistant
        // message (it self-hides when the run ends; never a
        // composer-docked second row).
        bottomSliver: SliverToBoxAdapter(
          key: const ValueKey('faChatRunStatusRow'),
          child: FaRunStatusRow(service: widget.service),
        ),
      ),
      // While streaming with an empty transcript the status row
      // is the only item (E1) — the package's default
      // "No messages yet" overlay would stack under it; idle
      // keeps the default (the row renders nothing then).
      emptyChatListBuilder: (context) =>
          _isStreaming ? const SizedBox.shrink() : const EmptyChatList(),
      composerBuilder: (_) => const SizedBox.shrink(),
    );
  }

  /// The drop highlight rides in a Stack above the body so the border
  /// overlay never shifts the transcript layout (AC3).
  Widget _wrapDropHighlight(Widget body) {
    return Stack(
      children: [
        Positioned.fill(child: body),
        if (_dropHovering)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                key: const ValueKey('faChatDropHighlight'),
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: fahChatColorsOf(context).indigo,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The theme-pack wallpaper paints under the transcript; null keeps
  /// the stock opaque surface.
  Widget _wrapWallpaper(Widget body) {
    final wallpaper = widget.wallpaperBuilder;
    if (wallpaper == null) return body;
    return Stack(
      children: [
        Positioned.fill(child: Builder(builder: wallpaper)),
        Positioned.fill(child: body),
      ],
    );
  }

  /// The `⌄ N new` jump-to-live pill (gh-1439): a floating, live-updating
  /// affordance in the banner slot family — centered, compact, one tap
  /// re-engages the live tail and flushes the count (AC2). The count is
  /// the shared [FollowMode.unseen]; approval prompts are NOT affected
  /// (AC6: they render through their own surface above this slot).
  Widget _followLivePill(FaChatStrings strings) {
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Semantics(
          label: strings.chatJumpToLive,
          button: true,
          child: Material(
            key: const ValueKey('faChatJumpToLivePill'),
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: _jumpToLive,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      strings.chatFollowNewCount('${_follow.unseen}'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Forwards a completed drop to the mounted composer through the bridge
  /// (files stage as chips, a text-only drop inserts at the cursor).
  void _onDropDone(DropDoneDetails details) {
    setState(() => _dropHovering = false);
    final handler = _dropBridge.handler;
    if (handler == null) return;
    unawaited(handler(details.files, details.rawText));
  }

  /// The top banner hides only on non-windowed hosts (no total, nothing
  /// above); a windowed host always shows it — count, spinner, or the
  /// terminal "Beginning of session" state (E6).
  ///
  /// Reveal-on-top (issue #974): the banner only renders while the
  /// viewport is parked at the oldest edge (or the transcript fits) —
  /// never over the live tail. Reads the measured cache, not the live
  /// getter: until the first post-frame measurement lands the banner
  /// stays hidden, so a windowed open never flashes it on frame one.
  ///
  /// Empty-session escape (issue #223): with no transcript rows loaded
  /// and nothing above the window there is nothing to page in, so no
  /// banner renders — even while the background count is still in flight
  /// or has failed. The terminal state likewise never renders for a
  /// header-only or single-record session (a "1 of 0"/"1 of 1" banner is
  /// nonsense over an already-complete transcript).
  bool _topBannerVisible(int? historyAbove) {
    if (!_topBannerRevealed) return false;
    final total = _historyTotal;
    if (historyAbove != null &&
        historyAbove <= 0 &&
        total != null &&
        total <= 1) {
      return false;
    }
    if (_lastSynced.isEmpty && (historyAbove ?? 0) <= 0) return false;
    return historyAbove == null || historyAbove > 0 || total != null;
  }

  String _topBannerLabel(FaChatStrings strings, int? historyAbove) {
    if (_historyLoadError != null) return strings.chatLoadEarlierFailed;
    if (_historyLoading) return '';
    if (historyAbove == null) return strings.chatLoadEarlier;
    if (historyAbove == 0) {
      return strings.chatBeginningOfSession('${_historyTotal ?? '?'}');
    }
    return strings.chatLoadEarlierCount('$historyAbove');
  }

  /// One pinned history banner row: a spinner while a page load is in
  /// flight, otherwise the label; tappable only when [tappable].
  Widget _historyPinnedBanner({
    required bool top,
    required String label,
    required bool tappable,
  }) {
    final loading = _historyLoading;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: tappable
            ? (top
                  ? widget.service.loadOlderHistory
                  // The tap's promise is the live tail (issue #1159 AC1):
                  // one owner for the re-engage — relatch + the E4
                  // deep-page-then-jump ordering. _jumpToLive already
                  // awaits the page-in before landing at 0; the tear-off
                  // is fire-and-forget (gh-1439 re-review).
                  : _jumpToLive)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              // Long error labels must wrap/ellipsize, never overflow.
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    final fileBrowserBuilder = widget.features.fileBrowser
        ? _fileBrowserBuilder
        : null;
    final headerActions = _buildHeaderActions(
      isWide,
      fileBrowserBuilder,
      filesPanelOpen: _filesPanelOpen,
    );
    final glass =
        FaDesignTokens.of(context).direction == FaVisualDirection.glass;
    final body = _buildBody(isWide, fileBrowserBuilder);
    final scaffold = Scaffold(
      key: _scaffoldKey,
      endDrawer: _buildEndDrawer(isWide, fileBrowserBuilder),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final filesPanelWidth = _liveFilesPanelWidth(constraints.maxWidth);
          // The header's right inset follows the SAME reveal as the
          // docked slot: the floating header glides with the panel's
          // boundary (the sidebar's smooth-boundary behavior) instead of
          // snapping when the panel's target flag flips.
          return AnimatedBuilder(
            animation: _filesPanelReveal,
            builder: (context, _) {
              final reveal = _filesPanelRevealValue;
              final panelCapable =
                  isWide && fileBrowserBuilder != null && filesPanelWidth > 0;
              final slotMounted = panelCapable && _filesPanelMounted;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: body),
                  if (widget.showAppBar)
                    Positioned(
                      top: 0,
                      left: 0,
                      // Use THIS center Stack's width, never the full window:
                      // the app sidebar can make those constraints very different.
                      right: slotMounted ? filesPanelWidth * reveal : 0,
                      child: _buildFloatingGlassHeader(isWide, headerActions),
                    ),
                  if (widget.showAppBar && FaDuoControlRail.isActive(context))
                    _buildDuoFloatingRail(
                      headerActions,
                      slotMounted ? filesPanelWidth * reveal : 0,
                      showBack: !isWide && Navigator.canPop(context),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
    if (!glass || BackdropGroup.of(context) != null) return scaffold;
    return BackdropGroup(child: scaffold);
  }

  /// The adaptive header's action list (issue #225): the list IS the
  /// priority order and demotion removes from the tail, so the pinned
  /// streaming stop comes first (never demoted — E2), then the secondary
  /// actions (trajectory, copy, the host's ✦ and Apps widgets) that
  /// yield on tight widths. Files sits LAST — the rightmost slot — and
  /// hides while the docked panel is open (toggle-as-part-of-panel, the
  /// chats-sidebar collapse/expand pattern): the visible toggle becomes
  /// the panel band's leading X, so the header never renders a second
  /// close-looking control for an open surface. On narrow layouts the
  /// entry stays — the end drawer has no band X of its own.
  List<FaHeaderAction> _buildHeaderActions(
    bool isWide,
    WidgetBuilder? fileBrowserBuilder, {
    required bool filesPanelOpen,
  }) {
    final strings = FaChatStrings.of(context);
    return [
      ?_streamingStopAction(strings),
      // One adaptive Trajectory action on every form factor. Wide pushes
      // the master-detail route; narrow swaps the body in place. The
      // adaptive header demotes it into ⋮ when the width runs out.
      if (widget.features.trajectory)
        FaHeaderAction(
          icon: !isWide && _showTrajectory
              ? Icons.chat_bubble_outline
              : Icons.timeline,
          label: !isWide && _showTrajectory
              ? TrajectoryStrings.of(context).switcherChat
              : strings.chatTrajectoryTooltip,
          onPressed: () {
            if (isWide) {
              _openTrajectoryRoute();
            } else {
              setState(() => _showTrajectory = !_showTrajectory);
            }
          },
        ),
      if (widget.features.copyTranscript)
        FaHeaderAction(
          icon: Icons.copy_outlined,
          label: strings.chatCopySessionTooltip,
          onPressed: _copySession,
        ),
      ..._hostHeaderActions(),
      if (fileBrowserBuilder != null && !(isWide && filesPanelOpen))
        FaHeaderAction(
          key: const ValueKey('faChatFilesAction'),
          icon: Icons.folder_outlined,
          label: strings.chatFilesTooltip,
          onPressed: _openFiles,
        ),
    ];
  }

  /// The pinned streaming stop — never demoted (E2).
  FaHeaderAction? _streamingStopAction(FaChatStrings strings) => _isStreaming
      ? FaHeaderAction(
          icon: Icons.stop,
          label: strings.chatAbortTooltip,
          onPressed: widget.service.abort,
          pinned: true,
        )
      : null;

  /// The host's dynamic-messages affordance (issue #102: the ✦ button)
  /// and apps-collapse toggle (issue #224: the Apps icon), rendered
  /// exactly as the host styles them, demotable into the ⋮ menu.
  List<FaHeaderAction> _hostHeaderActions() {
    final dynamicMessagesButton = FaChatHost.dynamicMessagesButtonBuilder?.call(
      context,
      widget.service,
    );
    final appsToggleButton = FaChatHost.appsToggleButtonBuilder?.call(
      context,
      widget.service,
    );
    return [
      if (dynamicMessagesButton != null)
        FaHeaderAction.widget(
          widget: dynamicMessagesButton.widget,
          label: dynamicMessagesButton.label,
          onPressed: dynamicMessagesButton.onPressed,
        ),
      if (appsToggleButton != null)
        FaHeaderAction.widget(
          widget: appsToggleButton.widget,
          label: appsToggleButton.label,
          onPressed: appsToggleButton.onPressed,
        ),
    ];
  }

  /// The files end drawer (narrow layouts only — wide uses the side
  /// panel in the body row); null hides it.
  Widget? _buildEndDrawer(bool isWide, WidgetBuilder? fileBrowserBuilder) {
    if (isWide || fileBrowserBuilder == null) return null;
    return Drawer(
      width: kFaChatFilesPanelWidth,
      child: SafeArea(child: fileBrowserBuilder(context)),
    );
  }

  /// Narrow + trajectory swaps Chat ⇄ Trajectory in an IndexedStack
  /// (PopScope closes the trajectory page first); everything else is the
  /// body row with the optional files side panel.
  Widget _buildBody(bool isWide, WidgetBuilder? fileBrowserBuilder) {
    if (!isWide && widget.features.trajectory) return _buildNarrowBody();
    return _buildBodyRow(isWide, fileBrowserBuilder);
  }

  Widget _buildNarrowBody() {
    return PopScope(
      canPop: !_showTrajectory,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _showTrajectory = false);
      },
      child: IndexedStack(
        index: _showTrajectory ? 1 : 0,
        children: [
          _buildChatBody(context),
          Padding(
            padding: EdgeInsets.only(
              top: widget.showAppBar ? _glassHeaderExtent : 0,
            ),
            // The measured glass header extent INCLUDES the SafeArea the
            // floating header consumed. TrajectoryScreen's own Scaffold
            // SafeArea must not apply that top inset a second time — on a
            // phone that painted the status bar twice and opened a giant
            // gap between the chat chrome and the trajectory page. The
            // embedded pane also skips the macOS traffic-light clearance:
            // it starts below the chat header, which already cleared the
            // traffic lights. The pushed standalone route keeps both.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: TrajectoryScreen(
                controller: _trajectory,
                loaded: _trajectoryLoaded,
                clearsTopChrome: false,
                scope: TrajectoryProjectionScope(
                  above: widget.service.historyAboveCount,
                  below: widget.service.historyBelowCount,
                  total: widget.service.historyTotalCount,
                ),
                onRecordActivate: (record) =>
                    widget.service.jumpToMessage(record.recordId),
                onClose: () => setState(() => _showTrajectory = false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodyRow(bool isWide, WidgetBuilder? fileBrowserBuilder) {
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _filesPanelReveal,
        builder: (context, _) {
          final filesPanelWidth = _liveFilesPanelWidth(constraints.maxWidth);
          // The reveal only plays on open/close; width drags land at 1.0.
          final reveal = _filesPanelRevealValue;
          final panelMounted =
              _filesPanelMounted &&
              isWide &&
              fileBrowserBuilder != null &&
              filesPanelWidth > 0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildChatBody(context)),
              if (panelMounted)
                // The docked slot mirrors the shell's presented-surface
                // reveal: the slot's WIDTH animates (0 → full) while the
                // card inside keeps its final size — the browser must not
                // reflow mid-flight — and the pane slides in from the
                // window's right edge with the sidebar's duration+curve.
                SizedBox(
                  key: const ValueKey('faChatFilesPanel'),
                  width: filesPanelWidth * reveal,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerRight,
                          minWidth: filesPanelWidth,
                          maxWidth: filesPanelWidth,
                          child: SizedBox(
                            width: filesPanelWidth,
                            child: IgnorePointer(
                              ignoring: reveal < .02,
                              child: Opacity(
                                opacity: reveal,
                                child: Transform.translate(
                                  offset: Offset(
                                    filesPanelWidth * (1 - reveal),
                                    0,
                                  ),
                                  // The panel sits FLUSH against the
                                  // transcript (no divider): the band's
                                  // glass edge and the resize handle carry
                                  // the seam. The scope carries the docked
                                  // panel's close intent — the band's own X
                                  // (left of the search capsule) closes the
                                  // panel; the header hides its Files entry
                                  // while the panel is open.
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Builder(
                                          builder: (context) {
                                            final panel = FaFilesPanelScope(
                                              closePanel: _closeFilesPanel,
                                              child: fileBrowserBuilder(
                                                context,
                                              ),
                                            );
                                            final duoRailWidth =
                                                FaDuoControlRail.widthOf(
                                                  context,
                                                );
                                            if (duoRailWidth == 0) return panel;
                                            // Only the wide docked slot
                                            // reaches the physical edge. The
                                            // narrow Drawer owns a SafeArea;
                                            // insetting its builder as well
                                            // would subtract this lane twice.
                                            return Padding(
                                              key: const ValueKey(
                                                'duoFilesContentLane',
                                              ),
                                              padding: EdgeInsets.only(
                                                right: duoRailWidth,
                                              ),
                                              child: panel,
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // The shared pane handle, CENTERED on the panel edge
                      // (the slot's left line) — the grip straddles the
                      // seam like the sidebar divider's does. Kept outside
                      // the reveal's ClipRect so the hit surface can reach
                      // 8px into the transcript; drags stay live the whole
                      // flight (width drags are never animated).
                      Positioned(
                        left: -8,
                        top: 0,
                        bottom: 0,
                        width: 16,
                        child: IgnorePointer(
                          ignoring: reveal < .02,
                          child: FaPaneResizeHandle(
                            key: const ValueKey('faChatFilesPanelResizeHandle'),
                            onDragUpdate: (dx) {
                              final desired = _clampFilesPanelWidth(
                                _filesPanelWidth - dx,
                                constraints.maxWidth,
                              );
                              if (desired == _filesPanelWidth) {
                                return;
                              }
                              setState(() => _filesPanelWidth = desired);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The friendly auth-expired error banner (issue #692): when the
/// service error carries the `[[auth-expired:<id>]]` marker, the chat's
/// error line renders this — a localized session-expired notice plus
/// the cleaned provider message (marker and dead `(CLI: …)` hint
/// stripped by [authExpiredDisplayText]) and, when the host wired
/// [FaChatScreen.onAuthRecovery], the re-authorize action — instead of
/// the raw redirect/CLI text.
class _AuthExpiredBanner extends StatelessWidget {
  const _AuthExpiredBanner({
    required this.strings,
    required this.error,
    required this.providerId,
    required this.onAuthorize,
  });

  final FaChatStrings strings;
  final String error;
  final String providerId;
  final FaAuthRecoveryCallback? onAuthorize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final detail = authExpiredDisplayText(error);
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.key_off, color: colors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    strings.chatAuthExpiredBannerTitle,
                    style: TextStyle(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    strings.chatAuthExpiredBannerBody(providerId),
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      style: TextStyle(
                        color: colors.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            // Issue #869: copy carries the RAW error verbatim — the
            // friendly text derives from it, the raw payload is what a
            // bug report needs.
            FahErrorCopyButton(text: error, color: colors.error),
            if (onAuthorize != null) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () => onAuthorize?.call(providerId),
                child: Text(strings.chatAuthExpiredBannerAction),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
