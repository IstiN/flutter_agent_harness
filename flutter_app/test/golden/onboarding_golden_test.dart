/// Golden (screenshot) tests for `lib/ui/screens/onboarding_screen.dart` —
/// the first-launch onboarding flow: welcome + AI disclaimer, permissions
/// explainer, model preset wizard, privacy. All four pages at phone size in
/// the dark theme, plus light-theme variants of the welcome and model pages
/// (both brightnesses must read well). The preset wizard renders with a
/// saved OpenRouter key so Apply is enabled (no missing-key warning).
library;

import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Pumps one onboarding page full-screen (the screen is itself a Scaffold)
/// with the stores a first launch would have.
Future<void> _pumpOnboardingPage(
  WidgetTester tester, {
  required int page,
  ThemeData? theme,
}) {
  return pumpGolden(
    tester,
    SessionKeysScope(
      store: SessionKeysStore.inMemory({'OPENROUTER_API_KEY': 'sk-or-saved'}),
      child: OnboardingScreen(
        onboardingStore: OnboardingStore.inMemory(),
        mediaModelsStore: MediaModelsStore.inMemory(),
        lastConnectionStore: LastConnectionStore.inMemory(),
        initialPage: page,
      ),
    ),
    size: goldenSizePhone,
    theme: theme,
    wrap: (child) => child,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('onboarding goldens', () {
    testWidgets('page 1 — welcome + AI disclaimer (dark)', (tester) async {
      await _pumpOnboardingPage(tester, page: 0);

      // Fa mark, feature rows, and the mandatory AI disclaimer box; the
      // first dot is active, Skip sits top-right.
      await expectGolden(tester, 'onboarding_welcome');
    });

    testWidgets('page 2 — permissions explainer (dark)', (tester) async {
      await _pumpOnboardingPage(tester, page: 1);

      // The six optional permission rows with icon chips.
      await expectGolden(tester, 'onboarding_permissions');
    });

    testWidgets('page 3 — model preset wizard (dark)', (tester) async {
      await _pumpOnboardingPage(tester, page: 2);

      // The budget preset card with an enabled Apply (key saved), the
      // quality card peeking in, and "Set up later".
      await expectGolden(tester, 'onboarding_models');
    });

    testWidgets('page 4 — privacy (dark)', (tester) async {
      await _pumpOnboardingPage(tester, page: 3);

      // The three privacy rows, the privacy-policy link, and the primary
      // button reading "Get started".
      await expectGolden(tester, 'onboarding_privacy');
    });

    testWidgets('page 1 — welcome + AI disclaimer (light)', (tester) async {
      await _pumpOnboardingPage(tester, page: 0, theme: buildFahThemeLight());

      await expectGolden(tester, 'onboarding_welcome_light');
    });

    testWidgets('page 3 — model preset wizard (light)', (tester) async {
      await _pumpOnboardingPage(tester, page: 2, theme: buildFahThemeLight());

      await expectGolden(tester, 'onboarding_models_light');
    });
  });
}
