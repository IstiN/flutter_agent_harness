// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for the boot flows: first launch (onboarding →
/// setup → connect → launcher home) and returning launch (restored
/// connection → straight to home, session resumed).
library;

import 'dart:io';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'integration_fakes.dart';

/// Builds the app shell around [BootstrapScreen] the way `MyApp` does, with
/// every persisted store riding one in-memory env.
Widget _bootApp({
  required MemoryExecutionEnv env,
  required LastConnectionStore lastConnection,
  required OnboardingStore onboarding,
  required SessionKeysStore keys,
}) {
  return MaterialApp(
    theme: buildFahTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: BootstrapScreen(
      env: env,
      registry: ProviderRegistry.inMemory(),
      lastConnectionStore: lastConnection,
      onboardingStore: onboarding,
      sessionKeysStore: keys,
      // Engine fakes keep the quick-start scan off the real plugin
      // singletons (their method channels have no answer in host tests).
      webLlmEngine: FakeWebLlmEngine({}),
      gemmaEngine: FakeGemmaEngine(const []),
      transformersJsEngine: FakeTransformersJsEngine({}),
    ),
  );
}

/// Lets real-async work (boot session creation, bundled-skills seeding,
/// asset loads, env persistence) finish, then settles the widget tree. The
/// boot/connect chains await real futures that never complete inside the
/// fake test zone, so plain `pumpAndSettle` cannot drive them.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

/// Bounded variant of [_settle] for surfaces with a perpetual animation
/// (the bundled demo live tiles never finish booting their real JS engine
/// in host tests, so `pumpAndSettle` never returns): polls with real-async
/// delays until [ready] finds its widget, then pumps a fixed number of
/// frames. Each poll also advances the fake clock — the boot's
/// `AgentService.create` waits out a 5 s fake-time timeout around the
/// bundled-skill asset load (> 50 KB assets never complete in the fake
/// zone, see the comment in agent_service.dart).
Future<void> _settleUntil(
  WidgetTester tester,
  Finder ready, {
  int attempts = 60,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    if (ready.evaluate().isNotEmpty) break;
  }
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the provider dropdown on the setup form and picks [label].
Future<void> _selectProvider(WidgetTester tester, String label) async {
  // The provider-first setup flow: a plain list (no dropdown) — the row
  // itself opens the config fields.
  await tester.ensureVisible(find.text(label).first);
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

/// A fake-backed service persisting into `env`'s sessions root (the same
/// root the boot flow's manager uses), for seeding "previous run" sessions.
AgentService _seedingService(MemoryExecutionEnv env) {
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
      streamFunction: scriptedTurns([(model) => textTurn(model, 'ok')]),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '${env.cwd}/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

void main() {
  // AgentService.create reads `.env` through dart:io; real IO futures never
  // complete inside the fake test zone, so the current directory points at
  // an empty one (no .env → no real IO). Same guard as setup_prefill_test.
  Directory emptyCwd() => Directory('/nonexistent-fah-test-dir');

  group('boot flows', () {
    testWidgets('first boot: onboarding → skip → setup → connect → launcher '
        'home; the key never reaches last_connection.json', (tester) async {
      await IOOverrides.runZoned(() async {
        final env = MemoryExecutionEnv();
        final lastConnection = await LastConnectionStore.load(env);
        final onboarding = await OnboardingStore.load(env);
        final keys = await SessionKeysStore.load(env);
        await tester.pumpWidget(
          _bootApp(
            env: env,
            lastConnection: lastConnection,
            onboarding: onboarding,
            keys: keys,
          ),
        );
        await _settle(tester);

        // First launch: onboarding shows, setup does not.
        expect(find.byType(OnboardingScreen), findsOneWidget);
        expect(find.byType(SetupScreen), findsNothing);

        // Four pages, Skip on every one of them.
        for (var page = 0; page < 3; page++) {
          expect(find.text('Skip'), findsOneWidget, reason: 'page ${page + 1}');
          await tester.tap(find.text('Continue'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Open Fa'), findsOneWidget);

        // Skipping sets the persisted flag and boot continues to the setup
        // form.
        await tester.tap(find.text('Skip'));
        await _settle(tester);
        expect(onboarding.seen, isTrue);
        expect(
          (await env.readTextFile(
            '${env.cwd}/${OnboardingStore.fileName}',
          )).valueOrNull,
          isNotNull,
        );
        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.byType(SetupScreen), findsOneWidget);

        // Complete the setup with a hosted endpoint and connect.
        await _selectProvider(tester, 'Ollama');
        await tester.enterText(
          find.widgetWithText(TextField, 'API key'),
          'sk-first-boot',
        );
        await tester.ensureVisible(find.text('Start chat'));
        await tester.tap(find.text('Start chat'));
        await _settle(tester);

        // Connected: the narrow-layout home is the apps launcher, with the
        // mini chat bar (composer) at the bottom.
        expect(find.byType(AppLauncherScreen), findsOneWidget);
        expect(find.byType(ChatComposer), findsOneWidget);

        // The connection persisted — non-secret parts only.
        final raw = (await env.readTextFile(
          '${env.cwd}/${LastConnectionStore.fileName}',
        )).valueOrNull!;
        expect(raw, contains('gpt-oss:120b'));
        expect(raw, contains('https://ollama.com/v1'));
        expect(raw, isNot(contains('sk-first-boot')));
      }, getCurrentDirectory: emptyCwd);
    });

    testWidgets('returning boot: saved connection + key auto-connects '
        'without onboarding and resumes the previous session', (tester) async {
      await IOOverrides.runZoned(() async {
        final env = MemoryExecutionEnv();
        // A previous run left: a persisted connection (no key), the key in
        // the saved-keys store, the onboarding flag seen, and a session with
        // a user message.
        final lastConnection = await LastConnectionStore.load(env);
        await lastConnection.saveFromConfig(
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'openai/gpt-4o-mini',
            baseUrl: 'https://openrouter.ai/api/v1',
            apiKey: 'sk-returning',
          ),
        );
        final keys = await SessionKeysStore.load(env);
        await keys.set('OPENROUTER_API_KEY', 'sk-returning');
        final onboarding = await OnboardingStore.load(env);
        await onboarding.markSeen();

        final seed = _seedingService(env);
        await tester.runAsync(() async {
          await seed.initialize();
          await seed.sendText('earlier chat');
          await seed.waitForIdle();
        });
        final seededId = seed.currentSessionId!;
        seed.dispose();

        await tester.pumpWidget(
          _bootApp(
            env: env,
            lastConnection: lastConnection,
            onboarding: onboarding,
            keys: keys,
          ),
        );
        await _settleUntil(tester, find.byType(AppLauncherScreen));

        // Straight to the launcher home: no onboarding, no setup form.
        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.byType(SetupScreen), findsNothing);
        expect(find.byType(AppLauncherScreen), findsOneWidget);

        // The previous session was resumed, not stacked under a fresh one.
        final launcher = tester.widget<AppLauncherScreen>(
          find.byType(AppLauncherScreen),
        );
        final manager = launcher.manager;
        expect(manager.activeId, seededId);
        expect(manager.sessions, hasLength(1));
        expect(
          manager.active!.service.messages.any(
            (message) => message.content.contains('earlier chat'),
          ),
          isTrue,
        );
      }, getCurrentDirectory: emptyCwd);
    });
  });
}
