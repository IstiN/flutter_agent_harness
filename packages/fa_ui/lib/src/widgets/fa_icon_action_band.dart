// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../chat/fa_adaptive_header.dart';
import '../theme/fa2_tokens.dart';
import 'fa2_controls.dart';
import 'fa_icon_action_button.dart';

/// A compact group of icon actions inside ONE rounded chrome surface.
///
/// Use this for actions that belong to the same presented surface (for
/// example Expand, Pin, Close and Overflow on an app). Unlike composing
/// several [FaIconActionButton]s, the band has no per-action fill, ring or
/// glass disc: the [FaSurface] is the only persistent chrome. Individual
/// controls keep their own tooltip, focus, disabled state and at-least-28pt
/// hit target. Hosts should prefer the 36pt default; 28pt is reserved for
/// exceptionally dense embedded panels.
///
/// The action metadata and ordering contract are shared with
/// [FaAdaptiveHeader] through [FaHeaderAction]. Optional [overflowItems]
/// add a borderless overflow control to the same capsule; selecting an item
/// calls [onOverflowSelected] with its value.
class FaIconActionBand<T> extends StatelessWidget {
  const FaIconActionBand({
    super.key,
    required this.actions,
    this.overflowItems = const [],
    this.onOverflowSelected,
    this.overflowMenuKey,
    this.overflowTooltip,
    this.menuColor,
    this.glass = false,
    this.actionSize = defaultActionSize,
    this.iconSize = defaultIconSize,
    this.spacing = 0,
  }) : assert(actionSize >= minHitTarget),
       assert(iconSize > 0),
       assert(spacing >= 0);

  /// The default square hit-target edge for every action.
  static const double defaultActionSize = 36;

  /// The default glyph edge, matching the control-scale Fa icon actions.
  static const double defaultIconSize = 18;

  /// The minimum supported interactive edge for dense embedded chrome.
  static const double minHitTarget = 28;

  /// Inline actions, rendered in list order.
  final List<FaHeaderAction> actions;

  /// Menu entries behind the trailing overflow glyph. Empty hides overflow.
  final List<PopupMenuEntry<T>> overflowItems;

  /// Called with the selected overflow entry's value.
  final ValueChanged<T>? onOverflowSelected;

  /// Lookup key for the inner overflow menu button.
  final Key? overflowMenuKey;

  /// Tooltip and accessibility name for overflow. Null uses the Material
  /// localizations' standard show-menu label.
  final String? overflowTooltip;

  /// Optional token-derived background for the overflow menu.
  final Color? menuColor;

  /// Whether the single capsule uses real glass in the glass direction.
  /// Other directions retain the same opaque token fallback as [FaSurface].
  final bool glass;

  /// Square interactive edge for each action, including overflow.
  final double actionSize;

  /// Glyph edge shared by inline actions and overflow.
  final double iconSize;

  /// Air between adjacent hit targets. The default is compact and gapless;
  /// the shared outer surface keeps the group visually connected.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final radius = BorderRadius.circular((actionSize + 4) / 2);
    final controls = <Widget>[
      for (var i = 0; i < actions.length; i++) ...[
        if (i > 0) SizedBox(width: spacing),
        _action(context, actions[i], tokens),
      ],
      if (overflowItems.isNotEmpty) ...[
        if (actions.isNotEmpty) SizedBox(width: spacing),
        _overflow(context),
      ],
    ];
    return FaSurface(
      glass: glass,
      useBackdropGroup: true,
      color: glass ? tokens.surface1.withValues(alpha: .45) : tokens.surface2,
      borderRadius: radius,
      borderSide: BorderSide(color: tokens.hairline),
      padding: const EdgeInsets.all(2),
      child: IconTheme.merge(
        data: IconThemeData(size: iconSize, color: tokens.ink1),
        child: Row(mainAxisSize: MainAxisSize.min, children: controls),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    FaHeaderAction action,
    FaDesignTokens tokens,
  ) {
    final enabled = action.onPressed != null;
    return IconButton(
      key: action.key,
      onPressed: action.onPressed,
      tooltip: action.label,
      padding: EdgeInsets.zero,
      iconSize: iconSize,
      constraints: BoxConstraints.tightFor(
        width: actionSize,
        height: actionSize,
      ),
      style: IconButton.styleFrom(
        minimumSize: Size.square(actionSize),
        maximumSize: Size.square(actionSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: enabled ? tokens.ink1 : tokens.ink3,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(actionSize / 3),
        ),
      ),
      icon: action.widget ?? Icon(action.icon, size: iconSize),
    );
  }

  Widget _overflow(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
    final button = context.findRenderObject() as RenderBox?;
    final origin = button?.localToGlobal(Offset.zero, ancestor: overlay);
    return PopupMenuButton<T>(
      // A docked Duo chat is narrower than the full-screen Overlay. Grow
      // left from the button's right edge rather than cover the model with
      // a menu sized for the other half of the foldable.
      constraints: overlay == null || origin == null
          ? null
          : () {
              // The full pane is the boundary. On a narrow pane the stock
              // 112pt menu minimum would otherwise override maxWidth and
              // leave an icon + gap wider than the row's Flexible label.
              // Measure back from the trigger's RIGHT edge: the popup grows
              // left, so space beyond that edge is not available to its rows.
              final available = (origin.dx + (button?.size.width ?? 0))
                  .clamp(0.0, overlay.size.width)
                  .toDouble();
              return BoxConstraints(
                minWidth: available < 112 ? available : 112,
                maxWidth: available,
              );
            }(),
      position: PopupMenuPosition.under,
      offset: Offset.zero,
      key: overflowMenuKey,
      tooltip:
          overflowTooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
      color: menuColor,
      padding: EdgeInsets.zero,
      iconSize: iconSize,
      style: IconButton.styleFrom(
        minimumSize: Size.square(actionSize),
        maximumSize: Size.square(actionSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(actionSize / 3),
        ),
      ),
      icon: Icon(Icons.more_vert, size: iconSize),
      onSelected: onOverflowSelected,
      itemBuilder: (context) => overflowItems,
    );
  }
}
