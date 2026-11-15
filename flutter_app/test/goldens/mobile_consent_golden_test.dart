/// Golden (screenshot) test for the mobile device-automation consent
/// screen (`lib/ui/screens/mobile_consent_screen.dart`): the full-screen
/// explanation + enable surface in a phone frame, en locale. The control
/// is a canned fake — goldens never touch method channels.
library;

import 'package:fa/services/mobile/mobile_consent.dart';
import 'package:fa/ui/screens/mobile_consent_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

class _FakeControl implements MobileControlContract {
  @override
  Future<String> flavor() async => 'god';

  @override
  Future<bool> accessibilityEnabled() async => false;

  @override
  Future<void> openAccessibilitySettings() async {}

  @override
  Future<void> disableAccessibility() async {}

  @override
  Future<bool> projectionConsent() async => false;
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('consent screen, service off (en)', (tester) async {
    await pumpGolden(
      tester,
      MobileConsentScreen(control: _FakeControl()),
      size: goldenSizePhone,
      wrap: (child) => child,
    );
    await expectGolden(tester, 'mobile_consent_screen');
  });
}
