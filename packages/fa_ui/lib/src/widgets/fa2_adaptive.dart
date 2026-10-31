// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';
import 'fa2_controls.dart' show FaMotionDuration;

/// One destination in [FaAdaptiveScaffold].
class FaDestination {
  const FaDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.tooltip,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final String? tooltip;
}

/// Fa's phone / foldable / desktop navigation shell.
///
/// Small uses bottom navigation; medium adds a rail and optional contextual
/// panel; large keeps navigation, context and board visible simultaneously.
class FaAdaptiveScaffold extends StatelessWidget {
  const FaAdaptiveScaffold({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.body,
    this.title,
    this.actions,
    this.leading,
    this.floatingActionButton,
    this.secondaryPanel,
    this.boardPanel,
  });

  final List<FaDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget body;
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final Widget? floatingActionButton;
  final Widget? secondaryPanel;
  final Widget? boardPanel;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final windowClass = faWindowClassForWidth(constraints.maxWidth);
        final appBar = AppBar(
          title: title,
          leading: leading,
          actions: [
            ...?actions,
            if (windowClass == FaWindowClass.medium && boardPanel != null)
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Board',
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                  icon: const Icon(Icons.space_dashboard_outlined),
                ),
              ),
          ],
        );
        final navDestinations = [
          for (final destination in destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon ?? destination.icon),
              label: destination.label,
              tooltip: destination.tooltip,
            ),
        ];
        final rail = NavigationRail(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          extended:
              windowClass == FaWindowClass.large &&
              constraints.maxWidth >= 1440,
          minExtendedWidth: 208,
          backgroundColor: tokens.surface1,
          indicatorColor: tokens.accentSoft,
          destinations: [
            for (final destination in destinations)
              NavigationRailDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(
                  destination.selectedIcon ?? destination.icon,
                ),
                label: Text(destination.label),
              ),
          ],
        );
        final centeredBody = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: body,
          ),
        );
        if (windowClass == FaWindowClass.small) {
          return Scaffold(
            appBar: appBar,
            body: body,
            floatingActionButton: floatingActionButton,
            bottomNavigationBar: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: navDestinations,
            ),
          );
        }
        return Scaffold(
          appBar: appBar,
          floatingActionButton: floatingActionButton,
          endDrawer: windowClass == FaWindowClass.medium && boardPanel != null
              ? Drawer(width: 420, child: SafeArea(child: boardPanel!))
              : null,
          body: Row(
            children: [
              rail,
              VerticalDivider(width: 1, color: tokens.hairline),
              if (secondaryPanel != null) ...[
                SizedBox(
                  width: windowClass == FaWindowClass.large ? 300 : 280,
                  child: secondaryPanel,
                ),
                VerticalDivider(width: 1, color: tokens.hairline),
              ],
              Expanded(child: centeredBody),
              if (windowClass == FaWindowClass.large && boardPanel != null) ...[
                VerticalDivider(width: 1, color: tokens.hairline),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: SizedBox(width: 400, child: boardPanel),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A responsive launcher grid: 4 / 6 / 8 columns by default.
class FaAppGrid extends StatelessWidget {
  const FaAppGrid({
    super.key,
    required this.children,
    this.crossAxisCount,
    this.padding = const EdgeInsets.all(20),
    this.shrinkWrap = false,
    this.physics,
  });

  final List<Widget> children;
  final int? crossAxisCount;
  final EdgeInsetsGeometry padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final count =
          crossAxisCount ??
          switch (faWindowClassForWidth(constraints.maxWidth)) {
            FaWindowClass.small => 4,
            FaWindowClass.medium => 6,
            FaWindowClass.large => 8,
          };
      return GridView.count(
        crossAxisCount: count,
        padding: padding,
        shrinkWrap: shrinkWrap,
        physics: physics,
        mainAxisSpacing: 20,
        crossAxisSpacing: 12,
        childAspectRatio: .68,
        children: children,
      );
    },
  );
}

/// An unboxed launcher icon with the canonical continuous-corner silhouette.
class FaAppIcon extends StatelessWidget {
  const FaAppIcon({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.running = false,
    this.gradient,
    this.color,
    this.size = 62,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  final bool running;
  final Gradient? gradient;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final iconWidget = Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: gradient == null ? color ?? tokens.surface2 : null,
        gradient: gradient,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(size * .27),
          side: BorderSide(color: tokens.hairline),
        ),
        shadows: tokens.brightness == Brightness.light
            ? [
                BoxShadow(
                  color: tokens.ink1.withValues(alpha: .07),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: tokens.accent, size: size * .43),
        child: Center(child: icon),
      ),
    );
    return Semantics(
      button: onTap != null,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: size + 8,
                height: size + 8,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Center(child: iconWidget),
                    if (running)
                      Positioned(
                        right: 0,
                        bottom: 1,
                        child: Container(
                          width: 15,
                          height: 15,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: tokens.accent,
                            border: Border.all(
                              color: tokens.background,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tokens.ink1,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A restrained shared-axis-style page transition with a reduced-motion path.
class FaPageTransitionSwitcher extends StatelessWidget {
  const FaPageTransitionSwitcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final reduce = FaMotion.reduceMotionOf(context);
    return AnimatedSwitcher(
      duration: FaMotion.duration(context, tokens.base),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final fade = FadeTransition(opacity: animation, child: child);
        if (reduce) return fade;
        return SlideTransition(
          position: Tween(
            begin: const Offset(.025, 0),
            end: Offset.zero,
          ).animate(animation),
          child: fade,
        );
      },
      child: child,
    );
  }
}

/// Motion accessibility helpers shared by app surfaces.
abstract final class FaMotion {
  static bool reduceMotionOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration duration(BuildContext context, Duration duration) =>
      FaMotionDuration.resolve(context, duration);
}
