// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'fa2_tokens.dart';

/// Live font choices from the Fa 2.0 styleguide header.
///
/// [system] deliberately uses the platform face instead of bundling a
/// proprietary font: SF on Apple platforms, Segoe UI on Windows, Roboto /
/// monospace on Material platforms, and the CSS system stack on the web.
enum FaFontPreset { system, geist, jakarta, inter, outfit }

/// The seven styleguide text roles and their resolved font families.
///
/// Sizes, line heights, weights and tracking come from `styleguide.css`;
/// Flutter letter spacing is pixels, so CSS `em` tracking is multiplied by
/// the font size. The active [FaFontPreset] changes families only, exactly
/// like the styleguide's `data-font` override.
@immutable
class FaTypography extends ThemeExtension<FaTypography> {
  const FaTypography({
    required this.preset,
    required this.display,
    required this.title,
    required this.headline,
    required this.body,
    required this.label,
    required this.caption,
    required this.mono,
  });

  final FaFontPreset preset;
  final TextStyle display;
  final TextStyle title;
  final TextStyle headline;
  final TextStyle body;
  final TextStyle label;
  final TextStyle caption;
  final TextStyle mono;

  String get displayFamily => display.fontFamily!;
  String get uiFamily => body.fontFamily!;
  String get monoFamily => mono.fontFamily!;

  /// Resolves the canonical scale for [direction] with one font [preset].
  factory FaTypography.forDirection(
    FaVisualDirection direction, {
    FaFontPreset preset = FaFontPreset.system,
    TargetPlatform? platform,
  }) {
    final families = _familiesFor(preset, platform ?? defaultTargetPlatform);
    final scale = _scaleFor(direction);
    final captionFamily = direction == FaVisualDirection.graphite
        ? families.mono
        : families.ui;
    final captionFallback = direction == FaVisualDirection.graphite
        ? families.monoFallback
        : families.uiFallback;
    return FaTypography(
      preset: preset,
      display: _style(
        scale.display,
        families.display,
        families.displayFallback,
      ),
      title: _style(scale.title, families.display, families.displayFallback),
      headline: _style(scale.headline, families.ui, families.uiFallback),
      body: _style(scale.body, families.ui, families.uiFallback),
      label: _style(scale.label, families.ui, families.uiFallback),
      caption: _style(scale.caption, captionFamily, captionFallback),
      mono: _style(scale.mono, families.mono, families.monoFallback),
    );
  }

  /// Returns the typography installed by [buildFaTheme], with a Glass/system
  /// fallback for painters and isolated widget tests.
  static FaTypography of(BuildContext context) =>
      Theme.of(context).extension<FaTypography>() ??
      FaTypography.forDirection(FaVisualDirection.glass);

  /// Projects the styleguide roles into Material without discarding colors
  /// or other platform typography properties already present on [base].
  TextTheme applyTo(TextTheme base) {
    final themed = base.apply(fontFamily: uiFamily);
    TextStyle? merge(TextStyle? stock, TextStyle style) => stock?.merge(style);
    TextStyle? uiRole(TextStyle? stock) => stock?.copyWith(
      fontFamily: uiFamily,
      fontFamilyFallback: body.fontFamilyFallback,
    );
    return themed.copyWith(
      displayLarge: merge(themed.displayLarge, display),
      displayMedium: merge(themed.displayMedium, display),
      displaySmall: merge(themed.displaySmall, display),
      headlineLarge: merge(themed.headlineLarge, title),
      headlineMedium: merge(themed.headlineMedium, title),
      headlineSmall: merge(themed.headlineSmall, title),
      titleLarge: merge(themed.titleLarge, headline),
      titleMedium: uiRole(themed.titleMedium),
      titleSmall: uiRole(themed.titleSmall),
      bodyLarge: uiRole(themed.bodyLarge),
      bodyMedium: merge(themed.bodyMedium, body),
      bodySmall: merge(themed.bodySmall, caption),
      labelLarge: merge(themed.labelLarge, label),
      labelMedium: uiRole(themed.labelMedium),
      labelSmall: uiRole(themed.labelSmall),
    );
  }

  @override
  FaTypography copyWith({
    FaFontPreset? preset,
    TextStyle? display,
    TextStyle? title,
    TextStyle? headline,
    TextStyle? body,
    TextStyle? label,
    TextStyle? caption,
    TextStyle? mono,
  }) {
    return FaTypography(
      preset: preset ?? this.preset,
      display: display ?? this.display,
      title: title ?? this.title,
      headline: headline ?? this.headline,
      body: body ?? this.body,
      label: label ?? this.label,
      caption: caption ?? this.caption,
      mono: mono ?? this.mono,
    );
  }

  @override
  FaTypography lerp(covariant FaTypography? other, double t) {
    if (other == null) return this;
    return FaTypography(
      preset: t < .5 ? preset : other.preset,
      display: TextStyle.lerp(display, other.display, t)!,
      title: TextStyle.lerp(title, other.title, t)!,
      headline: TextStyle.lerp(headline, other.headline, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      mono: TextStyle.lerp(mono, other.mono, t)!,
    );
  }
}

typedef _Families = ({
  String display,
  String ui,
  String mono,
  List<String>? displayFallback,
  List<String>? uiFallback,
  List<String>? monoFallback,
});

_Families _familiesFor(FaFontPreset preset, TargetPlatform platform) {
  if (preset == FaFontPreset.system) {
    final apple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    final ui = kIsWeb
        ? 'system-ui'
        : apple
        ? '.AppleSystemUIFont'
        : platform == TargetPlatform.windows
        ? 'Segoe UI'
        : 'Roboto';
    final mono = kIsWeb
        ? 'ui-monospace'
        : apple
        ? 'SF Mono'
        : platform == TargetPlatform.windows
        ? 'Consolas'
        : 'monospace';
    return (
      display: ui,
      ui: ui,
      mono: mono,
      displayFallback: null,
      uiFallback: null,
      monoFallback: const ['Menlo', 'Monaco', 'Consolas', 'monospace'],
    );
  }
  return switch (preset) {
    FaFontPreset.system => throw StateError('handled above'),
    FaFontPreset.geist => (
      display: 'Geist',
      ui: 'Geist',
      mono: 'Geist Mono',
      displayFallback: const ['Inter', 'Roboto'],
      uiFallback: const ['Inter', 'Roboto'],
      monoFallback: const ['JetBrainsMono', 'monospace'],
    ),
    FaFontPreset.jakarta => (
      display: 'Plus Jakarta Sans',
      ui: 'Plus Jakarta Sans',
      mono: 'JetBrainsMono',
      displayFallback: const ['Inter', 'Roboto'],
      uiFallback: const ['Inter', 'Roboto'],
      monoFallback: const ['monospace'],
    ),
    FaFontPreset.inter => (
      display: 'Inter',
      ui: 'Inter',
      mono: 'JetBrainsMono',
      displayFallback: const ['Roboto'],
      uiFallback: const ['Roboto'],
      monoFallback: const ['monospace'],
    ),
    FaFontPreset.outfit => (
      display: 'Outfit',
      ui: 'Inter',
      mono: 'DM Mono',
      displayFallback: const ['Plus Jakarta Sans', 'Inter'],
      uiFallback: const ['Roboto'],
      monoFallback: const ['monospace'],
    ),
  };
}

TextStyle _style(_Spec spec, String family, List<String>? fallback) {
  return TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: spec.size,
    height: spec.line / spec.size,
    fontWeight: spec.weight,
    letterSpacing: spec.tracking * spec.size,
  );
}

({
  _Spec display,
  _Spec title,
  _Spec headline,
  _Spec body,
  _Spec label,
  _Spec caption,
  _Spec mono,
})
_scaleFor(FaVisualDirection direction) {
  const mono = _Spec(13, 20, FontWeight.w400, 0);
  return switch (direction) {
    FaVisualDirection.glass => (
      display: const _Spec(42, 48, FontWeight.w700, -.03),
      title: const _Spec(26, 32, FontWeight.w600, -.02),
      headline: const _Spec(18, 24, FontWeight.w600, -.01),
      body: const _Spec(15, 23, FontWeight.w400, 0),
      label: const _Spec(13.5, 19, FontWeight.w600, .005),
      caption: const _Spec(12, 16, FontWeight.w500, .01),
      mono: mono,
    ),
    FaVisualDirection.nebula => (
      display: const _Spec(42, 46, FontWeight.w700, -.03),
      title: const _Spec(26, 32, FontWeight.w600, -.02),
      headline: const _Spec(18, 24, FontWeight.w600, -.01),
      body: const _Spec(15, 22, FontWeight.w400, 0),
      label: const _Spec(13, 18, FontWeight.w600, .01),
      caption: const _Spec(12, 16, FontWeight.w500, .01),
      mono: mono,
    ),
    FaVisualDirection.graphite => (
      display: const _Spec(40, 44, FontWeight.w500, -.025),
      title: const _Spec(24, 30, FontWeight.w500, -.015),
      headline: const _Spec(17, 24, FontWeight.w600, -.005),
      body: const _Spec(15, 22, FontWeight.w400, 0),
      label: const _Spec(13, 18, FontWeight.w500, .01),
      caption: const _Spec(11.5, 16, FontWeight.w400, .02),
      mono: mono,
    ),
    FaVisualDirection.porcelain => (
      display: const _Spec(42, 48, FontWeight.w700, -.03),
      title: const _Spec(26, 32, FontWeight.w700, -.02),
      headline: const _Spec(18, 24, FontWeight.w600, -.01),
      body: const _Spec(16, 24, FontWeight.w500, -.005),
      label: const _Spec(14, 20, FontWeight.w600, 0),
      caption: const _Spec(12.5, 16, FontWeight.w500, .005),
      mono: mono,
    ),
  };
}

final class _Spec {
  const _Spec(this.size, this.line, this.weight, this.tracking);

  final double size;
  final double line;
  final FontWeight weight;

  /// CSS tracking in `em`; converted to logical pixels by [_style].
  final double tracking;
}
