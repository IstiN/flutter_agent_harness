// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/dap_settings_page.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/redaction_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_navigation.dart';
import 'package:fa/ui/screens/skills_toggles_section.dart';
import 'package:fa/ui/screens/tools_availability_section.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa/ui/widgets/github_account_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

  Future<void> pumpCategory(
    WidgetTester tester,
    SettingsCategory category,
    AgentService service,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          service: service,
          env: service.env,
          registry: ProviderRegistry.inMemory(),
          layoutStore: LauncherLayoutStore.inMemory(),
          category: category,
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Providers & Models contains providers and concrete model '
      'controls instead of a Models dialog row', (tester) async {
    final service = fakeService();
    await service.initialize();
    await pumpCategory(tester, SettingsCategory.providersModels, service);

    expect(find.byType(ProvidersSection), findsOneWidget);
    expect(find.byType(DefaultChatModelSection), findsOneWidget);
    expect(find.byType(VisualDirectionSection), findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('UI Theme contains every appearance and chat-layout control', (
    tester,
  ) async {
    final service = fakeService();
    await service.initialize();
    await pumpCategory(tester, SettingsCategory.uiTheme, service);

    expect(find.byType(VisualDirectionSection), findsOneWidget);
    expect(find.byType(ThemePacksSection), findsOneWidget);
    expect(find.byType(ChatTextSection), findsOneWidget);
    expect(find.byType(ImagePreviewsSection), findsOneWidget);
    expect(find.byType(HomeGridSection), findsOneWidget);
    expect(find.byType(ProvidersSection), findsNothing);
    expect(find.byType(KeysSection), findsNothing);
  });

  testWidgets('Accounts & Secrets groups hub, GitHub and saved keys', (
    tester,
  ) async {
    final service = fakeService();
    await service.initialize();
    await pumpCategory(tester, SettingsCategory.accountsSecrets, service);

    expect(find.byType(DapHubSection), findsOneWidget);
    expect(find.byType(GithubAccountSection), findsOneWidget);
    expect(find.byType(KeysSection), findsOneWidget);
    expect(find.byType(ToolsAvailabilitySection), findsNothing);
  });

  testWidgets('Skills & Tools groups skills, tools and redaction', (
    tester,
  ) async {
    final service = fakeService();
    await service.initialize();
    await pumpCategory(tester, SettingsCategory.skillsTools, service);

    expect(find.byType(SkillsTogglesSection), findsOneWidget);
    expect(find.byType(ToolsAvailabilitySection), findsOneWidget);
    expect(find.byType(RedactionSection), findsOneWidget);
    expect(find.byType(ApprovalModeSelector), findsNothing);
    expect(find.byType(CompactionSection), findsNothing);
  });

  testWidgets('Agent Config groups approval, compaction and CLI-only '
      'agent settings', (tester) async {
    final service = fakeService();
    await service.initialize();
    await pumpCategory(tester, SettingsCategory.agentConfig, service);

    expect(find.byType(ApprovalModeSelector), findsOneWidget);
    expect(find.byType(CompactionSection), findsOneWidget);
    expect(find.byType(CliOnlySettingsSection), findsOneWidget);
    expect(find.byType(SkillsTogglesSection), findsNothing);
    expect(find.byType(DebugLogsSection), findsNothing);
  });

  testWidgets('Others keeps app reset, onboarding replay and diagnostics', (
    tester,
  ) async {
    final service = fakeService();
    await service.initialize();
    await pumpCategory(tester, SettingsCategory.others, service);

    expect(find.byType(ResetAppsSection), findsOneWidget);
    expect(find.byType(OnboardingReplaySection), findsOneWidget);
    expect(find.byType(DebugLogsSection), findsOneWidget);
    expect(find.byType(KeysSection), findsNothing);
  });

  testWidgets('narrow categorized Settings drills down and returns to the '
      'six top-level categories', (tester) async {
    final service = fakeService();
    await service.initialize();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(service: service, categorized: true)),
    );
    await tester.pumpAndSettle();

    for (final category in SettingsCategory.values) {
      expect(find.text(category.label), findsOneWidget);
    }
    expect(find.byType(ProvidersSection), findsNothing);

    await tester.tap(find.text(SettingsCategory.providersModels.label));
    await tester.pumpAndSettle();
    expect(find.byType(ProvidersSection), findsOneWidget);
    expect(find.byType(DefaultChatModelSection), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settingsBackButton')));
    await tester.pumpAndSettle();
    expect(find.byType(ProvidersSection), findsNothing);
    for (final category in SettingsCategory.values) {
      expect(find.text(category.label), findsOneWidget);
    }
  });
}
