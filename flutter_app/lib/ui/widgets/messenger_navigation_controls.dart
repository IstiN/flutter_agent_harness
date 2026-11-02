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

/// One predictable hide/show action with the same icon in both states.
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
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final button = IconButton(
      key: ValueKey(expanded ? 'chatSidebarCollapse' : 'chatSidebarExpand'),
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 20,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(32),
        maximumSize: const Size.square(32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: MessengerSidebarLeftIcon(color: tokens.ink2),
    );
    return SizedBox.square(
      dimension: 32,
      child: floating
          ? FaSurface(
              glass: tokens.direction == FaVisualDirection.glass,
              useBackdropGroup: true,
              circular: true,
              color: tokens.surface1.withValues(alpha: .94),
              child: button,
            )
          : button,
    );
  }
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

/// One horizontal category/network control. The selected category receives
/// the remaining width for its label; all other actions keep fixed hit rects.
class MessengerFilterControl extends StatelessWidget {
  const MessengerFilterControl({
    super.key,
    required this.categories,
    required this.selectedIndex,
    this.extraActions = const <Widget>[],
    required this.trailing,
  }) : assert(categories.length > 0),
       assert(selectedIndex >= 0 && selectedIndex < categories.length);

  static const double height = 44;
  static const double gap = 4;

  final List<Widget> categories;
  final int selectedIndex;

  /// Icon-only actions sharing the same fixed slots as unselected categories.
  final List<Widget> extraActions;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: tokens.surface1.withValues(alpha: .62),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: tokens.hairline),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final duration = FaMotion.duration(
                context,
                const Duration(milliseconds: 200),
              );
              const curve = Curves.easeInOutCubic;
              final count = categories.length;
              final fixedCount = count + extraActions.length;
              final gap = constraints.maxWidth >= 176
                  ? MessengerFilterControl.gap
                  : 2.0;
              // Preserve a usable selected icon+label segment when section
              // actions join the toolbar. Unselected icons share the remaining
              // fixed slots, capped at the original 36px desktop geometry.
              const minSelectedWidth = 56.0;
              final slot =
                  ((constraints.maxWidth -
                              gap * fixedCount -
                              minSelectedWidth) /
                          fixedCount)
                      .clamp(0.0, 36.0);
              final selectedWidth =
                  (constraints.maxWidth - gap * fixedCount - slot * fixedCount)
                      .clamp(0.0, constraints.maxWidth);
              final positions = <({double left, double width})>[];
              var left = 0.0;
              for (var index = 0; index < count; index++) {
                final width = index == selectedIndex ? selectedWidth : slot;
                positions.add((left: left, width: width));
                left += width + gap;
              }
              final extraPositions = <double>[];
              for (var index = 0; index < extraActions.length; index++) {
                extraPositions.add(left);
                left += slot + gap;
              }
              final selected = positions[selectedIndex];
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
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
                    Positioned(
                      key: ValueKey('chatFilterExtraActionSlot-$index'),
                      left: extraPositions[index],
                      width: slot,
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
                  if (constraints.maxWidth < 16) {
                    return const SizedBox.shrink();
                  }
                  // AnimatedPositioned changes the slot before the label's
                  // directional fade completes. Keep the intermediate narrow
                  // slot overflow-free instead of clipping a full-density row.
                  final dense = constraints.maxWidth < 32;
                  return Padding(
                    padding: iconOnly
                        ? EdgeInsets.zero
                        : EdgeInsets.symmetric(
                            horizontal: dense ? 2 : (compact ? 6 : 14),
                          ),
                    child: Row(
                      mainAxisSize: expanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      mainAxisAlignment: iconOnly
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        // The dormant expanded label still participates during
                        // the directional fade. Balance it so an icon-only glyph
                        // remains centered both at rest and mid-transition.
                        if (iconOnly) const Spacer(),
                        Icon(
                          icon,
                          size: dense ? 12 : (compact ? 15 : 16),
                          color: foreground,
                        ),
                        AnimatedContainer(
                          duration: duration,
                          curve: Curves.easeInOutCubic,
                          width: iconOnly || dense ? 0 : (compact ? 4 : 6),
                        ),
                        if (expanded || compact)
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
