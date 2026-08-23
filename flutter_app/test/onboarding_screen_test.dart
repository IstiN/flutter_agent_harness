// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
import 'package:fa_ui/fa_ui.dart' show ProviderEditorPage;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps the onboarding flow full-screen with the app's real theme and
/// localization; [keysStore] is exposed through a [SessionKeysScope] like
/// the app shell does.
Future<void> _pumpOnboarding(
  WidgetTester tester, {
  OnboardingStore? onboardingStore,
  SessionKeysStore? keysStore,
  int initialPage = 0,
  void Function({required bool skipped})? onFinished,
  ProviderRegistry? registry,
  LastConnectionStore? lastConnectionStore,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SessionKeysScope(
        store: keysStore ?? SessionKeysStore.inMemory(),
        child: OnboardingScreen(
          onboardingStore: onboardingStore,
          initialPage: initialPage,
          onFinished: onFinished,
          registry: registry,
          lastConnectionStore: lastConnectionStore,
        ),
      ),
    ),
  );
}

/// Runs [body] with the desktop platform override — the skills-consent
/// surfaces are desktop-only and widget tests default to android. The
/// override is reset before the binding's invariant check (it runs ahead
/// of addTearDown).
Future<void> _onDesktop(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('OnboardingStore', () {
    test('missing file loads as unseen', () async {
      final store = await OnboardingStore.load(MemoryExecutionEnv());
      expect(store.seen, isFalse);
    });

    test('corrupt file loads as unseen instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/onboarding_seen.json', 'not json {');
      final store = await OnboardingStore.load(env);
      expect(store.seen, isFalse);
    });

    test('the seen flag round-trips through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = await OnboardingStore.load(env);
      await store.markSeen();
      expect(store.seen, isTrue);

      final reloaded = await OnboardingStore.load(env);
      expect(reloaded.seen, isTrue);
    });

    test('a wrong schema version loads as unseen', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/onboarding_seen.json',
        '{"version": 99, "seen": true}',
      );
      final store = await OnboardingStore.load(env);
      expect(store.seen, isFalse);
    });
  });

  group('OnboardingScreen', () {
    late List<(String, Map<String, Object>)> events;

    setUp(() {
      events = [];
      AppAnalytics.install((name, params) => events.add((name, params)));
    });

    tearDown(() => AppAnalytics.install(null));

    testWidgets('swipes and Continues through all five pages', (tester) async {
      await _onDesktop(() async {
        await _pumpOnboarding(tester);
        await tester.pumpAndSettle();
        expect(find.text('Start with an idea.'), findsOneWidget);

        // A horizontal fling on page 1 turns the page.
        await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.text('Choose how Fa thinks.'), findsOneWidget);

        // The primary button advances too.
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.text('Give access only when it helps.'), findsOneWidget);

        await tester.tap(find.text('Continue without access'));
        await tester.pumpAndSettle();
        expect(find.text('Reuse your existing skills.'), findsOneWidget);

        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.text('Your sandbox is ready.'), findsOneWidget);
        expect(find.text('Open Fa'), findsOneWidget);

        // Analytics: only the started + screen events so far (no finish yet).
        expect(events.map((e) => e.$1), [
          'onboarding_started',
          'screen_opened',
        ]);
      });
    });

    testWidgets('provider step is mandatory when a registry is wired', (
      tester,
    ) async {
      await _pumpOnboarding(
        tester,
        initialPage: 1,
        registry: ProviderRegistry.inMemory(),
        lastConnectionStore: LastConnectionStore.inMemory(),
      );
      await tester.pumpAndSettle();

      // The shared Add-Provider list is shown…
      expect(find.text('Choose how Fa thinks.'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('CodeMie'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);

      // …and the step cannot be skipped or continued past.
      expect(find.text('Skip'), findsNothing);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Choose how Fa thinks.'), findsOneWidget);
    });

    testWidgets('configuring a provider unlocks the step and advances', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final lastConnection = LastConnectionStore.inMemory();
      await _pumpOnboarding(
        tester,
        initialPage: 1,
        registry: registry,
        lastConnectionStore: lastConnection,
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Custom'),
        200,
        scrollable: find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Acme');
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://acme.example/v1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'API key (optional)'),
        'sk-onboarding',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Provider + key persisted, the connection saved for the boot
      // auto-connect, and the flow advanced to the permissions page.
      expect(registry.providers, hasLength(1));
      expect(registry.keyFor(registry.providers.single.id), 'sk-onboarding');
      expect(lastConnection.connection?.baseUrl, 'https://acme.example/v1');
      expect(find.text('Give access only when it helps.'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget); // gate is past
    });

    testWidgets('Skip sets the seen flag and reports skipped', (tester) async {
      final store = OnboardingStore.inMemory();
      bool? skippedFlag;
      await _pumpOnboarding(
        tester,
        onboardingStore: store,
        onFinished: ({required bool skipped}) => skippedFlag = skipped,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(store.seen, isTrue);
      expect(skippedFlag, isTrue);
      expect(events.map((e) => e.$1), [
        'onboarding_started',
        'screen_opened',
        'onboarding_skipped',
      ]);
    });

    testWidgets(
      'Skip works from the last page too (skippable from every page)',
      (tester) async {
        await _onDesktop(() async {
          final store = OnboardingStore.inMemory();
          bool? skippedFlag;
          await _pumpOnboarding(
            tester,
            onboardingStore: store,
            initialPage: 4,
            onFinished: ({required bool skipped}) => skippedFlag = skipped,
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('Skip'));
          await tester.pumpAndSettle();

          expect(store.seen, isTrue);
          expect(skippedFlag, isTrue);
          expect(events.last.$1, 'onboarding_skipped');
          expect(events.last.$2['page'], 4);
        });
      },
    );

    testWidgets('Get started completes the flow and sets the flag', (
      tester,
    ) async {
      await _onDesktop(() async {
        final store = OnboardingStore.inMemory();
        bool? skippedFlag;
        await _pumpOnboarding(
          tester,
          onboardingStore: store,
          initialPage: 4,
          onFinished: ({required bool skipped}) => skippedFlag = skipped,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open Fa'));
        await tester.pumpAndSettle();

        expect(store.seen, isTrue);
        expect(skippedFlag, isFalse);
        expect(events.map((e) => e.$1), [
          'onboarding_started',
          'screen_opened',
          'onboarding_completed',
        ]);
      });
    });

    testWidgets('mobile flow: four pages, no skills step', (tester) async {
      // The default widget-test platform is android — the skills-consent
      // page is not part of the flow there.
      await _pumpOnboarding(tester);
      await tester.pumpAndSettle();
      expect(find.text('Start with an idea.'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Choose how Fa thinks.'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Give access only when it helps.'), findsOneWidget);

      await tester.tap(find.text('Continue without access'));
      await tester.pumpAndSettle();
      // No skills page — straight to the last page.
      expect(find.text('Reuse your existing skills.'), findsNothing);
      expect(find.text('Your sandbox is ready.'), findsOneWidget);
      expect(find.text('Open Fa'), findsOneWidget);
    });
  });

  group('BootstrapScreen onboarding routing', () {
    testWidgets(
      'first launch without a restorable connection shows onboarding',
      (tester) async {
        final onboardingStore = OnboardingStore.inMemory();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BootstrapScreen(
              env: MemoryExecutionEnv(),
              lastConnectionStore: LastConnectionStore.inMemory(),
              onboardingStore: onboardingStore,
              sessionKeysStore: SessionKeysStore.inMemory(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(OnboardingScreen), findsOneWidget);
        expect(find.byType(SetupScreen), findsNothing);

        // Skipping sets the flag and boot continues to the home bootstrap
        // (an empty manager + placeholder session — the launcher's empty
        // state prompts for a provider; the legacy setup form is gone).
        // One frame only: the home never settles in a fake-async test zone
        // (asset loads never complete), same as the restore-boot test.
        await tester.tap(find.text('Skip'));
        await tester.pump();
        expect(onboardingStore.seen, isTrue);
        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.byType(SetupScreen), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );

    testWidgets('a seen flag routes straight to the home bootstrap', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BootstrapScreen(
            env: MemoryExecutionEnv(),
            lastConnectionStore: LastConnectionStore.inMemory(),
            onboardingStore: OnboardingStore.inMemory(seen: true),
            sessionKeysStore: SessionKeysStore.inMemory(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(SetupScreen), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
      'seen onboarding + undecided skills consent shows the one-time dialog',
      (tester) async {
        await _onDesktop(() async {
          final env = MemoryExecutionEnv();
          final skillsStore = SkillsAccessStore(env);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildFahTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: BootstrapScreen(
                env: env,
                lastConnectionStore: LastConnectionStore.inMemory(),
                onboardingStore: OnboardingStore.inMemory(seen: true),
                skillsAccessStore: skillsStore,
                sessionKeysStore: SessionKeysStore.inMemory(),
              ),
            ),
          );
          // First frame + the post-frame store read + the dialog animation.
          // No pumpAndSettle: the empty-manager home never settles in a
          // fake-async test zone (asset loads never complete).
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Reuse existing agent skills?'), findsOneWidget);

          await tester.tap(find.text('Allow'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(await skillsStore.load(), SkillsAccess.granted);
        });
      },
    );

    testWidgets('the dialog Not now persists denied (never asks again)', (
      tester,
    ) async {
      await _onDesktop(() async {
        final env = MemoryExecutionEnv();
        final skillsStore = SkillsAccessStore(env);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BootstrapScreen(
              env: env,
              lastConnectionStore: LastConnectionStore.inMemory(),
              onboardingStore: OnboardingStore.inMemory(seen: true),
              skillsAccessStore: skillsStore,
              sessionKeysStore: SessionKeysStore.inMemory(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Reuse existing agent skills?'), findsOneWidget);

        await tester.tap(find.text('Not now'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(await skillsStore.load(), SkillsAccess.denied);
      });
    });

    testWidgets('a decided consent never triggers the dialog', (tester) async {
      await _onDesktop(() async {
        final env = MemoryExecutionEnv();
        await SkillsAccessStore(env).save(SkillsAccess.denied);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BootstrapScreen(
              env: env,
              lastConnectionStore: LastConnectionStore.inMemory(),
              onboardingStore: OnboardingStore.inMemory(seen: true),
              skillsAccessStore: SkillsAccessStore(env),
              sessionKeysStore: SessionKeysStore.inMemory(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(find.text('Reuse existing agent skills?'), findsNothing);
      });
    });

    testWidgets('mobile never shows the skills-consent dialog', (tester) async {
      // Default widget-test platform is android: the consent question has no
      // meaning there (the third-party roots don't exist), so the dialog
      // must not fire even with an undecided store.
      final env = MemoryExecutionEnv();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BootstrapScreen(
            env: env,
            lastConnectionStore: LastConnectionStore.inMemory(),
            onboardingStore: OnboardingStore.inMemory(seen: true),
            skillsAccessStore: SkillsAccessStore(env),
            sessionKeysStore: SessionKeysStore.inMemory(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reuse existing agent skills?'), findsNothing);
    });

    testWidgets(
      'a restorable connection skips onboarding (upgraders never see it)',
      (tester) async {
        final lastConnection = LastConnectionStore.inMemory();
        await lastConnection.saveFromConfig(
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'openai/gpt-4o-mini',
            baseUrl: 'https://openrouter.ai/api/v1',
            apiKey: 'sk-or-saved',
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BootstrapScreen(
              env: MemoryExecutionEnv(),
              lastConnectionStore: lastConnection,
              onboardingStore: OnboardingStore.inMemory(),
              sessionKeysStore: SessionKeysStore.inMemory({
                'OPENROUTER_API_KEY': 'sk-or-saved',
              }),
            ),
          ),
        );
        // One frame: the restore boot is in flight (spinner), onboarding is
        // not part of the tree.
        await tester.pump();
        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.byType(SetupScreen), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );
  });
}
