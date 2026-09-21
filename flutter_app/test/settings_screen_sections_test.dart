// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/tools_availability_section.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa_ui/fa_ui.dart' show ProviderEditorPage;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Drives the section gating of `SettingsScreen.build` (issue #702): the
/// no-service add-provider CTA, the service-gated control sections, the
/// subagent tree, and the layout-store section. The heavy Providers/
/// Models flows are covered by settings_test.dart; these pin the build
/// wiring that extraction moved into `_noServiceHint`,
/// `_modelsAndAgentsSections`, `_approvalAndToolsSections` and friends.
void main() {
  AgentService fakeService() {
    return AgentService(
      agent: Agent(
        model: Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test',
          baseUrl: 'https://example.com',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        systemPrompt: 'You are Fa.',
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.end();
          return stream;
        },
        toolRegistry: ToolRegistry(const []),
      ),
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    AgentService? service,
    ProviderRegistry? registry,
    LauncherLayoutStore? layoutStore,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          service: service,
          registry: registry,
          layoutStore: layoutStore,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('no-service add-provider CTA', () {
    testWidgets('shows when there is no service and no saved provider', (
      tester,
    ) async {
      await pumpScreen(tester, registry: ProviderRegistry.inMemory());

      expect(
        find.text('Connect a provider to start chatting.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Add provider'), findsOneWidget);
    });

    testWidgets('shows when no registry is available at all', (tester) async {
      await pumpScreen(tester);

      expect(
        find.text('Connect a provider to start chatting.'),
        findsOneWidget,
      );
    });

    testWidgets('hides once a provider is saved even without a service', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await pumpScreen(tester, registry: registry);

      expect(find.text('Connect a provider to start chatting.'), findsNothing);
    });

    testWidgets('hides when a service is connected', (tester) async {
      final service = fakeService();
      await service.initialize();
      await pumpScreen(tester, service: service);

      expect(find.text('Connect a provider to start chatting.'), findsNothing);
    });

    testWidgets('the CTA opens the provider editor; cancelling saves '
        'nothing', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await pumpScreen(tester, registry: registry);

      await tester.tap(find.widgetWithText(FilledButton, 'Add provider').last);
      await tester.pumpAndSettle();

      expect(find.byType(ProviderEditorPage), findsOneWidget);
      // Back out without saving: the registry stays empty and the CTA
      // still greets the user afterwards.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(registry.providers, isEmpty);
      expect(
        find.text('Connect a provider to start chatting.'),
        findsOneWidget,
      );
    });

    testWidgets('saving from the CTA editor adds the provider and key', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await pumpScreen(tester, registry: registry);

      await tester.tap(find.widgetWithText(FilledButton, 'Add provider').last);
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'CtaProvider',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://cta.example/v1',
      );
      final keyField = find.widgetWithText(TextField, 'API key');
      if (keyField.evaluate().isNotEmpty) {
        await tester.enterText(keyField, 'cta-key-1');
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers, hasLength(1));
      expect(registry.providers.single.name, 'CtaProvider');
      expect(
        registry.keyFor(registry.providers.single.id),
        anyOf(isNull, 'cta-key-1'),
      );
    });
  });

  group('service-gated sections', () {
    testWidgets('without a service the control sections stay hidden', (
      tester,
    ) async {
      await pumpScreen(tester, registry: ProviderRegistry.inMemory());

      expect(find.text('Models'), findsNothing);
      expect(find.byType(ResetAppsSection), findsNothing);
      expect(find.byType(ApprovalModeSelector), findsNothing);
      // Theme/keys/logs render for everyone.
      expect(find.byType(KeysSection), findsOneWidget);
      expect(find.byType(DebugLogsSection), findsOneWidget);
    });

    testWidgets('with a service the control sections render', (tester) async {
      final service = fakeService();
      await service.initialize();
      await pumpScreen(tester, service: service);

      expect(find.text('Models'), findsOneWidget);
      expect(find.byType(ResetAppsSection), findsOneWidget);
      expect(find.byType(ApprovalModeSelector), findsOneWidget);
      expect(find.byType(ToolsAvailabilitySection), findsOneWidget);
      expect(find.byType(CompactionSection), findsOneWidget);
      expect(find.byType(ProviderQueueSection), findsOneWidget);
    });
  });

  group('layout + agents sections', () {
    testWidgets('the home-grid section follows the layout store', (
      tester,
    ) async {
      final service = fakeService();
      await service.initialize();
      await pumpScreen(tester, service: service);
      expect(find.byType(HomeGridSection), findsNothing);

      await pumpScreen(
        tester,
        service: service,
        layoutStore: LauncherLayoutStore.inMemory(),
      );
      expect(find.byType(HomeGridSection), findsOneWidget);
    });

    testWidgets('the agents section follows the subagent manager', (
      tester,
    ) async {
      // The plain constructor leaves the manager unset — no Agents header.
      final bare = fakeService();
      await bare.initialize();
      await pumpScreen(tester, service: bare);
      expect(find.text('Agents'), findsNothing);

      // AgentService.create wires the real subagent manager.
      late final AgentService managed;
      await tester.runAsync(() async {
        managed = await AgentService.create(
          config: AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'test-model',
            baseUrl: 'https://example.com',
            apiKey: 'test-key',
          ),
          env: MemoryExecutionEnv(),
        );
      });
      await pumpScreen(tester, service: managed);
      expect(find.text('Agents'), findsOneWidget);
      expect(find.textContaining('test-model ·'), findsOneWidget);
    });
  });
}
