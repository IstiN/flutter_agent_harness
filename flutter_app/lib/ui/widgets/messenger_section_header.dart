// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

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
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 3),
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
          ),
          child: ProgressiveBlur(
            key: underlayKey,
            maxSigma: 8,
            direction: ProgressiveBlurDirection.topToBottom,
            falloff: 3.0,
          ),
        ),
      ),
    );
  }
}

/// Shared simple messenger panel: one header, a body starting at its real
/// bottom, and the approved 6pt glass tail above scrolling content. Hosts
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
            child: Padding(
              padding: EdgeInsets.only(top: headerHeight),
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
    this.leading,
    this.trailing,
    this.newButtonKey,
    this.compact = false,
    this.collapsed = false,
  });

  final String title;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
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
    // The real-glass frame's 1pt border insets its child; opaque frames do
    // not. Compensate the row height so every visual direction keeps the
    // same absolute action centerline instead of drifting by one pixel.
    final glassFrameInset = tokens.direction == FaVisualDirection.glass
        ? 1.0
        : 0.0;
    final contentHeight = compact
        ? 54.0
        : (isMac ? 54.0 : 58.0) - 2 * glassFrameInset;
    // Only the narrow compact header sits beside the native traffic lights
    // and needs their 30pt clearance. The wide sidebar starts to their right:
    // its search/actions share the chat and Files centerline at y=35 instead
    // of dropping into a second row below the titlebar.
    final titlebarHeight = isMac
        ? (compact ? 30.0 : 0.0)
        : (collapsed ? 58.0 : 0.0);
    final brand = Semantics(
      button: onBrandTap != null || onProfile != null,
      label: context.l10n.chatProfileSettings,
      child: GestureDetector(
        key: const ValueKey('messengerProfile'),
        onTap: onBrandTap ?? onProfile,
        onLongPress: onBrandLongPress,
        child: const SizedBox.square(
          key: ValueKey('wideShellFaBrand'),
          dimension: 30,
          child: FaLogo(size: 30),
        ),
      ),
    );
    // WideLayoutShell owns the single toggle so it can follow the animated
    // sidebar boundary without duplicating actions in the two content states.
    return Transform.translate(
      offset: Offset(compact || collapsed ? 0 : -glassFrameInset, 0),
      child: Container(
        height: titlebarHeight + (collapsed ? 46.0 : contentHeight),
        color: tokens.direction == FaVisualDirection.glass
            ? Colors.transparent
            : colors.panel,
        child: Column(
          children: [
            if (titlebarHeight > 0)
              SizedBox(
                key: const ValueKey('macosSidebarTitlebar'),
                width: double.infinity,
                height: titlebarHeight,
              ),
            if (collapsed)
              SizedBox(height: 46, child: Center(child: brand))
            else
              SizedBox(
                height: contentHeight,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(compact ? 12 : 10, 7, 10, 7),
                  child: Row(
                    children: [
                      leading ?? brand,
                      if (compact && searchController != null) ...[
                        const SizedBox(width: 8),
                        // A fixed title slot keeps Search at the same geometry
                        // for Chats, Activity and Apps in the compact shell.
                        SizedBox(
                          width: 64,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      SizedBox(width: searchController == null ? 8 : 6),
                      if (searchController != null)
                        // THE one search field (SessionSearchField): the
                        // same capsule the Files band renders.
                        Expanded(
                          child: SessionSearchField(
                            key: const ValueKey('messengerSearchField'),
                            controller: searchController,
                            focusNode: searchFocusNode,
                            hintText: searchHint,
                            onQueryChanged: onSearch,
                          ),
                        )
                      else
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: compact ? 16 : 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (onNew != null &&
                          (!compact || searchController == null)) ...[
                        const SizedBox(width: 8),
                        SizedBox.square(
                          dimension: 32,
                          child: IconButton.filled(
                            key:
                                newButtonKey ??
                                const ValueKey('messengerNewButton'),
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
                      ],
                      if (trailing != null) ...[
                        const SizedBox(width: 4),
                        trailing!,
                      ],
                      if (!compact && onCollapse != null) ...[
                        const SizedBox(width: 4),
                        const SizedBox.square(dimension: 36),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
