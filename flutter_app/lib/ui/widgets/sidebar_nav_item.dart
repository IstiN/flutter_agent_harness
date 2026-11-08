import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'messenger_navigation_controls.dart';

/// One navigation row in the wide-screen sidebar, or a compact primary tab.
/// The selected destination uses Fa2 accent tokens. When [collapsed] is true
/// only the centered icon is shown with a [Tooltip] revealing the label.
class SidebarNavItem extends StatelessWidget {
  const SidebarNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
    this.compact = false,
    this.desktopTab = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final bool compact;
  final bool desktopTab;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (desktopTab && !collapsed) {
      return _DesktopSidebarNavItem(item: this);
    }
    return _SidebarNavItemBody(item: this);
  }
}

class _SidebarNavItemBody extends StatelessWidget {
  const _SidebarNavItemBody({required this.item});

  final SidebarNavItem item;

  @override
  Widget build(BuildContext context) {
    if (item.compact) return _CompactSidebarNavItem(item: item);
    if (item.collapsed) return _CollapsedSidebarNavItem(item: item);
    return _ExpandedSidebarNavItem(item: item);
  }
}

class _DesktopSidebarNavItem extends StatelessWidget {
  const _DesktopSidebarNavItem({required this.item});

  final SidebarNavItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final foreground = item.selected ? tokens.accent : tokens.ink2;
    return Semantics(
      button: true,
      selected: item.selected,
      child: Material(
        key: ValueKey('messengerPrimaryTab-${item.label}'),
        color: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: item.onTap,
          child: SizedBox(
            height: 32,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: AnimatedDefaultTextStyle(
                  duration: FaMotion.duration(
                    context,
                    const Duration(milliseconds: 200),
                  ),
                  curve: Curves.easeInOutCubic,
                  style: typography.label.copyWith(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: item.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSidebarNavItem extends StatelessWidget {
  const _CompactSidebarNavItem({required this.item});

  final SidebarNavItem item;

  @override
  Widget build(BuildContext context) {
    if (item.collapsed) return _CompactCollapsedSidebarNavItem(item: item);
    return MessengerCategoryChip(
      chipKey: ValueKey('messengerPrimaryChip-${item.label}'),
      icon: item.icon,
      label: item.label,
      selected: item.selected,
      compact: true,
      onTap: item.onTap,
    );
  }
}

class _CompactCollapsedSidebarNavItem extends StatelessWidget {
  const _CompactCollapsedSidebarNavItem({required this.item});

  final SidebarNavItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final foreground = item.selected ? tokens.accent : tokens.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Semantics(
        selected: item.selected,
        child: IconButton(
          onPressed: item.onTap,
          tooltip: item.label,
          icon: Icon(item.icon, size: 18, color: foreground),
          style: IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            maximumSize: const Size(40, 40),
            padding: EdgeInsets.zero,
            foregroundColor: foreground,
            backgroundColor: item.selected
                ? tokens.accentSoft
                : Colors.transparent,
            shape: const StadiumBorder(),
          ),
        ),
      ),
    );
  }
}

class _CollapsedSidebarNavItem extends StatelessWidget {
  const _CollapsedSidebarNavItem({required this.item});

  final SidebarNavItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final foreground = item.selected ? tokens.accent : tokens.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: item.selected ? tokens.accentSoft : Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: item.onTap,
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          child: Tooltip(
            message: item.label,
            child: SizedBox(
              height: 42,
              child: Center(
                child: Icon(item.icon, size: 22, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandedSidebarNavItem extends StatelessWidget {
  const _ExpandedSidebarNavItem({required this.item});

  final SidebarNavItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final foreground = item.selected ? tokens.accent : tokens.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: item.selected ? tokens.accentSoft : Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: item.onTap,
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(item.icon, size: 22, color: foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: typography.label.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w500,
                    ),
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
