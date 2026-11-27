// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The locked-pack design tokens (gh-2391 addendum 8 item 2): a branded
/// build's [FaUiTheme] with `lockDesignTokens` feeds the pack palette's
/// accent into [FaDesignTokens] per brightness — accent, accentInk,
/// accentSoft and info follow the pack, so every `tokens.accent` consumer
/// (nav rail, FABs, chips, the FaLogo tile stroke) speaks one accent. The
/// stock builder keeps the stock tokens byte-identically (REG).
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _packAccentDark = Color(0xFF4ADE80);
const _packAccentLight = Color(0xFF16A34A);
const _stockAccent = Color(0xFF3F8FF7);

/// A two-variant pack palette, built the way [ThemePackColors.toFahColors]
/// maps a profile's `themePack` section: explicit surface slots + accents.
FahColors _packPalette(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final accent = dark ? _packAccentDark : _packAccentLight;
  return (dark ? FahColors.dark : FahColors.light)
      .override(
        bg: dark ? const Color(0xFF07080D) : const Color(0xFFF4F2EE),
        panel: dark ? const Color(0xFF101218) : const Color(0xFFFFFFFF),
        text: dark ? const Color(0xFFE9EAEE) : const Color(0xFF1C1B18),
        onAccent: const Color(0xFF07080D),
      )
      .withAccents(indigo: accent, teal: accent);
}

FaUiTheme _lockedPack() => FaUiTheme(
  lockDesignTokens: true,
  darkPalette: _packPalette(Brightness.dark),
  lightPalette: _packPalette(Brightness.light),
);

void main() {
  group('buildFaTheme with lockDesignTokens', () {
    for (final brightness in Brightness.values) {
      test('$brightness: the pack accent drives the design tokens', () {
        final expectedAccent = brightness == Brightness.dark
            ? _packAccentDark
            : _packAccentLight;
        final data = buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: brightness,
          uiTheme: _lockedPack(),
        );
        final tokens = data.extension<FaDesignTokens>()!;
        expect(tokens.accent, expectedAccent);
        expect(tokens.accent, isNot(_stockAccent));
        // The readable ink on the accent follows the pack's onAccent.
        expect(tokens.accentInk, const Color(0xFF07080D));
        // Stock info == stock accent; the locked info follows the pack.
        expect(tokens.info, expectedAccent);
        // The soft wash stays a pack-tinted surface, never the stock one.
        expect(tokens.accentSoft, isNot(tokens.accent));
        expect(tokens.accentSoft, isNot(_stockAccent));
      });
    }

    test('the Material color scheme and the tokens agree', () {
      final data = buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
        uiTheme: _lockedPack(),
      );
      expect(
        data.extension<FaDesignTokens>()!.accent,
        data.colorScheme.primary,
      );
    });
  });

  group('stock tokens (REG)', () {
    for (final brightness in Brightness.values) {
      test('$brightness: no uiTheme keeps the stock accent byte-identical', () {
        final data = buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: brightness,
        );
        final tokens = data.extension<FaDesignTokens>()!;
        expect(tokens.accent, _stockAccent);
        expect(tokens.info, _stockAccent);
        expect(tokens.accentInk, const Color(0xFFFFFFFF));
      });

      test('$brightness: an unlocked pack palette keeps the stock tokens '
          '(REG)', () {
        final unlocked = FaUiTheme(
          darkPalette: _lockedPack().darkPalette,
          lightPalette: _lockedPack().lightPalette,
        );
        final data = buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: brightness,
          uiTheme: unlocked,
        );
        final tokens = data.extension<FaDesignTokens>()!;
        expect(tokens.accent, _stockAccent);
        expect(tokens.accentInk, const Color(0xFFFFFFFF));
      });
    }
  });
}
