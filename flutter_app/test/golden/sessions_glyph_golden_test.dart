// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Goldens for issue #462: the modernized sessions glyph (A4b «Modern pair
// + dots»). Covers the toggle button's normal and active (pressed) states
// under both themes, plus a size strip proving the E1 legibility at the
// small bar sizes (16–24 px).
library;

import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Pumps the sessions toggle exactly as it lives in the chat bar — an
/// [IconButton] on the sheet's panel-alt surface — under [dark].
Future<void> _pumpToggle(WidgetTester tester, {required bool dark}) async {
  await pumpGolden(
    tester,
    Builder(
      builder: (context) {
        final colors = FahColors.of(context);
        return ColoredBox(
          color: colors.panelAlt,
          child: Center(
            child: IconButton(
              onPressed: () {},
              icon: SessionsGlyph(
                color: colors.dim,
                background: colors.panelAlt,
              ),
            ),
          ),
        );
      },
    ),
    theme: dark ? buildFahTheme() : buildFahThemeLight(),
    size: const Size(160, 96),
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('normal state, dark theme', (tester) async {
    await _pumpToggle(tester, dark: true);
    await expectGolden(tester, 'sessions_glyph_dark');
  });

  testWidgets('normal state, light theme', (tester) async {
    await _pumpToggle(tester, dark: false);
    await expectGolden(tester, 'sessions_glyph_light');
  });

  testWidgets('active (pressed) state, dark theme', (tester) async {
    await _pumpToggle(tester, dark: true);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await expectGolden(tester, 'sessions_glyph_dark_active');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('active (pressed) state, light theme', (tester) async {
    await _pumpToggle(tester, dark: false);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await expectGolden(tester, 'sessions_glyph_light_active');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('size strip — E1 legibility at small bar sizes', (tester) async {
    await pumpGolden(
      tester,
      Builder(
        builder: (context) {
          final colors = FahColors.of(context);
          return ColoredBox(
            color: colors.panelAlt,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final size in const [16.0, 18.0, 20.0, 22.0, 24.0])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SessionsGlyph(
                        color: colors.dim,
                        background: colors.panelAlt,
                        size: size,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
      size: const Size(360, 96),
    );
    await expectGolden(tester, 'sessions_glyph_sizes');
  });
}
