// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'fa2_tokens.dart';
import 'fa2_typography.dart';
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
  FaFontPreset fontPreset = FaFontPreset.system,
}) {
  final tokens = FaDesignTokens.forDirection(direction, brightness);
  final typography = FaTypography.forDirection(direction, preset: fontPreset);
  final packPalette = uiTheme?.paletteFor(brightness);
  final directionPalette = FahColors.fromDesignTokens(tokens);
  final palette = packPalette ?? directionPalette;
  final customized = FaUiTheme(
    indigo: uiTheme?.indigo ?? palette.indigo,
    teal: uiTheme?.teal ?? palette.teal,
    fontFamily: uiTheme?.fontFamily ?? typography.uiFamily,
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
  final presetTextTheme = typography.applyTo(base.textTheme);
  final customFamily = uiTheme?.fontFamily;
  final textTheme = customFamily == null
      ? presetTextTheme
      : presetTextTheme.apply(fontFamily: customFamily);
  final label = textTheme.labelLarge!;
  final actionTextStyle = TextStyle(
    fontFamily: label.fontFamily,
    fontFamilyFallback: label.fontFamilyFallback,
    fontSize: label.fontSize,
    height: label.height,
    fontWeight: label.fontWeight,
    letterSpacing: label.letterSpacing,
  );
  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: textTheme.titleLarge,
    ),
    tooltipTheme: direction == FaVisualDirection.glass
        ? base.tooltipTheme.copyWith(
            waitDuration: const Duration(milliseconds: 450),
            showDuration: const Duration(seconds: 3),
            verticalOffset: 18,
            preferBelow: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xF22C2C2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            textStyle: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          )
        : base.tooltipTheme,
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(actionTextStyle),
      ),
    ),
    // The four control families, restyled from the same semantic tokens the
    // Fa widgets read — raw Material Switch/Radio/Checkbox/Slider call sites
    // inherit the styleguide look instead of the stock M3 blue capsules.
    switchTheme: _faSwitchTheme(tokens),
    radioTheme: _faRadioTheme(tokens),
    checkboxTheme: _faCheckboxTheme(tokens),
    sliderTheme: _faSliderTheme(tokens),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(actionTextStyle),
      ),
    ),
    extensions: [...base.extensions.values, tokens, typography],
    splashFactory: direction == FaVisualDirection.glass
        ? InkSparkle.splashFactory
        : InkRipple.splashFactory,
  );
}

/// The disabled wash shared by every control family: the enabled color at
/// 55% alpha keeps a disabled row visible but inert on all surfaces.
Color _faControlDisabledWash(Color color) => color.withValues(alpha: .55);

SwitchThemeData _faSwitchTheme(FaDesignTokens tokens) => SwitchThemeData(
  trackColor: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) {
      return _faControlDisabledWash(tokens.surface3);
    }
    return states.contains(WidgetState.selected)
        ? tokens.accent
        : tokens.surface3;
  }),
  thumbColor: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) {
      return _faControlDisabledWash(tokens.ink3);
    }
    return states.contains(WidgetState.selected)
        ? tokens.accentInk
        : tokens.ink1;
  }),
  // Flat tracks: the hairline M3 outline would reintroduce stock chrome.
  trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
);

RadioThemeData _faRadioTheme(FaDesignTokens tokens) => RadioThemeData(
  fillColor: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) {
      return _faControlDisabledWash(tokens.ink3);
    }
    return states.contains(WidgetState.selected) ? tokens.accent : tokens.ink2;
  }),
);

CheckboxThemeData _faCheckboxTheme(FaDesignTokens tokens) =>
  CheckboxThemeData(
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (!states.contains(WidgetState.selected)) return Colors.transparent;
      return states.contains(WidgetState.disabled)
          ? _faControlDisabledWash(tokens.surface3)
          : tokens.accent;
    }),
    checkColor: WidgetStatePropertyAll(tokens.accentInk),
    // Unchecked boxes draw the hairline ring; once checked the accent fill
    // covers it (CheckboxThemeData.side is stateless).
    side: BorderSide(color: tokens.hairline, width: 1.5),
    shape: RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(tokens.radiusXs),
    ),
  );

SliderThemeData _faSliderTheme(FaDesignTokens tokens) => SliderThemeData(
  trackHeight: 4,
  activeTrackColor: tokens.accent,
  inactiveTrackColor: tokens.surface3,
  secondaryActiveTrackColor: tokens.surface3.withValues(alpha: .5),
  thumbColor: tokens.accent,
  overlayColor: tokens.accent.withValues(alpha: .12),
  activeTickMarkColor: Colors.transparent,
  inactiveTickMarkColor: Colors.transparent,
  valueIndicatorColor: tokens.surface2,
  valueIndicatorTextStyle: TextStyle(color: tokens.ink1, fontSize: 12),
  // Flat capsule thumb: no M3 elevation shadow on the token surfaces.
  thumbShape: const RoundSliderThumbShape(
    enabledThumbRadius: 8,
    elevation: 0,
    pressedElevation: 0,
  ),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
);
