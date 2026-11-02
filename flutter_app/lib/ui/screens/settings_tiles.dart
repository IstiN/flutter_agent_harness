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
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
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
                const SizedBox(width: 12),
                faui.FaSwitch(value: value, onChanged: onChanged),
              ],
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
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
    );
  }
}