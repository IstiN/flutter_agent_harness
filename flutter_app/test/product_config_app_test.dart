import 'package:fa/main.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stock MyApp retains the Fa title', (tester) async {
    await tester.pumpWidget(
      MyApp(themeController: ThemeController.inMemory(FahThemeMode.dark)),
    );
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Fa');
  });

  testWidgets('host product name reaches the app shell without a host fork', (
    tester,
  ) async {
    final config = FaProductConfig.fromJson({
      'productId': 'host-product',
      'displayName': 'Host Workspace',
      'featureFlags': <Object?>[],
    });
    await tester.pumpWidget(
      MyApp(
        productConfig: config,
        themeController: ThemeController.inMemory(FahThemeMode.dark),
      ),
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'Host Workspace',
    );
  });
}
