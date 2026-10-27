// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Issue #1848 coverage: [ModelIdAutocompleteField]'s build arms — the
/// loading spinner/helper, the bundled-catalog note, and the
/// case-insensitive `/models` option filter.
void main() {
  const models = ['Gemini-2.5-Flash', 'gemini-2.5-pro', 'gpt-4o'];

  Future<void> pumpField(
    WidgetTester tester, {
    required TextEditingController controller,
    required FocusNode focusNode,
    bool loading = false,
    bool fromBundledCatalog = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelIdAutocompleteField(
            controller: controller,
            focusNode: focusNode,
            models: models,
            loading: loading,
            fromBundledCatalog: fromBundledCatalog,
          ),
        ),
      ),
    );
    // Bounded pumps: a visible loading spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('while loading the field shows the fetching helper and a '
      'spinner', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpField(
      tester,
      controller: controller,
      focusNode: focusNode,
      loading: true,
    );
    expect(find.text('Fetching models from the endpoint…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('an idle field shows no spinner and no helper', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpField(tester, controller: controller, focusNode: focusNode);
    expect(find.text('Fetching models from the endpoint…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Model id'), findsOneWidget);
  });

  testWidgets('the bundled-catalog note renders only when the list fell '
      'back to the offline catalog', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    const note = 'Live list unavailable — showing the bundled catalog';

    await pumpField(
      tester,
      controller: controller,
      focusNode: focusNode,
      fromBundledCatalog: true,
    );
    expect(find.text(note), findsOneWidget);

    await pumpField(tester, controller: controller, focusNode: focusNode);
    expect(find.text(note), findsNothing);
  });

  testWidgets('the options filter is a case-insensitive contains on the '
      'typed text, and picking one writes it into the controller', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpField(tester, controller: controller, focusNode: focusNode);

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'GEM');
    await tester.pumpAndSettle();

    // Case-insensitive: both Gemini ids match 'GEM', gpt-4o does not.
    expect(find.text('Gemini-2.5-Flash'), findsOneWidget);
    expect(find.text('gemini-2.5-pro'), findsOneWidget);
    expect(find.text('gpt-4o'), findsNothing);

    await tester.tap(find.text('Gemini-2.5-Flash'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Gemini-2.5-Flash');
  });

  testWidgets('a whitespace-only query lists every model id', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpField(tester, controller: controller, focusNode: focusNode);

    // The query is trimmed — a space keeps the overlay open with the
    // full, unfiltered model list.
    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), ' ');
    await tester.pumpAndSettle();

    for (final id in models) {
      expect(find.text(id), findsOneWidget);
    }
  });

  testWidgets('a custom typed id stays valid — it never filters the field '
      'itself', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpField(tester, controller: controller, focusNode: focusNode);

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'my-private-endpoint/v1');
    await tester.pumpAndSettle();

    // No option matches, but the typed id simply stays in the field.
    expect(controller.text, 'my-private-endpoint/v1');
    expect(find.text('my-private-endpoint/v1').first, findsOneWidget);
  });
}
