// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fahMarkdownStyleSheet', () {
    test('body text is pinned to the dense chat line height', () {
      final sheet = fahMarkdownStyleSheet(buildFahTheme());
      expect(sheet.p?.height, 1.35);
      expect(sheet.listBullet?.height, 1.35);
      expect(sheet.h1?.height, 1.3);
    });

    test('sizes are explicit even when the theme text theme is null-sized', () {
      // The current Flutter ships M3 text themes with null fontSize — the
      // stylesheet must still resolve concrete sizes (fromTheme asserts).
      final sheet = fahMarkdownStyleSheet(buildFahTheme());
      expect(sheet.p?.fontSize, 14);
      expect(sheet.h1?.fontSize, 28);
      expect(sheet.h2?.fontWeight, FontWeight.w700);
    });

    test('fontSize scales the body and keeps heading proportions', () {
      final sheet = fahMarkdownStyleSheet(buildFahTheme(), fontSize: 18);
      expect(sheet.p?.fontSize, 18);
      expect(sheet.h1?.fontSize, 36);
      expect(sheet.h3?.fontSize, closeTo(24.3, 0.01));
      expect(sheet.listBullet?.fontSize, 18);
      expect(sheet.code?.fontSize, closeTo(16.56, 0.01));
    });
  });
}
