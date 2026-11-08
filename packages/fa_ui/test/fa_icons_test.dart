// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every semantic glyph has a theme default', () {
    const theme = FaIconThemeData();
    for (final glyph in FaSemanticIcon.values) {
      expect(theme.resolve(glyph), isA<IconData>(), reason: glyph.name);
    }
  });

  testWidgets('FaIcon resolves semantic defaults and inherited sizing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.graphite,
          brightness: Brightness.dark,
        ),
        home: const Center(
          child: IconTheme(
            data: IconThemeData(size: 22, color: Colors.amber),
            child: FaIcon(FaSemanticIcon.search),
          ),
        ),
      ),
    );

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.search_rounded);
    expect(icon.size, isNull);
    expect(icon.color, isNull);
    expect(tester.getSize(find.byType(Icon)), const Size.square(22));
  });

  testWidgets('FaIconThemeData overrides only selected semantic glyphs', (
    tester,
  ) async {
    final base = buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    );
    const custom = FaIconThemeData(
      icons: {FaSemanticIcon.search: Icons.public},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: base.copyWith(
          extensions: [
            ...base.extensions.values.where(
              (extension) => extension is! FaIconThemeData,
            ),
            custom,
          ],
        ),
        home: const Column(
          children: [
            FaIcon(FaSemanticIcon.search),
            FaIcon(FaSemanticIcon.back),
          ],
        ),
      ),
    );

    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    expect(icons[0].icon, Icons.public);
    expect(icons[1].icon, Icons.chevron_left_rounded);
    expect(custom.copyWith().resolve(FaSemanticIcon.search), Icons.public);
    expect(custom.lerp(null, 0.8), same(custom));
  });
}
