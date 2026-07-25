// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/ui/app_theme.dart';

/// Builds the `jsr.theme` map injected into every JS app: the current
/// brightness plus the [FahColors] palette as hex strings, so JS apps can
/// follow the app's light/dark mode instead of hardcoding colors.
///
/// Keys (also documented in `assets/skills/js-apps/SKILL.md`):
/// - `brightness` — `'dark'` or `'light'`
/// - `dark` — bool, true in dark mode
/// - `background`, `surface`, `surfaceAlt`, `border`, `borderBright`,
///   `text`, `muted`, `accent`, `accent2`, `onAccent`, `error`,
///   `userBubble`, `userBubbleBorder`, `codeBg` — `'#RRGGBB'` hex
/// - `isDark`, `bg` — legacy aliases kept for apps written against the
///   runtime's original default theme map
Map<String, dynamic> jsThemeMap(BuildContext context) {
  final colors = FahColors.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  return <String, dynamic>{
    'brightness': dark ? 'dark' : 'light',
    'dark': dark,
    'background': _hex(colors.bg),
    'surface': _hex(colors.panel),
    'surfaceAlt': _hex(colors.panelAlt),
    'border': _hex(colors.border),
    'borderBright': _hex(colors.borderBright),
    'text': _hex(colors.text),
    'muted': _hex(colors.dim),
    'accent': _hex(colors.teal),
    'accent2': _hex(colors.indigo),
    'onAccent': _hex(colors.onAccent),
    'error': _hex(colors.error),
    'userBubble': _hex(colors.userBubble),
    'userBubbleBorder': _hex(colors.userBubbleBorder),
    'codeBg': _hex(colors.codeBg),
    // Legacy aliases (runtime's original default theme map).
    'isDark': dark,
    'bg': _hex(colors.bg),
  };
}

/// The compact one-line theme summary appended to in-app Fa messages so the
/// agent never has to guess colors, e.g.
/// `Theme: dark, bg #070A10, surface #0D1420, text #E8EEF7, accent #5EEAD4,
/// accent2 #818CF8`.
String jsThemeSummaryLine(Map<String, dynamic> theme) =>
    'Theme: ${theme['brightness']}, '
    'bg ${theme['background']}, '
    'surface ${theme['surface']}, '
    'text ${theme['text']}, '
    'accent ${theme['accent']}, '
    'accent2 ${theme['accent2']}';

/// Formats [color] as `'#RRGGBB'` (uppercase, no alpha). The alpha channel
/// is dropped because JS color props are opaque hex strings; apps needing
/// translucency layer it on top themselves (e.g. via an `opacity` prop).
String _hex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
