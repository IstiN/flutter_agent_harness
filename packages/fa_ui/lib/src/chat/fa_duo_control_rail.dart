// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'fa_adaptive_header.dart';
import 'fa_duo_layout.dart';

/// Vertical action chrome for the Duo's reserved right-hand system zone.
///
/// With a [FaDuoLayoutScope], UIKit's vertical-bar trait and camera reserved
/// regions drive the layout. The inset-only path remains for older embedded
/// hosts that do not install the native scope yet.
class FaDuoControlRail extends StatelessWidget {
  const FaDuoControlRail({
    super.key,
    this.leading = const <Widget>[],
    this.actions = const <FaHeaderAction>[],
    this.overflowItems = const <PopupMenuEntry<String>>[],
    this.onOverflowSelected,
    this.overflowMenuKey,
    this.overflowTooltip,
    this.menuColor,
    this.glass = true,
  });

  /// Minimum right inset treated as the Duo control zone.
  static const double minimumWidth = 60;

  /// Top clearance below the camera and connectivity indicators.
  static const double top = 88;

  /// Expanded shells place their New-chat control at [top]; chat actions start
  /// one 52pt slot lower so the two rails never overlap.
  static const double expandedChatTop = top + 52 + 16;

  /// Shared circular action size inside the rail.
  static const double actionDimension = 36;

  /// Vertical separation between controls.
  static const double spacing = 8;

  /// The active trailing rail width, or zero for ordinary/horizontal bars.
  static double widthOf(BuildContext context) {
    final media = MediaQuery.of(context);
    final geometry = FaDuoLayoutScope.maybeOf(context);
    if (geometry == null) {
      return media.padding.right >= minimumWidth ? media.padding.right : 0;
    }
    if (!geometry.isDuo ||
        geometry.verticalBarEdge != FaDuoVerticalBarEdge.trailing) {
      return 0;
    }
    return geometry.trailingWidth(media.size, media.padding);
  }

  /// Global-safe top clearance derived from the active camera region.
  static double topOf(BuildContext context) {
    final geometry = FaDuoLayoutScope.maybeOf(context);
    return geometry == null || !isActive(context)
        ? top
        : geometry.controlsTop(top);
  }

  /// Chat actions also clear the expanded shell's New-chat slot.
  static double expandedTopOf(BuildContext context) {
    if (!isActive(context)) return expandedChatTop;
    final media = MediaQuery.of(context);
    // The chat header is already inside SafeArea; native region coordinates
    // are view-global. Convert once instead of applying the top inset twice.
    final top = (topOf(context) - media.padding.top).clamp(
      0.0,
      double.infinity,
    );
    // Only the expanded shell owns a second New-chat rail. A pushed narrow
    // chat must start directly below the camera, not below a phantom slot.
    return media.size.width >= 900 ? top + 52 + 16 : top;
  }

  /// Whether the Duo rail should replace horizontal header actions.
  static bool isActive(BuildContext context) => widthOf(context) > 0;

  /// Host controls rendered before [actions] (Back, New chat, model chip).
  final List<Widget> leading;

  /// Chat/app actions in their existing priority order.
  final List<FaHeaderAction> actions;

  /// Optional menu entries kept below every inline action.
  final List<PopupMenuEntry<String>> overflowItems;

  /// Handles an overflow selection.
  final ValueChanged<String>? onOverflowSelected;

  /// Lookup key for the overflow control.
  final Key? overflowMenuKey;

  /// Overflow accessibility tooltip.
  final String? overflowTooltip;

  /// Overflow menu surface color.
  final Color? menuColor;

  /// Whether circular controls sample the floating backdrop.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (final child in leading) _cell(child),
      for (final action in actions) _cell(_action(action)),
      if (overflowItems.isNotEmpty) _cell(_overflow(context)),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(bottom: spacing),
                child: child,
              ),
          ],
        ),
      ),
    );
  }

  Widget _cell(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: actionDimension),
      child: child,
    ),
  );

  Widget _action(FaHeaderAction action) {
    final hosted = action.widget;
    if (hosted != null) {
      return SizedBox.square(
        dimension: actionDimension,
        child: FaHeaderCircularAction(
          dimension: actionDimension,
          glass: glass,
          child: hosted,
        ),
      );
    }
    return FaHeaderCircularAction(
      dimension: actionDimension,
      glass: glass,
      child: IconButton(
        key: action.key,
        onPressed: action.onPressed,
        tooltip: action.label,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: actionDimension,
          height: actionDimension,
        ),
        icon: Icon(action.icon, size: 18),
      ),
    );
  }

  Widget _overflow(BuildContext context) => FaHeaderCircularAction(
    dimension: actionDimension,
    glass: glass,
    child: PopupMenuButton<String>(
      key: overflowMenuKey,
      tooltip:
          overflowTooltip ??
          MaterialLocalizations.of(context).moreButtonTooltip,
      color: menuColor,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: actionDimension,
        height: actionDimension,
      ),
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: onOverflowSelected,
      itemBuilder: (_) => overflowItems,
    ),
  );
}
