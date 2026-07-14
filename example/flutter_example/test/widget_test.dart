import 'package:flutter/material.dart';
import 'package:flutter_agent_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Setup screen asks for API key', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Connect to fah'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Start chat'), findsOneWidget);
  });
}
