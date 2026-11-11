// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math' as math;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show ProgressiveBlur, ProgressiveBlurDirection;

/// The approved messenger glass underlay, shared by every sidebar section
/// and Files. Parent supplies only the height and clips it to the panel:
/// no top gap, 2pt left / 3pt right inset, 14pt top radii, and a steep
/// falloff whose lower region is completely sharp (no visible bottom seam).
final class MessengerGlassUnderlay extends StatelessWidget {
  const MessengerGlassUnderlay({
    super.key,
    this.underlayKey = const ValueKey('chatListChromeUnderlay'),
  });

  /// Stable key for geometry tests; each host may use its own semantic key.
  final Key underlayKey;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final light = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 3),
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // No bounded AdaptiveGlass here: its own rounded outline and
              // constant tint made a visible card with a hard bottom edge.
              // The progressive blur + fading frost below ARE the transition.
              ProgressiveBlur(
                key: underlayKey,
                maxSigma: 8,
                direction: ProgressiveBlurDirection.topToBottom,
                falloff: 3.0,
              ),
              // Blur alone is invisible until a row happens to scroll under
              // it. A restrained token tint makes the header read as glass
              // at rest too, then falls to zero before the content seam.
              DecoratedBox(
                key: const ValueKey('messengerGlassFrost'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tokens.surface1.withValues(alpha: light ? .76 : .58),
                      tokens.surface1.withValues(alpha: light ? .36 : .26),
                      tokens.surface1.withValues(alpha: 0),
                    ],
                    stops: const [0, .55, 1],
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

/// Floating page chrome shared by Apps and categorized Settings. Geometry
/// mirrors the desktop chat header: a small glass icon and title pill float
/// over the page; back and secondary actions are independent controls.
final class MessengerFloatingPageHeader extends StatelessWidget {
  const MessengerFloatingPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.onIconTap,
    this.leading,
    this.actions = const <Widget>[],
    this.trafficLightClearance = false,
    this.duoLeadingToTrailing = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onIconTap;
  final Widget? leading;
  final List<Widget> actions;

  /// Full-window macOS routes lower only [leading] below the traffic lights.
  /// The title/icon and page body keep their ordinary vertical position.
  final bool trafficLightClearance;

  /// Places [leading] at the usable trailing edge on Duo only. Ordinary
  /// phone/desktop headers keep their conventional leading navigation.
  final bool duoLeadingToTrailing;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final leadingTop = trafficLightClearance && FaWindowChrome.isMacOS
        ? 9.0 + FaWindowChrome.titlebarHeight
        : 9.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final geometry = _HeaderGeometry.of(context, constraints, actions);
          return SizedBox(
            height: geometry.headerHeight(hasActions: actions.isNotEmpty),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: geometry.duoRailWidth,
                  child: _buildIconAndTitleColumn(tokens, geometry.titleWidth),
                ),
                if (leading case final leading?)
                  _buildLeadingOverlay(leading, leadingTop, geometry),
                if (actions.isNotEmpty && geometry.duoRailWidth == 0)
                  _buildTrailingActionsRow(),
                if (actions.isNotEmpty && geometry.duoRailWidth > 0)
                  _buildDuoActionRail(geometry),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The icon bubble above the title pill — the header's left column.
  Widget _buildIconAndTitleColumn(FaDesignTokens tokens, double titleWidth) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?) ...[
          Padding(
            padding: const EdgeInsets.only(top: 11),
            child: FaHeaderCircularAction(
              key: const ValueKey('messengerPageIcon'),
              dimension: 36,
              glass: true,
              child: onIconTap == null
                  ? Icon(icon, size: 18, color: tokens.ink1)
                  : IconButton(
                      onPressed: onIconTap,
                      icon: Icon(icon, size: 18, color: tokens.ink1),
                    ),
            ),
          ),
          const SizedBox(height: 4),
        ],
        _buildTitlePill(tokens, titleWidth),
      ],
    );
  }

  /// The centered title (+ optional subtitle) pill.
  Widget _buildTitlePill(FaDesignTokens tokens, double titleWidth) {
    return FaSurface(
      key: const ValueKey('messengerPageTitlePill'),
      glass: true,
      useBackdropGroup: true,
      color: tokens.surface1,
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        width: titleWidth,
        height: 40,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (subtitle case final subtitle? when subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.ink2,
                  fontSize: 10,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                ),
              ),
            Text(
              title,
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
    );
  }

  /// Places [leading] — the conventional left navigation, or the
  /// Duo-rail-trailing Back on Duo.
  Widget _buildLeadingOverlay(
    Widget leading,
    double leadingTop,
    _HeaderGeometry geometry,
  ) {
    final duoLeading = duoLeadingToTrailing && geometry.duoRailWidth > 0;
    return Positioned(
      top: leadingTop,
      left: duoLeading ? null : 0,
      // Settings already owns the Duo/SafeArea lane. Zero is
      // its usable trailing edge; subtracting the rail again
      // would put Back on top of the centered title.
      right: duoLeading ? 0 : null,
      child: leading,
    );
  }

  /// The ordinary (non-Duo) horizontal actions row at the header's top
  /// trailing edge.
  Widget _buildTrailingActionsRow() {
    return Positioned(
      top: 9,
      right: 0,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions) ...[
            action,
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// The Duo control rail hosting the actions along the window's
  /// trailing edge.
  Widget _buildDuoActionRail(_HeaderGeometry geometry) {
    return Positioned(
      top: geometry.duoTop,
      right: -8,
      bottom: 0,
      width: geometry.duoRailWidth,
      child: FaDuoControlRail(leading: actions),
    );
  }
}

/// The LayoutBuilder-derived geometry of a [MessengerSectionHeader]:
/// the Duo rail's footprint and the title pill's width budget.
final class _HeaderGeometry {
  const _HeaderGeometry._({
    required this.duoRailWidth,
    required this.duoTop,
    required this.titleWidth,
    required this.duoHeight,
  });

  static _HeaderGeometry of(
    BuildContext context,
    BoxConstraints constraints,
    List<Widget> actions,
  ) {
    final duoRailWidth = FaDuoControlRail.widthOf(context);
    final contentWidth = math.max(
      0.0,
      constraints.maxWidth - duoRailWidth,
    );
    final actionWidth = math.min(360.0, contentWidth * .38);
    final titleWidth = math.min(
      320.0,
      math.max(200.0, contentWidth - 2 * (actionWidth + 12)),
    );
    final duoTop = FaDuoControlRail.topOf(context);
    final duoHeight = math.min(
      400.0,
      duoTop +
          actions.length *
              (FaDuoControlRail.actionDimension +
                  FaDuoControlRail.spacing) +
          FaDuoControlRail.spacing,
    );
    return _HeaderGeometry._(
      duoRailWidth: duoRailWidth,
      duoTop: duoTop,
      titleWidth: titleWidth,
      duoHeight: duoHeight,
    );
  }

  /// The Duo control rail's width — 0 on ordinary phone/desktop headers.
  final double duoRailWidth;

  /// The Duo control rail's top inset.
  final double duoTop;

  /// The title pill's width budget inside the header's content column.
  final double titleWidth;

  /// The Duo rail's natural height for the header's action count.
  final double duoHeight;

  /// The header's total height: the ordinary 91px pill row, grown only
  /// when a Duo rail with actions demands more room.
  double headerHeight({required bool hasActions}) =>
      duoRailWidth > 0 && hasActions ? math.max(91.0, duoHeight) : 91;
}

/// Hosts a [MessengerFloatingPageHeader] over a full-size transparent body.
/// Only the title pill and controls are glass; there is deliberately no
/// full-width header surface or progressive blur band.
final class MessengerFloatingPageScaffold extends StatelessWidget {
  const MessengerFloatingPageScaffold({
    super.key,
    required this.header,
    required this.body,
  });

  static const double bodyTop = 108;

  final Widget header;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final glass = tokens.direction == FaVisualDirection.glass;
    // The host supplies token background + FahWallpaper, exactly like Local
    // and Network chats. Another color here would hide the pixels the short
    // glass controls need to sample.
    final page = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: body),
        Positioned(top: 0, left: 0, right: 0, child: header),
      ],
    );
    if (!glass || BackdropGroup.of(context) != null) return page;
    return BackdropGroup(child: page);
  }
}

/// The inset a glass-panel scroll view applies internally instead of placing
/// the whole body below the header. This is what lets rows scroll under the
/// blur, matching Channels and Messages.
final class MessengerGlassBodyInsets extends InheritedWidget {
  const MessengerGlassBodyInsets({
    super.key,
    required this.top,
    required super.child,
  });

  final double top;

  static double topOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MessengerGlassBodyInsets>()
          ?.top ??
      0;

  @override
  bool updateShouldNotify(MessengerGlassBodyInsets oldWidget) =>
      top != oldWidget.top;
}

/// The floating phone dock's occupied bottom height, for scroll views that
/// run underneath it.
///
/// The narrow shell scaffold sets `extendBody` while the dock rides in its
/// `bottomNavigationBar` slot, so the ambient [MediaQuery] padding.bottom
/// inside the narrow body is INFLATED to exactly the dock's occupied height
/// (home indicator + 8pt separation gap + 56pt pill). Sections consume that
/// value as scroll padding so their final rows stay reachable above the
/// glass instead of being cut behind the pill.
///
/// Desktop layouts never build the narrow scaffold: their raw inset stays
/// 0 (and the desktop Duo camera profile seeds at most 34), which never
/// reaches [minInflatedBottom] — so [bottomOf] resolves to 0 there and
/// every caller keeps its legacy padding, keeping desktop geometry
/// byte-identical.
final class MessengerFloatingDockInsets {
  MessengerFloatingDockInsets._();

  /// 56pt pill ([MessengerBottomNavigation.height]) + 8pt bottom gap
  /// ([MessengerBottomNavigation.bottomGap]) — the smallest inflated value
  /// the narrow scaffold can report. Raw device safe areas (iOS home
  /// indicator ≈ 34) stay below it, so only the scaffold's inflated inset
  /// qualifies. (Literal: importing the controls file here would create an
  /// import cycle.)
  static const double minInflatedBottom = 64;

  /// The dock's occupied bottom height, or 0 when the ambient MediaQuery
  /// was not inflated for the floating dock (desktop, standalone hosts).
  static double bottomOf(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return bottom >= minInflatedBottom ? bottom : 0;
  }
}

/// Shared simple messenger panel: one header and a full-size scrolling body.
/// Scroll views consume [MessengerGlassBodyInsets] internally. Hosts
/// with extra banner/filter rows use [MessengerGlassUnderlay] directly.
final class MessengerGlassPanel extends StatelessWidget {
  const MessengerGlassPanel({
    super.key,
    required this.header,
    required this.body,
    required this.underlayKey,
    this.compact = false,
  });

  final Widget header;
  final Widget body;
  final Key underlayKey;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final glass = tokens.direction == FaVisualDirection.glass;
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final headerHeight = compact ? (isMac ? 84.0 : 54.0) : 52.0;
    final query = MediaQuery.of(context);
    final scrollingBody = compact
        ? body
        : MediaQuery(
            data: query.copyWith(
              padding: query.padding.copyWith(
                top: query.padding.top + 6,
                right: query.padding.right + 1,
              ),
            ),
            child: body,
          );
    return ColoredBox(
      color: glass ? Colors.transparent : colors.panel,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: MessengerGlassBodyInsets(
              top: headerHeight,
              child: scrollingBody,
            ),
          ),
          if (glass)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: headerHeight + 6,
              child: MessengerGlassUnderlay(underlayKey: underlayKey),
            ),
          Positioned(top: 0, left: 0, right: 0, child: header),
        ],
      ),
    );
  }
}

/// Shared PoC sidebar header: circular Fa profile, optional compact title,
/// search, and a desktop New action.
final class MessengerSectionHeader extends StatelessWidget {
  const MessengerSectionHeader({
    super.key,
    required this.title,
    required this.searchController,
    required this.searchHint,
    required this.onProfile,
    required this.onNew,
    this.onSearch,
    this.onBrandTap,
    this.onBrandLongPress,
    this.onExpand,
    this.onCollapse,
    this.searchFocusNode,
    this.searchCollapsed = false,
    this.onSearchReveal,
    this.onSearchClose,
    this.onSettings,
    this.leading,
    this.trailing,
    this.newButtonKey,
    this.compact = false,
    this.collapsed = false,
  });

  final String title;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final bool searchCollapsed;
  final VoidCallback? onSearchReveal;
  final VoidCallback? onSearchClose;

  /// Explicit phone Settings action; wide layouts use the pinned rail row.
  final VoidCallback? onSettings;
  final String searchHint;
  final VoidCallback? onProfile;
  final VoidCallback? onNew;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onBrandTap;
  final VoidCallback? onBrandLongPress;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
  final Widget? leading;
  final Widget? trailing;
  final Key? newButtonKey;
  final bool compact;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final geometry = _geometry(tokens, isMac);
    final showSearch = searchController != null && !searchCollapsed;
    final brand = _brand(context);
    return Transform.translate(
      offset: Offset(compact || collapsed ? 0 : -geometry.glassFrameInset, 0),
      child: Container(
        height: geometry.titlebarHeight + geometry.contentHeight,
        color: tokens.direction == FaVisualDirection.glass
            ? Colors.transparent
            : colors.panel,
        child: Column(
          children: [
            if (geometry.titlebarHeight > 0)
              SizedBox(
                key: const ValueKey('macosSidebarTitlebar'),
                width: double.infinity,
                height: geometry.titlebarHeight,
              ),
            if (collapsed)
              SizedBox(
                height: geometry.contentHeight,
                child: Center(child: brand),
              )
            else
              _expandedContent(
                context,
                brand,
                colors,
                tokens,
                showSearch,
                geometry,
              ),
          ],
        ),
      ),
    );
  }

  ({double glassFrameInset, double contentHeight, double titlebarHeight})
  _geometry(FaDesignTokens tokens, bool isMac) {
    // Real glass insets its child by its 1pt border; opaque frames do not.
    final glassFrameInset = tokens.direction == FaVisualDirection.glass
        ? 1.0
        : 0.0;
    final contentHeight = compact
        ? 54.0
        : (isMac ? 54.0 : 58.0) - 2 * glassFrameInset;
    // Only the narrow compact header clears the native traffic lights.
    final titlebarHeight = isMac && compact ? 30.0 : 0.0;
    return (
      glassFrameInset: glassFrameInset,
      contentHeight: contentHeight,
      titlebarHeight: titlebarHeight,
    );
  }

  Widget _brand(BuildContext context) {
    const brandSize = 30.0;
    return Semantics(
      button: onBrandTap != null || onProfile != null,
      label: context.l10n.chatProfileSettings,
      child: GestureDetector(
        key: const ValueKey('messengerProfile'),
        onTap: onBrandTap ?? onProfile,
        onLongPress: onBrandLongPress,
        child: SizedBox.square(
          key: const ValueKey('wideShellFaBrand'),
          dimension: brandSize,
          child: FaLogo(size: brandSize, trailingDot: collapsed),
        ),
      ),
    );
  }

  Widget _expandedContent(
    BuildContext context,
    Widget brand,
    FahColors colors,
    FaDesignTokens tokens,
    bool showSearch,
    ({double glassFrameInset, double contentHeight, double titlebarHeight})
    geometry,
  ) {
    return SizedBox(
      height: geometry.contentHeight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 12 : 10, 7, 10, 7),
        child: Row(
          children: _rowChildren(context, brand, colors, tokens, showSearch),
        ),
      ),
    );
  }

  List<Widget> _rowChildren(
    BuildContext context,
    Widget brand,
    FahColors colors,
    FaDesignTokens tokens,
    bool showSearch,
  ) {
    return [
      leading ?? brand,
      if (compact && showSearch) ...[
        const SizedBox(width: 8),
        SizedBox(width: 64, child: _compactTitle(context, colors)),
      ],
      SizedBox(width: showSearch ? 6 : 8),
      Expanded(child: _searchOrTitle(colors, showSearch)),
      ..._searchRevealWidgets(),
      ..._newWidgets(context, tokens),
      ..._trailingWidgets(),
      ..._settingsWidgets(context),
      ..._collapseWidgets(),
    ];
  }

  Widget _compactTitle(BuildContext context, FahColors colors) {
    if (onSearchClose == null) {
      return Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.text,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FaIconActionButton(
        buttonKey: const ValueKey('messengerSearchClose'),
        onPressed: onSearchClose,
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        diameter: 32,
        glyphSize: 22,
        glass: false,
        child: const FaIcon(FaSemanticIcon.back),
      ),
    );
  }

  Widget _searchOrTitle(FahColors colors, bool showSearch) {
    if (showSearch) {
      return SessionSearchField(
        key: const ValueKey('messengerSearchField'),
        controller: searchController,
        focusNode: searchFocusNode,
        hintText: searchHint,
        onQueryChanged: onSearch,
      );
    }
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.text,
        fontSize: compact ? 16 : 17,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  List<Widget> _searchRevealWidgets() {
    if (!searchCollapsed || searchController == null) return const [];
    return [
      const SizedBox(width: 8),
      FaIconActionButton(
        buttonKey: const ValueKey('messengerSearchReveal'),
        onPressed: onSearchReveal,
        tooltip: searchHint,
        diameter: 32,
        glyphSize: 21,
        glass: false,
        child: const FaIcon(FaSemanticIcon.search),
      ),
    ];
  }

  List<Widget> _newWidgets(BuildContext context, FaDesignTokens tokens) {
    if (onNew == null || (compact && searchController != null)) {
      return const [];
    }
    return [
      const SizedBox(width: 8),
      SizedBox.square(
        dimension: 32,
        child: IconButton.filled(
          key: newButtonKey ?? const ValueKey('messengerNewButton'),
          onPressed: onNew,
          tooltip: context.l10n.chatNew,
          iconSize: 18,
          color: Colors.white,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            backgroundColor: tokens.accent,
            foregroundColor: tokens.accentInk,
            minimumSize: const Size.square(32),
            maximumSize: const Size.square(32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: const Icon(Icons.edit_outlined),
        ),
      ),
    ];
  }

  List<Widget> _trailingWidgets() {
    final widget = trailing;
    if (widget == null) return const [];
    return [const SizedBox(width: 8), widget];
  }

  List<Widget> _settingsWidgets(BuildContext context) {
    if (!compact || onSettings == null) return const [];
    return [
      const SizedBox(width: 8),
      FaIconActionButton(
        buttonKey: const ValueKey('narrowSettingsButton'),
        onPressed: onSettings,
        tooltip: context.l10n.settingsTitle,
        diameter: 32,
        glyphSize: 20,
        glass: false,
        child: const Icon(Icons.settings_outlined),
      ),
    ];
  }

  List<Widget> _collapseWidgets() {
    if (compact || onCollapse == null) return const [];
    return [const SizedBox(width: 4), const SizedBox.square(dimension: 36)];
  }
}
