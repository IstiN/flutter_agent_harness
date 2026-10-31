import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

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
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final typography = FaTypography.of(context);
    final fg = selected ? tokens.accent : tokens.ink2;
    final selectedBg = tokens.accentSoft;

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
        child: Material(
          color: selected ? selectedBg : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(tokens.radiusSm),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(tokens.radiusSm),
            child: SizedBox(
              height: 34,
              child: Center(
                child: collapsed
                    ? Tooltip(
                        message: label,
                        child: Icon(icon, size: 18, color: fg),
                      )
                    : Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.label.copyWith(
                          color: fg,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
            ),
          ),
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
