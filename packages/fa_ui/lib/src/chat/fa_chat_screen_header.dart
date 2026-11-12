part of 'fa_chat_screen.dart';

/// Floating and stacked chat header layout, including the Duo rail.
extension _FaChatScreenHeader on _FaChatScreenState {
  /// Compact foldable priority: keep Trajectory and Files one tap away;
  /// demote only Copy session. Rebuild the small action records instead of
  /// relying on positional indices (streaming Stop and host buttons vary).
  List<FaHeaderAction> _compactDuoHeaderActions(
    List<FaHeaderAction> source,
    FaChatStrings strings,
  ) {
    FaHeaderAction copy(FaHeaderAction action, {required bool pinned}) =>
        action.widget != null
        ? FaHeaderAction.widget(
            key: action.key,
            widget: action.widget!,
            label: action.label,
            onPressed: action.onPressed,
            pinned: pinned,
          )
        : FaHeaderAction(
            key: action.key,
            icon: action.icon,
            label: action.label,
            onPressed: action.onPressed,
            pinned: pinned,
          );
    final primary = <FaHeaderAction>[];
    final copyActions = <FaHeaderAction>[];
    for (final action in source) {
      if (action.label == strings.chatCopySessionTooltip) {
        copyActions.add(action);
      } else {
        primary.add(copy(action, pinned: action.pinned));
      }
    }
    return [...primary, ...copyActions];
  }

  Widget _buildFloatingGlassHeader(
    bool isWide,
    List<FaHeaderAction> headerActions,
  ) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: _onGlassChromeResized,
      child: SizeChangedLayoutNotifier(
        child: SizedBox(
          key: _glassHeaderMeasureKey,
          child: SafeArea(
            bottom: false,
            // This header belongs to the chat PANE, not the display edge.
            // On Duo the outer shell already handles the fold/landscape
            // insets. Re-applying them here moves ⋮ 84pt into the chat,
            // on top of the model chip and its popup.
            left: false,
            right: false,
            // Keep the avatar + centered title pill stacked at every width.
            // Narrow routes add Back independently; actions still demote into
            // the adaptive overflow instead of switching to the compact bar.
            child: _buildStackedGlassHeader(
              headerActions,
              isWide: isWide,
              showBack:
                  !isWide &&
                  !FaDuoControlRail.isActive(context) &&
                  Navigator.canPop(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStackedGlassHeader(
    List<FaHeaderAction> headerActions, {
    required bool isWide,
    bool showBack = false,
  }) {
    final tokens = FaDesignTokens.of(context);
    return Padding(
      key: const ValueKey('faChatFloatingHeader'),
      // The canonical narrow bar strip: 6 + 91 + 6 (FaFloatingHeaderBar).
      padding: const EdgeInsets.symmetric(
        horizontal: FaFloatingHeaderBar.padHorizontal,
        vertical: FaFloatingHeaderBar.padVertical,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Title sizing retains the original side budget. The action row
          // itself may use all safe space to the right of the centered avatar
          // so a long model id is not truncated by an artificial 38% cap.
          final duoRailWidth = FaDuoControlRail.widthOf(context);
          final duoRailActive = duoRailWidth > 0;
          final contentWidth = math.max(
            0.0,
            constraints.maxWidth - duoRailWidth,
          );
          final titleSideWidth = math.min(360.0, contentWidth * .38);
          final compactActions =
              contentWidth < 560 || (isWide && contentWidth < 600);
          final orderedActions = compactActions || duoRailActive
              ? _compactDuoHeaderActions(
                  headerActions,
                  FaChatStrings.of(context),
                )
              : headerActions;
          final actionWidth = duoRailActive
              ? 0.0
              : compactActions
              ? math.max(0.0, contentWidth - (showBack ? 72 : 40))
              : math.max(0.0, contentWidth / 2 - 18 - 12);
          // A Duo pane is compact even when the unfolded DISPLAY is wide.
          // The chip reserves only its icon until its measured text lane
          // can actually hold the label (chipMinWidth..chipMaxWidth growth
          // otherwise lets a 240pt text chip displace the session ⋮).
          final chipReserve = math.min(
            compactActions ? 36.0 : 112.0,
            math.min(240.0, actionWidth),
          );
          // Do not grow a compact chip back into a 240pt text label after
          // fit. That growth pushes ⋮ off the right edge on the full Duo
          // shell (the old `Row` clipped it without an overflow error).
          final headerChipWidth = math.min(
            compactActions ? 36.0 : 240.0,
            actionWidth,
          );
          // A fixed, viewport-derived pill width keeps geometry identical
          // across direction-specific font families while remaining a
          // centered identity control rather than a full-width app bar.
          final titleWidth = math.min(
            320.0,
            math.max(200.0, contentWidth - 2 * (titleSideWidth + 12)),
          );
          final builtAvatar = widget.avatarBuilder?.call(context, 'assistant');
          return SizedBox(
            // FaFloatingHeaderBar.contentHeight: 11 (identity air) + 36
            // (avatar) + 4 + 40 (pill): the avatar's center (11 + 18 = 29)
            // sits ON the action row's center (Positioned top 9 + 40/2) —
            // one centerline for the whole stacked glass header, and the
            // circle clears the band's top edge (the old top-0 avatar read
            // clipped at the window edge). Every narrow header strip shares
            // this canonical bar geometry (see FaFloatingHeaderBar).
            height: FaFloatingHeaderBar.contentHeight,
            child: Stack(
              // The vertical rail extends below the ordinary header without
              // inflating its measured extent or the transcript's top melt.
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: duoRailWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The ONE circular chrome (FaHeaderCircularAction —
                      // the painter behind FaIconActionButton): token
                      // surface fill + hairline, ink1 glyph — not a third
                      // tinted-glass disc.
                      Padding(
                        padding: const EdgeInsets.only(
                          top: FaFloatingHeaderBar.iconTop,
                        ),
                        child: FaHeaderCircularAction(
                          key: const ValueKey('faChatHeaderAvatar'),
                          dimension: FaFloatingHeaderBar.actionDimension,
                          // Floating identity circle on the header
                          // backdrop: the glass underlay state.
                          glass: true,
                          child:
                              builtAvatar ??
                              Icon(
                                widget.projectIcon ?? Icons.person_rounded,
                                size: widget.projectIcon == null ? 25 : 18,
                                color: widget.projectIconColor ?? tokens.ink1,
                              ),
                        ),
                      ),
                      const SizedBox(height: FaFloatingHeaderBar.iconTitleGap),
                      FaSurface(
                        key: const ValueKey('faChatHeaderTitlePill'),
                        glass: true,
                        useBackdropGroup: true,
                        color: tokens.surface1,
                        borderRadius: BorderRadius.circular(14),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        onTap: widget.onProjectTap,
                        child: SizedBox(
                          width: titleWidth,
                          height: FaFloatingHeaderBar.pillHeight,
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    if (widget.projectLabel case final label?
                                        when label.isNotEmpty)
                                      Text(
                                        label,
                                        key: const ValueKey(
                                          'faChatHeaderProjectLabel',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: tokens.ink2,
                                          fontSize: 10,
                                          height: 1.2,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    Text(
                                      widget.title,
                                      key: const ValueKey(
                                        'faChatHeaderSessionLabel',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: tokens.ink1,
                                        fontSize: 13,
                                        height: 1.25,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (widget.onProjectTap != null)
                                Icon(
                                  Icons.chevron_right,
                                  size: 15,
                                  color: tokens.ink2,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (showBack)
                  Positioned(
                    top: FaFloatingHeaderBar.actionBandTop,
                    left: 0,
                    width: FaFloatingHeaderBar.pillHeight,
                    height: FaFloatingHeaderBar.pillHeight,
                    child: _glassHeaderAction(
                      IconTheme.merge(
                        data: const IconThemeData(size: 18),
                        child: const BackButton(
                          key: ValueKey('faChatHeaderBack'),
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!duoRailActive)
                  Positioned(
                    top: FaFloatingHeaderBar.actionBandTop,
                    right: 0,
                    width: actionWidth,
                    height: FaFloatingHeaderBar.pillHeight,
                    child: FaAdaptiveHeader(
                      visualDensity: VisualDensity.compact,
                      overflowMenuKey: const ValueKey('faChatHeaderOverflow'),
                      chip: widget.modelChip,
                      chipMinWidth: chipReserve,
                      chipMaxWidth: headerChipWidth,
                      compactActionLimit: compactActions ? 2 : null,
                      onChipTap: widget.onModelChipTap,
                      chipMenuLabel: widget.chipMenuLabel,
                      actions: orderedActions,
                      iconSize: 18,
                      actionGap: 0,
                      menuColor: tokens.surface2,
                      actionBandBuilder:
                          (context, actions, overflowItems, onSelected) =>
                              FaIconActionBand<String>(
                                actions: actions,
                                overflowItems: overflowItems,
                                onOverflowSelected: onSelected,
                                overflowMenuKey: const ValueKey(
                                  'faChatHeaderOverflow',
                                ),
                                overflowTooltip: FaChatStrings.of(
                                  context,
                                ).chatMoreTooltip,
                                menuColor: tokens.surface2,
                                glass: true,
                              ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A hit-testable Duo rail hosted by the full-height chat stack.
  ///
  /// Keeping this inside the measured header paints correctly with Clip.none
  /// but leaves every control below the header outside its hit-test bounds.
  Widget _buildDuoFloatingRail(
    List<FaHeaderAction> headerActions,
    double right, {
    required bool showBack,
  }) {
    final media = MediaQuery.of(context);
    final top = media.padding.top + 6 + FaDuoControlRail.expandedTopOf(context);
    final bottom =
        media.padding.bottom + math.max(18.0, _glassComposerExtent + 18);
    return Positioned(
      top: top,
      right: right,
      width: FaDuoControlRail.widthOf(context),
      height: math.max(0.0, media.size.height - top - bottom),
      child: FaDuoControlRail(
        key: const ValueKey('faChatDuoControlRail'),
        leading: [
          if (showBack)
            _glassHeaderAction(
              IconTheme.merge(
                data: const IconThemeData(size: 18),
                child: const BackButton(
                  key: ValueKey('faChatHeaderBack'),
                  style: ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ),
            ),
          if (widget.modelChip case final chip?)
            SizedBox.square(
              dimension: FaDuoControlRail.actionDimension,
              child: chip,
            ),
        ],
        actions: _compactDuoHeaderActions(
          headerActions,
          FaChatStrings.of(context),
        ),
        overflowMenuKey: const ValueKey('faChatHeaderOverflow'),
        overflowTooltip: FaChatStrings.of(context).chatMoreTooltip,
        menuColor: FaDesignTokens.of(context).surface2,
      ),
    );
  }

  /// The chat bar's circular action chrome: the ONE control scale (the
  /// 36pt [FaIconActionButton.defaultDiameter] — the sidebar toggle's and
  /// the Files band's circle) floating on the header backdrop with no
  /// surface of its own: the glass underlay state (owner rule).
  Widget _glassHeaderAction(Widget button) => FaHeaderCircularAction(
    dimension: FaIconActionButton.defaultDiameter,
    glass: true,
    child: button,
  );
}
