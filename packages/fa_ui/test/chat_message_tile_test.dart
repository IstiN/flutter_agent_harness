// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SandboxImageResolver images() => SandboxImageResolver(MemoryExecutionEnv());

  Widget wrap(Widget child, {FaUiTheme? uiTheme}) {
    return FaUiThemeProvider(
      data: uiTheme ?? const FaUiTheme(),
      child: MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('assistant bubble shows the avatarBuilder widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'assistant', content: 'hello'),
          images: images(),
          avatarBuilder: (context, role) =>
              role == 'assistant' ? const Text('AV') : null,
        ),
      ),
    );
    expect(find.text('AV'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('no avatarBuilder renders the stock default avatar bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'assistant', content: 'hello'),
          images: images(),
        ),
      ),
    );
    expect(find.text('hello'), findsOneWidget);
    // The stock avatar is the small indigo circle with the sparkle icon.
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
  });

  testWidgets('surface tokens re-seat the bubble and keep the stock border', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'assistant', content: 'hello'),
          images: images(),
        ),
        uiTheme: const FaUiTheme(
          background: Color(0xFF0B0B0F),
          surface: Color(0xFF13131A),
        ),
      ),
    );
    final container = tester.widget<Container>(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == const Color(0xFF13131A),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    // The border follows the ambient divider color (== the stock border in
    // the Fa theme).
    expect(
      (decoration.border! as Border).top.color,
      buildFahTheme().dividerColor,
    );
  });

  test('fahChatColorsOf maps the surface tokens onto the chat palette', () {
    const stock = FahColors.dark;
    final reseated = stock.withSurfaces(
      background: const Color(0xFF0B0B0F),
      surface: const Color(0xFF13131A),
    );
    expect(reseated.bg, const Color(0xFF0B0B0F));
    expect(reseated.panel, const Color(0xFF13131A));
    expect(reseated.panelAlt, const Color(0xFF13131A));
    // Untouched fields stay stock.
    expect(reseated.text, stock.text);
    expect(reseated.border, stock.border);
    // An all-null call is pixel-identical.
    final identicalCopy = stock.withSurfaces();
    expect(identicalCopy.bg, stock.bg);
    expect(identicalCopy.panel, stock.panel);
  });
}
