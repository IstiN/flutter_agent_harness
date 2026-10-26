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
    this.onChipTap,
    this.chipMenuLabel,
    this.chipMenuIcon = Icons.memory,
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

  /// Invoked when the demoted model chip is picked from the ⋮ menu (the
  /// same picker the inline chip opens on tap — issue #225 AC3: model
  /// switching stays reachable at widths that cannot fit the chip).
  final VoidCallback? onChipTap;

  /// The ⋮-menu row label for the demoted model chip (the model id).
  /// Null falls back to the chip-tap route with a generic label.
  final String? chipMenuLabel;

  /// The ⋮-menu row icon for the demoted model chip.
  final IconData? chipMenuIcon;

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

  /// Whether a project identity pill renders (either half present).
  bool get _hasProject => projectIcon != null || projectLabel != null;

  /// The leading slot's width (0 when absent).
  double get _leadingWidth => leading != null ? _slot : 0.0;

  /// Width budget the fit arithmetic reserves for the chip (0 when absent).
  double get _chipBudget => chip != null ? chipMaxWidth : 0.0;

  /// The project pill's minimum width (0 when absent): a tappable pill
  /// needs its icon+label minimum, a bare identity needs less.
  double get _pillMin {
    if (!_hasProject) return 0.0;
    return onProjectTap != null ? 38.0 : 22.0;
  }

  /// The demotable (non-pinned) actions, in order — the tail that shrinks
  /// on tight widths.
  List<FaHeaderAction> get _demotable => [
    for (final action in actions)
      if (!action.pinned) action,
  ];

  /// The ⋮ slot's width: present when more actions may demote or
  /// menu-only entries keep the menu alive.
  double _overflowSlot(int inline, int demotableCount, bool overflowVisible) =>
      (inline < demotableCount || overflowVisible) ? _slot : 0.0;

  /// Greedy-fit width: the fixed content plus [inline] demotable slots
  /// and [chipWidth] of chip budget.
  // ponytail: the chip/pill budgets are caps, not measurements — a
  // render-object fit is the upgrade path if real widths ever drift.
  double _widthFor({
    required int inline,
    required double chipWidth,
    required int demotableCount,
    required int pinnedCount,
    required bool overflowVisible,
  }) =>
      _leadingWidth +
      _pillMin +
      chipWidth +
      pinnedCount * _slot +
      inline * _slot +
      _overflowSlot(inline, demotableCount, overflowVisible);

  /// How many demotable actions stay inline at [maxWidth]: the greedy
  /// tail-first demotion (secondary before primary, issue #225).
  int _inlineCount({
    required int demotableCount,
    required int pinnedCount,
    required double chipWidth,
    required bool overflowVisible,
    required double maxWidth,
  }) {
    var inline = demotableCount;
    while (inline > 0 &&
        _widthFor(
              inline: inline,
              chipWidth: chipWidth,
              demotableCount: demotableCount,
              pinnedCount: pinnedCount,
              overflowVisible: overflowVisible,
            ) >
            maxWidth) {
      inline--;
    }
    return inline;
  }

  /// The title/pill text budget split: the pill gets up to a 35% share,
  /// never under [pillMin] and never over the available space.
  double _pillCap(double availableForText, double pillMin) {
    var cap = availableForText * 0.35;
    if (cap < pillMin) cap = pillMin;
    if (cap > availableForText) cap = availableForText;
    return cap;
  }

  /// One fit pass: greedy demotion, chip-demotes-last, and the pill cap.
  _HeaderFit _planFit(BoxConstraints constraints) {
    final demotable = _demotable;
    final pinnedCount = actions.length - demotable.length;
    final overflowVisible = menuItems.isNotEmpty;
    final chipWidth = _chipBudget;
    final inlineCount = _inlineCount(
      demotableCount: demotable.length,
      pinnedCount: pinnedCount,
      chipWidth: chipWidth,
      overflowVisible: overflowVisible,
      maxWidth: constraints.maxWidth,
    );
    // The chip demotes last (issue #225): only when even with every
    // action in the menu the row still cannot fit it.
    final chipInline =
        chip != null &&
        _widthFor(
              inline: 0,
              chipWidth: chipWidth,
              demotableCount: demotable.length,
              pinnedCount: pinnedCount,
              overflowVisible: overflowVisible,
            ) <=
            constraints.maxWidth;
    // The pill never participates in a flex split that could undercut
    // its icon minimum: it gets all remaining space it may use (35%
    // share, at least its minimum), and the title absorbs the rest.
    final fixedForText =
        _leadingWidth +
        (chipInline ? chipWidth : 0.0) +
        pinnedCount * _slot +
        inlineCount * _slot +
        _overflowSlot(inlineCount, demotable.length, overflowVisible);
    final availableForText = constraints.maxWidth - fixedForText;
    return _HeaderFit(
      inlineCount: inlineCount,
      chipInline: chipInline,
      pillCap: _pillCap(availableForText, _pillMin),
      overflow: demotable.sublist(inlineCount),
      showOverflow: inlineCount < demotable.length || overflowVisible,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildRow(context, FaChatStrings.of(context), _planFit(constraints)),
    );
  }

  /// The row for one fit pass (the [LayoutBuilder] body).
  Widget _buildRow(
    BuildContext context,
    FaChatStrings strings,
    _HeaderFit fit,
  ) => Row(
    children: [
      ..._leadingRegion(),
      if (_hasProject)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: fit.pillCap),
          child: _projectPill(context),
        ),
      _titleRegion(_hasProject),
      if (fit.chipInline) chip!,
      ..._actionsRegion(fit),
      if (fit.showOverflow) _overflowMenu(context, strings, fit),
    ],
  );

  /// The row's leading slot (the sheet's sessions glyph).
  List<Widget> _leadingRegion() =>
      leading == null ? const <Widget>[] : [leading!, const SizedBox(width: 4)];

  /// The title slot: ellipsized text, or a spacer when the header has
  /// neither title nor project identity.
  Widget _titleRegion(bool hasProject) {
    if (title == null) {
      return hasProject ? const SizedBox.shrink() : const Spacer();
    }
    return Expanded(
      flex: hasProject ? 2 : 1,
      child: Text(
        title!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      ),
    );
  }

  /// The action group: pinned actions render unconditionally at the head
  /// (only the demotable tail shrinks), then the inline head of the tail.
  List<Widget> _actionsRegion(_HeaderFit fit) => [
    for (final action in actions)
      if (action.pinned) _barButton(action),
    for (final action in _demotable.sublist(0, fit.inlineCount))
      _barButton(action),
  ];

  /// The ⋮-menu row for the demoted model chip, or null when the chip
  /// rendered inline (or no tap route exists).
  PopupMenuItem<String>? _chipMenuItem(FaChatStrings strings, _HeaderFit fit) {
    if (chip == null || fit.chipInline || onChipTap == null) return null;
    return PopupMenuItem<String>(
      value: 'chip',
      child: Row(
        children: [
          Icon(chipMenuIcon, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              chipMenuLabel ?? strings.chatModelPicker,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// The ⋮-menu rows for the demoted actions, in demotion order.
  List<PopupMenuItem<String>> _actionMenuItems(_HeaderFit fit) => [
    for (var i = 0; i < fit.overflow.length; i++)
      PopupMenuItem<String>(
        value: 'action:$i',
        child: Row(
          children: [
            if (fit.overflow[i].icon != null) ...[
              Icon(fit.overflow[i].icon, size: 20),
              const SizedBox(width: 12),
            ],
            Expanded(child: Text(fit.overflow[i].label)),
          ],
        ),
      ),
  ];

  /// Routes a ⋮ selection: the demoted chip reopens the model picker, an
  /// `action:N` value fires the demoted action, anything else is a
  /// menu-only entry.
  void _onOverflowSelected(String value, _HeaderFit fit) {
    if (value == 'chip') {
      onChipTap?.call();
    } else if (value.startsWith('action:')) {
      fit.overflow[int.parse(value.substring(7))].onPressed?.call();
    } else {
      onMenuSelected?.call(value);
    }
  }

  /// The ⋮ overflow menu: the demoted chip (issue #225 AC3), the demoted
  /// actions, then the host's menu-only entries.
  Widget _overflowMenu(
    BuildContext context,
    FaChatStrings strings,
    _HeaderFit fit,
  ) {
    final chipItem = _chipMenuItem(strings, fit);
    return PopupMenuButton<String>(
      key: overflowMenuKey,
      icon: Icon(Icons.more_vert, size: iconSize),
      tooltip: overflowTooltip ?? strings.chatMoreTooltip,
      color: menuColor,
      itemBuilder: (context) => [
        ?chipItem,
        ..._actionMenuItems(fit),
        ...menuItems,
      ],
      onSelected: (value) => _onOverflowSelected(value, fit),
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
  /// action carries one, otherwise a plain icon button. The action's key
  /// stays attached whichever form renders (widget actions included).
  Widget _barButton(FaHeaderAction action) {
    if (action.widget != null) {
      return KeyedSubtree(key: action.key, child: action.widget!);
    }
    return IconButton(
      key: action.key,
      icon: Icon(action.icon, size: iconSize),
      tooltip: action.label,
      visualDensity: visualDensity,
      onPressed: action.onPressed,
    );
  }
}

/// The width-fit outcome for one [FaAdaptiveHeader] layout pass: how many
/// actions stay inline, whether the chip fits, and what the ⋮ menu carries.
final class _HeaderFit {
  const _HeaderFit({
    required this.inlineCount,
    required this.chipInline,
    required this.pillCap,
    required this.overflow,
    required this.showOverflow,
  });

  /// Demotable actions kept inline (the tail demotes first).
  final int inlineCount;

  /// Whether the model chip renders inline (it demotes last, issue #225).
  final bool chipInline;

  /// The project pill's max width for this pass.
  final double pillCap;

  /// The actions demoted into the ⋮ menu, in demotion order.
  final List<FaHeaderAction> overflow;

  /// Whether the ⋮ button renders at all.
  final bool showOverflow;
}
