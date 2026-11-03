// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

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
      final rowChildren = children.sublist(start, end);
      rows.add(
        Row(
          children: [
            for (var index = 0; index < itemsPerRow; index++) ...[
              if (index > 0) const SizedBox(width: gap),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: index < rowChildren.length
                      ? rowChildren[index]
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
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
  }) : assert(children.length > 0),
       assert(selectedIndex >= 0 && selectedIndex < children.length);

  static const double height = 56;
  static const double maxWidth = 280;
  static const double horizontalMargin = 12;
  static const double bottomGap = 8;

  final List<Widget> children;
  final int selectedIndex;

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
          constraints: const BoxConstraints(maxWidth: maxWidth),
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
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final foreground = selected ? tokens.accent : tokens.ink2;
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22, color: foreground),
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
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: foreground,
        fontSize: compact ? 11 : 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    final duration = FaMotion.duration(
      context,
      const Duration(milliseconds: 200),
    );
    final targetOpacity = iconOnly ? 0.0 : 1.0;
    final animatedLabel = ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          begin: animateLabel ? 1 - targetOpacity : targetOpacity,
          end: targetOpacity,
        ),
        duration: duration,
        curve: Curves.easeInOutCubic,
        builder: (context, opacity, child) => opacity <= .001
            ? const SizedBox.shrink()
            : Opacity(opacity: opacity, child: labelText),
      ),
    );
    Widget animatedIcon(double size) =>
        Icon(icon, size: size, color: foreground);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        selected: selected,
        child: Material(
          key: chipKey,
          color: selected && selectionBackground
              ? tokens.accent.withValues(alpha: .12)
              : iconOnly || !selectionBackground
              ? Colors.transparent
              : tokens.surface1.withValues(alpha: .55),
          shape: StadiumBorder(
            side: selected && selectionBackground
                ? BorderSide(color: tokens.accent.withValues(alpha: .18))
                : iconOnly || !selectionBackground
                ? BorderSide.none
                : BorderSide(color: tokens.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: SizedBox(
              height: 32,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 12) {
                    return const SizedBox.shrink();
                  }
                  // AnimatedPositioned changes the slot before the label's
                  // directional fade completes. Keep the intermediate narrow
                  // slot overflow-free instead of clipping a full-density row.
                  final dense = constraints.maxWidth < 32;
                  final denseIconSize = constraints.maxWidth < 14 ? 10.0 : 12.0;
                  return Padding(
                    padding: iconOnly
                        ? EdgeInsets.zero
                        : EdgeInsets.symmetric(
                            horizontal: dense
                                ? 0
                                : (textLed ? 4 : (compact ? 6 : 14)),
                          ),
                    child: Row(
                      mainAxisSize: expanded || compact
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      // A text-led selected segment centers the icon+label
                      // group like a segmented control; the dormant expanded
                      // standalone label stays start-aligned.
                      mainAxisAlignment: iconOnly || (textLed && compact)
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        // The dormant expanded label still participates during
                        // the directional fade. Balance it so an icon-only glyph
                        // remains centered both at rest and mid-transition.
                        if (iconOnly) const Spacer(),
                        animatedIcon(
                          dense ? denseIconSize : (compact ? 15 : 16),
                        ),
                        AnimatedContainer(
                          duration: duration,
                          curve: Curves.easeInOutCubic,
                          width: iconOnly || dense ? 0 : (compact ? 4 : 6),
                        ),
                        if (expanded || compact)
                          // Flexible (not Expanded) lets the centered text-led
                          // group hug its label instead of filling the slot.
                          if (textLed && compact)
                            Flexible(
                              child: AnimatedContainer(
                                duration: duration,
                                curve: Curves.easeInOutCubic,
                                width: iconOnly ? 0 : null,
                                child: animatedLabel,
                              ),
                            )
                          else
                            Expanded(
                              child: AnimatedContainer(
                                duration: duration,
                                curve: Curves.easeInOutCubic,
                                width: iconOnly ? 0 : null,
                                child: animatedLabel,
                              ),
                            )
                        else
                          animatedLabel,
                        if (!dense)
                          if (badge case final count? when count > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.accent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                count > 99 ? '99+' : '$count',
                                style: TextStyle(
                                  color: tokens.accentInk,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
        const curve = Curves.easeInOutCubic;
        final count = categories.length;
        // The trailing selector is a control too: it occupies the final
        // fixed slot and therefore participates in the width budget.
        final controlCount = count + extraActions.length + 1;
        final selectedExtraVisible =
            selectedExtraIndex != null && highlightSelectedExtra;
        final selectedCategoryVisible = highlightSelectedCategory;
        final expandedCount =
            (selectedCategoryVisible ? 1 : 0) + (selectedExtraVisible ? 1 : 0);
        final fixedCount = controlCount - expandedCount;
        final gap = constraints.maxWidth >= 300
            ? MessengerFilterControl.gap
            : 1.0;
        // Two segmented groups can be selected at once (a chat filter
        // and a shell section). Both keep their icon and gain a text
        // slot; quiet icon slots retain a fixed hit rect. The section
        // label gets the larger share so localized names stay readable.
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
            (constraints.maxWidth -
                    gap * (controlCount - 1) -
                    slot * fixedCount)
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
        final positions = <({double left, double width})>[];
        var left = 0.0;
        for (var index = 0; index < count; index++) {
          final isSelected = index == selectedIndex;
          final width = isSelected && selectedCategoryVisible
              ? selectedWidth
              : slot;
          positions.add((left: left, width: width));
          left += width + gap;
        }
        final extraPositions = <({double left, double width})>[];
        for (var index = 0; index < extraActions.length; index++) {
          final width = index == selectedExtraIndex && selectedExtraVisible
              ? selectedExtraWidth
              : slot;
          extraPositions.add((left: left, width: width));
          left += width + gap;
        }
        final selected = positions[selectedIndex];
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            if (selectedCategoryVisible)
              AnimatedPositioned(
                key: const ValueKey('chatFilterSelectionPill'),
                duration: duration,
                curve: curve,
                left: selected.left,
                width: selected.width,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: tokens.accent.withValues(alpha: .12),
                      shape: StadiumBorder(
                        side: BorderSide(
                          color: tokens.accent.withValues(alpha: .18),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            for (var index = 0; index < count; index++)
              AnimatedPositioned(
                key: ValueKey('chatFilterSlot-$index'),
                duration: duration,
                curve: curve,
                left: positions[index].left,
                width: positions[index].width,
                top: 0,
                bottom: 0,
                child: categories[index],
              ),
            for (var index = 0; index < extraActions.length; index++)
              AnimatedPositioned(
                key: ValueKey('chatFilterExtraActionSlot-$index'),
                duration: duration,
                curve: curve,
                left: extraPositions[index].left,
                width: extraPositions[index].width,
                top: 0,
                bottom: 0,
                child: extraActions[index],
              ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: slot,
              child: trailing,
            ),
          ],
        );
      },
    );
  }
}
