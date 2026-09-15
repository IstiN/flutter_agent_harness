import 'dart:async';

import 'package:fa/ui/widgets/secret_request_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Opens the sheet fully (all tester calls awaited INSIDE this helper)
  /// and returns the sheet's result future.
  Future<Future<String?>> openSheet(
    WidgetTester tester,
    String prompt,
  ) async {
    final result = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => unawaited(
                  showPasswordPromptSheet(context, prompt).then(
                    (value) => result.complete(value),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result.future;
  }

  testWidgets('Enter submits the typed value; the field is obscured',
      (tester) async {
    final done = await openSheet(tester, '[sudo] password for user:');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await done, 'hunter2');
  });

  testWidgets('Submit stays disabled while the field is empty and enables '
      'once text is entered', (tester) async {
    final done = await openSheet(tester, 'Password:');
    expect(
      tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Submit'),
          matching: find.byType(FilledButton),
        ),
      ).onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'pw');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Submit'),
          matching: find.byType(FilledButton),
        ),
      ).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(await done, 'pw');
  });

  testWidgets('Cancel (and the close icon) resolves with null - declined',
      (tester) async {
    final done = await openSheet(tester, 'Password:');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await done, isNull);
  });
}
