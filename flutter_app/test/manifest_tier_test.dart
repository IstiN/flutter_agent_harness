// UT-manifest-1 (issue #622): static tier audit for the Android flavor
// split. Pure Dart — plain File reads + RegExp, no flutter_test binding, no
// channels. Run from flutter_app/: `flutter test test/manifest_tier_test.dart`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mainManifest = File('android/app/src/main/AndroidManifest.xml');
  final godManifest = File('android/app/src/god/AndroidManifest.xml');
  final gradle = File('android/app/build.gradle.kts');
  final godA11yConfig =
      File('android/app/src/god/res/xml/accessibility_service_config.xml');
  final godStrings = File('android/app/src/god/res/values/strings.xml');
  String read(File file, String label) {
    if (!file.existsSync()) {
      throw StateError(
        '$label missing at ${file.path} — run this test from flutter_app/.',
      );
    }
    return file.readAsStringSync();
  }

  /// The audit scans real declarations, not prose — comments may name the
  /// banned symbols when explaining their absence.
  String declarations(String xml) =>
      xml.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  final mainXml = declarations(read(mainManifest, 'store (main) manifest'));
  final godXml = declarations(read(godManifest, 'god manifest'));
  final gradleSrc = read(gradle, 'build.gradle.kts');

  group('store (main) manifest — Play-safe baseline', () {
    for (final banned in const [
      'QUERY_ALL_PACKAGES',
      'FOREGROUND_SERVICE_MEDIA_PROJECTION',
      'BIND_ACCESSIBILITY_SERVICE',
      'android.accessibilityservice',
      'SYSTEM_ALERT_WINDOW',
    ]) {
      test('does not contain $banned', () {
        expect(
          mainXml.contains(banned),
          isFalse,
          reason: 'store APK surface must stay free of "$banned" — '
              'it lives only in android/app/src/god/AndroidManifest.xml '
              '(UT-manifest-1 diff: main manifest LEAKS the god symbol).',
        );
      });
    }

    test('declares the LAUNCHER <queries> intent for store-visible app lists', () {
      final hasLauncherQuery = RegExp(
        r'<queries>[\s\S]*android\.intent\.action\.MAIN[\s\S]*'
        r'android\.intent\.category\.LAUNCHER[\s\S]*</queries>',
      ).hasMatch(mainXml);
      expect(
        hasLauncherQuery,
        isTrue,
        reason: 'without the MAIN/LAUNCHER <queries> intent the store flavor '
            'cannot enumerate launcher apps without QUERY_ALL_PACKAGES.',
      );
    });
  });

  group('god manifest — automation surface', () {
    for (final required in const [
      'QUERY_ALL_PACKAGES',
      'android.permission.FOREGROUND_SERVICE"',
      'FOREGROUND_SERVICE_MEDIA_PROJECTION',
      'BIND_ACCESSIBILITY_SERVICE',
      '.mobile.MobileAccessibilityService',
      'android.accessibilityservice.AccessibilityService',
      'accessibility_service_config',
      '.mobile.MobileProjectionService',
      'mediaProjection',
    ]) {
      test('declares $required', () {
        expect(
          godXml.contains(required),
          isTrue,
          reason: 'god manifest is missing "$required" — the sideload APK '
              'would silently lack the automation surface (UT-manifest-1 '
              'diff: god manifest MISSING a required symbol).',
        );
      });
    }
  });

  group('accessibility service resources (god only)', () {
    test('config declares content retrieval + gestures', () {
      final config = read(godA11yConfig, 'accessibility_service_config.xml');
      expect(config.contains('android:canRetrieveWindowContent="true"'), isTrue,
          reason: 'dumpHierarchy needs window content.');
      expect(config.contains('android:canPerformGestures="true"'), isTrue,
          reason: 'coordinate tap/swipe needs gesture dispatch.');
      expect(config.contains('@string/accessibility_service_description'),
          isTrue, reason: 'Play/service description hook.');
    });

    test('description string exists under god res/values', () {
      read(godStrings, 'god strings.xml');
    });

    test('main source set never touches the accessibility framework', () {
      final sources = Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'));
      for (final file in sources) {
        final src = file.readAsStringSync();
        expect(
          src.contains('android.accessibilityservice') ||
              RegExp(r':\s*AccessibilityService\b').hasMatch(src),
          isFalse,
          reason: '${file.path} references the accessibility framework — '
              'store sources must carry zero accessibility symbols.',
        );
      }
    });
  });

  group('build.gradle.kts flavor tiers', () {
    test('declares the "tier" dimension with store + god flavors', () {
      expect(gradleSrc.contains('flavorDimensions += "tier"'), isTrue,
          reason: 'flavor dimension "tier" missing.');
      expect(gradleSrc.contains('create("store")'), isTrue,
          reason: 'store flavor missing.');
      expect(gradleSrc.contains('create("god")'), isTrue,
          reason: 'god flavor missing.');
    });

    test('store applicationId stays exactly dev.fa1.app', () {
      final match = RegExp(
        r'create\("store"\)\s*\{[^}]*applicationId\s*=\s*"([^"]+)"',
      ).firstMatch(gradleSrc);
      expect(match, isNotNull, reason: 'store flavor has no applicationId.');
      expect(
        match!.group(1),
        'dev.fa1.app',
        reason: 'the applicationId is IMMUTABLE after the first Play upload '
            '(issue #289) — store must stay exactly "dev.fa1.app".',
      );
    });

    test('god applicationId ends with .god', () {
      final match = RegExp(
        r'create\("god"\)\s*\{[^}]*applicationId\s*=\s*"([^"]+)"',
      ).firstMatch(gradleSrc);
      expect(match, isNotNull, reason: 'god flavor has no applicationId.');
      final id = match!.group(1)!;
      expect(
        id.endsWith('.god'),
        isTrue,
        reason: 'god applicationId "$id" must end with ".god" so the '
            'sideload APK installs beside the store app.',
      );
    });
  });
}
