// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `/models` fetch recording its calls and reporting two models.
final class _RecordingFetcher {
  final calls = <(String, String)>[];

  Future<ModelsEndpointInfo> call(
    String baseUrl, {
    required String apiKey,
  }) async {
    calls.add((baseUrl, apiKey));
    return (
      const ['acme-1', 'acme-9'],
      const <String, int>{},
      const <String, int>{},
    );
  }
}

void main() {
  group('ProviderEditorPage model row', () {
    ProviderEditorResult? result;

    Future<void> openEditor(
      WidgetTester tester,
      ProviderEditorPage page,
    ) async {
      result = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () {
                  Navigator.of(context)
                      .push<ProviderEditorResult>(
                        MaterialPageRoute(builder: (_) => page),
                      )
                      .then((value) => result = value);
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
    }

    testWidgets('shows the current model; the picked model saves', (
      tester,
    ) async {
      final fetcher = _RecordingFetcher();
      await openEditor(
        tester,
        ProviderEditorPage(
          title: 'Add provider',
          prefillName: 'Acme',
          prefillBaseUrl: 'https://acme.example/v1',
          prefillModelId: 'acme-1',
          modelsFetcher: fetcher.call,
        ),
      );

      // The row shows the current model; there is no model text field.
      expect(find.text('acme-1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ProviderEditorPage),
          matching: find.widgetWithText(TextField, 'Model id (optional)'),
        ),
        findsNothing,
      );

      // The selector opens against the typed URL and lists the fetched ids.
      await tester.tap(find.widgetWithText(InkWell, 'Model id (optional)'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      expect(fetcher.calls.single.$1, 'https://acme.example/v1');
      await tester.tap(find.widgetWithText(ListTile, 'acme-9'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Back on the editor the row follows the pick, and Save reports it.
      expect(find.text('acme-9'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.modelId, 'acme-9');
    });

    testWidgets('an empty model shows the choose hint', (tester) async {
      await openEditor(
        tester,
        ProviderEditorPage(
          title: 'Add provider',
          modelsFetcher: _RecordingFetcher().call,
        ),
      );
      expect(find.text('Tap to choose'), findsOneWidget);
    });

    testWidgets('the freshly typed key authorizes the selector fetch', (
      tester,
    ) async {
      final fetcher = _RecordingFetcher();
      await openEditor(
        tester,
        ProviderEditorPage(
          title: 'Add provider',
          prefillName: 'Acme',
          prefillBaseUrl: 'https://acme.example/v1',
          modelsFetcher: fetcher.call,
        ),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'API key (optional)'),
        'sk-typed',
      );
      await tester.tap(find.widgetWithText(InkWell, 'Model id (optional)'));
      await tester.pumpAndSettle();

      expect(fetcher.calls.single.$2, 'sk-typed');
    });

    testWidgets('preset mode falls back to the stored preset key', (
      tester,
    ) async {
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-stored' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final fetcher = _RecordingFetcher();
      await openEditor(
        tester,
        ProviderEditorPage(
          title: 'OpenRouter',
          preset: ProviderPreset.openrouter,
          modelsFetcher: fetcher.call,
        ),
      );

      // The key field stays empty (a key is saved): the selector must
      // authorize with the stored preset key, resolved through the host.
      await tester.tap(find.widgetWithText(InkWell, 'Model id'));
      await tester.pumpAndSettle();

      expect(fetcher.calls.single.$1, ProviderPreset.openrouter.baseUrl);
      expect(fetcher.calls.single.$2, 'sk-stored');
    });

    testWidgets("edit mode resolves the provider's stored key", (tester) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-kept');
      final fetcher = _RecordingFetcher();
      await openEditor(
        tester,
        ProviderEditorPage(
          title: 'Edit provider',
          initial: provider,
          hasSavedKey: true,
          registry: registry,
          modelsFetcher: fetcher.call,
        ),
      );

      await tester.tap(find.widgetWithText(InkWell, 'Model id (optional)'));
      await tester.pumpAndSettle();

      expect(fetcher.calls.single.$2, 'sk-kept');
    });
  });
}
