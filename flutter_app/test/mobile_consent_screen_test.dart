// Widget tests for the mobile device-automation consent screen.
//
// The screen is driven through a fake implementing the pure-Dart
// MobileControlContract, so no platform channel is touched. Covers:
// render (title + body + button), the enable flow (acknowledge →
// pending → system settings call), the one-tap disable flow, the
// store-flavor defensive gate, resume reconciliation, and en/ru locales.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/mobile/mobile_consent.dart';
import 'package:fa/ui/screens/mobile_consent_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeControl implements MobileControlContract {
  FakeControl({this.flavorValue = 'god', this.enabled = false});

  final String flavorValue;
  bool enabled;
  final List<String> calls = [];

  @override
  Future<String> flavor() async {
    calls.add('flavor');
    return flavorValue;
  }

  @override
  Future<bool> accessibilityEnabled() async {
    calls.add('accessibilityEnabled');
    return enabled;
  }

  @override
  Future<void> openAccessibilitySettings() async {
    calls.add('openAccessibilitySettings');
    // Opening the system page does not enable anything — the user flips
    // the toggle there (tests set [enabled] to model that).
  }

  @override
  Future<void> disableAccessibility() async {
    calls.add('disableAccessibility');
    enabled = false;
  }

  @override
  Future<bool> projectionConsent() async {
    calls.add('projectionConsent');
    return false;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required MobileControlContract control,
  MobileConsentModel? model,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MobileConsentScreen(control: control, model: model),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders title, consent copy and the enable button', (
    tester,
  ) async {
    final control = FakeControl();
    await _pump(tester, control: control);

    expect(find.text('Device automation'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text('Enable — open system settings'), findsOneWidget);
    expect(find.text('Accessibility service: off'), findsOneWidget);
    expect(
      find.textContaining('read the screen content'),
      findsOneWidget,
    );
  });

  testWidgets('enable: acknowledges, marks pending, opens system settings', (
    tester,
  ) async {
    final control = FakeControl();
    final model = MobileConsentModel();
    await _pump(tester, control: control, model: model);
    expect(model.stage, MobileConsentStage.notShown);

    await tester.tap(find.text('Enable — open system settings'));
    await tester.pumpAndSettle();

    expect(control.calls, contains('openAccessibilitySettings'));
    expect(model.stage, MobileConsentStage.servicePending);
    expect(model.eventLog, hasLength(2));
  });

  testWidgets('resume from system settings reconciles the stage to on', (
    tester,
  ) async {
    final control = FakeControl();
    final model = MobileConsentModel();
    await _pump(tester, control: control, model: model);

    await tester.tap(find.text('Enable — open system settings'));
    await tester.pumpAndSettle();
    // The user flips the toggle in the system page before returning.
    control.enabled = true;
    expect(model.stage, MobileConsentStage.servicePending);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(model.stage, MobileConsentStage.serviceOn);
    expect(find.text('Accessibility service: on'), findsOneWidget);
    // The one-tap disable replaces the enable button.
    expect(find.text('Disable'), findsOneWidget);
    expect(find.text('Enable — open system settings'), findsNothing);
  });

  testWidgets('disable: one tap calls the control and lands serviceOff', (
    tester,
  ) async {
    final control = FakeControl(enabled: true);
    final model = MobileConsentModel(stage: MobileConsentStage.serviceOn);
    await _pump(tester, control: control, model: model);
    expect(find.text('Disable'), findsOneWidget);

    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();

    expect(control.calls, contains('disableAccessibility'));
    expect(model.stage, MobileConsentStage.serviceOff);
    expect(find.text('Accessibility service: off'), findsOneWidget);
  });

  testWidgets('store flavor shows the not-available gate and no buttons', (
    tester,
  ) async {
    final control = FakeControl(flavorValue: 'store');
    await _pump(tester, control: control);

    expect(
      find.text('Device automation is not available in this build of Fa.'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Enable — open system settings'), findsNothing);
  });

  testWidgets('ru locale renders the Russian copy', (tester) async {
    final control = FakeControl();
    await _pump(tester, control: control, locale: const Locale('ru'));

    expect(find.text('Автоматизация устройства'), findsOneWidget);
    expect(find.text('Включить — открыть настройки системы'), findsOneWidget);
    expect(find.text('Служба специальных возможностей: выключена'),
        findsOneWidget);
  });
}
