// The CodeMie SSO picker pages moved out of the service (issue #476):
// widget-layer behavior — result contract, cancel affordance, trim, and the
// informational project flow.
import 'dart:async';

import 'package:fa/ui/screens/codemie_sso_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('showCodeMieModelPicker — the result contract', () {
    testWidgets('Connect returns the trimmed field value', (tester) async {
      final result = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showCodeMieModelPicker(
                  context,
                  const ['m1', 'm2'],
                  preselected: '  m1  ',
                ).then(result.complete);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The preselection seeds the quick-filter field.
      expect(find.widgetWithText(TextField, '  m1  '), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  gemini-z ');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(result.future, completion('gemini-z'));
    });

    testWidgets('an empty field pops null (empty pick = cancel)', (tester) async {
      final result = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showCodeMieModelPicker(context, const ['m1']).then(result.complete);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(result.future, completion(isNull));
    });

    testWidgets('Cancel only exists when the picker is cancellable', (tester) async {
      final result = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showCodeMieModelPicker(
                  context,
                  const ['m1'],
                  preselected: 'm1',
                  allowCancel: true,
                ).then(result.complete);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result.future, completion(isNull));
    });

    testWidgets('without allowCancel there is no Cancel button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showCodeMieModelPicker(context, const ['m1']);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cancel'), findsNothing);
    });
  });

  group('showCodeMieProjectPicker — purely informational', () {
    testWidgets('Continue always pops (selection does not affect auth headers)', (
      tester,
    ) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: CodeMieProjectPickerPage(
            projects: const ['proj-a', 'proj-b'],
            onSelected: (value) => selected = value,
          ),
        ),
      );

      // Nothing selected yet → the first project is the implicit answer.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(selected, 'proj-a');
    });

    testWidgets('a tapped row becomes the selection (check mark moves)', (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: CodeMieProjectPickerPage(
            projects: const ['proj-a', 'proj-b'],
            onSelected: (value) => selected = value,
          ),
        ),
      );

      await tester.tap(find.text('proj-b'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(selected, 'proj-b');
    });

    testWidgets('the push helper presents the page full-screen on narrow canvases', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showCodeMieProjectPicker(context, const ['proj-a']);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.appBarTitleText('CodeMie Project'), findsOneWidget);
      expect(find.text('proj-a'), findsOneWidget);
    });
  });
}

extension on CommonFinders {
  Finder appBarTitleText(String text) => find.descendant(
    of: find.byType(AppBar),
    matching: find.text(text),
  );
}
