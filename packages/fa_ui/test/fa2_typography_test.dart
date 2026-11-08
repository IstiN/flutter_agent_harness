import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaTypography font presets', () {
    test('system uses native Apple, Windows and Material families', () {
      final apple = FaTypography.forDirection(
        FaVisualDirection.glass,
        platform: TargetPlatform.macOS,
      );
      expect(apple.displayFamily, '.AppleSystemUIFont');
      expect(apple.uiFamily, '.AppleSystemUIFont');
      expect(apple.monoFamily, 'SF Mono');

      final windows = FaTypography.forDirection(
        FaVisualDirection.glass,
        platform: TargetPlatform.windows,
      );
      expect(windows.uiFamily, 'Segoe UI');
      expect(windows.monoFamily, 'Consolas');

      final android = FaTypography.forDirection(
        FaVisualDirection.glass,
        platform: TargetPlatform.android,
      );
      expect(android.uiFamily, 'Roboto');
      expect(android.monoFamily, 'monospace');
    });

    test(
      'bundled presets mirror the styleguide display, UI and mono stacks',
      () {
        final geist = FaTypography.forDirection(
          FaVisualDirection.glass,
          preset: FaFontPreset.geist,
        );
        expect(geist.displayFamily, 'Geist');
        expect(geist.uiFamily, 'Geist');
        expect(geist.monoFamily, 'Geist Mono');

        final jakarta = FaTypography.forDirection(
          FaVisualDirection.glass,
          preset: FaFontPreset.jakarta,
        );
        expect(jakarta.displayFamily, 'Plus Jakarta Sans');
        expect(jakarta.uiFamily, 'Plus Jakarta Sans');
        expect(jakarta.monoFamily, 'JetBrainsMono');

        final inter = FaTypography.forDirection(
          FaVisualDirection.glass,
          preset: FaFontPreset.inter,
        );
        expect(inter.displayFamily, 'Inter');
        expect(inter.uiFamily, 'Inter');
        expect(inter.monoFamily, 'JetBrainsMono');

        final outfit = FaTypography.forDirection(
          FaVisualDirection.glass,
          preset: FaFontPreset.outfit,
        );
        expect(outfit.displayFamily, 'Outfit');
        expect(outfit.uiFamily, 'Inter');
        expect(outfit.monoFamily, 'DM Mono');
      },
    );
  });

  group('FaTypography direction scales', () {
    test(
      'glass transfers CSS sizes, line heights, weights and em tracking',
      () {
        final type = FaTypography.forDirection(
          FaVisualDirection.glass,
          preset: FaFontPreset.jakarta,
        );
        _expectStyle(
          type.display,
          family: 'Plus Jakarta Sans',
          size: 42,
          lineHeight: 48,
          weight: FontWeight.w700,
          trackingEm: -.03,
        );
        _expectStyle(
          type.title,
          family: 'Plus Jakarta Sans',
          size: 26,
          lineHeight: 32,
          weight: FontWeight.w600,
          trackingEm: -.02,
        );
        _expectStyle(
          type.headline,
          family: 'Plus Jakarta Sans',
          size: 18,
          lineHeight: 24,
          weight: FontWeight.w600,
          trackingEm: -.01,
        );
        _expectStyle(
          type.body,
          family: 'Plus Jakarta Sans',
          size: 15,
          lineHeight: 23,
          weight: FontWeight.w400,
          trackingEm: 0,
        );
        _expectStyle(
          type.label,
          family: 'Plus Jakarta Sans',
          size: 13.5,
          lineHeight: 19,
          weight: FontWeight.w600,
          trackingEm: .005,
        );
        _expectStyle(
          type.caption,
          family: 'Plus Jakarta Sans',
          size: 12,
          lineHeight: 16,
          weight: FontWeight.w500,
          trackingEm: .01,
        );
        _expectStyle(
          type.mono,
          family: 'JetBrainsMono',
          size: 13,
          lineHeight: 20,
          weight: FontWeight.w400,
          trackingEm: 0,
        );
      },
    );

    test('nebula, graphite and porcelain keep their distinct scales', () {
      final nebula = FaTypography.forDirection(FaVisualDirection.nebula);
      expect(nebula.display.fontSize, 42);
      expect(nebula.display.height, closeTo(46 / 42, 1e-9));
      expect(nebula.title.fontWeight, FontWeight.w600);
      expect(nebula.body.height, closeTo(22 / 15, 1e-9));

      final graphite = FaTypography.forDirection(
        FaVisualDirection.graphite,
        preset: FaFontPreset.geist,
      );
      _expectStyle(
        graphite.display,
        family: 'Geist',
        size: 40,
        lineHeight: 44,
        weight: FontWeight.w500,
        trackingEm: -.025,
      );
      _expectStyle(
        graphite.caption,
        family: 'Geist Mono',
        size: 11.5,
        lineHeight: 16,
        weight: FontWeight.w400,
        trackingEm: .02,
      );

      final porcelain = FaTypography.forDirection(FaVisualDirection.porcelain);
      expect(porcelain.body.fontSize, 16);
      expect(porcelain.body.fontWeight, FontWeight.w500);
      expect(porcelain.body.letterSpacing, closeTo(-.08, 1e-9));
      expect(porcelain.label.fontSize, 14);
      expect(porcelain.caption.fontSize, 12.5);
    });
  });

  group('FaTypography Material integration', () {
    test('buildFaTheme exposes the scale and projects semantic roles', () {
      final theme = buildFaTheme(
        direction: FaVisualDirection.graphite,
        brightness: Brightness.dark,
        fontPreset: FaFontPreset.outfit,
      );
      final type = theme.extension<FaTypography>()!;
      expect(type.preset, FaFontPreset.outfit);
      expect(theme.textTheme.displaySmall?.fontFamily, 'Outfit');
      expect(theme.textTheme.displaySmall?.fontSize, 40);
      expect(theme.textTheme.headlineMedium?.fontFamily, 'Outfit');
      expect(theme.textTheme.titleLarge?.fontFamily, 'Inter');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(theme.textTheme.labelLarge?.fontWeight, FontWeight.w500);
      expect(theme.textTheme.bodySmall?.fontFamily, 'DM Mono');
    });

    test(
      'Cyrillic fallback reaches every Material role and action buttons',
      () {
        final theme = buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
          fontPreset: FaFontPreset.jakarta,
        );
        final styles = <TextStyle?>[
          theme.textTheme.displayLarge,
          theme.textTheme.displayMedium,
          theme.textTheme.displaySmall,
          theme.textTheme.headlineLarge,
          theme.textTheme.headlineMedium,
          theme.textTheme.headlineSmall,
          theme.textTheme.titleLarge,
          theme.textTheme.titleMedium,
          theme.textTheme.titleSmall,
          theme.textTheme.bodyLarge,
          theme.textTheme.bodyMedium,
          theme.textTheme.bodySmall,
          theme.textTheme.labelLarge,
          theme.textTheme.labelMedium,
          theme.textTheme.labelSmall,
          theme.filledButtonTheme.style?.textStyle?.resolve({}),
          theme.elevatedButtonTheme.style?.textStyle?.resolve({}),
        ];
        for (final style in styles) {
          expect(style?.fontFamilyFallback, contains('Inter'));
        }
      },
    );

    test('an explicit theme-pack family still wins over the preset', () {
      final theme = buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.light,
        fontPreset: FaFontPreset.geist,
        uiTheme: const FaUiTheme(fontFamily: 'HostBrand'),
      );
      expect(theme.textTheme.displaySmall?.fontFamily, 'HostBrand');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'HostBrand');
      expect(
        theme.filledButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
        'HostBrand',
      );
    });
  });
}

void _expectStyle(
  TextStyle style, {
  required String family,
  required double size,
  required double lineHeight,
  required FontWeight weight,
  required double trackingEm,
}) {
  expect(style.fontFamily, family);
  expect(style.fontSize, size);
  expect(style.height, closeTo(lineHeight / size, 1e-9));
  expect(style.fontWeight, weight);
  expect(style.letterSpacing, closeTo(trackingEm * size, 1e-9));
}
