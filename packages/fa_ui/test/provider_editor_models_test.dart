// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a host page, pushes the editor from it and returns the completer
/// receiving the editor's result on pop.
Future<Completer<ProviderEditorResult?>> _pushEditor(
  WidgetTester tester,
  ProviderEditorPage page,
) async {
  final result = Completer<ProviderEditorResult?>();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result.complete(
                await Navigator.of(context).push<ProviderEditorResult>(
                  MaterialPageRoute(builder: (_) => page),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(ProviderEditorPage), findsOneWidget);
  return result;
}

/// Lets the debounced `/models` fetch fire and land.
Future<void> _settleFetch(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

Finder _modelField() => find.descendant(
  of: find.byType(FaModelListPicker),
  matching: find.byType(TextField),
);

void main() {
  group('ProviderEditorPage model quick select', () {
    testWidgets('the fetched list filters live and a tap picks the id', (
      tester,
    ) async {
      final result = await _pushEditor(
        tester,
        ProviderEditorPage(
          title: 'Add provider',
          modelsFetcher: (baseUrl, {required apiKey}) async => (
            const ['alpha-1', 'beta-2', 'gamma-3'],
            const <String, int>{},
            const <String, int>{},
          ),
        ),
      );

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Acme');
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://acme.example/v1',
      );
      await _settleFetch(tester);
      expect(find.text('alpha-1'), findsOneWidget);
      expect(find.text('beta-2'), findsOneWidget);

      // Typing narrows the list; the field text doubles as the query.
      await tester.enterText(_modelField(), 'bet');
      await tester.pumpAndSettle();
      expect(find.text('alpha-1'), findsNothing);
      expect(find.text('beta-2'), findsOneWidget);

      // A tap writes the id back as the value.
      await tester.tap(find.text('beta-2'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_modelField()).controller!.text,
        'beta-2',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect((await result.future)?.modelId, 'beta-2');
    });

    testWidgets('manual entry stays valid: an unknown id saves as typed', (
      tester,
    ) async {
      final result = await _pushEditor(
        tester,
        ProviderEditorPage(
          title: 'Add provider',
          modelsFetcher: (baseUrl, {required apiKey}) async =>
              (const ['alpha-1'], const <String, int>{}, const <String, int>{}),
        ),
      );

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Acme');
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://acme.example/v1',
      );
      await _settleFetch(tester);

      await tester.enterText(_modelField(), 'custom-x');
      await tester.pumpAndSettle();
      // The discoverable manual row shows for a query with no exact match.
      expect(find.text('Use "custom-x"'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect((await result.future)?.modelId, 'custom-x');
    });

    testWidgets('changing the endpoint re-fetches the list (debounced)', (
      tester,
    ) async {
      final fetchedUrls = <String>[];
      await _pushEditor(
        tester,
        ProviderEditorPage(
          title: 'Add provider',
          modelsFetcher: (baseUrl, {required apiKey}) async {
            fetchedUrls.add(baseUrl);
            return (
              const <String>[],
              const <String, int>{},
              const <String, int>{},
            );
          },
        ),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://a.example/v1',
      );
      await _settleFetch(tester);
      expect(fetchedUrls, ['https://a.example/v1']);

      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://b.example/v1',
      );
      await _settleFetch(tester);
      expect(fetchedUrls, ['https://a.example/v1', 'https://b.example/v1']);
    });

    testWidgets('preset mode fetches the seeded endpoint on open', (
      tester,
    ) async {
      final fetchedUrls = <String>[];
      await _pushEditor(
        tester,
        ProviderEditorPage(
          title: 'OpenRouter',
          preset: ProviderPreset.openrouter,
          modelsFetcher: (baseUrl, {required apiKey}) async {
            fetchedUrls.add(baseUrl);
            return (
              const ['openrouter/auto'],
              const <String, int>{},
              const <String, int>{},
            );
          },
        ),
      );
      await _settleFetch(tester);
      expect(fetchedUrls, ['https://openrouter.ai/api/v1']);
      expect(find.text('openrouter/auto'), findsOneWidget);
    });
  });
}
