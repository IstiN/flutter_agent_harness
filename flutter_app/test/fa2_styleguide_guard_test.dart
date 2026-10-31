import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Fa 2.0 styleguide architecture', () {
    const redesignedSurfaces = <String, List<String>>{
      'lib/main.dart': [
        'buildFaTheme(',
        'faWindowClassForWidth(',
        'fontPreset: theme.fontPreset',
      ],
      'lib/services/theme_controller.dart': [
        'FaFontPreset',
        "'font': _fontPreset.name",
      ],
      'lib/ui/screens/app_launcher_screen.dart': [
        'FaDesignTokens.of(context)',
        'FaTextField(',
        'RoundedSuperellipseBorder(',
      ],
      'lib/ui/screens/settings_sections.dart': [
        'VisualDirectionSection',
        'buildFaTheme(',
        'FaTypography.forDirection(',
        'FaFontPreset',
      ],
      'lib/ui/screens/onboarding_screen.dart': [
        'FaDesignTokens.of(context)',
        'showJoinSheet(',
      ],
      'lib/ui/widgets/wide_layout_shell.dart': [
        'FaDesignTokens.of(context)',
        'FaWindowClass.large',
      ],
      'lib/ui/widgets/fa_mark.dart': ['FaLogo('],
    };

    test('redesigned app surfaces consume the shared styleguide', () {
      for (final entry in redesignedSurfaces.entries) {
        final source = File(entry.key).readAsStringSync();
        for (final requiredUse in entry.value) {
          expect(
            source.contains(requiredUse),
            isTrue,
            reason:
                '${entry.key} bypasses the styleguide; expected '
                '$requiredUse',
          );
        }
        expect(
          source.contains('FahPalette.') || source.contains('FahLightPalette.'),
          isFalse,
          reason: '${entry.key} must not bypass semantic direction colors',
        );
      }
    });

    test('shared Fa 2.0 widgets contain no one-off hex palettes', () {
      const files = [
        '../packages/fa_ui/lib/src/widgets/fa2_controls.dart',
        '../packages/fa_ui/lib/src/widgets/fa2_adaptive.dart',
        '../packages/fa_ui/lib/src/widgets/fa_logo.dart',
      ];
      for (final path in files) {
        final source = File(path).readAsStringSync();
        expect(source.contains('FaDesignTokens'), isTrue, reason: path);
        expect(source.contains('Color(0x'), isFalse, reason: path);
      }
    });

    test('app and fa_ui cannot bypass the central UI font resolver', () {
      const centralResolver =
          '../packages/fa_ui/lib/src/theme/fa2_typography.dart';
      final directFamily = RegExp(
        "fontFamily(?:Fallback)?\\s*:\\s*(?:const\\s*)?(?:\\[\\s*)?"
        "'(?:Inter|Manrope|Outfit|SpaceGrotesk|Space Grotesk|"
        "Plus Jakarta Sans|PlusJakartaSans|DM Sans|DMSans|Geist|"
        "RobotoFlex|Roboto Flex|Google Sans Code|GoogleSansCode|"
        "\\.AppleSystemUIFont|SF Pro Text|Segoe UI|Roboto)'",
      );
      expect(directFamily.hasMatch("fontFamily:\n  'Inter'"), isTrue);
      expect(
        directFamily.hasMatch("fontFamilyFallback: const ['Inter']"),
        isTrue,
      );
      expect(directFamily.hasMatch('fontFamily: typography.uiFamily'), isFalse);

      final violations = <String>[];
      for (final root in ['lib', '../packages/fa_ui/lib']) {
        for (final entity in Directory(root).listSync(recursive: true)) {
          if (entity is! File ||
              !entity.path.endsWith('.dart') ||
              entity.path == centralResolver) {
            continue;
          }
          final source = entity.readAsStringSync();
          for (final match in directFamily.allMatches(source)) {
            violations.add('${entity.path}: ${match.group(0)}');
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason:
            'UI families must come from FaTypography/buildFaTheme so the '
            'selected preset reaches every app element.',
      );
    });

    test('the app reaches Liquid Glass only through the fa_ui wrapper', () {
      final violations = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.readAsStringSync().contains(
          'package:liquid_glass_renderer',
        )) {
          violations.add(entity.path);
        }
      }
      expect(violations, isEmpty);
    });
  });
}
