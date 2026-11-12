// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';
import '../widgets/fa2_controls.dart' show FaSurface;
import 'chat_strings.dart';

/// One action of [FaAdaptiveHeader].
///
/// Either an icon-driven bar button ([icon]) or a host-styled [widget] (see
/// [FaChatHeaderAction]); [label] feeds both the bar tooltip and the
/// overflow-menu row. Actions render in list order — the list IS the
/// priority order, and demotion on tight widths removes from the tail, so
/// order primary actions first and secondary ones last (copy, ✦, apps);
/// pinned actions always render at the head of the group regardless of
/// list position.
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

/// Builds one grouped visual surface for the adaptive header's inline
/// actions and overflow. The header still owns fit/demotion and menu
/// routing; the builder owns only the chrome (for example
/// `FaIconActionBand`). When supplied, it replaces [FaAdaptiveHeader.actionBuilder]
/// and [FaAdaptiveHeader.overflowBuilder] in the regular row.
typedef FaHeaderActionBandBuilder =
    Widget Function(
      BuildContext context,
      List<FaHeaderAction> actions,
      List<PopupMenuEntry<String>> overflowItems,
      ValueChanged<String> onOverflowSelected,
    );

/// The narrow shell's canonical floating header bar geometry — the ONE
/// bar height every mobile header strip shares, so the chats, Apps,
/// trajectory, and opened-app chrome read as a single system on a phone.
///
/// The chat floating glass header is the reference implementation: 6pt
/// vertical air, then a 91pt content column (11pt identity air, the 36pt
/// leading circle, a 4pt gap, the 40pt title pill) whose action band
/// (top 9, height 40) shares the circle's centerline. Every other narrow
/// header bar sizes itself from these constants instead of private
/// literals, and the goldens assert the four strips stay equal
/// (`narrow_ios_header_heights_golden_test.dart`).
abstract final class FaFloatingHeaderBar {
  /// Horizontal air around the bar's content column.
  static const double padHorizontal = 8;

  /// Vertical air above and below the content column (the chat header's
  /// `EdgeInsets.fromLTRB(8, 6, 8, 6)`).
  static const double padVertical = 6;

  /// Air between the content column's top edge and the leading circle.
  static const double iconTop = 11;

  /// The leading circle's edge (chat avatar, Apps icon, back buttons).
  static const double actionDimension = 36;

  /// Gap between the leading circle and the title pill.
  static const double iconTitleGap = 4;

  /// The centered title pill's height (the chat/app bar's control band
  /// height too: actions ride `top 9 + 40`).
  static const double pillHeight = 40;

  /// The action band's top inset inside the content column; its 40pt band
  /// shares the leading circle's centerline (11 + 36/2 == 9 + 40/2).
  static const double actionBandTop = 9;

  /// The content column's height: 11 + 36 + 4 + 40.
  static const double contentHeight =
      iconTop + actionDimension + iconTitleGap + pillHeight;

  /// The full bar strip extent below the safe area: 6 + 91 + 6. On an
  /// iPhone (status bar 59) the chat header's measured
  /// `_glassHeaderExtent` is `59 + barExtent` = 162.
  static const double barExtent = padVertical + contentHeight + padVertical;
}

/// The ONE circular chrome for icon actions (the painter behind
/// [FaIconActionButton], the styleguide's canonical circular icon
/// control). Token-driven surface fill + hairline ring — the same style
/// for every direction and brightness; call sites never pick a surface
/// gray. The child keeps its own tooltip, disabled state and InkResponse;
/// Material supplies the hover/press overlay, and the merged [IconTheme]
/// pins the one ink token (ink1) at the 18px glyph scale.
///
/// [dimension] keeps the family parameterized: the chat header's 40pt
/// bar chrome stays the default, while the Files chrome and every other
/// control-scale circle run the composer's 36pt
/// ([FaIconActionButton.defaultDiameter]).
///
/// [glass] is the state-conditional underlay (owner rule): flat token
/// surface when the circle sits on a parent surface (the Files band, the
/// narrow header slab — the parent already provides its backdrop), and a
/// liquid-glass disc when it floats on the chat header's backdrop with
/// no panel of its own.
class FaHeaderCircularAction extends StatelessWidget {
  const FaHeaderCircularAction({
    super.key,
    required this.child,
    this.dimension = 40,
    this.glass = false,
  }) : assert(dimension > 0);

  final Widget child;

  /// The circle's edge length (the chat bar's chrome is 40pt; control
  /// scale circles pass 36).
  final double dimension;

  /// Whether the chrome rides a glass underlay (floating header state).
  /// Default false — the flat token surface, for circles on parent
  /// surfaces.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    if (glass && tokens.direction == FaVisualDirection.glass) {
      // The glass IS the surface: the kit disc (AdaptiveGlass via FaSurface,
      // Fa-tuned per the pixel audit) replaces the opaque token fill — the
      // old surface1@.94 fill plus surface2 chrome smothered the shader's
      // rim and the under-disc refraction (the murky-disc regression). Only
      // a transparent ink host rides inside so child InkResponses keep a
      // Material ancestor.
      return FaSurface(
        glass: true,
        circular: true,
        useBackdropGroup: true,
        color: tokens.surface1.withValues(alpha: .45),
        child: SizedBox.square(
          dimension: dimension,
          child: Material(
            type: MaterialType.transparency,
            child: IconTheme.merge(
              data: IconThemeData(size: 18, color: tokens.ink1),
              child: child,
            ),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: dimension,
      child: Material(
        color: tokens.surface2,
        shape: CircleBorder(side: BorderSide(color: tokens.hairline)),
        clipBehavior: Clip.antiAlias,
        child: IconTheme.merge(
          data: IconThemeData(size: 18, color: tokens.ink1),
          child: child,
        ),
      ),
    );
  }
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
    this.chipMinWidth,
    this.onChipTap,
    this.chipMenuLabel,
    this.chipMenuIcon = Icons.memory,
    this.actions = const <FaHeaderAction>[],
    this.menuItems = const <PopupMenuEntry<String>>[],
    this.onMenuSelected,
    this.actionBuilder,
    this.overflowBuilder,
    this.actionBandBuilder,
    this.compactActionLimit,
    this.menuColor,
    this.overflowMenuKey,
    this.overflowTooltip,
    this.visualDensity = VisualDensity.standard,
    this.iconSize = 24,
    this.actionGap = 0,
  }) : assert(actionGap >= 0),
       assert(
         chipMinWidth == null ||
             (chipMinWidth >= 0 && chipMinWidth <= chipMaxWidth),
       );

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

  /// Maximum rendered width for [chip].
  final double chipMaxWidth;

  /// Optional fit reserve for an action-only header's flexible chip.
  ///
  /// Fit/demotion reserves this smaller width, then the inline chip may grow
  /// into the actual remainder up to [chipMaxWidth]. Null preserves the
  /// original fixed-reserve behavior for generic title/project headers.
  final double? chipMinWidth;

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

  /// Optional chrome wrapper for an inline action (used by floating glass).
  final Widget Function(
    BuildContext context,
    FaHeaderAction action,
    Widget button,
  )?
  actionBuilder;

  /// Optional chrome wrapper for the overflow action.
  final Widget Function(BuildContext context, Widget button)? overflowBuilder;

  /// Optional single-surface renderer for inline actions plus overflow.
  /// Fit, demotion and menu callbacks stay owned by this header.
  final FaHeaderActionBandBuilder? actionBandBuilder;

  /// Maximum inline actions for a compact pane whose model control has its
  /// own overflow route. Null preserves the unrestricted greedy fit.
  final int? compactActionLimit;

  /// The overflow menu's background color (the sheet passes its panel alt).
  final Color? menuColor;

  /// The ⋮ button's key (lookup in widget tests).
  final Key? overflowMenuKey;

  /// The ⋮ button's tooltip; defaults to [FaChatStrings.chatMoreTooltip].
  final String? overflowTooltip;

  /// Button density: compact on the sheet (40px slots), standard in the
  /// app bar (48px slots).
  final VisualDensity visualDensity;

  /// Bar icon size (24 in the app bar, 18 for compact circular actions).
  final double iconSize;

  /// Visual gap between adjacent inline/overflow action slots. Included in
  /// fit arithmetic so adding chrome spacing only demotes actions earlier.
  final double actionGap;

  /// One action slot's width: [IconButton]'s minimum interactive dimension
  /// adjusted by the density, which is exactly how the bar buttons size.
  // The grouped glass band adds 2pt on each side of its 36pt control.
  double get _slot => 48 + 4 * visualDensity.horizontal;
  double _bandWidth(int slots) =>
      actionBandBuilder != null &&
          compactActionLimit != null &&
          visualDensity.horizontal == -2
      ? slots * 40 + (slots > 0 ? 4 : 0)
      : slots * _slot + (slots > 0 ? (slots - 1) * actionGap : 0);

  /// Whether a project identity pill renders (either half present).
  bool get _hasProject => projectIcon != null || projectLabel != null;

  /// The leading slot's width (0 when absent).
  double get _leadingWidth => leading != null ? _slot + 4 : 0.0;

  /// Width budget the fit arithmetic reserves for the chip (0 when absent).
  double get _chipBudget => chip != null ? (chipMinWidth ?? chipMaxWidth) : 0.0;

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

  double _actionsWidth({
    required int inline,
    required int demotableCount,
    required int pinnedCount,
    required bool overflowVisible,
  }) {
    final overflow = _overflowSlot(inline, demotableCount, overflowVisible) > 0;
    final count = pinnedCount + inline + (overflow ? 1 : 0);
    return _bandWidth(count);
  }

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
      _actionsWidth(
        inline: inline,
        demotableCount: demotableCount,
        pinnedCount: pinnedCount,
        overflowVisible: overflowVisible,
      );

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
    final int inlineCount =
        _inlineCount(
          demotableCount: demotable.length,
          pinnedCount: pinnedCount,
          chipWidth: chipWidth,
          overflowVisible: overflowVisible,
          maxWidth: constraints.maxWidth,
        ).clamp(
          0,
          math.min(compactActionLimit ?? demotable.length, demotable.length),
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
        _actionsWidth(
          inline: inlineCount,
          demotableCount: demotable.length,
          pinnedCount: pinnedCount,
          overflowVisible: overflowVisible,
        );
    final availableForText = constraints.maxWidth - fixedForText;
    final emergency = availableForText < 0;
    var renderChipWidth = chipWidth;
    if (chipInline && chipMinWidth != null && title == null && !_hasProject) {
      final remainder =
          constraints.maxWidth -
          _leadingWidth -
          _actionsWidth(
            inline: inlineCount,
            demotableCount: demotable.length,
            pinnedCount: pinnedCount,
            overflowVisible: overflowVisible,
          );
      renderChipWidth = remainder.clamp(chipWidth, chipMaxWidth).toDouble();
    }
    return _HeaderFit(
      inlineCount: inlineCount,
      chipInline: chipInline,
      chipWidth: renderChipWidth,
      pillCap: emergency ? 0 : _pillCap(availableForText, _pillMin),
      overflow: demotable.sublist(inlineCount),
      showOverflow: inlineCount < demotable.length || overflowVisible,
      emergency: emergency,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _slot) return const SizedBox.shrink();
        final strings = FaChatStrings.of(context);
        final fit = _planFit(constraints);
        return fit.emergency
            ? _buildEmergencyRow(context, strings, constraints, fit)
            : _buildRow(context, strings, fit);
      },
    );
  }

  /// Last-resort actions-only layout for transient/nested widths too small
  /// for identity/title/chip content. Every rendered slot still fits; pinned
  /// and primary actions win, and the overflow itself is shown only when its
  /// full hit target fits. No negative constraints or unbounded flex child.
  Widget _buildEmergencyRow(
    BuildContext context,
    FaChatStrings strings,
    BoxConstraints constraints,
    _HeaderFit fit,
  ) {
    var remaining = constraints.maxWidth;
    final children = <Widget>[];
    var inlineCount = 0;
    var slotCount = 0;

    bool reserveSlot() {
      final needed = (slotCount == 0 ? 0.0 : actionGap) + _slot;
      if (needed > remaining) return false;
      remaining -= needed;
      slotCount++;
      return true;
    }

    void addGapIfNeeded() {
      if (children.isNotEmpty && actionGap > 0) {
        children.add(SizedBox(width: actionGap));
      }
    }

    for (final action in actions) {
      if (!action.pinned || !reserveSlot()) continue;
      addGapIfNeeded();
      children.add(_barButton(action));
    }
    final demotable = _demotable;
    for (final action in demotable) {
      if (!reserveSlot()) break;
      addGapIfNeeded();
      children.add(_barButton(action));
      inlineCount++;
    }
    final emergencyFit = _HeaderFit(
      inlineCount: inlineCount,
      chipInline: false,
      chipWidth: 0,
      pillCap: 0,
      overflow: demotable.sublist(inlineCount),
      showOverflow:
          inlineCount < demotable.length ||
          fit.showOverflow ||
          (chip != null && onChipTap != null),
      emergency: true,
    );
    if (emergencyFit.showOverflow && reserveSlot()) {
      addGapIfNeeded();
      children.add(_overflowMenu(context, strings, emergencyFit));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// The row for one fit pass (the [LayoutBuilder] body).
  Widget _buildRow(
    BuildContext context,
    FaChatStrings strings,
    _HeaderFit fit,
  ) => Row(
    children: [
      ..._leadingRegion(),
      if (_hasProject && fit.pillCap > 0)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: fit.pillCap),
          child: _projectPill(context),
        ),
      _titleRegion(_hasProject),
      if (fit.chipInline)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: fit.chipWidth),
          child: chip!,
        ),
      if (actionBandBuilder != null)
        _actionsBand(context, strings, fit)
      else ...[
        ..._actionsRegion(fit),
        if (fit.showOverflow) ...[
          if (fit.inlineCount > 0 || actions.any((action) => action.pinned))
            SizedBox(width: actionGap),
          _overflowMenu(context, strings, fit),
        ],
      ],
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

  /// Pinned actions first, then the inline head of the demotable tail.
  List<FaHeaderAction> _inlineActions(_HeaderFit fit) => [
    for (final action in actions)
      if (action.pinned) action,
    ..._demotable.sublist(0, fit.inlineCount),
  ];

  /// The action group: pinned actions render unconditionally at the head
  /// (only the demotable tail shrinks), then the inline head of the tail.
  List<Widget> _actionsRegion(_HeaderFit fit) {
    final buttons = [
      for (final action in _inlineActions(fit)) _barButton(action),
    ];
    return [
      for (var index = 0; index < buttons.length; index++) ...[
        if (index > 0) SizedBox(width: actionGap),
        buttons[index],
      ],
    ];
  }

  /// Routes the already-fitted actions through the grouped renderer. Menu
  /// metadata remains identical to the standalone overflow button.
  Widget _actionsBand(
    BuildContext context,
    FaChatStrings strings,
    _HeaderFit fit,
  ) {
    final inline = _inlineActions(fit);
    final overflowItems = fit.showOverflow
        ? _overflowItems(context, strings, fit)
        : const <PopupMenuEntry<String>>[];
    if (inline.isEmpty && overflowItems.isEmpty) {
      return const SizedBox.shrink();
    }
    return actionBandBuilder!(
      context,
      inline,
      overflowItems,
      (value) => _onOverflowSelected(value, fit),
    );
  }

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

  /// Menu rows shared by the standalone and grouped overflow controls.
  List<PopupMenuEntry<String>> _overflowItems(
    BuildContext context,
    FaChatStrings strings,
    _HeaderFit fit,
  ) => [?_chipMenuItem(strings, fit), ..._actionMenuItems(fit), ...menuItems];

  /// The ⋮ overflow menu: the demoted chip (issue #225 AC3), the demoted
  /// actions, then the host's menu-only entries.
  Widget _overflowMenu(
    BuildContext context,
    FaChatStrings strings,
    _HeaderFit fit,
  ) {
    final button = PopupMenuButton<String>(
      key: overflowMenuKey,
      icon: Icon(Icons.more_vert, size: iconSize),
      tooltip: overflowTooltip ?? strings.chatMoreTooltip,
      color: menuColor,
      style: ButtonStyle(visualDensity: visualDensity),
      itemBuilder: (context) => _overflowItems(context, strings, fit),
      onSelected: (value) => _onOverflowSelected(value, fit),
    );
    return overflowBuilder?.call(context, button) ?? button;
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
    final button = action.widget != null
        ? KeyedSubtree(key: action.key, child: action.widget!)
        : IconButton(
            key: action.key,
            icon: Icon(action.icon, size: iconSize),
            tooltip: action.label,
            visualDensity: visualDensity,
            onPressed: action.onPressed,
          );
    return Builder(
      builder: (context) =>
          actionBuilder?.call(context, action, button) ?? button,
    );
  }
}

/// The width-fit outcome for one [FaAdaptiveHeader] layout pass: how many
/// actions stay inline, whether the chip fits, and what the ⋮ menu carries.
final class _HeaderFit {
  const _HeaderFit({
    required this.inlineCount,
    required this.chipInline,
    required this.chipWidth,
    required this.pillCap,
    required this.overflow,
    required this.showOverflow,
    required this.emergency,
  });

  /// Demotable actions kept inline (the tail demotes first).
  final int inlineCount;

  /// Whether the model chip renders inline (it demotes last, issue #225).
  final bool chipInline;

  /// Actual render cap after any action-only remainder growth.
  final double chipWidth;

  /// The project pill's max width for this pass.
  final double pillCap;

  /// The actions demoted into the ⋮ menu, in demotion order.
  final List<FaHeaderAction> overflow;

  /// Whether the ⋮ button renders at all.
  final bool showOverflow;

  /// Fixed content exceeded the local width; build uses the safe fallback.
  final bool emergency;
}
