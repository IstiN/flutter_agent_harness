import 'package:fa/main.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

final class _RecordingUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return true;
  }
}

void main() {
  testWidgets('stock MyApp retains the Fa title', (tester) async {
    await tester.pumpWidget(
      MyApp(themeController: ThemeController.inMemory(FahThemeMode.dark)),
    );
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Fa');
  });

  testWidgets('host product name reaches the app shell without a host fork', (
    tester,
  ) async {
    final config = FaProductConfig.fromJson({
      'productId': 'host-product',
      'displayName': 'Host Workspace',
      'featureFlags': <Object?>[],
    });
    await tester.pumpWidget(
      MyApp(
        productConfig: config,
        themeController: ThemeController.inMemory(FahThemeMode.dark),
      ),
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'Host Workspace',
    );
  });
  testWidgets('first run consumes host brand, Open label and privacy link', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final config = FaProductConfig.fromJson({
      'productId': 'ain',
      'displayName': 'AIN',
      'brandAssets': <String, Object?>{},
      'legalLinks': {'privacy': 'https://legal.ain.test/privacy'},
      'featureFlags': <Object?>[],
    });
    final launcher = _RecordingUrlLauncher();
    final previousLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

    await tester.pumpWidget(
      MyApp(
        productConfig: config,
        onboardingStore: OnboardingStore.inMemory(),
        themeController: ThemeController.inMemory(FahThemeMode.dark),
      ),
    );
    await tester.pump();

    expect(find.text('AIN'), findsOneWidget);
    expect(find.text('Fa'), findsNothing);
    expect(find.byType(ProductBrandMark), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('productBrandMonogram')),
      findsNWidgets(2),
    );

    await tester.tap(find.text('Privacy Policy'));
    await tester.pump();
    expect(launcher.launched, ['https://legal.ain.test/privacy']);
  });

  testWidgets('legacy setup consumes host brand and declares its asset', (
    tester,
  ) async {
    final config = FaProductConfig.fromJson({
      'productId': 'ain',
      'displayName': 'AIN',
      'brandAssets': {'icon192': 'icons/ain-192.png'},
      'featureFlags': <Object?>[],
    });
    await tester.pumpWidget(
      MyApp(
        productConfig: config,
        themeController: ThemeController.inMemory(FahThemeMode.dark),
      ),
    );
    await tester.pump();
    expect(find.text('Connect to AIN'), findsOneWidget);
    expect(find.text('Connect to Fa'), findsNothing);
    expect(find.byType(ProductBrandMark), findsOneWidget);
    expect(find.byKey(const ValueKey('productBrandImage')), findsOneWidget);
  });
}
