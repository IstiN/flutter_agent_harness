// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'fa2_tokens.dart';
import 'fa_ui_theme.dart';

/// Builds a complete Material theme for an approved Fa 2.0 direction.
///
/// The existing [buildFahTheme] / [buildFahThemeLight] APIs remain the
/// compatibility path. A supplied theme pack keeps its explicit overrides;
/// otherwise the core legacy fa_ui/chat colors are projected from the same
/// semantic tokens consumed by the new components.
ThemeData buildFaTheme({
  required FaVisualDirection direction,
  required Brightness brightness,
  FaUiTheme? uiTheme,
}) {
  final tokens = FaDesignTokens.forDirection(direction, brightness);
  final packPalette = uiTheme?.paletteFor(brightness);
  final directionPalette = FahColors.fromDesignTokens(tokens);
  final palette = packPalette ?? directionPalette;
  final customized = FaUiTheme(
    indigo: uiTheme?.indigo ?? palette.indigo,
    teal: uiTheme?.teal ?? palette.teal,
    fontFamily: uiTheme?.fontFamily,
    cardRadius: uiTheme?.cardRadius ?? tokens.radiusLg,
    inputRadius: uiTheme?.inputRadius ?? tokens.radiusMd,
    buttonRadius: uiTheme?.buttonRadius ?? tokens.radiusMd,
    background: uiTheme?.background,
    surface: uiTheme?.surface,
    userBubble: uiTheme?.userBubble ?? tokens.accentSoft,
    userBubbleBorder:
        uiTheme?.userBubbleBorder ?? tokens.accent.withValues(alpha: .4),
    darkPalette: brightness == Brightness.dark ? palette : null,
    lightPalette: brightness == Brightness.light ? palette : null,
  );
  final base = brightness == Brightness.dark
      ? buildFahTheme(uiTheme: customized)
      : buildFahThemeLight(uiTheme: customized);
  return base.copyWith(
    extensions: [...base.extensions.values, tokens],
    splashFactory: direction == FaVisualDirection.glass
        ? InkSparkle.splashFactory
        : InkRipple.splashFactory,
  );
}
