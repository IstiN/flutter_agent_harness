// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared styleguide rows for the settings screens: token-styled
/// replacements for the raw Material list tiles ([SwitchListTile],
/// [CheckboxListTile], [RadioListTile]) that leaked stock Material
/// controls into the themed settings surface. Every row reads
/// [FaDesignTokens], so all four Fa visual directions render correctly.
library;

import 'package:flutter/material.dart';
import 'package:fa_ui/fa_ui.dart' as faui;

/// One grouped settings surface: an optional eyebrow label above a
/// [faui.FaSurface] card (~14 radius, hairline outline) whose children sit
/// on 16pt side insets and never butt against the card edge — trailing
/// controls keep ≥16pt, and the card's last row keeps the card's own
/// rounding above the page bottom.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.label,
    this.hint,
    this.header,
    required this.children,
    this.footer,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  /// The dim eyebrow above the card (the section's name).
  final String? label;

  /// One-line helper under the eyebrow.
  final String? hint;

  /// A full-width header row inside the card (e.g. a trailing action).
  final Widget? header;

  /// The group's rows; hairlines are interleaved automatically.
  final List<Widget> children;

  /// Below the card (notes, helper text).
  final Widget? footer;

  /// The card's inner vertical padding.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = faui.FaDesignTokens.of(context);
    final rows = <Widget>[
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) faui.FaHairline(indent: 16, symmetry: 0),
        children[i],
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              label!,
              style: TextStyle(
                color: tokens.ink2,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: .2,
              ),
            ),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              hint!,
              style: TextStyle(color: tokens.ink2, fontSize: 12, height: 1.35),
            ),
          ),
        faui.FaSurface(
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [?header, ...rows],
            ),
          ),
        ),
        ?footer,
      ],
    );
  }
}

/// A settings row with a trailing [faui.FaSwitch]: the styleguide
/// replacement for [SwitchListTile] (and boolean [CheckboxListTile]s —
/// the switch is the Fa control for a live on/off setting). Tapping the
/// row toggles, like the Material tile it replaces.
class SettingsSwitchRow extends StatelessWidget {
  /// Creates the row.
  const SettingsSwitchRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.leading,
  });

  /// The switch state.
  final bool value;

  /// The toggle handler; `null` disables the whole row (the hard floor of
  /// an absent capability stays visible but inert).
  final ValueChanged<bool>? onChanged;

  /// The row title (already-localized plain text).
  final Widget title;

  /// Optional one-line helper under the title.
  final Widget? subtitle;

  /// Optional leading icon (the section's pictogram, 20 px, token ink).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final tokens = faui.FaDesignTokens.of(context);
    return MergeSemantics(
      child: Semantics(
        enabled: onChanged != null,
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              // 12px sides keep the title off a card's edge; containers
              // add their own 16pt insets, so the trailing switch always
              // lands ≥16pt from the card boundary.
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  if (leading != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(size: 20, color: tokens.ink2),
                      child: leading!,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            color: tokens.ink1,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
                          child: title,
                        ),
                        if (subtitle != null)
                          DefaultTextStyle.merge(
                            style: TextStyle(
                              color: tokens.ink2,
                              fontSize: 12,
                              height: 1.35,
                            ),
                            child: subtitle!,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  faui.FaSwitch(value: value, onChanged: onChanged),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A selectable settings row (token radio): the styleguide replacement
/// for [RadioListTile]. The selection marker is a token-colored dot pair
/// instead of a stock Material radio.
class SettingsRadioRow extends StatelessWidget {
  /// Creates the row.
  const SettingsRadioRow({
    super.key,
    required this.selected,
    required this.onTap,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  /// Whether this row is the group's selected entry.
  final bool selected;

  /// Selects the row; `null` keeps it inert.
  final VoidCallback? onTap;

  /// The row title.
  final Widget title;

  /// Optional helper under the title.
  final Widget? subtitle;

  /// Optional trailing action (e.g. the theme-pack delete button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = faui.FaDesignTokens.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? tokens.accent : tokens.ink3,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          color: tokens.ink1,
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          height: 1.3,
                        ),
                        child: title,
                      ),
                      if (subtitle != null)
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            color: tokens.ink2,
                            fontSize: 12,
                            height: 1.35,
                          ),
                          child: subtitle!,
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A token-styled single-select picker: the settings replacement for the
/// raw [DropdownButtonFormField] (whose stock M3 decorator — theme fill,
/// default border, chevron — leaked the Material look). The field reads
/// [faui.FaDesignTokens] directly: surface2 fill, hairline capsule border,
/// ink text and chevron, matching [faui.FaTextField]'s geometry so the
/// two sit side by side as one family.
class SettingsDropdown<T> extends StatelessWidget {
  const SettingsDropdown({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.labelText,
    this.hintText,
    this.enabled = true,
    this.itemKey,
  });

  /// The choices; each entry's [DropdownMenuItem.value] must be set.
  final List<DropdownMenuItem<T>> items;

  /// The selected value (a [Key]ed widget re-seeds the FormField when the
  /// value changes from elsewhere — see [itemKey]).
  final T? value;

  /// Selection handler; `null` disables the picker.
  final ValueChanged<T?>? onChanged;

  /// The floating label (none on dense capsule rows).
  final String? labelText;

  /// The empty-selection hint.
  final String? hintText;

  /// Whether the picker accepts input.
  final bool enabled;

  /// Key the underlying FormField re-seeds on (pass the current value's
  /// key so external changes reset the displayed selection).
  final Key? itemKey;

  @override
  Widget build(BuildContext context) {
    final tokens = faui.FaDesignTokens.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          borderSide: BorderSide(color: color, width: width),
        );
    // The base style carries the theme family (the golden font guard fails
    // any family-less override — issue #947); only ink/size/height are
    // retokened on top.
    final baseStyle = Theme.of(context).textTheme.titleMedium ?? TextStyle();
    return DropdownButtonFormField<T>(
      key: itemKey,
      initialValue: value,
      isExpanded: true,
      items: items,
      onChanged: enabled ? onChanged : null,
      style: baseStyle.copyWith(color: tokens.ink1, fontSize: 14, height: 1.3),
      dropdownColor: tokens.surface2,
      iconEnabledColor: tokens.ink2,
      iconDisabledColor: tokens.ink3,
      elevation: 8,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      menuMaxHeight: 360,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        filled: true,
        fillColor: tokens.surface2,
        labelStyle: TextStyle(color: tokens.ink2),
        hintStyle: TextStyle(color: tokens.ink3),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: border(tokens.hairline),
        enabledBorder: border(tokens.hairline),
        disabledBorder: border(tokens.hairline),
        focusedBorder: border(tokens.accent, 1.5),
      ),
    );
  }
}
