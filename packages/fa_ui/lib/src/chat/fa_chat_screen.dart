// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        ApprovalDecision,
        ApprovalRequest,
        AskAnswer,
        AskQuestion,
        MemoryExecutionEnv,
        RequestSecretResult,
        TrajectorySnapshot;
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';

import '../theme/app_theme.dart';
import '../theme/fa_ui_theme.dart';
import '../trajectory/trajectory_controller.dart';
import '../trajectory/trajectory_panel.dart';
import '../trajectory/trajectory_view.dart';
import '../trajectory/trajectory_strings.dart';
import 'approval_ui.dart';
import 'ask_ui.dart';
import 'chat_composer.dart';
import 'chat_message_tile.dart';
import 'chat_strings.dart';
import 'fa_adaptive_header.dart';
import 'fa_chat_features.dart';
import 'fa_chat_host.dart';
import 'fa_chat_service.dart';
import 'markdown_style.dart';
import 'media_player.dart';
import 'secret_request_sheet.dart';

/// Minimum body width (logical px) at which the files panel becomes a
/// persistent, collapsible panel instead of an end drawer.
const double kWideLayoutBreakpoint = 900;

/// Width of the files side panel / end drawer.
const double kFaChatFilesPanelWidth = 300;

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

  /// True once the USER dragged the transcript away (parked at ≥ the
  /// near-bottom latch). Programmatic scrolls — the tail follow and the
  /// live-widget clamp's own animateTo — never set this, so the clamp
  /// keeps working after it moves the viewport past the latch threshold,
  /// while a real user scroll always wins (issue #379 AC2). Dragging
  /// back to the bottom relatches.
  bool _userScrolledAway = false;

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

  /// Whether the file browser side panel is expanded (wide layouts only).
  bool _filesPanelOpen = false;

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
  /// opens the end drawer on narrow ones.
  void _openFiles() {
    if (MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint) {
      setState(() => _filesPanelOpen = !_filesPanelOpen);
      if (_filesPanelOpen) {
        FaChatHost.track('files_opened', {'source': 'chat'});
      }
    } else {
      FaChatHost.track('files_opened', {'source': 'chat'});
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  @override
  void initState() {
    super.initState();
    FaChatHost.track('screen_opened', {'screen_name': 'chat'});
    _chatController = InMemoryChatController();
    _chatScrollController.addListener(_trackNearBottom);
    _subscribeToService(widget.service);
    if (widget.features.trajectory) _trajectory;
    _isStreaming = widget.service.isStreaming;
    _error = widget.service.error;
    _historyAbove = widget.service.historyAboveCount;
    _historyLoadError = widget.service.historyLoadError;
    _historyLoading = widget.service.historyLoading;
    _historyHasNewer = widget.service.historyHasNewer;
    _historyBelow = widget.service.historyBelowCount;
    _historyTotal = widget.service.historyTotalCount;
    _syncMessages();
  }

  @override
  void didUpdateWidget(covariant FaChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      // The host swapped sessions (close/switch): re-subscribe and re-sync.
      _unsubscribeFromService(oldWidget.service);
      _subscribeToService(widget.service);
      _unbindTrajectory();
      if (widget.features.trajectory) _trajectory;
      _isStreaming = widget.service.isStreaming;
      _error = widget.service.error;
      _historyAbove = widget.service.historyAboveCount;
      _historyLoadError = widget.service.historyLoadError;
      _historyLoading = widget.service.historyLoading;
      _historyHasNewer = widget.service.historyHasNewer;
      _historyBelow = widget.service.historyBelowCount;
      _historyTotal = widget.service.historyTotalCount;
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
    _userNearBottom = position.pixels < 150;
  }

  /// Classifies scroll activity on the transcript's own scrollable
  /// (depth 0 — inner tool-output scrollables don't count): a user drag
  /// parking above the latch threshold marks the transcript
  /// scrolled-away; anything landing back under the threshold relatches.
  void _trackUserScroll(ScrollNotification notification) {
    if (notification.depth != 0) return;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return;
    }
    if (!_chatScrollController.hasClients) return;
    final pixels = _chatScrollController.position.pixels;
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _userScrolledAway = pixels >= 150;
    } else if (pixels < 150) {
      _userScrolledAway = false;
    }
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
      // Issue #379: while the current turn holds a live (un-interacted)
      // widget, the follow clamps to keep the widget's leading edge
      // inside the viewport instead of pinning the tail. Manual scroll
      // still wins — this only runs while following (AC2).
      final target = _liveWidgetClampOffset() ?? 0.0;
      if ((target - _chatScrollController.offset).abs() < 1) return;
      _chatScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.linearToEaseOut,
      );
      // The animated list mounts the freshly inserted row one frame
      // later, so this frame's geometry (and the target above) lags one
      // chunk behind. Re-measure on the next frame and correct — the
      // leading edge must land inside the viewport exactly (AC1).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_chatScrollController.hasClients) return;
        if (!_userNearBottom) return;
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
    final viewport = RenderAbstractViewport.of(row);
    final topReveal = viewport.getOffsetToReveal(row, 1.0).offset;
    if (topReveal <= 0) return null; // fully visible at the tail already
    return topReveal + 16; // a small margin keeps the edge strictly inside
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
    _chatScrollController.dispose();
    _unbindTrajectory();
    _unsubscribeFromService(widget.service);
    _chatController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _syncMessages();
    });

    final needsRebuild =
        widget.service.isStreaming != _isStreaming ||
        widget.service.error != _error ||
        widget.service.historyAboveCount != _historyAbove ||
        widget.service.historyLoadError != _historyLoadError ||
        widget.service.historyLoading != _historyLoading ||
        widget.service.historyHasNewer != _historyHasNewer ||
        widget.service.historyBelowCount != _historyBelow ||
        widget.service.historyTotalCount != _historyTotal;
    if (needsRebuild) {
      final wasStreaming = _isStreaming;
      _isStreaming = widget.service.isStreaming;
      _error = widget.service.error;
      _historyAbove = widget.service.historyAboveCount;
      _historyLoadError = widget.service.historyLoadError;
      _historyLoading = widget.service.historyLoading;
      _historyHasNewer = widget.service.historyHasNewer;
      _historyBelow = widget.service.historyBelowCount;
      _historyTotal = widget.service.historyTotalCount;

      // Issue #379: the turn ended while the user had scrolled away —
      // release the clamp for the current target; returning to the tail
      // later must not re-clamp it (GOAL §1).
      if (wasStreaming && !_isStreaming && _userScrolledAway) {
        final target = _clampTarget();
        if (target != null) _releasedClamps.add(target.$1);
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncMessages() async {
    if (_isSyncing) {
      _syncDebounce?.cancel();
      _syncDebounce = Timer(const Duration(milliseconds: 50), () {
        if (mounted) _syncMessages();
      });
      return;
    }
    _isSyncing = true;

    try {
      final converted = await Future.wait(
        widget.service.messages.indexed.map(
          (entry) => _toMessage(entry.$1, entry.$2),
        ),
      );
      final newList = converted.toList();
      // The top banner's empty-session escape (issue #223) reads the
      // synced window; an emptiness flip must repaint it even when no
      // service field changed (the initial history sync notifies nobody).
      final emptinessFlipped = _lastSynced.isEmpty != newList.isEmpty;

      if (_lastSynced.isEmpty || newList.isEmpty) {
        // History load: instant, no set animation (messages are read from
        // disk; they must appear as one frame, not slide in).
        await _chatController.setMessages(newList, animated: false);
      } else {
        final oldLen = _lastSynced.length;
        final newLen = newList.length;
        final minLen = math.min(oldLen, newLen);

        var commonPrefix = 0;
        while (commonPrefix < minLen &&
            _lastSynced[commonPrefix].id == newList[commonPrefix].id) {
          commonPrefix++;
        }

        final changes =
            (commonPrefix - math.min(oldLen, commonPrefix)) +
            (oldLen - commonPrefix) +
            (newLen - commonPrefix);
        // A big diff (a session switch, an external-history load) syncs in
        // ONE setMessages pass: per-message inserts rebuild the list per
        // row and stream in bottom-up, visibly slow on long transcripts.
        if (changes > 12) {
          await _chatController.setMessages(newList, animated: false);
        } else {
          for (var i = 0; i < commonPrefix; i++) {
            if (_messageChanged(_lastSynced[i], newList[i])) {
              await _chatController.updateMessage(_lastSynced[i], newList[i]);
            }
          }

          for (var i = oldLen - 1; i >= commonPrefix; i--) {
            await _chatController.removeMessage(_lastSynced[i]);
          }

          // A big append (an external-history reload pulled many rows at
          // once) skips the per-row insert animations the same way.
          final appended = newLen - commonPrefix;
          final oldSuppress = _suppressInsertAnimations;
          if (appended > 12) {
            _suppressInsertAnimations = true;
          }
          for (var i = commonPrefix; i < newLen; i++) {
            await _chatController.insertMessage(newList[i], index: i);
          }
          _suppressInsertAnimations = oldSuppress;
        }
      }

      _lastSynced = newList;

      // E3 (issue #379): a widget id entering the current turn afresh —
      // a NEW dynamic message, or the same widget re-presented later —
      // re-arms its chip/clamp state.
      final turnIds = {for (final (id, _) in _turnWidgets()) id};
      for (final id in turnIds) {
        if (_turnWidgetIds.contains(id)) continue;
        _dismissedWidgetChips.remove(id);
        _interactedWidgets.remove(id);
        _releasedClamps.remove(id);
      }
      _turnWidgetIds = turnIds;
      // The chip lives outside the animated list: rebuild the shell when
      // a sync changed its target (a new widget appeared, or the current
      // one aged out of the turn).
      final chipId = _chipTarget()?.$1;
      if (chipId != _lastChipTargetId) {
        _lastChipTargetId = chipId;
        if (mounted) setState(() {});
      }
      if (emptinessFlipped && mounted) setState(() {});
      // Drop jump anchors for ids the sync removed (edits rebuild ids).
      final liveIds = {for (final message in newList) message.id};
      _itemKeys.removeWhere((id, _) => !liveIds.contains(id));
      // The first completed sync was the history load — live inserts from
      // here on animate normally.
      _suppressInsertAnimations = false;
      _scrollToTailIfFollowing();
    } on Object catch (e, stack) {
      // _syncMessages runs from a Timer callback: an escape here is an
      // unhandled async error that repeats on every service notification
      // (the "Uncaught Error" console storm). Log it and leave
      // _lastSynced stale so the next notification retries the sync.
      debugPrint('chat sync failed: $e\n$stack');
    } finally {
      _isSyncing = false;
    }
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

  Future<Message> _toMessage(int index, FaChatMessage chat) async {
    final id = 'msg-$index';
    final now = DateTime.now();

    switch (chat.role) {
      case 'user':
        // Issue #461: user messages with attachments render through the
        // shared ChatMessageTile (thumbnails/chips inside the bubble), the
        // same way every other surface renders them. Text-only messages
        // keep the plain text row.
        if (chat.attachments.isNotEmpty) {
          return Message.custom(
            id: id,
            authorId: 'user',
            createdAt: now,
            metadata: <String, dynamic>{
              'role': 'user',
              'content': chat.content,
              'attachments': chat.attachments,
            },
          );
        }
        return Message.text(
          id: id,
          authorId: 'user',
          text: chat.content,
          createdAt: now,
        );
      case 'assistant':
        return Message.text(
          id: id,
          authorId: 'assistant',
          text: chat.content,
          createdAt: now,
        );
      case 'system':
      case 'tool':
      case 'thinking':
      case 'widget':
        return Message.custom(
          id: id,
          authorId: chat.role == 'tool' ? 'tool' : 'system',
          createdAt: now,
          metadata: <String, dynamic>{
            'role': chat.role,
            'toolName': chat.toolName,
            'content': chat.content,
            'isError': chat.isError,
            'data': chat.data,
          },
        );
      default:
        return Message.text(
          id: id,
          authorId: 'system',
          text: chat.content,
          createdAt: now,
        );
    }
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(FaChatStrings.of(context).chatCopiedToClipboard),
          duration: const Duration(seconds: 2),
        ),
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
    final composerBuilder = widget.composerBuilder;
    final strings = FaChatStrings.of(context);
    // Pinned history banners (issue #135): "Load earlier" at the top of
    // the loaded range, "Load newer" at the bottom (the page-down path
    // back to the live tail after deep paging). Both are tap-only (no
    // scroll-triggered loads), show a spinner while a page is in flight,
    // and turn into the terminal "Beginning of session (1 of N)" once
    // the top of the file is reached (E6).
    final historyAbove = _historyAbove;
    final historyBelow = _historyBelow;
    final wallpaper = widget.wallpaperBuilder;
    Widget body = DropTarget(
      // Drag-and-drop over the chat area stages attachments (issue #465).
      // Hosts that turn the attachments feature off keep drops off too.
      enable: widget.features.attachments,
      onDragEntered: (_) => setState(() => _dropHovering = true),
      onDragExited: (_) => setState(() => _dropHovering = false),
      onDragDone: _onDropDone,
      child: Column(
      children: [
        if (_error case final error?)
          Material(
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
                ],
              ),
            ),
          ),
        if (_topBannerVisible(historyAbove))
          _historyPinnedBanner(
            top: true,
            label: _topBannerLabel(strings, historyAbove),
            // An error banner IS the retry surface (round-1 behavior).
            tappable:
                !_historyLoading &&
                !(historyAbove == 0 && _historyLoadError == null),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              _trackUserScroll(notification);
              return false;
            },
            child: Chat(
              currentUserId: 'user',
              resolveUser: _resolveUser,
              chatController: _chatController,
              // With a wallpaper layer the transcript surface paints
              // transparent so the layer underneath shows through (E2: the
              // layer itself owns the color fallback when the image is gone).
              backgroundColor: wallpaper == null
                  ? null
                  : const Color(0x00000000),
              builders: Builders(
                textMessageBuilder: _buildTextMessage,
                customMessageBuilder: _buildCustomMessage,
                chatAnimatedListBuilder: (context, itemBuilder) =>
                    ChatAnimatedList(
                      itemBuilder: itemBuilder,
                      scrollController: _chatScrollController,
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
                      insertAnimationDurationResolver: (_) =>
                          _suppressInsertAnimations
                          ? const Duration(milliseconds: 1)
                          : const Duration(milliseconds: 250),
                      // The typing indicator lives IN the list (issue #459):
                      // in a reversed scroll view the bottom sliver renders
                      // visually LAST — below the newest message, right
                      // above the composer — scrolling away with the
                      // content instead of pinning above the input bar.
                      bottomSliver: _isStreaming
                          ? const SliverToBoxAdapter(
                              key: ValueKey('faChatTypingFooter'),
                              child: FaTypingFooter(),
                            )
                          : null,
                    ),
                // While streaming with an empty transcript the footer is the
                // only item (E1) — the package's default "No messages yet"
                // overlay would stack under it; idle keeps the default.
                emptyChatListBuilder: (context) => _isStreaming
                    ? const SizedBox.shrink()
                    : const EmptyChatList(),
                composerBuilder: (_) => const SizedBox.shrink(),
              ),
              theme: Theme.of(context).brightness == Brightness.light
                  ? buildFahChatThemeLight(
                      uiTheme: FaUiThemeProvider.of(context),
                    )
                  : buildFahChatTheme(uiTheme: FaUiThemeProvider.of(context)),
            ),
          ),
        ),
        if (_buildWidgetOpenChip(context) case final chip?) chip,
        if (_historyHasNewer)
          _historyPinnedBanner(
            top: false,
            label: _historyLoadError != null
                ? strings.chatLoadEarlierFailed
                : historyBelow == null || historyBelow <= 0
                ? strings.chatLoadNewer
                : strings.chatLoadNewerCount('$historyBelow'),
            tappable: !_historyLoading,
          ),
        composerBuilder != null
            ? composerBuilder(context, widget.service, _dropBridge)
            : ChatComposer(
                service: widget.service,
                features: widget.features,
                dropBridge: _dropBridge,
              ),
      ],
      ),
    );
    // The drop highlight rides in a Stack above the body so the border
    // overlay never shifts the transcript layout (AC3).
    body = Stack(
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
    if (wallpaper == null) return body;
    return Stack(
      children: [
        Positioned.fill(child: Builder(builder: wallpaper)),
        Positioned.fill(child: body),
      ],
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
  /// Empty-session escape (issue #223): with no transcript rows loaded
  /// and nothing above the window there is nothing to page in, so no
  /// banner renders — even while the background count is still in flight
  /// or has failed. The terminal state likewise never renders for a
  /// header-only or single-record session (a "1 of 0"/"1 of 1" banner is
  /// nonsense over an already-complete transcript).
  bool _topBannerVisible(int? historyAbove) {
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
                  : widget.service.loadNewerHistory)
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
    final strings = FaChatStrings.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    final fileBrowserBuilder = widget.features.fileBrowser
        ? _fileBrowserBuilder
        : null;
    final appsToggleButton = FaChatHost.appsToggleButtonBuilder?.call(
      context,
      widget.service,
    );
    final dynamicMessagesButton = FaChatHost.dynamicMessagesButtonBuilder?.call(
      context,
      widget.service,
    );
    // The adaptive header's action list (issue #225): the list IS the
    // priority order and demotion removes from the tail, so the pinned
    // streaming stop comes first (never demoted — E2), then the primary
    // actions (files, trajectory), then the secondary ones (copy, the
    // host's ✦ and Apps widgets) that yield first on tight widths.
    final headerActions = <FaHeaderAction>[
      if (_isStreaming)
        FaHeaderAction(
          icon: Icons.stop,
          label: strings.chatAbortTooltip,
          onPressed: widget.service.abort,
          pinned: true,
        ),
      if (fileBrowserBuilder != null)
        FaHeaderAction(
          icon: Icons.folder_outlined,
          label: strings.chatFilesTooltip,
          onPressed: _openFiles,
        ),
      // Wide: the app-bar entry pushes the full-screen master-detail
      // route (AC1). Narrow uses the switcher below the app bar instead.
      if (widget.features.trajectory && isWide)
        FaHeaderAction(
          icon: Icons.timeline,
          label: strings.chatTrajectoryTooltip,
          onPressed: _openTrajectoryRoute,
        ),
      if (widget.features.copyTranscript)
        FaHeaderAction(
          icon: Icons.copy_outlined,
          label: strings.chatCopySessionTooltip,
          onPressed: _copySession,
        ),
      // The host's dynamic-messages affordance (issue #102: the ✦ button)
      // and apps-collapse toggle (issue #224: the Apps icon), rendered
      // exactly as the host styles them, demotable into the ⋮ menu.
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
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.showAppBar
          ? AppBar(
              // The ONE adaptive header (issue #225): project identity ·
              // title · model chip · actions · ⋮ overflow in one row.
              title: FaAdaptiveHeader(
                title: widget.title,
                projectIcon: widget.projectIcon,
                projectIconColor: widget.projectIconColor,
                projectLabel: widget.projectLabel,
                onProjectTap: widget.onProjectTap,
                chip: widget.modelChip,
                onChipTap: widget.onModelChipTap,
                chipMenuLabel: widget.chipMenuLabel,
                actions: headerActions,
              ),
              // Narrow: the Chat | Trajectory switcher sits in the app
              // bar's bottom slot and swaps the screen body.
              bottom: widget.features.trajectory && !isWide
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(52),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Center(child: _trajectorySwitcher(context)),
                      ),
                    )
                  : null,
            )
          : null,
      endDrawer: isWide || fileBrowserBuilder == null
          ? null
          : Drawer(
              width: kFaChatFilesPanelWidth,
              child: SafeArea(child: fileBrowserBuilder(context)),
            ),
      body: !isWide && widget.features.trajectory
          ? PopScope(
              canPop: !_showTrajectory,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) setState(() => _showTrajectory = false);
              },
              child: IndexedStack(
                index: _showTrajectory ? 1 : 0,
                children: [
                  _buildChatBody(context),
                  TrajectoryScreen(
                    controller: _trajectory,
                    loaded: _trajectoryLoaded,
                    scope: TrajectoryProjectionScope(
                      above: widget.service.historyAboveCount,
                      below: widget.service.historyBelowCount,
                      total: widget.service.historyTotalCount,
                    ),
                    onRecordActivate: (record) =>
                        widget.service.jumpToMessage(record.recordId),
                    onClose: () => setState(() => _showTrajectory = false),
                  ),
                ],
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildChatBody(context)),
                if (isWide &&
                    _filesPanelOpen &&
                    fileBrowserBuilder != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: kFaChatFilesPanelWidth,
                    child: fileBrowserBuilder(context),
                  ),
                ],
              ],
            ),
    );
  }

  /// The narrow Chat | Trajectory segmented switcher (app-bar bottom
  /// slot); swaps the screen body between the transcript and the
  /// trajectory page. Controller state lives at screen level, so the swap
  /// never loses scroll, selection, or filters (AC2/E6).
  Widget _trajectorySwitcher(BuildContext context) {
    final trajectoryStrings = TrajectoryStrings.of(context);
    final colors = FahColors.of(context);
    return SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: false,
          label: Text(trajectoryStrings.switcherChat),
        ),
        ButtonSegment(
          value: true,
          label: Text(trajectoryStrings.switcherTrajectory),
        ),
      ],
      selected: {_showTrajectory},
      showSelectedIcon: false,
      onSelectionChanged: (selection) =>
          setState(() => _showTrajectory = selection.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(BorderSide(color: colors.border)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? colors.panelAlt : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? colors.text : colors.dim,
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
