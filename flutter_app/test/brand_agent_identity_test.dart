// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2391 addendum 9 item 1: with the host brand builder installed (the
/// app boot wires it to [FaBrandTile]) and an AIN product scope, the
/// assistant avatar — and every session/subagent tile riding FaAiAvatar —
/// renders the host mark, never the stock `>Fa` glyph.
library;

import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the assistant avatar follows the AIN profile — no Fa glyph '
      'in the widget tree', (tester) async {
    FaUiHost.brandAvatarBuilder =
        ({required size, dark}) => FaBrandTile(size: size, dark: dark);
    addTearDown(() => FaUiHost.brandAvatarBuilder = null);
    await tester.pumpWidget(
      ProductConfigScope(
        productConfig: const FaProductConfig(
          productId: 'ain',
          displayName: 'AIN',
          agentName: 'AIN Agent',
          featureFlags: <String>{},
        ),
        child: MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: Center(
              child: ChatMessageTile(
                message: FaChatMessage(role: 'assistant', content: 'hello'),
                images: SandboxImageResolver(MemoryExecutionEnv()),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(FaAiAvatar), findsOneWidget);
    expect(find.byType(ProductBrandMark), findsOneWidget);
    expect(find.byType(FaLogo), findsNothing);
    expect(find.text('>Fa'), findsNothing);
    expect(find.textContaining('Fa '), findsNothing);
  });

  testWidgets('stock scope keeps the stock avatar (REG)', (tester) async {
    FaUiHost.brandAvatarBuilder =
        ({required size, dark}) => FaBrandTile(size: size, dark: dark);
    addTearDown(() => FaUiHost.brandAvatarBuilder = null);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(
          body: Center(
            child: ChatMessageTile(
              message: FaChatMessage(role: 'assistant', content: 'hello'),
              images: SandboxImageResolver(MemoryExecutionEnv()),
            ),
          ),
        ),
      ),
    );
    // No scope → stock: FaBrandTile renders the stock logo unchanged.
    expect(find.byType(FaLogo), findsOneWidget);
    expect(find.byType(ProductBrandMark), findsNothing);
  });
}
