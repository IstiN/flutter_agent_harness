/// Golden (screenshot) tests for `lib/ui/screens/onboarding_screen.dart` —
/// the first-launch onboarding flow matching the reference design: welcome
/// with chat/app mockups, provider selection, permission cards, and the
/// ready page with app grid. Dark + light variants at phone and desktop sizes.
library;

import 'package:fa/services/onboarding_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Pumps one onboarding page full-screen (the screen is itself a Scaffold).
Future<void> _pumpOnboardingPage(
  WidgetTester tester, {
  required int page,
  ThemeData? theme,
  Size? size,
}) {
  return pumpGolden(
    tester,
    OnboardingScreen(
      onboardingStore: OnboardingStore.inMemory(),
      initialPage: page,
    ),
    size: size ?? goldenSizePhone,
    theme: theme,
    wrap: (child) => child,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('onboarding goldens (new design)', () {
    testWidgets('page 1 — Start with an idea (dark, phone)', (tester) async {
      await _pumpOnboardingPage(tester, page: 0);
      await expectGolden(tester, 'onboarding_p1_dark_phone');
    });

    testWidgets('page 1 — Start with an idea (light, phone)', (tester) async {
      await _pumpOnboardingPage(tester, page: 0, theme: buildFahThemeLight());
      await expectGolden(tester, 'onboarding_p1_light_phone');
    });

    testWidgets('page 2 — Choose provider (dark, phone)', (tester) async {
      await _pumpOnboardingPage(tester, page: 1);
      await expectGolden(tester, 'onboarding_p2_dark_phone');
    });

    testWidgets('page 3 — Permissions (dark, phone)', (tester) async {
      await _pumpOnboardingPage(tester, page: 2);
      await expectGolden(tester, 'onboarding_p3_dark_phone');
    });

    testWidgets('page 4 — Sandbox ready (dark, phone)', (tester) async {
      await _pumpOnboardingPage(tester, page: 3);
      await expectGolden(tester, 'onboarding_p4_dark_phone');
    });

    testWidgets('page 1 — Start with an idea (dark, desktop)', (tester) async {
      await _pumpOnboardingPage(tester, page: 0, size: goldenSizeDesktop);
      await expectGolden(tester, 'onboarding_p1_dark_desktop');
    });

    testWidgets('page 1 — Start with an idea (light, desktop)', (tester) async {
      await _pumpOnboardingPage(
        tester,
        page: 0,
        theme: buildFahThemeLight(),
        size: goldenSizeDesktop,
      );
      await expectGolden(tester, 'onboarding_p1_light_desktop');
    });

    testWidgets('page 2 — Choose provider (dark, desktop)', (tester) async {
      await _pumpOnboardingPage(tester, page: 1, size: goldenSizeDesktop);
      await expectGolden(tester, 'onboarding_p2_dark_desktop');
    });

    testWidgets('page 3 — Permissions (dark, desktop)', (tester) async {
      await _pumpOnboardingPage(tester, page: 2, size: goldenSizeDesktop);
      await expectGolden(tester, 'onboarding_p3_dark_desktop');
    });

    testWidgets('page 4 — Sandbox ready (dark, desktop)', (tester) async {
      await _pumpOnboardingPage(tester, page: 3, size: goldenSizeDesktop);
      await expectGolden(tester, 'onboarding_p4_dark_desktop');
    });
  });
}
