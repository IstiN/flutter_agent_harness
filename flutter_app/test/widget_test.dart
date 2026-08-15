import 'package:flutter/material.dart';
import 'package:fa/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Setup screen asks for API key', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    // Provider-first form: the config fields appear after picking a
    // provider.
    expect(find.text('Connect to Fa'), findsOneWidget);
    await tester.ensureVisible(find.text('OpenRouter').first);
    await tester.tap(find.text('OpenRouter').first);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Start chat'), findsOneWidget);
  });
}
