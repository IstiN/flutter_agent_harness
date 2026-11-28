// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart';

/// gh-2466: the settings form's vision switch derives from the ENDPOINT's
/// reported input modalities when the `/models` answer carries them — the
/// AIN gateway serves multimodal ids the id heuristic cannot see
/// (`mistralai/mistral-large-4-0` is text+image) and serves text-only ids
/// with image in the name. The heuristic keeps covering unreported ids.
void main() {
  testWidgets('endpoint-reported image modalities check the vision switch '
      '(heuristic-missed id)', (tester) async {
    Future<ModelsEndpointInfo> modelsWithModalities(
      String baseUrl, {
      required String apiKey,
    }) async => (
      const ['mistralai/mistral-large-4-0', 'sao10k/l3-lunaris-8b'],
      const <String, int>{},
      const <String, int>{},
      const {
        'mistralai/mistral-large-4-0': ['text', 'image'],
        'sao10k/l3-lunaris-8b': ['text'],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentSettingsForm(
              registry: ProviderRegistry.inMemory(),
              modelsFetcher: modelsWithModalities,
              onConnect: (_) async {},
            ),
          ),
        ),
      ),
    );
    // Provider-first form: pick a provider (OpenRouter) to reveal the
    // config fields.
    await tester.ensureVisible(find.text('OpenRouter'));
    await tester.tap(find.text('OpenRouter'));
    await tester.pumpAndSettle();
    // The debounced endpoint fetch lands.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    bool visionValue() {
      final rowFinder = find.widgetWithText(
        SettingsSwitchRow,
        'Supports images (vision)',
      );
      expect(rowFinder, findsOneWidget);
      return tester.widget<SettingsSwitchRow>(rowFinder).value;
    }

    // A heuristic-missed id with a reported image modality → checked.
    await tester.enterText(
      find.widgetWithText(TextField, 'Model id'),
      'mistralai/mistral-large-4-0',
    );
    await tester.pump();
    expect(visionValue(), isTrue, reason: 'the endpoint reported image');

    // A reported text-only id → unchecked (the heuristic would keep the
    // previous value; the endpoint's word wins).
    await tester.enterText(
      find.widgetWithText(TextField, 'Model id'),
      'sao10k/l3-lunaris-8b',
    );
    await tester.pump();
    expect(visionValue(), isFalse, reason: 'the endpoint reported text-only');
  });

  testWidgets(
    'the connect config carries the endpoint-derived vision verdict',
    (tester) async {
      AgentConfig? connected;
      Future<ModelsEndpointInfo> modelsWithModalities(
        String baseUrl, {
        required String apiKey,
      }) async => (
        const ['mistralai/mistral-large-4-0'],
        const <String, int>{'mistralai/mistral-large-4-0': 1048576},
        const <String, int>{},
        const {
          'mistralai/mistral-large-4-0': ['text', 'image'],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentSettingsForm(
                registry: ProviderRegistry.inMemory(),
                modelsFetcher: modelsWithModalities,
                onConnect: (config) async => connected = config,
              ),
            ),
          ),
        ),
      );
      // Provider-first form: pick a provider (OpenRouter) to reveal the
      // config fields.
      await tester.ensureVisible(find.text('OpenRouter'));
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'mistralai/mistral-large-4-0',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Start chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start chat'));
      await tester.pumpAndSettle();

      expect(connected, isNotNull);
      expect(connected!.supportsImages, isTrue);
      expect(connected!.contextWindow, 1048576);
    },
  );
}
