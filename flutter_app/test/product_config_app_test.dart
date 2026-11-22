import 'dart:convert';
import 'dart:io';

import '../../scripts/build_product_web.dart';

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
  testWidgets('staged runtime profile reaches the published brand image', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('fa-brand-e2e-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final assets = Directory('${temp.path}/assets')..createSync();
    for (final (name, size) in [
      ('external-192.png', 192),
      ('external-512.png', 512),
      ('favicon.png', 64),
      ('splash.png', 128),
    ]) {
      File('${assets.path}/$name').writeAsBytesSync(_png(size));
    }
    final profile = File('${temp.path}/product.json')
      ..writeAsStringSync(
        jsonEncode({
          'productId': 'ain',
          'displayName': 'AIN',
          'brandAssets': {
            'icon192': 'external-192.png',
            'icon512': 'external-512.png',
            'favicon': 'favicon.png',
            'splash': 'splash.png',
          },
          'featureFlags': <Object?>[],
        }),
      );
    final output = '${temp.path}/web';
    await tester.runAsync(
      () => buildProductWeb(
        profilePath: profile.path,
        assetsPath: assets.path,
        outputPath: output,
        builder: (path) async => _fixtureShell(Directory(path)),
      ),
    );
    final script = File('$output/product_config.js').readAsStringSync();
    final encoded = RegExp(
      r'window.__faProductProfile = (.*);',
    ).firstMatch(script)!.group(1)!;
    final runtime = FaProductConfig.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );

    expect(runtime.brandAssets['icon192'], 'icons/Icon-192.png');
    expect(
      File('$output/${runtime.brandAssets['icon192']}').existsSync(),
      isTrue,
    );
    expect(File('$output/external-192.png').existsSync(), isFalse);

    await tester.pumpWidget(
      MaterialApp(home: ProductBrandMark(productConfig: runtime)),
    );
    final image = tester.widget<Image>(
      find.byKey(const ValueKey('productBrandImage')),
    );
    expect((image.image as AssetImage).assetName, 'icons/Icon-192.png');
  });

  testWidgets('branded first run without privacy metadata hides the Fa link', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final config = FaProductConfig.fromJson({
      'productId': 'ain',
      'displayName': 'AIN',
      'featureFlags': <Object?>[],
    });
    await tester.pumpWidget(
      MyApp(
        productConfig: config,
        onboardingStore: OnboardingStore.inMemory(),
        themeController: ThemeController.inMemory(FahThemeMode.dark),
      ),
    );
    await tester.pump();
    expect(find.text('AIN'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsNothing);
  });
}

List<int> _png(int size) {
  final bytes = List<int>.filled(45, 0);
  bytes.setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.setRange(8, 12, [0, 0, 0, 13]);
  bytes.setRange(12, 16, ascii.encode('IHDR'));
  bytes.setRange(16, 20, [size >> 24, size >> 16, size >> 8, size & 255]);
  bytes.setRange(20, 24, [size >> 24, size >> 16, size >> 8, size & 255]);
  bytes[24] = 8;
  bytes[25] = 6;
  bytes.setRange(37, 41, ascii.encode('IEND'));
  return bytes;
}

Directory _fixtureShell(Directory directory) {
  directory.createSync(recursive: true);
  Directory('${directory.path}/icons').createSync();
  File('${directory.path}/index.html').writeAsStringSync(
    '<!DOCTYPE html><html><head><title>Fa</title></head><body>'
    '<script src="fs_store.js"></script></body></html>',
  );
  File('${directory.path}/manifest.json').writeAsStringSync('{"name":"Fa"}');
  File(
    '${directory.path}/flutter_service_worker.js',
  ).writeAsStringSync("var cacheName = 'flutter-app';");
  return directory;
}
