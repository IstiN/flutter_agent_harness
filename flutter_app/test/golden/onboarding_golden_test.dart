/// Golden (screenshot) tests for `lib/ui/screens/onboarding_screen.dart` —
/// the first-launch onboarding flow matching the reference design: welcome
/// with chat/app mockups, provider selection, permission cards, and the
/// ready page with app grid. Dark + light variants at phone and desktop sizes.
/// Also covers `onboarding_mockups` (the part file with the mockup widgets)
/// and `provider_marks` (the brand icons in the page-2 provider cards).
library;

import 'package:fa/services/last_connection.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
import 'package:fa_ui/fa_ui.dart' show ProviderEditorPage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Pumps one onboarding page full-screen (the screen is itself a Scaffold).
Future<void> _pumpOnboardingPage(
  WidgetTester tester, {
  required int page,
  ThemeData? theme,
  Size? size,
  ProviderRegistry? registry,
  LastConnectionStore? lastConnectionStore,
}) {
  return pumpGolden(
    tester,
    OnboardingScreen(
      onboardingStore: OnboardingStore.inMemory(),
      initialPage: page,
      registry: registry,
      lastConnectionStore: lastConnectionStore,
    ),
    size: size ?? goldenSizePhone,
    theme: theme,
    wrap: (child) => child,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  // The flow is four pages on every platform — third-party skills are
  // discovered by default (opt-out), so there is no consent page.
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

    testWidgets('page 2 — mandatory gate: locked Continue, no Skip (phone)', (
      tester,
    ) async {
      await _pumpOnboardingPage(
        tester,
        page: 1,
        registry: ProviderRegistry.inMemory(),
        lastConnectionStore: LastConnectionStore.inMemory(),
      );
      await expectGolden(tester, 'onboarding_p2_gated_phone');
    });

    testWidgets('page 2 — mandatory gate: locked Continue, no Skip (desktop)', (
      tester,
    ) async {
      await _pumpOnboardingPage(
        tester,
        page: 1,
        size: goldenSizeDesktop,
        registry: ProviderRegistry.inMemory(),
        lastConnectionStore: LastConnectionStore.inMemory(),
      );
      await expectGolden(tester, 'onboarding_p2_gated_desktop');
    });

    testWidgets('page 2 — provider configured: checked card, unlocked '
        'Continue (phone)', (tester) async {
      await _pumpOnboardingPage(
        tester,
        page: 1,
        registry: ProviderRegistry.inMemory(),
        lastConnectionStore: LastConnectionStore.inMemory(),
      );

      // Drive the real flow: OpenAI (an above-the-fold card) → editor →
      // save. The configured card gets the check and the flow auto-advances
      // to page 3.
      await tester.tap(find.text('OpenAI'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'API key (optional)'),
        'sk-golden',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Back to page 2: the configured card shows the check, Continue is
      // unlocked.
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'onboarding_p2_configured_phone');
    });
  });
}
