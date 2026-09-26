// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `/models` fetch reporting no models (keeps the pickers off network).
Future<ModelsEndpointInfo> _noModels(
  String baseUrl, {
  required String apiKey,
}) async {
  return (const <String>[], const <String, int>{}, const <String, int>{});
}

/// Issue #975: EVERY add-provider entry opens the ONE settings flow —
/// [AddProviderPresetPickerPage] → the provider editor — never the bare
/// simplified [ProviderEditorPage] push.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'session model picker add-provider opens the settings preset picker',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedModelPickerPage(
            connection: FaStaticChatConnection(
              providerKind: 'openai-completions',
              activeBaseUrl: 'https://acme.example/v1',
              modelId: 'acme-1',
            ),
            onApply: (_) async {},
            registry: registry,
            modelsFetcher: _noModels,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();

      // The SAME page widget the Settings → Providers → Add flow opens —
      // never the bare editor push.
      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      expect(find.byType(ProviderEditorPage), findsNothing);
    },
  );

  testWidgets(
    'media-slot picker add-provider fallback opens the settings preset picker',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaSlotProviderPickerPage(
            slot: null,
            title: 'Pick a provider',
            registry: ProviderRegistry.inMemory(),
            connectedOnly: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();

      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      expect(find.byType(ProviderEditorPage), findsNothing);
    },
  );
}
