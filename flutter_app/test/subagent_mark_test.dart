import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/subagent_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Finder> pumpMark(WidgetTester tester, Brightness brightness) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.light
            ? buildFahThemeLight()
            : buildFahTheme(),
        home: Scaffold(
          body: Center(
            child: ColoredBox(
              color: brightness == Brightness.light
                  ? const Color(0xFFF8F9FC)
                  : const Color(0xFF14161A),
              child: const SubagentMark(size: 13),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return find.byType(SubagentMark);
  }

  testWidgets('renders in the light theme', (tester) async {
    final finder = await pumpMark(tester, Brightness.light);
    expect(finder, findsOneWidget);
    expect(tester.getSize(finder), const Size(13, 13));
  });

  testWidgets('renders in the dark theme', (tester) async {
    final finder = await pumpMark(tester, Brightness.dark);
    expect(finder, findsOneWidget);
    expect(tester.getSize(finder), const Size(13, 13));
  });

  testWidgets('an explicit color and size are honored', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahThemeLight(),
        home: const Scaffold(
          body: Center(child: SubagentMark(size: 11, color: Color(0xFF5EEAD4))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SubagentMark)), const Size(11, 11));
  });
}
