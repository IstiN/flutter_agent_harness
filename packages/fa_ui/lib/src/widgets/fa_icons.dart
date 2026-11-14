// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

/// Semantic glyphs used by Fa chrome instead of app-side Material/Cupertino
/// icon constants.
enum FaSemanticIcon {
  memory,
  search,
  back,
  close,
  edit,
  expandMore,
  radioUnchecked,
  checkCircle,
  phone,
  more,
  devices,
  chat,
  chevronRight,
  laptop,
  send,
}

/// Theme-owned glyph mapping for [FaIcon].
///
/// Applications render semantic icons; a theme can replace any subset of the
/// glyph set without changing app widgets. Unspecified icons retain the Fa
/// defaults.
@immutable
class FaIconThemeData extends ThemeExtension<FaIconThemeData> {
  const FaIconThemeData({this.icons = const {}});

  final Map<FaSemanticIcon, IconData> icons;

  static const Map<FaSemanticIcon, IconData> _defaults = {
    FaSemanticIcon.memory: Icons.memory,
    FaSemanticIcon.search: Icons.search_rounded,
    FaSemanticIcon.back: Icons.chevron_left_rounded,
    FaSemanticIcon.close: Icons.close_rounded,
    FaSemanticIcon.edit: Icons.edit_outlined,
    FaSemanticIcon.expandMore: Icons.expand_more_rounded,
    FaSemanticIcon.radioUnchecked: Icons.radio_button_unchecked,
    FaSemanticIcon.checkCircle: Icons.check_circle,
    FaSemanticIcon.phone: Icons.phone_iphone,
    FaSemanticIcon.more: Icons.more_horiz_rounded,
    FaSemanticIcon.devices: Icons.devices_outlined,
    FaSemanticIcon.chat: Icons.chat_bubble_outline_rounded,
    FaSemanticIcon.chevronRight: Icons.chevron_right_rounded,
    FaSemanticIcon.laptop: Icons.laptop_mac_rounded,
    FaSemanticIcon.send: Icons.send_rounded,
  };

  static FaIconThemeData of(BuildContext context) =>
      Theme.of(context).extension<FaIconThemeData>() ?? const FaIconThemeData();

  IconData resolve(FaSemanticIcon icon) => icons[icon] ?? _defaults[icon]!;

  @override
  FaIconThemeData copyWith({Map<FaSemanticIcon, IconData>? icons}) =>
      FaIconThemeData(icons: {...this.icons, ...?icons});

  @override
  FaIconThemeData lerp(FaIconThemeData? other, double t) {
    if (other == null) return this;
    return t < 0.5 ? this : other;
  }
}

/// An icon whose concrete glyph is resolved by [FaIconThemeData].
///
/// Size and color inherit the surrounding [IconTheme] unless explicitly
/// supplied, so Fa buttons keep ownership of glyph geometry and token ink.
class FaIcon extends StatelessWidget {
  const FaIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final FaSemanticIcon icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Icon(
    FaIconThemeData.of(context).resolve(icon),
    size: size,
    color: color,
    semanticLabel: semanticLabel,
  );
}
