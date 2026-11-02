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
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final fg = selected ? tokens.accent : tokens.ink2;
    final selectedBg = tokens.accentSoft;

    if (desktopTab && !collapsed) {
      return Semantics(
        button: true,
        selected: selected,
        child: Material(
          key: ValueKey('messengerPrimaryTab-$label'),
          color: Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
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
                      color: fg,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                    child: Text(
                      label,
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

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: collapsed
            ? Semantics(
                selected: selected,
                child: IconButton(
                  onPressed: onTap,
                  tooltip: label,
                  icon: Icon(icon, size: 18, color: fg),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    maximumSize: const Size(40, 40),
                    padding: EdgeInsets.zero,
                    foregroundColor: fg,
                    backgroundColor: selected ? selectedBg : Colors.transparent,
                    shape: const StadiumBorder(),
                  ),
                ),
              )
            : MessengerCategoryChip(
                chipKey: ValueKey('messengerPrimaryChip-$label'),
                icon: icon,
                label: label,
                selected: selected,
                compact: true,
                onTap: onTap,
              ),
      );
    }

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Material(
          color: selected ? selectedBg : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(tokens.radiusSm),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(tokens.radiusSm),
            child: Tooltip(
              message: label,
              child: SizedBox(
                height: 42,
                child: Center(child: Icon(icon, size: 22, color: fg)),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: selected ? selectedBg : Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 22, color: fg),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: typography.label.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w500,
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
