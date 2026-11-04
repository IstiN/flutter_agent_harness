// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'dart:math' as math;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One Telegram-style destination in the vertical messenger rail.
class MessengerRailDestination {
  const MessengerRailDestination({
    required this.rowKey,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.badgeMuted = false,
  });

  /// Stable row identity (tests + menu anchoring).
  final Key rowKey;
  final IconData icon;

  /// The single-line label centered below the pictogram.
  final String label;
  final bool selected;
  final void Function(BuildContext rowContext)? onTap;

  /// Count rendered as a circle overlapping the icon's top-right; hidden
  /// when null or zero.
  final int? badge;

  /// Muted gray variant (quiet counts, e.g. running sessions); default is
  /// the accent fill.
  final bool badgeMuted;
}

/// The vertical left rail (Telegram pattern) that replaces the floating
/// horizontal section pill-bar in the wide shell.
///
/// Geometry contract (owner spec): a floating glass card ~78pt wide —
/// 1:1 with the collapsed chats sidebar's panel (8pt margins on every
/// side, the same 18pt card radius, one shared backdrop capture) —
/// separated from the content column by the card's 8pt seam; rows pitch
/// ~64pt; a row is a pictogram (25–28pt) with a single-line ~10pt label
/// CENTERED BELOW it; the unread badge is a 19–20pt circle overlapping
/// the icon's top-right; the selected row tints icon+label ACCENT with NO
/// background fill; the bottom slot is a pinned settings glyph; the tap
/// target is the whole row (icon+label together).
class MessengerNavRail extends StatelessWidget {
  const MessengerNavRail({
    super.key,
    required this.destinations,
    required this.settingsLabel,
    required this.onSettingsTap,
    this.bottomPadding = 10,
  });

  /// Full-bled rail width; the content column starts after [seam].
  static const double width = 78;
  static const double seam = 8;
  static const double rowPitch = 64;
  static const double iconSize = 26;
  static const double labelSize = 10;
  static const double badgeSize = 19;

  /// The card radius, the same value the collapsed chats sidebar's glass
  /// panel uses in wide_layout_shell.dart (owner: the rail is under glass
  /// 1:1 with that panel — one radius, no drift; pinned equal by the
  /// wide-shell surface test).
  static const double glassRadius = 18;

  final List<MessengerRailDestination> destinations;
  final String settingsLabel;
  final VoidCallback onSettingsTap;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    // One glass surface for the WHOLE rail (never per row): the same
    // FaSurface glass treatment as the collapsed chats sidebar's panel —
    // same tokens (surface1 tint, kit glass settings), same 18pt radius,
    // same BackdropGroup participation — so content slides under it and
    // blurs through 1:1 with that panel.
    // Titlebar clearance: on macOS desktop the window is a fullSizeContent
    // view — MediaQuery.top reads 0 while the real traffic lights float
    // over the first ~28pt — so use a fixed macOS inset (the faAppBar
    // clearance zone, 40pt: lights + breathing room). Everywhere else the
    // chats-sidebar formula applies: max(seam, MediaQuery top) — the card's
    // 8pt margin plus what remains of the platform titlebar.
    final titlebarTop = (!kIsWeb &&
            defaultTargetPlatform == TargetPlatform.macOS)
        ? 40.0
        : math.max(
            0.0,
            MediaQuery.paddingOf(context).top - MessengerNavRail.seam,
          );
    return Padding(
      padding: const EdgeInsets.all(MessengerNavRail.seam),
      child: FaSurface(
        glass: true,
        useBackdropGroup: true,
        color: tokens.surface1,
        borderRadius: BorderRadius.circular(MessengerNavRail.glassRadius),
        child: Column(
          children: [
            SizedBox(height: titlebarTop),
            for (final destination in destinations)
              MessengerNavRailItem(destination: destination),
            const Spacer(),
            MessengerNavRailItem(
              destination: MessengerRailDestination(
                rowKey: const ValueKey('railSettingsRow'),
                icon: Icons.settings_outlined,
                label: settingsLabel,
                selected: false,
                onTap: (_) => onSettingsTap(),
              ),
            ),
            SizedBox(height: bottomPadding),
          ],
        ),
      ),
    );
  }
}

/// One whole-row destination: pictogram + centered label below, accent
/// tint when selected (never a background fill), optional top-right badge.
class MessengerNavRailItem extends StatelessWidget {
  const MessengerNavRailItem({super.key, required this.destination});

  final MessengerRailDestination destination;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final color = destination.selected ? tokens.accent : tokens.ink2;
    final label = destination.label;
    return SizedBox(
      key: destination.rowKey,
      width: MessengerNavRail.width,
      height: MessengerNavRail.rowPitch,
      child: Semantics(
        button: true,
        label: label,
        selected: destination.selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => destination.onTap?.call(context),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      destination.icon,
                      size: MessengerNavRail.iconSize,
                      color: color,
                    ),
                    if (destination.badge case final count? when count > 0)
                      Positioned(
                        top: -3,
                        right: -8,
                        child: MessengerRailBadge(
                          count: count,
                          muted: destination.badgeMuted,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.label.copyWith(
                    color: color,
                    fontSize: MessengerNavRail.labelSize,
                    height: 1.15,
                    fontWeight: destination.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The 19pt count circle overlapping the icon's top-right: accent fill with
/// the accent's on-color numeral, or the muted gray variant.
class MessengerRailBadge extends StatelessWidget {
  const MessengerRailBadge({
    super.key,
    required this.count,
    this.muted = false,
  });

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final colors = FahColors.of(context);
    return Container(
      key: muted
          ? const ValueKey('railBadgeMuted')
          : const ValueKey('railBadgeAccent'),
      constraints: const BoxConstraints(minWidth: MessengerNavRail.badgeSize),
      height: MessengerNavRail.badgeSize,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? colors.panelAlt : tokens.accent,
        shape: BoxShape.circle,
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: muted ? colors.dim : tokens.accentInk,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
