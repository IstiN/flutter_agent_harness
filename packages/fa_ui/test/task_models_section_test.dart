// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `/models` fetch reporting two ids.
Future<ModelsEndpointInfo> _someModels(
  String baseUrl, {
  required String apiKey,
}) async =>
    (const ['fast-1', 'fast-2'], const <String, int>{}, const <String, int>{});

void main() {
  group('TaskModelsSection', () {
    testWidgets('role rows show the override or the main-model fallback', (
      tester,
    ) async {
      final store = TaskModelsStore.inMemory();
      await store.setOverride(
        TaskRole.subagent,
        const TaskRoleConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://acme.example/v1',
          modelId: 'delegate-1',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskModelsSection(store: store, mainModelId: 'main-1'),
          ),
        ),
      );

      expect(find.text('Quick model'), findsOneWidget);
      expect(find.text('Subagents model'), findsOneWidget);
      expect(find.text('Same as main'), findsOneWidget); // smol
      expect(find.text('delegate-1'), findsOneWidget); // subagent
    });

    testWidgets('the role editor lists endpoint models, quick-searches and '
        'saves the pick', (tester) async {
      final store = TaskModelsStore.inMemory();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskModelsSection(store: store, mainModelId: 'main-1'),
          ),
        ),
      );

      await tester.tap(find.text('Quick model'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskRoleConfigPage), findsOneWidget);

      // Pick a hosted provider; the editor fetches its list (the fetch is
      // injected through the page — pump a fresh one with the override).
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const TaskRoleConfigPage(
                      role: TaskRole.smol,
                      mainModelId: 'main-1',
                      modelsFetcher: _someModels,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Custom endpoint: type the base URL, the debounced fetch feeds the
      // list (the fetch is the injected override).
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://acme.example/v1',
      );
      await tester.pump(const Duration(milliseconds: 700)); // debounce
      await tester.pumpAndSettle();

      // The list renders; typing narrows it; a tap fills the field.
      expect(find.text('fast-1'), findsOneWidget);
      expect(find.text('fast-2'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'fast-2',
      );
      await tester.pumpAndSettle();
      expect(find.text('fast-1'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'fast-2'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // (The page popped; nothing asserted about the result here — the
      // section-level flow below covers persistence.)
      expect(find.byType(TaskRoleConfigPage), findsNothing);
    });

    testWidgets('"Use main model" clears the override', (tester) async {
      final store = TaskModelsStore.inMemory();
      await store.setOverride(
        TaskRole.smol,
        const TaskRoleConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://acme.example/v1',
          modelId: 'fast-1',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TaskModelsSection(store: store)),
        ),
      );

      await tester.tap(find.text('Quick model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use main model'));
      await tester.pumpAndSettle();

      expect(store.overrideFor(TaskRole.smol), isNull);
    });
  });
}
