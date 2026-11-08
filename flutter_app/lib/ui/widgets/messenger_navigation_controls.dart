// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'messenger_nav_rail.dart';

/// SF-like sidebar.left glyph shared by the expanded and collapsed shell.
class MessengerSidebarLeftIcon extends StatelessWidget {
  const MessengerSidebarLeftIcon({super.key, this.color, this.size = 20});

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const ValueKey('sidebarLeftIcon'),
      size: Size.square(size),
      painter: _SidebarLeftPainter(
        color: color ?? IconTheme.of(context).color ?? Colors.black,
      ),
    );
  }
}

class _SidebarLeftPainter extends CustomPainter {
  const _SidebarLeftPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 20;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final frame = RRect.fromRectAndRadius(
      const Rect.fromLTWH(1.2, 2.2, 17.6, 15.6),
      const Radius.circular(4),
    );
    canvas.drawRRect(frame, paint);
    canvas.drawLine(const Offset(7.2, 3), const Offset(7.2, 17), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SidebarLeftPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// One predictable hide/show action with the same icon in both states —
/// rendered through the styleguide's ONE [FaIconActionButton] (36pt,
/// token fill + hairline, ink1 glyph), the same circle family as the
/// chat header actions and the Files band chrome, at the header band's
/// shared action centerline. Floating vs docked no longer changes the
/// style: ONE circle for every state.
class MessengerSidebarToggle extends StatelessWidget {
  const MessengerSidebarToggle({
    super.key,
    required this.expanded,
    required this.tooltip,
    required this.onPressed,
    this.floating = false,
  });

  final bool expanded;
  final String tooltip;
  final VoidCallback onPressed;

  /// Floating over the center content (collapsed rail state) → the glass
  /// underlay; docked on the titlebar band → the flat token state.
  final bool floating;

  @override
  Widget build(BuildContext context) => FaIconActionButton(
    // The composer's control scale — the header band's circle norm.
    diameter: FaIconActionButton.defaultDiameter,
    buttonKey: ValueKey(expanded ? 'chatSidebarCollapse' : 'chatSidebarExpand'),
    tooltip: tooltip,
    onPressed: onPressed,
    glass: floating,
    child: const MessengerSidebarLeftIcon(
      // The family glyph (FaIconActionButton.glyphSizeFor(36)): the
      // painter fills its canvas, so 18px is the band's ink norm.
      size: 18,
    ),
  );
}

/// One layout rhythm for primary sections and secondary filters. Wide rows
/// distribute space equally; compact rows scroll instead of overflowing.
class MessengerChipGroup extends StatelessWidget {
  const MessengerChipGroup({
    super.key,
    required this.children,
    this.itemsPerRow = 1,
    this.scroll = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  }) : assert(itemsPerRow > 0);

  final List<Widget> children;
  final int itemsPerRow;
  final bool scroll;
  final EdgeInsetsGeometry padding;

  static const double gap = 6;
  static const double compactItemWidth = 112;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: scroll ? _buildScrollRow() : _buildRows(),
    );
  }

  Widget _buildScrollRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) const SizedBox(width: gap),
            SizedBox(
              width: compactItemWidth,
              height: 32,
              child: children[index],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRows() {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += itemsPerRow) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
      final end = (start + itemsPerRow).clamp(0, children.length);
      rows.add(_buildRow(children.sublist(start, end)));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _buildRow(List<Widget> rowChildren) {
    return Row(
      children: [
        for (var index = 0; index < itemsPerRow; index++) ...[
          if (index > 0) const SizedBox(width: gap),
          _buildRowCell(rowChildren, index),
        ],
      ],
    );
  }

  Widget _buildRowCell(List<Widget> rowChildren, int index) {
    return Expanded(
      child: SizedBox(
        height: 32,
        child: index < rowChildren.length
            ? rowChildren[index]
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// Wide section tabs with one animated selection pill and stable text slots.
class MessengerTextTabGroup extends StatelessWidget {
  const MessengerTextTabGroup({
    super.key,
    required this.children,
    required this.selectedIndex,
  }) : assert(children.length > 0),
       assert(selectedIndex >= 0 && selectedIndex < children.length);

  static const double height = 46;

  final List<Widget> children;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = MessengerChipGroup.gap;
            final width =
                (constraints.maxWidth - gap * (children.length - 1)) /
                children.length;
            final duration = FaMotion.duration(
              context,
              const Duration(milliseconds: 200),
            );
            return Stack(
              children: [
                AnimatedPositioned(
                  key: const ValueKey('wideShellPrimarySelectionPill'),
                  duration: duration,
                  curve: Curves.easeInOutCubic,
                  left: selectedIndex * (width + gap),
                  width: width,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: tokens.accentSoft,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ),
                for (var index = 0; index < children.length; index++)
                  Positioned(
                    left: index * (width + gap),
                    width: width,
                    top: 0,
                    bottom: 0,
                    child: children[index],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One horizontal category/network control. Selected segments receive the
/// remaining width for their labels; all other actions keep fixed hit rects.
class MessengerFilterControl extends StatelessWidget {
  const MessengerFilterControl({
    super.key,
    required this.categories,
    required this.selectedIndex,
    this.extraActions = const <Widget>[],
    this.selectedExtraIndex,
    required this.trailing,
    this.highlightSelectedCategory = true,
    this.highlightSelectedExtra = true,
    this.glass = false,
  }) : assert(categories.length > 0),
       assert(selectedIndex >= 0 && selectedIndex < categories.length),
       assert(
         selectedExtraIndex == null ||
             (selectedExtraIndex >= 0 &&
                 selectedExtraIndex < extraActions.length),
       );

  static const double height = 44;
  static const double gap = 4;

  final List<Widget> categories;
  final int selectedIndex;

  /// Icon-only actions sharing the same fixed slots as unselected categories.
  final List<Widget> extraActions;

  /// The selected extra action, if that action group carries its own
  /// selection (for example the shell's section destinations). It shares the
  /// remaining width with the selected category.
  final int? selectedExtraIndex;

  /// Whether the selected category gets the selection pill and an expanded
  /// slot. An outer section can own the toolbar's one visible selection (for
  /// example Activity/Apps) while the filter value itself stays active but
  /// visually quiet.
  final bool highlightSelectedCategory;

  /// Whether the selected extra action gets an expanded slot. The shell keeps
  /// its implicit home destination quiet while a category owns the selection.
  final bool highlightSelectedExtra;

  /// Floating-glass treatment: translucent fill without the hairline slab
  /// border, for toolbars that sit on frosted chrome (iMessage-style
  /// underlay — rows ghost through behind the floating controls).
  final bool glass;

  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        // Real liquid-glass capsule in the glass direction — the jelly
        // refraction/specular comes from the styleguide FaSurface
        // (LiquidGlass), not a painted gradient. Opaque directions keep the
        // bordered slab. Inner padding stays 2 so segment geometry is
        // identical in both variants.
        child: glass
            ? FaSurface(
                key: const ValueKey('messengerFilterGlassCapsule'),
                glass: true,
                useBackdropGroup: true,
                color: tokens.surface1,
                tintAmount: .10,
                tintOpacity: .40,
                borderRadius: BorderRadius.circular(18),
                // 3px inner padding matches the boxed variant's border+2
                // (1px border + 2px padding): segment sizes and glyph
                // insets must be identical across variants.
                padding: const EdgeInsets.all(3),
                child: _SegmentLayout(
                  categories: categories,
                  extraActions: extraActions,
                  selectedIndex: selectedIndex,
                  selectedExtraIndex: selectedExtraIndex,
                  highlightSelectedCategory: highlightSelectedCategory,
                  highlightSelectedExtra: highlightSelectedExtra,
                  trailing: trailing,
                ),
              )
            : Container(
                key: const ValueKey('messengerFilterBoxedCapsule'),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: tokens.surface1.withValues(alpha: .62),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tokens.hairline),
                ),
                child: _SegmentLayout(
                  categories: categories,
                  extraActions: extraActions,
                  selectedIndex: selectedIndex,
                  selectedExtraIndex: selectedExtraIndex,
                  highlightSelectedCategory: highlightSelectedCategory,
                  highlightSelectedExtra: highlightSelectedExtra,
                  trailing: trailing,
                ),
              ),
      ),
    );
  }
}

/// Floating phone navigation with one shared surface and one moving pill.
/// Destinations keep their full slot as the hit target; only the inner pill
/// moves, so pointer and semantics geometry never depends on the animation.
class MessengerBottomNavigation extends StatelessWidget {
  const MessengerBottomNavigation({
    super.key,
    required this.children,
    required this.selectedIndex,
    this.widthLimit = maxWidth,
  }) : assert(children.length > 0),
       assert(selectedIndex >= 0 && selectedIndex < children.length);

  static const double height = 56;
  static const double maxWidth = 280;
  static const double expandedMaxWidth = 448;
  static const double horizontalMargin = 12;
  static const double bottomGap = 8;

  final List<Widget> children;
  final int selectedIndex;
  final double widthLimit;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final duration = FaMotion.duration(
      context,
      const Duration(milliseconds: 200),
    );
    return SizedBox(
      height: height,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widthLimit),
          child: FaSurface(
            glass: tokens.direction == FaVisualDirection.glass,
            useBackdropGroup: true,
            borderRadius: BorderRadius.circular(height / 2),
            color: tokens.surface1.withValues(
              alpha: tokens.direction == FaVisualDirection.glass ? .82 : .98,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final slotWidth = constraints.maxWidth / children.length;
                return Stack(
                  children: [
                    AnimatedPositioned(
                      key: const ValueKey('narrowShellSelectionPill'),
                      duration: duration,
                      curve: Curves.easeInOutCubic,
                      left: selectedIndex * slotWidth + 4,
                      width: slotWidth - 8,
                      top: 4,
                      bottom: 4,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: tokens.accentSoft,
                            shape: StadiumBorder(
                              side: BorderSide(
                                color: tokens.accent.withValues(alpha: .16),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    for (var index = 0; index < children.length; index++)
                      Positioned(
                        left: index * slotWidth,
                        width: slotWidth,
                        top: 0,
                        bottom: 0,
                        child: children[index],
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The narrow-shell compose action, using the same glass chrome as the dock.
class MessengerNewChatButton extends StatelessWidget {
  const MessengerNewChatButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  static const double size = 52;

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: SizedBox.square(
          dimension: size,
          child: FaSurface(
            glass: tokens.direction == FaVisualDirection.glass,
            useBackdropGroup: true,
            circular: true,
            borderRadius: BorderRadius.circular(size / 2),
            color: tokens.surface1.withValues(
              alpha: tokens.direction == FaVisualDirection.glass ? .72 : .98,
            ),
            onTap: onTap,
            child: Icon(Icons.edit_outlined, size: 22, color: tokens.accent),
          ),
        ),
      ),
    );
  }
}

/// One vertical icon-over-label destination in [MessengerBottomNavigation].
class MessengerBottomNavigationItem extends StatelessWidget {
  const MessengerBottomNavigationItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.badgeMuted = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? badge;
  final bool badgeMuted;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final foreground = selected ? tokens.accent : tokens.ink2;
    final showBadge = badge != null && badge! > 0;
    final destinationIcon = showBadge
        ? SizedBox(
            width: 34,
            height: 26,
            child: Stack(
              children: [
                Positioned(
                  left: 6,
                  top: 2,
                  child: Icon(icon, size: 22, color: foreground),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: MessengerRailBadge(count: badge!, muted: badgeMuted),
                ),
              ],
            ),
          )
        : Icon(icon, size: 22, color: foreground);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        selected: selected,
        child: Material(
          key: ValueKey('messengerPrimaryChip-$label'),
          color: Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  destinationIcon,
                  const SizedBox(height: 3),
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: FaMotion.duration(
                        context,
                        const Duration(milliseconds: 200),
                      ),
                      curve: Curves.easeInOutCubic,
                      style: typography.label.copyWith(
                        color: foreground,
                        fontSize: 11,
                        height: 1.15,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded category control shared by chat filters and the apps catalog.
class MessengerCategoryChip extends StatelessWidget {
  const MessengerCategoryChip({
    super.key,
    required this.chipKey,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.expanded = false,
    this.compact = false,
    this.iconOnly = false,
    this.textLed = false,
    this.animateLabel = false,
    this.selectionBackground = true,
  });

  final Key chipKey;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? badge;

  /// Fills the parent and ellipsizes the label in fixed filter grids.
  final bool expanded;

  /// Adapts density and icon+label layout without changing chip geometry or
  /// selected/unselected styling between primary and filter destinations.
  final bool compact;

  /// Icon-only segments still expose their label through tooltip/semantics.
  final bool iconOnly;

  /// Text-led selected segments: the icon stays visible and the label gets an
  /// expanded slot. Used by the dense shared sidebar toolbar so a selected
  /// destination communicates both its glyph and its name.
  final bool textLed;

  /// Restarts the two directional label fades only for a real filter change.
  final bool animateLabel;

  /// Filter groups paint one shared moving pill behind their categories.
  final bool selectionBackground;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final foreground = selected ? tokens.accent : tokens.ink2;
    final duration = FaMotion.duration(
      context,
      const Duration(milliseconds: 200),
    );
    final animatedLabel = _buildAnimatedLabel(
      _buildLabelText(foreground),
      duration,
    );
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        selected: selected,
        child: Material(
          key: chipKey,
          color: _backgroundColor(tokens),
          shape: StadiumBorder(side: _borderSide(tokens)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: SizedBox(
              height: 32,
              child: LayoutBuilder(
                builder: (context, constraints) => _buildLayout(
                  constraints,
                  duration,
                  animatedLabel,
                  foreground,
                  tokens,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Text _buildLabelText(Color foreground) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: foreground,
        fontSize: compact ? 11 : 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
  }

  Widget _buildAnimatedLabel(Text labelText, Duration duration) {
    final targetOpacity = iconOnly ? 0.0 : 1.0;
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          begin: animateLabel ? 1 - targetOpacity : targetOpacity,
          end: targetOpacity,
        ),
        duration: duration,
        curve: Curves.easeInOutCubic,
        builder: (context, opacity, child) =>
            _buildLabelOpacity(opacity, labelText),
      ),
    );
  }

  Widget _buildLabelOpacity(double opacity, Text labelText) {
    return opacity <= .001
        ? const SizedBox.shrink()
        : Opacity(opacity: opacity, child: labelText);
  }

  Color _backgroundColor(FaDesignTokens tokens) {
    if (selected && selectionBackground) {
      return tokens.accent.withValues(alpha: .12);
    }
    if (iconOnly || !selectionBackground) return Colors.transparent;
    return tokens.surface1.withValues(alpha: .55);
  }

  BorderSide _borderSide(FaDesignTokens tokens) {
    if (selected && selectionBackground) {
      return BorderSide(color: tokens.accent.withValues(alpha: .18));
    }
    if (iconOnly || !selectionBackground) return BorderSide.none;
    return BorderSide(color: tokens.hairline);
  }

  Widget _buildLayout(
    BoxConstraints constraints,
    Duration duration,
    Widget animatedLabel,
    Color foreground,
    FaDesignTokens tokens,
  ) {
    if (constraints.maxWidth < 12) return const SizedBox.shrink();
    // Keep intermediate narrow slots overflow-free during directional fades.
    final dense = constraints.maxWidth < 32;
    return Padding(
      padding: _horizontalPadding(dense),
      child: Row(
        mainAxisSize: _rowMainAxisSize(),
        mainAxisAlignment: _rowMainAxisAlignment(),
        children: _rowChildren(
          dense,
          constraints.maxWidth,
          duration,
          animatedLabel,
          foreground,
          tokens,
        ),
      ),
    );
  }

  EdgeInsets _horizontalPadding(bool dense) {
    if (iconOnly) return EdgeInsets.zero;
    if (dense) return EdgeInsets.zero;
    return EdgeInsets.symmetric(horizontal: textLed ? 4 : (compact ? 6 : 14));
  }

  MainAxisSize _rowMainAxisSize() =>
      expanded || compact ? MainAxisSize.max : MainAxisSize.min;

  MainAxisAlignment _rowMainAxisAlignment() => iconOnly || (textLed && compact)
      ? MainAxisAlignment.center
      : MainAxisAlignment.start;

  double _iconSize(bool dense, double maxWidth) {
    if (dense) return maxWidth < 14 ? 10.0 : 12.0;
    return compact ? 15 : 16;
  }

  double _iconSpacing(bool dense) => iconOnly || dense ? 0 : (compact ? 4 : 6);

  Widget _labelContainer(Widget animatedLabel, Duration duration) {
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeInOutCubic,
      width: iconOnly ? 0 : null,
      child: animatedLabel,
    );
  }

  Widget _labelSlot(Widget animatedLabel, Duration duration) {
    if (!(expanded || compact)) return animatedLabel;
    final child = _labelContainer(animatedLabel, duration);
    // Flexible lets the centered text-led group hug its label.
    if (textLed && compact) return Flexible(child: child);
    return Expanded(child: child);
  }

  List<Widget> _rowChildren(
    bool dense,
    double maxWidth,
    Duration duration,
    Widget animatedLabel,
    Color foreground,
    FaDesignTokens tokens,
  ) {
    return [
      // Balance the dormant expanded label so icon-only glyphs stay centered.
      if (iconOnly) const Spacer(),
      Icon(icon, size: _iconSize(dense, maxWidth), color: foreground),
      AnimatedContainer(
        duration: duration,
        curve: Curves.easeInOutCubic,
        width: _iconSpacing(dense),
      ),
      _labelSlot(animatedLabel, duration),
      ..._badgeWidgets(dense, tokens),
    ];
  }

  int? get _visibleBadge {
    final count = badge;
    if (count == null || count <= 0) return null;
    return count;
  }

  String _badgeLabel(int count) => count > 99 ? '99+' : '$count';

  List<Widget> _badgeWidgets(bool dense, FaDesignTokens tokens) {
    if (dense) return const [];
    final count = _visibleBadge;
    if (count == null) return const [];
    return [
      const SizedBox(width: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: tokens.accent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _badgeLabel(count),
          style: TextStyle(
            color: tokens.accentInk,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ];
  }
}

typedef _SegmentPosition = ({double left, double width});
typedef _SegmentGeometry = ({
  double gap,
  double slot,
  double selectedWidth,
  double selectedExtraWidth,
  bool selectedCategoryVisible,
  bool selectedExtraVisible,
});
typedef _SegmentPositions = ({
  List<_SegmentPosition> categories,
  List<_SegmentPosition> extras,
});

/// The segment slot layout shared by both MessengerFilterControl capsules:
/// fixed icon slots plus one or two expanded text slots and a moving
/// selection pill. Pure layout — the capsule surface is the parent's job.
class _SegmentLayout extends StatelessWidget {
  const _SegmentLayout({
    required this.categories,
    required this.extraActions,
    required this.selectedIndex,
    required this.selectedExtraIndex,
    required this.highlightSelectedCategory,
    required this.highlightSelectedExtra,
    required this.trailing,
  });

  final List<Widget> categories;
  final List<Widget> extraActions;
  final int selectedIndex;
  final int? selectedExtraIndex;
  final bool highlightSelectedCategory;
  final bool highlightSelectedExtra;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final duration = FaMotion.duration(
          context,
          const Duration(milliseconds: 200),
        );
        final geometry = _geometry(constraints);
        final positions = _positions(geometry);
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            if (geometry.selectedCategoryVisible)
              _selectionPill(
                positions.categories[selectedIndex],
                duration,
                tokens,
              ),
            ..._categorySlots(positions.categories, duration),
            ..._extraSlots(positions.extras, duration),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: geometry.slot,
              child: trailing,
            ),
          ],
        );
      },
    );
  }

  _SegmentGeometry _geometry(BoxConstraints constraints) {
    // The trailing selector occupies the final fixed slot.
    final controlCount = categories.length + extraActions.length + 1;
    final selectedExtraVisible =
        selectedExtraIndex != null && highlightSelectedExtra;
    final selectedCategoryVisible = highlightSelectedCategory;
    final expandedCount =
        (selectedCategoryVisible ? 1 : 0) + (selectedExtraVisible ? 1 : 0);
    final fixedCount = controlCount - expandedCount;
    final gap = constraints.maxWidth >= 300 ? MessengerFilterControl.gap : 1.0;
    final widths = _selectedWidths(
      constraints,
      controlCount,
      fixedCount,
      gap,
      selectedCategoryVisible,
      selectedExtraVisible,
    );
    return (
      gap: gap,
      slot: widths.slot,
      selectedWidth: widths.selectedWidth,
      selectedExtraWidth: widths.selectedExtraWidth,
      selectedCategoryVisible: selectedCategoryVisible,
      selectedExtraVisible: selectedExtraVisible,
    );
  }

  ({double slot, double selectedWidth, double selectedExtraWidth})
  _selectedWidths(
    BoxConstraints constraints,
    int controlCount,
    int fixedCount,
    double gap,
    bool selectedCategoryVisible,
    bool selectedExtraVisible,
  ) {
    const minSelectedWidth = 64.0;
    const minSelectedExtraWidth = 72.0;
    final minimumExpandedWidth =
        (selectedCategoryVisible ? minSelectedWidth : 0.0) +
        (selectedExtraVisible ? minSelectedExtraWidth : 0.0);
    final slot =
        ((constraints.maxWidth -
                    gap * (controlCount - 1) -
                    minimumExpandedWidth) /
                fixedCount)
            .clamp(12.0, 36.0);
    final expandedBudget =
        (constraints.maxWidth - gap * (controlCount - 1) - slot * fixedCount)
            .clamp(0.0, constraints.maxWidth);
    final selectedWidth = !selectedCategoryVisible
        ? 0.0
        : selectedExtraVisible
        ? expandedBudget *
              minSelectedWidth /
              (minSelectedWidth + minSelectedExtraWidth)
        : expandedBudget;
    final selectedExtraWidth = !selectedExtraVisible
        ? 0.0
        : selectedCategoryVisible
        ? expandedBudget *
              minSelectedExtraWidth /
              (minSelectedWidth + minSelectedExtraWidth)
        : expandedBudget;
    return (
      slot: slot,
      selectedWidth: selectedWidth,
      selectedExtraWidth: selectedExtraWidth,
    );
  }

  _SegmentPositions _positions(_SegmentGeometry geometry) {
    final positions = <_SegmentPosition>[];
    var left = 0.0;
    for (var index = 0; index < categories.length; index++) {
      final width = index == selectedIndex && geometry.selectedCategoryVisible
          ? geometry.selectedWidth
          : geometry.slot;
      positions.add((left: left, width: width));
      left += width + geometry.gap;
    }
    final extraPositions = <_SegmentPosition>[];
    for (var index = 0; index < extraActions.length; index++) {
      final width = index == selectedExtraIndex && geometry.selectedExtraVisible
          ? geometry.selectedExtraWidth
          : geometry.slot;
      extraPositions.add((left: left, width: width));
      left += width + geometry.gap;
    }
    return (categories: positions, extras: extraPositions);
  }

  Widget _selectionPill(
    _SegmentPosition selected,
    Duration duration,
    FaDesignTokens tokens,
  ) {
    return AnimatedPositioned(
      key: const ValueKey('chatFilterSelectionPill'),
      duration: duration,
      curve: Curves.easeInOutCubic,
      left: selected.left,
      width: selected.width,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: tokens.accent.withValues(alpha: .12),
            shape: StadiumBorder(
              side: BorderSide(color: tokens.accent.withValues(alpha: .18)),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _categorySlots(
    List<_SegmentPosition> positions,
    Duration duration,
  ) {
    return [
      for (var index = 0; index < positions.length; index++)
        AnimatedPositioned(
          key: ValueKey('chatFilterSlot-$index'),
          duration: duration,
          curve: Curves.easeInOutCubic,
          left: positions[index].left,
          width: positions[index].width,
          top: 0,
          bottom: 0,
          child: categories[index],
        ),
    ];
  }

  List<Widget> _extraSlots(
    List<_SegmentPosition> positions,
    Duration duration,
  ) {
    return [
      for (var index = 0; index < positions.length; index++)
        AnimatedPositioned(
          key: ValueKey('chatFilterExtraActionSlot-$index'),
          duration: duration,
          curve: Curves.easeInOutCubic,
          left: positions[index].left,
          width: positions[index].width,
          top: 0,
          bottom: 0,
          child: extraActions[index],
        ),
    ];
  }
}
