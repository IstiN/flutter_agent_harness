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

    testWidgets('a role edit runs the SAME unified picker as the default '
        'chat model, in override mode', (tester) async {
      final store = TaskModelsStore.inMemory();
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskModelsSection(
              store: store,
              registry: registry,
              modelsFetcher: _someModels,
              mainBaseUrl: 'https://openrouter.ai/api/v1',
            ),
          ),
        ),
      );

      await tester.tap(find.text('Quick model'));
      await tester.pumpAndSettle();

      // The unified picker: search field, the clear row, fetched models.
      expect(find.byType(UnifiedModelPickerPage), findsOneWidget);
      expect(find.text('Main connection'), findsOneWidget);
      expect(
        find.textContaining('fast-2', findRichText: true),
        findsWidgets,
      );

      await tester.tap(
        find.textContaining('fast-2', findRichText: true).first,
      );
      await tester.pumpAndSettle();

      final saved = store.overrideFor(TaskRole.smol);
      expect(saved, isNotNull);
      expect(saved!.baseUrl, 'https://acme.example/v1');
      expect(saved.modelId, 'fast-2');
      // The key rides by NAME (host-scoped), never a value.
      expect(saved.apiKeyName, ProviderRegistry.keyNameFor(saved.baseUrl));
    });

    testWidgets('"Main connection" clears the override', (tester) async {
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
          home: Scaffold(
            body: TaskModelsSection(
              store: store,
              mainBaseUrl: 'https://openrouter.ai/api/v1',
            ),
          ),
        ),
      );

      await tester.tap(find.text('Quick model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main connection'));
      await tester.pumpAndSettle();

      expect(store.overrideFor(TaskRole.smol), isNull);
    });
  });
}
