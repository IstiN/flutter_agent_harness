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
/// simplified [ProviderEditorPage] push. Round-1 pins (PR #979): the
/// fallback never offers less than its opener (on-device routes forward),
/// the host-builder branch is invoked with the ROUTE context, the unified
/// picker refetches on return, and the Add tile hides without a registry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  UnifiedModelPickerPage buildPicker({
    required ProviderRegistry registry,
    required ModelsEndpointFetcher modelsFetcher,
    List<FaOnDeviceRoute> onDeviceProviders = const [],
    WidgetBuilder? addProviderPage,
  }) {
    return UnifiedModelPickerPage(
      connection: FaStaticChatConnection(
        providerKind: 'openai-completions',
        activeBaseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      ),
      onApply: (_) async {},
      registry: registry,
      modelsFetcher: modelsFetcher,
      onDeviceProviders: onDeviceProviders,
      addProviderPage: addProviderPage,
    );
  }

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
          home: buildPicker(
            registry: registry,
            modelsFetcher: _noModels,
            // The fallback must never offer less than the opener: the
            // picker's own on-device routes ride into the preset picker.
            onDeviceProviders: [
              FaOnDeviceRoute(
                label: 'Gemma on device',
                pageBuilder: (context, onApply) => const SizedBox(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();

      // The SAME page widget the Settings → Providers → Add flow opens —
      // never the bare editor push — with the opener's on-device routes
      // (the picker's lazy list needs a scroll to the tail tiles).
      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      expect(find.byType(ProviderEditorPage), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Gemma on device'),
        200,
        scrollable: find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.text('Gemma on device'),
        ),
        findsOneWidget,
      );
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
            onDeviceRoutes: [
              FaOnDeviceRoute(
                label: 'Gemma on device',
                pageBuilder: (context, onApply) => const SizedBox(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();

      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      expect(find.byType(ProviderEditorPage), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Gemma on device'),
        200,
        scrollable: find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.text('Gemma on device'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'host addProviderPage builder wins and gets the route context',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      final builderContexts = <BuildContext>[];
      await tester.pumpWidget(
        MaterialApp(
          home: buildPicker(
            registry: registry,
            modelsFetcher: _noModels,
            addProviderPage: (routeContext) {
              builderContexts.add(routeContext);
              return const Scaffold(body: Text('HOST_PICKER'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The route below the pushed one goes offstage — capture the picker
      // context BEFORE opening the add flow.
      final pickerContext =
          tester.state(find.byType(UnifiedModelPickerPage)).context;

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();

      // The host page is what got pushed…
      expect(find.text('HOST_PICKER'), findsOneWidget);
      // …built exactly once, with the PUSHED ROUTE's context (not the
      // tile's): its modal route is the host page's, not the picker's.
      expect(builderContexts, hasLength(1));
      final pickerRoute = ModalRoute.of(pickerContext)!;
      final builderRoute = ModalRoute.of(builderContexts.single)!;
      expect(identical(builderRoute, pickerRoute), isFalse);
      expect(builderRoute.isCurrent, isTrue);
    },
  );

  testWidgets('unified picker refetches models when the add flow returns', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'acme-1',
    );
    var fetches = 0;
    Future<ModelsEndpointInfo> countingFetch(
      String baseUrl, {
      required String apiKey,
    }) async {
      fetches++;
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }

    await tester.pumpWidget(
      MaterialApp(
        home: buildPicker(
          registry: registry,
          modelsFetcher: countingFetch,
          addProviderPage: (routeContext) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(routeContext).pop(),
              child: const Text('DONE'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fetches, 1, reason: 'initial fetch on open');

    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    expect(fetches, 1, reason: 'no refetch while the add flow is open');

    await tester.tap(find.text('DONE'));
    await tester.pumpAndSettle();
    expect(fetches, 2, reason: 'the newly added provider must appear');
  });

  testWidgets('the Add tile hides when the picker has no registry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedModelPickerPage(
          connection: FaStaticChatConnection(
            providerKind: 'openai-completions',
            activeBaseUrl: 'https://acme.example/v1',
            modelId: 'acme-1',
          ),
          onApply: (_) async {},
          modelsFetcher: _noModels,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add provider'), findsNothing);
  });
}
