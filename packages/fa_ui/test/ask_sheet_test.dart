// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _options = [
  AskOption(label: 'Alpha'),
  AskOption(label: 'Beta'),
];

/// Pumps a host whose button opens the ask sheet; the returned completer
/// carries the sheet's result.
Future<List<AskAnswer>?> Function() _openSheet(WidgetTester tester) {
  // ignore: omit_local_variable_types
  List<AskAnswer>? result = const [];
  var answered = false;
  // The sentinel: `result` stays `const []` until the sheet pops.
  final host = MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: FilledButton(
          onPressed: () async {
            final answers = await showAskSheet(context, const [
              AskQuestion(question: 'Pick one', options: _options),
            ]);
            result = answers;
            answered = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  // ignore: avoid_returning_null
  return () async {
    await tester.pumpWidget(host);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return null;
  };
}

void main() {
  testWidgets('single-select shows the free-text field alongside options', (
    tester,
  ) async {
    final open = _openSheet(tester);
    await open();
    // No hidden-behind-a-radio custom answer: the field is visible up
    // front, next to the option list.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('typing a custom answer submits it without touching options', (
    tester,
  ) async {
    List<AskAnswer>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showAskSheet(context, const [
                  AskQuestion(question: 'Pick one', options: _options),
                ]);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'my own answer');
    await tester.pump();
    await tester.tap(find.text('Answer'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.single.freeText, 'my own answer');
    expect(result!.single.selected, isEmpty);
  });

  testWidgets('option plus typed note yields selection with freeText', (
    tester,
  ) async {
    List<AskAnswer>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showAskSheet(context, const [
                  AskQuestion(question: 'Pick one', options: _options),
                ]);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'but only on weekdays');
    await tester.pump();
    await tester.tap(find.text('Answer'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.single.selected, ['Beta']);
    expect(result!.single.freeText, 'but only on weekdays');
  });
}
