// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of wide_layout_shell.dart: the build/_buildBody presentation family
// (the _buildShell* scaffold, the _buildWide* wide-body builders and the
// presented-surface widgets) lives here so the main file stays under the
// 2800-line guard. Same library, so private members resolve.

part of 'wide_layout_shell.dart';

/// Shell chrome and wide-body presentation: scaffold + bottom nav, the
/// narrow body and its navigation, the animated wide geometry/sidebar/
/// center columns, and the presented app/activity surfaces.
extension _WideLayoutShellPresentation on _WideLayoutShellState {
  /// A presented surface covers the narrow shell (and animates out over
  /// its exit), hiding the bottom chrome while it is on screen.
  bool _presentationCoversNarrow(bool narrow) =>
      narrow && (_presentationMounted || _presentationReveal.value > 0);

  /// The floating Duo New-chat rail rides the chats-family sections while
  /// no presented surface owns the screen.
  bool _showsDuoNewChatRail(double duoRailWidth) =>
      duoRailWidth > 0 &&
      !_presentationMounted &&
      const {
        _WideShellSection.chats,
        _WideShellSection.local,
        _WideShellSection.activity,
      }.contains(_section);

  /// Scaffold supplies both the required Material ancestor and a snack
  /// host now that no permanent launcher pane owns one. List/Activity
  /// panels need an explicit content lane for their New-chat rail. Apps
  /// and standalone Settings own their SafeArea and must not be inset twice.
  Widget _buildShellScaffold(
    FahColors colors, {
    required bool narrow,
    required bool presentationCoversNarrow,
    required bool duoNewChat,
    required double duoRailWidth,
  }) {
    return Scaffold(
      backgroundColor: colors.bg,
      extendBody: !presentationCoversNarrow && narrow,
      body: Stack(
        children: [
          Positioned.fill(
            child: _buildShellBodyLane(
              colors,
              narrow: narrow,
              duoNewChat: duoNewChat,
              duoRailWidth: duoRailWidth,
            ),
          ),
          if (duoNewChat)
            Positioned(
              top: FaDuoControlRail.topOf(context),
              right: 0,
              bottom: FaDuoControlRail.topOf(context),
              width: duoRailWidth,
              child: FaDuoControlRail(leading: [_duoNewChatButton(narrow)]),
            ),
        ],
      ),
      bottomNavigationBar: _shellBottomNavigation(
        narrow: narrow,
        presentationCoversNarrow: presentationCoversNarrow,
      ),
      floatingActionButton: _narrowNewChatFab(
        narrow: narrow,
        duoNewChat: duoNewChat,
        presentationCoversNarrow: presentationCoversNarrow,
      ),
    );
  }

  /// The New-chat button the Duo rail leads with (the key tracks the
  /// surface: the narrow shell reuses the dock's key).
  MessengerNewChatButton _duoNewChatButton(bool narrow) {
    return MessengerNewChatButton(
      key: ValueKey(narrow ? 'narrowShellNewChat' : 'messengerNewButton'),
      onTap: () => unawaited(_newSession()),
      label: context.l10n.wideChatFallbackTitle,
    );
  }

  /// The shell's body lane: the section surface, widened by the Duo rail's
  /// lane only where the narrow dock New-chat rides it.
  Widget _buildShellBodyLane(
    FahColors colors, {
    required bool narrow,
    required bool duoNewChat,
    required double duoRailWidth,
  }) {
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

  /// The presented surface suppresses the narrow dock entirely.
  Widget? _shellBottomNavigation({
    required bool narrow,
    required bool presentationCoversNarrow,
  }) {
    return presentationCoversNarrow
        ? null
        : (narrow ? _buildNarrowNavigation() : null);
  }

  /// The dock's New-chat FAB only when the Duo rail is not already on the
  /// chats home.
  MessengerNewChatButton? _narrowNewChatFab({
    required bool narrow,
    required bool duoNewChat,
    required bool presentationCoversNarrow,
  }) {
    return narrow &&
            !duoNewChat &&
            !presentationCoversNarrow &&
            _section == _WideShellSection.chats
        ? MessengerNewChatButton(
            key: const ValueKey('narrowShellNewChat'),
            onTap: () => unawaited(_newSession()),
            label: context.l10n.wideChatFallbackTitle,
          )
        : null;
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

  Widget _buildBody(FahColors colors) {
    final tokens = FaDesignTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return TweenAnimationBuilder<double>(
          tween: Tween(end: _sidebarCollapsed ? 1.0 : 0.0),
          duration: FaMotion.duration(
            context,
            _WideLayoutShellState._sidebarCollapseDuration,
          ),
          curve: Curves.easeInOutCubic,
          builder: (context, progress, _) =>
              _buildWideBodyGeometry(colors, tokens, constraints, progress),
        );
      },
    );
  }

  /// The wide body's animated geometry. One value drives all visible
  /// geometry. TweenAnimationBuilder starts at its end on first mount, and
  /// an unchanged zero target makes persisted divider resize direct rather
  /// than animated.
  Widget _buildWideBodyGeometry(
    FahColors colors,
    FaDesignTokens tokens,
    BoxConstraints constraints,
    double progress,
  ) {
    final sidebarWidth =
        _sidebarWidth +
        (_WideLayoutShellState._collapsedSidebarWidth - _sidebarWidth) *
            progress;
    final contentCollapsed = progress >= .5;
    // The glass card keeps 8pt floating margins on the window edges
    // (top, bottom, right) — the content must live INSIDE them,
    // never under the clip (the old -8 let rows bleed 8px past the
    // card's right edge). The LEADING margin is shared with the
    // rail: its trailing 8pt margin-as-seam IS the card gutter
    // (owner: the rail↔sidebar gap halves to 8pt total), so the
    // leading margin is 0 and the content fills the rest.
    final contentWidth =
        (contentCollapsed
            ? _WideLayoutShellState._collapsedSidebarWidth
            : _sidebarWidth) -
        8;
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
    final toggleShift = _WideLayoutShellState._isMacOS ? 60 * progress : 0.0;
    // The rail's floating glass card (8pt margins on every side,
    // 1:1 with the collapsed chats panel) + its trailing 8pt
    // margin-as-seam precede the sidebar column, so floating
    // chrome anchored to the sidebar's edges must clear the
    // rail's footprint.
    final railLeading = MessengerNavRail.width + MessengerNavRail.seam * 2;
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
    // Built once per geometry pass (not per reveal tick), exactly like the
    // pre-decomposition closure capture — the sidebar panel must not
    // restart its internal animations on every reveal-animation frame.
    final sidebarContent = _buildSidebar(colors, collapsed: contentCollapsed);
    return AnimatedBuilder(
      animation: _presentationReveal,
      builder: (context, _) => _buildWideBodyStack(
        colors,
        tokens,
        constraints,
        progress,
        sidebarWidth: sidebarWidth,
        sidebarContent: sidebarContent,
        contentWidth: contentWidth,
        contentCollapsed: contentCollapsed,
        contentOpacity: contentOpacity,
        contentInTransition: contentInTransition,
        toggleLeft: toggleLeft,
        railLeading: railLeading,
      ),
    );
  }

  /// The wide body's Stack: the rail/sidebar/center row, the floating
  /// toggle, the pane handle and the presentation overlays.
  Widget _buildWideBodyStack(
    FahColors colors,
    FaDesignTokens tokens,
    BoxConstraints constraints,
    double progress, {
    required double sidebarWidth,
    required Widget sidebarContent,
    required double contentWidth,
    required bool contentCollapsed,
    required double contentOpacity,
    required bool contentInTransition,
    required double toggleLeft,
    required double railLeading,
  }) {
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
        _buildWideBodyRow(
          colors,
          tokens,
          reveal,
          sidebarWidth: sidebarWidth,
          sidebarContent: sidebarContent,
          contentWidth: contentWidth,
          contentCollapsed: contentCollapsed,
          contentOpacity: contentOpacity,
          contentInTransition: contentInTransition,
          slotVisible: slotVisible,
          floatingPanel: floatingPanel,
        ),
        _buildWideSidebarToggle(toggleLeft),
        if (!_sidebarCollapsed && progress == 0)
          _buildWidePaneResizeHandle(railLeading, sidebarWidth),
        ..._buildWidePresentationOverlays(
          presentation,
          full: full,
          floatingPanel: floatingPanel,
          reveal: reveal,
        ),
      ],
    );
  }

  /// The wide body's rail / sidebar / center row plus the docked
  /// presentation slot.
  Widget _buildWideBodyRow(
    FahColors colors,
    FaDesignTokens tokens,
    double reveal, {
    required double sidebarWidth,
    required Widget sidebarContent,
    required double contentWidth,
    required bool contentCollapsed,
    required double contentOpacity,
    required bool contentInTransition,
    required bool slotVisible,
    required bool floatingPanel,
  }) {
    return Row(
      children: [
        _buildNavRail(),
        _buildWideSidebarColumn(
          colors,
          tokens,
          sidebarWidth: sidebarWidth,
          sidebarContent: sidebarContent,
          contentWidth: contentWidth,
          contentOpacity: contentOpacity,
          contentInTransition: contentInTransition,
        ),
        Expanded(child: _buildWideCenterColumn(colors, tokens)),
        if (slotVisible && !floatingPanel) _buildDockedPresentationSlot(reveal),
      ],
    );
  }

  /// The sidebar's floating glass card: the collapsed pane keeps its
  /// 8pt gutter contract while the sidebar content stays live through
  /// the collapse animation.
  Widget _buildWideSidebarColumn(
    FahColors colors,
    FaDesignTokens tokens, {
    required double sidebarWidth,
    required Widget sidebarContent,
    required double contentWidth,
    required double contentOpacity,
    required bool contentInTransition,
  }) {
    return SizedBox(
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
                child: Opacity(opacity: contentOpacity, child: sidebarContent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The center panel's frame: the Apps overview paints its own full-bled
  /// slab, so it keeps square corners where the chat panels stay rounded.
  Widget _buildWideCenterColumn(FahColors colors, FaDesignTokens tokens) {
    return _desktopPanelFrame(
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
          : const BorderRadius.horizontal(right: Radius.circular(18)),
      // The collapsed toggle is floating chrome, never a
      // participant in the transcript/header layout.
      child: _buildCenterSurface(colors),
    );
  }

  /// One action follows the animated boundary; the header trees
  /// only crossfade content and never duplicate the toggle.
  Widget _buildWideSidebarToggle(double toggleLeft) {
    return Positioned(
      left: toggleLeft,
      // One shared action centerline in expanded and collapsed states:
      // y=35 with the chat trajectory/copy and the docked Files
      // X/search/overflow controls.
      top: _WideLayoutShellState._isMacOS ? 17 : 19,
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
        onPressed: () => _updateShell(() {
          _sidebarCollapsed = !_sidebarCollapsed;
          _sidebarStateBeforePresentation = null;
        }),
      ),
    );
  }

  /// The shared pane handle, CENTERED on the panel edge:
  /// the glass card keeps an 8pt outer margin, so its
  /// right edge sits at sidebarWidth - 8 — the old handle
  /// hung 12pt off that edge, floating over the seam
  /// (owner call). The hit surface still straddles the
  /// card's padding band and the gutter; the drag
  /// contract (delta → clamp → persist on settle) is
  /// untouched.
  Widget _buildWidePaneResizeHandle(double railLeading, double sidebarWidth) {
    return Positioned(
      left: railLeading + sidebarWidth - 16,
      top: 0,
      bottom: 0,
      child: FaPaneResizeHandle(
        key: kSidebarDragHandleKey,
        onDragUpdate: (dx) => _updateShell(() {
          _sidebarWidth = (_sidebarWidth + dx).clamp(
            SessionUiPrefsStore.minSidebarWidth,
            SessionUiPrefsStore.maxSidebarWidth,
          );
        }),
        onDragEnd: _onSidebarDragEnd,
        onDragCancel: _onSidebarDragEnd,
      ),
    );
  }

  /// The presentation overlay layers: the slide-over floating panel on a
  /// tight window, the running-apps backdrop, and the running-apps dock.
  List<Widget> _buildWidePresentationOverlays(
    MessengerAppPresentation? presentation, {
    required bool full,
    required bool floatingPanel,
    required double reveal,
  }) {
    return [
      if (floatingPanel) _buildFloatingPresentationSlot(reveal),
      ..._buildWideRunningAppsBackdrop(presentation, full),
      if (_runningApps.isNotEmpty)
        Positioned(
          right: FaDuoControlRail.widthOf(context),
          top: 72,
          bottom: 72,
          child: Center(child: _buildRunningAppsDock()),
        ),
    ];
  }

  /// The running-apps backdrop: kept warm (offstage) while an ordinary
  /// presentation rides the slot, full-screen when the presentation went
  /// full.
  List<Widget> _buildWideRunningAppsBackdrop(
    MessengerAppPresentation? presentation,
    bool full,
  ) {
    return [
      if (presentation == null && _runningApps.isNotEmpty)
        Positioned.fill(child: Offstage(child: _buildRunningAppsStack())),
      if (presentation != null && full)
        Positioned.fill(child: _buildRunningAppsStack()),
    ];
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
      onFullScreen: () => _updateShell(() {
        presentation.fullScreen = !presentation.fullScreen;
      }),
      onPin: () => _updateShell(() {
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
      // The devices tree lives in the sidebar column (the Local panel's
      // slot); the message column keeps the chat.
      _WideShellSection.devices => _buildChatArea(colors),
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
}
