// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chat/fa_adaptive_header.dart';
import '../chat/fa_duo_control_rail.dart';
import '../utils/page_presentation.dart';

/// Shared window-chrome geometry for route, floating and presented headers.
///
/// macOS uses `fullSizeContentView`: native traffic lights float over the
/// top-left titlebar. Embedded panels and centered dialogs do not own that
/// area, so they must not inherit full-window clearance.
abstract final class FaWindowChrome {
  /// Whether native macOS window controls float over Flutter content.
  static bool get isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// Height reserved for a route title in the native macOS titlebar.
  static const double titlebarHeight = 32;

  /// Horizontal clearance for compact presented-app title content.
  static const double compactLeadingInset = 72;

  /// Whether a route should split its title and navigation rows for macOS.
  static bool routeClearance(BuildContext? context, {required bool enabled}) =>
      enabled && isMacOS && (context == null || !FaDialogScope.of(context));

  /// Whether compact presented-app content starts at the window's left edge.
  static bool presentedAppClearance(
    BuildContext context, {
    required bool embeddedInPanel,
  }) => isMacOS && (!embeddedInPanel || MediaQuery.sizeOf(context).width < 640);
}

/// An app bar whose macOS form keeps the title in the native titlebar and
/// lowers ONLY the navigation row (Back/actions) below the traffic lights.
///
/// Other platforms, embedded surfaces and centered Fa dialogs keep the
/// ordinary Material [AppBar]. Pass the current [context] whenever available
/// so dialog presentation is detected automatically.
PreferredSizeWidget faRouteAppBar({
  BuildContext? context,
  Widget? title,
  List<Widget>? actions,
  Widget? leading,
  bool? centerTitle,
  bool trafficLightClearance = true,
  double? toolbarHeight,
}) {
  if (FaWindowChrome.routeClearance(context, enabled: trafficLightClearance)) {
    return FaRouteHeader(
      title: title,
      actions: actions,
      leading: leading,
      centerTitle: centerTitle,
      toolbarHeight: toolbarHeight,
    );
  }
  if (context != null &&
      !FaDialogScope.of(context) &&
      FaDuoControlRail.isActive(context)) {
    return _FaDuoRouteHeader(
      title: title,
      actions: actions,
      leading: leading,
      centerTitle: centerTitle,
      toolbarHeight: toolbarHeight,
    );
  }
  return AppBar(
    title: title,
    actions: actions,
    leading: leading,
    centerTitle: centerTitle,
    toolbarHeight: toolbarHeight,
  );
}

/// A compact route title with Duo Back overlaid in the native trailing rail.
///
/// Keeping [preferredSize] at the ordinary toolbar height is intentional:
/// making the app bar as tall as the camera clearance would recreate the
/// giant empty body inset that the rail is meant to avoid.
final class _FaDuoRouteHeader extends StatefulWidget
    implements PreferredSizeWidget {
  const _FaDuoRouteHeader({
    this.title,
    this.actions,
    this.leading,
    this.centerTitle,
    double? toolbarHeight,
  }) : toolbarHeight = toolbarHeight ?? kToolbarHeight;

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool? centerTitle;
  final double toolbarHeight;

  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight);

  @override
  State<_FaDuoRouteHeader> createState() => _FaDuoRouteHeaderState();
}

final class _FaDuoRouteHeaderState extends State<_FaDuoRouteHeader> {
  OverlayEntry? _backEntry;
  ModalRoute<void>? _route;
  bool _syncScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant _FaDuoRouteHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      final hasBack = widget.leading != null || Navigator.of(context).canPop();
      if (!hasBack) {
        _backEntry?.remove();
        _backEntry = null;
        return;
      }
      final entry = _backEntry;
      if (entry == null) {
        _backEntry = OverlayEntry(builder: _buildBack);
        Overlay.of(context).insert(_backEntry!);
      } else {
        entry.markNeedsBuild();
      }
    });
  }

  Widget _buildBack(BuildContext _) {
    if (_route?.isCurrent == false) return const SizedBox.shrink();
    final back =
        widget.leading ??
        (Navigator.of(context).canPop()
            ? const BackButton(key: ValueKey('faDuoRouteBack'))
            : null);
    if (back == null) return const SizedBox.shrink();
    return Positioned(
      top: FaDuoControlRail.topOf(context),
      right: 0,
      width: FaDuoControlRail.widthOf(context),
      height: FaDuoControlRail.actionDimension + FaDuoControlRail.spacing,
      child: FaDuoControlRail(
        leading: [
          SizedBox.square(
            dimension: FaDuoControlRail.actionDimension,
            child: FaHeaderCircularAction(
              dimension: FaDuoControlRail.actionDimension,
              child: IconTheme.merge(
                data: const IconThemeData(size: 18),
                child: back,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _backEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final railWidth = FaDuoControlRail.widthOf(context);
    return Padding(
      padding: EdgeInsets.only(right: railWidth),
      child: MediaQuery.removePadding(
        context: context,
        removeRight: true,
        child: AppBar(
          title: widget.title,
          actions: widget.actions,
          centerTitle: widget.centerTitle,
          toolbarHeight: widget.toolbarHeight,
          automaticallyImplyLeading: false,
        ),
      ),
    );
  }
}

/// The shared full-window route header. Prefer [faRouteAppBar] at call sites.
final class FaRouteHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const FaRouteHeader({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.centerTitle,
    double? toolbarHeight,
  }) : toolbarHeight = toolbarHeight ?? kToolbarHeight;

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool? centerTitle;
  final double toolbarHeight;

  @override
  Size get preferredSize =>
      Size.fromHeight(FaWindowChrome.titlebarHeight + toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appBarTheme = AppBarTheme.of(context);
    final centered = centerTitle ?? true;
    final titleStyle =
        appBarTheme.titleTextStyle ??
        theme.textTheme.titleLarge ??
        const TextStyle(fontSize: 20, fontWeight: FontWeight.w500);
    return Material(
      color: appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      elevation: appBarTheme.elevation ?? 0,
      child: Column(
        children: [
          SizedBox(
            key: const ValueKey('faRouteTitlebar'),
            height: FaWindowChrome.titlebarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 72),
              child: Align(
                alignment: centered ? Alignment.center : Alignment.centerLeft,
                child: DefaultTextStyle.merge(
                  style: titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: title ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          SizedBox(
            key: const ValueKey('faRouteNavigationRow'),
            height: toolbarHeight,
            child: AppBar(
              automaticallyImplyLeading: leading == null,
              leading: leading,
              actions: actions,
              centerTitle: centerTitle,
              toolbarHeight: toolbarHeight,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
            ),
          ),
        ],
      ),
    );
  }
}
