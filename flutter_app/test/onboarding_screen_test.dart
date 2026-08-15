// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
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
        ),
      ),
    ),
  );
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

    testWidgets('swipes and Continues through all four pages', (tester) async {
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
      expect(find.text('Your sandbox is ready.'), findsOneWidget);
      expect(find.text('Open Fa'), findsOneWidget);

      // Analytics: only the started + screen events so far (no finish yet).
      expect(events.map((e) => e.$1), ['onboarding_started', 'screen_opened']);
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
        final store = OnboardingStore.inMemory();
        bool? skippedFlag;
        await _pumpOnboarding(
          tester,
          onboardingStore: store,
          initialPage: 3,
          onFinished: ({required bool skipped}) => skippedFlag = skipped,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();

        expect(store.seen, isTrue);
        expect(skippedFlag, isTrue);
        expect(events.last.$1, 'onboarding_skipped');
        expect(events.last.$2['page'], 3);
      },
    );

    testWidgets('Get started completes the flow and sets the flag', (
      tester,
    ) async {
      final store = OnboardingStore.inMemory();
      bool? skippedFlag;
      await _pumpOnboarding(
        tester,
        onboardingStore: store,
        initialPage: 3,
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

        // Skipping sets the flag and boot continues to the setup form.
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();
        expect(onboardingStore.seen, isTrue);
        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.byType(SetupScreen), findsOneWidget);
      },
    );

    testWidgets('a seen flag routes straight to the setup form', (
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
      expect(find.byType(SetupScreen), findsOneWidget);
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
