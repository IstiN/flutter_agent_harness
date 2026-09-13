// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'chat_strings.dart';

/// One action of [FaAdaptiveHeader].
///
/// Either an icon-driven bar button ([icon]) or a host-styled [widget] (see
/// [FaChatHeaderAction]); [label] feeds both the bar tooltip and the
/// overflow-menu row. Actions render in list order — the list IS the
/// priority order, and demotion on tight widths removes from the tail, so
/// order primary actions first (files, trajectory) and secondary ones last
/// (copy, ✦, apps).
class FaHeaderAction {
  const FaHeaderAction({
    this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.pinned = false,
  }) : widget = null;

  /// A host-styled bar button with its overflow-menu metadata.
  const FaHeaderAction.widget({
    this.key,
    required this.widget,
    required this.label,
    required this.onPressed,
    this.pinned = false,
  }) : icon = null;

  /// The key for the inline bar button (lookup in widget tests).
  final Key? key;

  /// The bar icon; null only for [FaHeaderAction.widget] actions.
  final IconData? icon;

  /// The host-styled inline bar widget; null for icon actions.
  final Widget? widget;

  /// The bar tooltip AND the overflow-menu label (accessibility keeps the
  /// action's name wherever it renders — issue #225).
  final String label;

  /// Invoked on tap (bar) or menu selection (overflow).
  final VoidCallback? onPressed;

  /// Never demotes into the overflow menu (the streaming stop button must
  /// stay one tap away — issue #225 E2).
  final bool pinned;
}

/// The ONE adaptive header row (issue #225): project identity · chat title ·
/// model chip · action icons · ⋮ overflow, in a single row that adapts at
/// any width. Whatever the fixed-width content cannot fit demotes into the
/// ⋮ menu automatically — text yields before icons move, and the model chip
/// demotes last among the actions.
///
/// Surfaces:
/// - `FaChatScreen`'s app bar (title slot) — the merged chat/project bar;
/// - the session chat sheet's header row — the same widget family, styled
///   compact, so there is no third header variant.
///
/// The widget is a bare [Row] under a [LayoutBuilder]: the caller supplies
/// outer padding (the sheet wraps it; the app bar's `titleSpacing` covers
/// the chat bar). RTL mirrors the row; the ⋮ stays at the trailing edge.
class FaAdaptiveHeader extends StatelessWidget {
  const FaAdaptiveHeader({
    super.key,
    this.leading,
    this.title,
    this.titleStyle,
    this.projectIcon,
    this.projectIconColor,
    this.projectLabel,
    this.projectStyle,
    this.onProjectTap,
    this.chip,
    this.chipMaxWidth = 132,
    this.actions = const <FaHeaderAction>[],
    this.menuItems = const <PopupMenuEntry<String>>[],
    this.onMenuSelected,
    this.menuColor,
    this.overflowMenuKey,
    this.overflowTooltip,
    this.visualDensity = VisualDensity.standard,
    this.iconSize = 24,
  });

  /// Rendered before the project slot (the sheet's sessions glyph).
  final Widget? leading;

  /// The chat title (ellipsized; yields before icons move).
  final String? title;

  /// Title style; null inherits the ambient [DefaultTextStyle] (the app
  /// bar's `titleTextStyle`).
  final TextStyle? titleStyle;

  /// The project identity icon (folder glyph).
  final IconData? projectIcon;

  /// The project icon color (indigo when the session has a folder).
  final Color? projectIconColor;

  /// The project identity label ("Personal" or the folder basename).
  final String? projectLabel;

  /// Project label style; null inherits the ambient text style.
  final TextStyle? projectStyle;

  /// Invoked on the project pill's tap (the session info dialog).
  final VoidCallback? onProjectTap;

  /// The inline model chip (a first-class citizen; demotes last among the
  /// actions, only under extreme width).
  final Widget? chip;

  /// Width budget the fit arithmetic reserves for [chip]. The chip is
  /// host-built and ellipsis-capped by the same value in practice; an
  /// over-reserve only demotes an icon a few px early, never overflows.
  final double chipMaxWidth;

  /// Priority-ordered actions; the tail demotes into the ⋮ menu first.
  final List<FaHeaderAction> actions;

  /// Menu-only entries (the sheet's new/rename/full/copy/close); they keep
  /// the ⋮ visible even when every action fits inline (issue #225 E4 is
  /// the reverse: no demotion AND no menu items hides the ⋮).
  final List<PopupMenuEntry<String>> menuItems;

  /// Invoked with a [menuItems] value on selection.
  final ValueChanged<String>? onMenuSelected;

  /// The overflow menu's background color (the sheet passes its panel alt).
  final Color? menuColor;

  /// The ⋮ button's key (lookup in widget tests).
  final Key? overflowMenuKey;

  /// The ⋮ button's tooltip; defaults to [FaChatStrings.chatMoreTooltip].
  final String? overflowTooltip;

  /// Button density: compact on the sheet (40px slots), standard in the
  /// app bar (48px slots).
  final VisualDensity visualDensity;

  /// Bar icon size (24 in the app bar, 20 on the sheet).
  final double iconSize;

  /// One action slot's width: [IconButton]'s minimum interactive dimension
  /// adjusted by the density, which is exactly how the bar buttons size.
  double get _slot => 48 + 4 * visualDensity.horizontal;

  @override
  Widget build(BuildContext context) {
    final strings = FaChatStrings.of(context);
    final hasProject = projectIcon != null || projectLabel != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final demotable = [
          for (final action in actions)
            if (!action.pinned) action,
        ];
        final pinnedCount = actions.length - demotable.length;
        final overflowVisible = menuItems.isNotEmpty;

        // Greedy fit: keep as many demotable actions inline as the fixed
        // content allows, demoting tail-first (secondary before primary).
        // ponytail: the chip/pill budgets are caps, not measurements — a
        // render-object fit is the upgrade path if real widths ever drift.
        var inline = demotable.length;
        final chipBudget = chip != null ? chipMaxWidth : 0.0;
        final pillMin = hasProject ? (onProjectTap != null ? 38.0 : 22.0) : 0.0;
        double widthFor(int n, double chipWidth) =>
            (leading != null ? _slot : 0) +
            pillMin +
            chipWidth +
            pinnedCount * _slot +
            n * _slot +
            ((n < demotable.length || overflowVisible) ? _slot : 0);
        while (inline > 0 &&
            widthFor(inline, chipBudget) > constraints.maxWidth) {
          inline--;
        }
        // The chip demotes last (issue #225): only when even with every
        // action in the menu the row still cannot fit it.
        final chipInline = chip != null &&
            widthFor(0, chipBudget) <= constraints.maxWidth;
        // The pill never participates in a flex split that could undercut
        // its icon minimum: it gets all remaining space it may use (35%
        // share, at least its minimum), and the title absorbs the rest.
        final fixedForText = (leading != null ? _slot : 0) +
            (chipInline ? chipBudget : 0) +
            pinnedCount * _slot +
            inline * _slot +
            ((inline < demotable.length || overflowVisible) ? _slot : 0);
        final availableForText = constraints.maxWidth - fixedForText;
        var pillCap = availableForText * 0.35;
        if (pillCap < pillMin) pillCap = pillMin;
        if (pillCap > availableForText) pillCap = availableForText;
        final overflow = demotable.sublist(inline);

        return Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 4)],
            if (hasProject)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: pillCap),
                child: _projectPill(context),
              ),
            if (title != null)
              Expanded(
                flex: hasProject ? 2 : 1,
                child: Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              )
            else if (!hasProject)
              const Spacer(),
            if (chipInline) chip!,
            // Pinned actions render unconditionally at the head of the
            // action group; only the demotable tail shrinks.
            for (final action in actions)
              if (action.pinned) _barButton(action),
            for (final action in demotable.sublist(0, inline))
              _barButton(action),
            if (inline < demotable.length || overflowVisible)
              PopupMenuButton<String>(
                key: overflowMenuKey,
                icon: Icon(Icons.more_vert, size: iconSize),
                tooltip: overflowTooltip ?? strings.chatMoreTooltip,
                color: menuColor,
                itemBuilder: (context) => [
                  for (var i = 0; i < overflow.length; i++)
                    PopupMenuItem<String>(
                      value: 'action:$i',
                      child: Row(
                        children: [
                          if (overflow[i].icon != null) ...[
                            Icon(overflow[i].icon, size: 20),
                            const SizedBox(width: 12),
                          ],
                          Expanded(child: Text(overflow[i].label)),
                        ],
                      ),
                    ),
                  ...menuItems,
                ],
                onSelected: (value) {
                  if (value.startsWith('action:')) {
                    overflow[int.parse(value.substring(7))].onPressed?.call();
                  } else {
                    onMenuSelected?.call(value);
                  }
                },
              ),
          ],
        );
      },
    );
  }

  /// The project identity pill: icon + ellipsized label, tappable when the
  /// surface wires [onProjectTap] (the wide shell's session info dialog).
  Widget _projectPill(BuildContext context) {
    final label = Text(
      projectLabel ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: projectStyle,
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (projectIcon != null) ...[
          Icon(projectIcon, size: 16, color: projectIconColor),
          const SizedBox(width: 6),
        ],
        Flexible(child: label),
      ],
    );
    if (onProjectTap == null) return row;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onProjectTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: row,
        ),
      ),
    );
  }

  /// The inline bar button of [action]: the host-styled widget when the
  /// action carries one, otherwise a plain icon button.
  Widget _barButton(FaHeaderAction action) {
    if (action.widget != null) return action.widget!;
    return IconButton(
      key: action.key,
      icon: Icon(action.icon, size: iconSize),
      tooltip: action.label,
      visualDensity: visualDensity,
      onPressed: action.onPressed,
    );
  }
}
