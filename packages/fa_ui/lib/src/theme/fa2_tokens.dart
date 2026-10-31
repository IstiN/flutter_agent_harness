// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// The four visual languages from the Fa 2.0 styleguide.
enum FaVisualDirection { glass, nebula, graphite, porcelain }

/// Content-width buckets shared by navigation, grids and split views.
enum FaWindowClass { small, medium, large }

/// Resolves the Fa 2.0 responsive contract: phone, fold/tablet, desktop.
FaWindowClass faWindowClassForWidth(double width) {
  if (width < 640) return FaWindowClass.small;
  if (width < 1024) return FaWindowClass.medium;
  return FaWindowClass.large;
}

/// Semantic design values for one [FaVisualDirection] and brightness.
///
/// App code consumes these roles instead of embedding direction-specific
/// colors. The values mirror `styleguide.js` in the approved Fa 2.0 POC.
@immutable
class FaDesignTokens extends ThemeExtension<FaDesignTokens> {
  const FaDesignTokens({
    required this.direction,
    required this.brightness,
    required this.background,
    required this.backgroundAlt,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.ink1,
    required this.ink2,
    required this.ink3,
    required this.hairline,
    required this.accent,
    required this.accentInk,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.agentHues,
    required this.radiusXs,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
    this.radiusPill = 999,
    required this.glassBlur,
    required this.fast,
    required this.base,
    required this.emphasized,
  });

  final FaVisualDirection direction;
  final Brightness brightness;
  final Color background;
  final Color backgroundAlt;
  final Color surface1;
  final Color surface2;
  final Color surface3;
  final Color ink1;
  final Color ink2;
  final Color ink3;
  final Color hairline;
  final Color accent;
  final Color accentInk;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;

  /// Stable agent identity colors in styleguide order (agent1 … agent6).
  final List<Color> agentHues;

  final double radiusXs;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;
  final double radiusPill;
  final double glassBlur;
  final Duration fast;
  final Duration base;
  final Duration emphasized;

  /// Tokens from the nearest [Theme], with a Glass palette in the ambient
  /// brightness for painters and tests outside a Material app.
  static FaDesignTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<FaDesignTokens>() ??
        FaDesignTokens.forDirection(FaVisualDirection.glass, theme.brightness);
  }

  /// Returns the canonical palette for one of the eight theme combinations.
  factory FaDesignTokens.forDirection(
    FaVisualDirection direction,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    final p = switch ((direction, brightness)) {
      (FaVisualDirection.glass, Brightness.dark) => const _Palette(
        bg: 0xFF080A10,
        s1: 0xFF0F1320,
        s2: 0xFF161B2C,
        s3: 0xFF1E243A,
        i1: 0xFFF0F4FC,
        i2: 0xFF9FB0D0,
        i3: 0xFF889ABE,
        line: 0xFF222D46,
        accent: 0xFF38BDF8,
        accentInk: 0xFF080A10,
        soft: 0xFF14263C,
        success: 0xFF34D399,
        warning: 0xFFFBBF24,
        danger: 0xFFF87171,
        info: 0xFF60A5FA,
        hues: [
          0xFF38BDF8,
          0xFF818CF8,
          0xFF34D399,
          0xFFF472B6,
          0xFFFBBF24,
          0xFF2DD4BF,
        ],
      ),
      (FaVisualDirection.glass, Brightness.light) => const _Palette(
        bg: 0xFFF0F4F8,
        s1: 0xFFFFFFFF,
        s2: 0xFFE5ECF4,
        s3: 0xFFD6E0EC,
        i1: 0xFF0B1322,
        i2: 0xFF3E4C66,
        i3: 0xFF505F7D,
        line: 0xFFC4D2E4,
        accent: 0xFF0277BD,
        accentInk: 0xFFFFFFFF,
        soft: 0xFFE1F1FB,
        success: 0xFF027A48,
        warning: 0xFFB54708,
        danger: 0xFFC42129,
        info: 0xFF0E64B8,
        hues: [
          0xFF0277BD,
          0xFF4F46E5,
          0xFF027A48,
          0xFFDB2777,
          0xFFB54708,
          0xFF0D9488,
        ],
      ),
      (FaVisualDirection.nebula, Brightness.dark) => const _Palette(
        bg: 0xFF0B0C10,
        s1: 0xFF11131A,
        s2: 0xFF181B24,
        s3: 0xFF1E212D,
        i1: 0xFFF0F2F8,
        i2: 0xFF9BA3B8,
        i3: 0xFF8892A8,
        line: 0xFF242838,
        accent: 0xFF9366FF,
        accentInk: 0xFF0B0C10,
        soft: 0xFF241B42,
        success: 0xFF10B981,
        warning: 0xFFF59E0B,
        danger: 0xFFEF4444,
        info: 0xFF60A5FA,
        hues: [
          0xFF9366FF,
          0xFF38BDF8,
          0xFF34D399,
          0xFFF472B6,
          0xFFFBBF24,
          0xFFA78BFA,
        ],
      ),
      (FaVisualDirection.nebula, Brightness.light) => const _Palette(
        bg: 0xFFF4F5F9,
        s1: 0xFFFFFFFF,
        s2: 0xFFEAEBF2,
        s3: 0xFFDFE1EC,
        i1: 0xFF0C0E14,
        i2: 0xFF474D5E,
        i3: 0xFF5C6377,
        line: 0xFFD1D5E4,
        accent: 0xFF6D28D9,
        accentInk: 0xFFFFFFFF,
        soft: 0xFFEDE9FE,
        success: 0xFF047857,
        warning: 0xFFB45309,
        danger: 0xFFB91C1C,
        info: 0xFF1D4ED8,
        hues: [
          0xFF6D28D9,
          0xFF0284C7,
          0xFF059669,
          0xFFDB2777,
          0xFFD97706,
          0xFF7C3AED,
        ],
      ),
      (FaVisualDirection.graphite, Brightness.dark) => const _Palette(
        bg: 0xFF0E0F11,
        s1: 0xFF151619,
        s2: 0xFF1C1E22,
        s3: 0xFF25282D,
        i1: 0xFFE9EBEE,
        i2: 0xFFA8AEB7,
        i3: 0xFF8B929C,
        line: 0xFF2B2F35,
        accent: 0xFFF2A93B,
        accentInk: 0xFF1B1305,
        soft: 0xFF2E2414,
        success: 0xFF5FC28E,
        warning: 0xFFFF8F5A,
        danger: 0xFFFF6F6A,
        info: 0xFF86B6F0,
        hues: [
          0xFF86B6F0,
          0xFFF2A93B,
          0xFF5FC28E,
          0xFFD79AC0,
          0xFF6FCFC6,
          0xFFC9B37A,
        ],
      ),
      (FaVisualDirection.graphite, Brightness.light) => const _Palette(
        bg: 0xFFF2F3F5,
        s1: 0xFFFAFAFB,
        s2: 0xFFFFFFFF,
        s3: 0xFFE5E7EB,
        i1: 0xFF0F1114,
        i2: 0xFF454A52,
        i3: 0xFF5A6069,
        line: 0xFFD4D7DC,
        accent: 0xFF9A5A00,
        accentInk: 0xFFFFFFFF,
        soft: 0xFFF6E6CC,
        success: 0xFF1E7046,
        warning: 0xFFA2470F,
        danger: 0xFFB22A25,
        info: 0xFF255C9E,
        hues: [
          0xFF2F64A6,
          0xFF9A5A00,
          0xFF1E7046,
          0xFF9A4677,
          0xFF18777A,
          0xFF6E5E2B,
        ],
      ),
      (FaVisualDirection.porcelain, Brightness.light) => const _Palette(
        bg: 0xFFECEFF2,
        s1: 0xFFF6F8FA,
        s2: 0xFFFFFFFF,
        s3: 0xFFE1E6EB,
        i1: 0xFF12171C,
        i2: 0xFF46505B,
        i3: 0xFF5A6571,
        line: 0xFFD5DCE3,
        accent: 0xFF1D6B65,
        accentInk: 0xFFFFFFFF,
        soft: 0xFFD3E7E4,
        success: 0xFF2A7A4C,
        warning: 0xFF8C5C00,
        danger: 0xFFB3261E,
        info: 0xFF2B5F9C,
        hues: [
          0xFF3B78AD,
          0xFFB9662F,
          0xFF3E8C5D,
          0xFF8E62A6,
          0xFFB8546F,
          0xFF2F8890,
        ],
      ),
      (FaVisualDirection.porcelain, Brightness.dark) => const _Palette(
        bg: 0xFF0F1317,
        s1: 0xFF161B20,
        s2: 0xFF1D2329,
        s3: 0xFF262E35,
        i1: 0xFFE9EEF2,
        i2: 0xFFAEB8C2,
        i3: 0xFF909BA6,
        line: 0xFF2C353D,
        accent: 0xFF72C6BB,
        accentInk: 0xFF062420,
        soft: 0xFF173431,
        success: 0xFF78C99A,
        warning: 0xFFE4B866,
        danger: 0xFFF2928A,
        info: 0xFF8DB8EC,
        hues: [
          0xFF83B4E2,
          0xFFE59E6E,
          0xFF7FC99B,
          0xFFC2A0D9,
          0xFFE795AA,
          0xFF73C4CB,
        ],
      ),
    };
    final radii = switch (direction) {
      FaVisualDirection.glass => const [6.0, 10.0, 16.0, 22.0, 30.0],
      FaVisualDirection.nebula => const [4.0, 8.0, 12.0, 16.0, 22.0],
      FaVisualDirection.graphite => const [2.0, 4.0, 6.0, 8.0, 12.0],
      FaVisualDirection.porcelain => const [6.0, 10.0, 14.0, 20.0, 28.0],
    };
    final motion = switch (direction) {
      FaVisualDirection.glass => const [160, 260, 400],
      FaVisualDirection.nebula => const [140, 220, 320],
      FaVisualDirection.graphite => const [100, 160, 240],
      FaVisualDirection.porcelain => const [180, 320, 460],
    };
    return FaDesignTokens(
      direction: direction,
      brightness: brightness,
      background: Color(p.bg),
      backgroundAlt: Color.lerp(Color(p.bg), Color(p.soft), dark ? .32 : .2)!,
      surface1: Color(p.s1),
      surface2: Color(p.s2),
      surface3: Color(p.s3),
      ink1: Color(p.i1),
      ink2: Color(p.i2),
      ink3: Color(p.i3),
      hairline: Color(p.line),
      accent: Color(p.accent),
      accentInk: Color(p.accentInk),
      accentSoft: Color(p.soft),
      success: Color(p.success),
      warning: Color(p.warning),
      danger: Color(p.danger),
      info: Color(p.info),
      agentHues: [for (final hue in p.hues) Color(hue)],
      radiusXs: radii[0],
      radiusSm: radii[1],
      radiusMd: radii[2],
      radiusLg: radii[3],
      radiusXl: radii[4],
      glassBlur: direction == FaVisualDirection.glass ? 24 : 0,
      fast: Duration(milliseconds: motion[0]),
      base: Duration(milliseconds: motion[1]),
      emphasized: Duration(milliseconds: motion[2]),
    );
  }

  @override
  FaDesignTokens copyWith({
    FaVisualDirection? direction,
    Brightness? brightness,
    Color? background,
    Color? backgroundAlt,
    Color? surface1,
    Color? surface2,
    Color? surface3,
    Color? ink1,
    Color? ink2,
    Color? ink3,
    Color? hairline,
    Color? accent,
    Color? accentInk,
    Color? accentSoft,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    List<Color>? agentHues,
    double? radiusXs,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusXl,
    double? radiusPill,
    double? glassBlur,
    Duration? fast,
    Duration? base,
    Duration? emphasized,
  }) => FaDesignTokens(
    direction: direction ?? this.direction,
    brightness: brightness ?? this.brightness,
    background: background ?? this.background,
    backgroundAlt: backgroundAlt ?? this.backgroundAlt,
    surface1: surface1 ?? this.surface1,
    surface2: surface2 ?? this.surface2,
    surface3: surface3 ?? this.surface3,
    ink1: ink1 ?? this.ink1,
    ink2: ink2 ?? this.ink2,
    ink3: ink3 ?? this.ink3,
    hairline: hairline ?? this.hairline,
    accent: accent ?? this.accent,
    accentInk: accentInk ?? this.accentInk,
    accentSoft: accentSoft ?? this.accentSoft,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    info: info ?? this.info,
    agentHues: agentHues ?? this.agentHues,
    radiusXs: radiusXs ?? this.radiusXs,
    radiusSm: radiusSm ?? this.radiusSm,
    radiusMd: radiusMd ?? this.radiusMd,
    radiusLg: radiusLg ?? this.radiusLg,
    radiusXl: radiusXl ?? this.radiusXl,
    radiusPill: radiusPill ?? this.radiusPill,
    glassBlur: glassBlur ?? this.glassBlur,
    fast: fast ?? this.fast,
    base: base ?? this.base,
    emphasized: emphasized ?? this.emphasized,
  );

  @override
  FaDesignTokens lerp(covariant FaDesignTokens? other, double t) {
    if (other == null) return this;
    Color color(Color a, Color b) => Color.lerp(a, b, t)!;
    return copyWith(
      direction: t < .5 ? direction : other.direction,
      brightness: t < .5 ? brightness : other.brightness,
      background: color(background, other.background),
      backgroundAlt: color(backgroundAlt, other.backgroundAlt),
      surface1: color(surface1, other.surface1),
      surface2: color(surface2, other.surface2),
      surface3: color(surface3, other.surface3),
      ink1: color(ink1, other.ink1),
      ink2: color(ink2, other.ink2),
      ink3: color(ink3, other.ink3),
      hairline: color(hairline, other.hairline),
      accent: color(accent, other.accent),
      accentInk: color(accentInk, other.accentInk),
      accentSoft: color(accentSoft, other.accentSoft),
      success: color(success, other.success),
      warning: color(warning, other.warning),
      danger: color(danger, other.danger),
      info: color(info, other.info),
      agentHues: [
        for (var i = 0; i < agentHues.length; i++)
          color(agentHues[i], other.agentHues[i]),
      ],
      radiusXs: lerpDouble(radiusXs, other.radiusXs, t),
      radiusSm: lerpDouble(radiusSm, other.radiusSm, t),
      radiusMd: lerpDouble(radiusMd, other.radiusMd, t),
      radiusLg: lerpDouble(radiusLg, other.radiusLg, t),
      radiusXl: lerpDouble(radiusXl, other.radiusXl, t),
      radiusPill: lerpDouble(radiusPill, other.radiusPill, t),
      glassBlur: lerpDouble(glassBlur, other.glassBlur, t),
      fast: t < .5 ? fast : other.fast,
      base: t < .5 ? base : other.base,
      emphasized: t < .5 ? emphasized : other.emphasized,
    );
  }
}

class _Palette {
  const _Palette({
    required this.bg,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.i1,
    required this.i2,
    required this.i3,
    required this.line,
    required this.accent,
    required this.accentInk,
    required this.soft,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.hues,
  });
  final int bg, s1, s2, s3, i1, i2, i3, line;
  final int accent, accentInk, soft, success, warning, danger, info;
  final List<int> hues;
}
