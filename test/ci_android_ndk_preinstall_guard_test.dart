// gh-1655 rework — the ci.yml `build-android` leg went red on a truncated
// NDK download: the app reads `ndkVersion = flutter.ndkVersion`, Gradle
// configuration found no NDK under $ANDROID_HOME/ndk/, and AGP ran its
// own sdkmanager auto-install — which has NO retry. The runner's network
// to dl.google.com cut the android-ndk-r28c-linux transfer at 33%, the
// partial bytes unzipped as "Error on ZipFile unknown archive", and the
// build died in configuration — one transfer fault, zero code faults,
// red leg + red aggregate Quality gate (the same head later built green
// on main when the same download came back whole: pure roulette, and the
// release/nightly lanes ride it bare as well). The flutter_gemma Android
// seed (gh-1468) established the cure for this exact failure class: move
// the download OUT of the unretryable mid-build path, pre-fetch it with
// bounded retry, and skip idempotently when the artifact is present.
//
// Deliberately YAML-level asserts (the ci_gemma_android_seed_guard_test.dart
// static pattern — a future bare Android build job must red here, not
// silently re-enter the download roulette):
//  AC1  the shared composite action exists, is composite, resolves the NDK
//       version from the pinned Flutter SDK's own gradle plugin source (the
//       exact value `flutter.ndkVersion` resolves to — no second pin to
//       drift), skips idempotently when the NDK is already installed,
//       installs through sdkmanager with bounded retry, and fails LOUDLY
//       (an ::error:: annotation, not a silent empty install) when the
//       version cannot be resolved,
//  AC2  every CI job that builds an Android APK/AAB pre-installs through
//       the action BEFORE its flutter/fastlane build step,
//  AC3  each workflow references the action exactly once per Android build
//       job (a count below means a build job lost the pre-install in a
//       refactor; above means a new site appeared that the map must
//       acknowledge),
//  AC4  the app still reads `ndkVersion = flutter.ndkVersion` — the
//       runtime resolution in the action can never skew from what AGP
//       requests; a literal pin on either side breaks that coupling and
//       must update this guard TOGETHER,
//  AC5  the extraction pattern in the action matches the gradle plugin
//       source of a locally resolvable Flutter SDK (env-dependent, named
//       skip) — the class of drift where Flutter restructures the plugin
//       file and the action's grep silently yields nothing.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const preinstallAction = './.github/actions/android-ndk-preinstall';
const actionPath = '.github/actions/android-ndk-preinstall/action.yml';
const appGradlePath = 'flutter_app/android/app/build.gradle.kts';

/// Every (workflow, job) that builds an Android APK/AAB for the app — the
/// same class enumeration the flutter_gemma seed guard pins (gh-1310: the
/// network-roulette fix must cover the whole class — the release path
/// (build-mobile.yml) and nightly (build-release matrix) hit the same
/// on-demand NDK download the PR leg did).
const androidBuildJobs = {
  '.github/workflows/ci.yml': ['build-android'],
  '.github/workflows/build-mobile.yml': ['build-android', 'build-android-apks'],
  '.github/workflows/nightly.yml': ['build-release'],
};

/// Run-step signatures that mean "this step compiles the Android app" —
/// the pre-install must run before any of them in the same job. `matrix.cmd`
/// covers nightly's build-release matrix, where the per-row command
/// (`cmd: flutter build apk --flavor store --release` on the android row)
/// is interpolated at job level.
final androidBuildSignatures = [
  RegExp(r'flutter build (apk|appbundle)\b'),
  RegExp(r'fastlane android build_release\b'),
  RegExp(r'matrix\.cmd'),
];

/// The action's extraction pattern for `flutter.ndkVersion` — the single
/// source of truth lives in the gradle plugin bundled with the SDK
/// flutter-action installed (FlutterExtension.kt, `val ndkVersion`).
/// Mirrored here so AC5 can prove it matches a real SDK.
const ndkVersionDeclPattern =
    'val ndkVersion: String = "[0-9]+\\.[0-9]+\\.[0-9]+"';

YamlList jobSteps(String workflowPath, String jobKey) {
  final root = loadYaml(read(workflowPath)) as YamlMap;
  final job = (root['jobs'] as YamlMap)[jobKey] as YamlMap;
  return job['steps'] as YamlList;
}

void main() {
  group('gh-1655 — Android builds pre-install the Flutter-pinned NDK', () {
    test('AC1: the pre-install action exists and is composite', () {
      final action = loadYaml(read(actionPath)) as YamlMap;
      expect(action['name'], isNotNull);
      final runs = action['runs'] as YamlMap;
      expect(runs['using'], 'composite');
      expect(runs['steps'], isA<YamlList>());
    });

    test('AC1: the action resolves flutter.ndkVersion from the SDK '
        'gradle plugin (single source of truth)', () {
      final body = read(actionPath);
      expect(
        body,
        contains('FlutterExtension.kt'),
        reason:
            'the NDK version must be resolved from the pinned Flutter '
            "SDK's gradle plugin source — the exact value "
            '`flutter.ndkVersion` (and thus AGP at configuration time) '
            'resolves to. A second, hand-pinned version drifts the moment '
            'the Flutter pin moves',
      );
      expect(
        body,
        contains(ndkVersionDeclPattern),
        reason:
            'the extraction must target the `val ndkVersion` declaration '
            'in FlutterExtension.kt — see AC5 for the real-SDK match',
      );
    });

    test('AC1: the action fails loudly when the version cannot be resolved',
        () {
      final body = read(actionPath);
      expect(
        body,
        contains('::error::'),
        reason:
            'an unresolvable version must fail the step with an ::error:: '
            'annotation — a silent empty version installs nothing and the '
            'build dies later in the very unretryable auto-install path '
            'this action exists to bypass',
      );
    });

    test('AC1: the action skips idempotently when the NDK is present', () {
      final body = read(actionPath);
      expect(
        body,
        contains('source.properties'),
        reason:
            'AGP marks a fully installed NDK with source.properties under '
            r'$ANDROID_HOME/ndk/<version> — the same lookup it performs at '
            'configuration time. Checking it makes the pre-install a '
            'no-op where the image already carries the NDK',
      );
    });

    test('AC1: the install is bounded-retried through sdkmanager', () {
      final body = read(actionPath);
      expect(
        body,
        contains('sdkmanager'),
        reason:
            'the install must go through sdkmanager — the same channel '
            "AGP's auto-install uses, so a pre-installed NDK lands exactly "
            r'where AGP looks ($ANDROID_HOME/ndk/<version>)',
      );
      expect(
        body,
        contains('--install'),
        reason: 'sdkmanager must run in install mode, not license-only',
      );
      expect(
        body,
        contains('for attempt in 1 2 3'),
        reason:
            'gh-1655: the mid-build auto-install has NO retry — one '
            "truncated download unzipped as 'Error on ZipFile unknown "
            "'archive' and the leg went red. The pre-install must bound "
            'the same roulette: three attempts, then fail loudly',
      );
      expect(
        body,
        contains('sleep 10'),
        reason:
            'a retry with no backoff re-races the same saturated network '
            'window (same posture as the macOS companion-dylibs step)',
      );
    });

    for (final entry in androidBuildJobs.entries) {
      final workflow = entry.key;
      for (final jobKey in entry.value) {
        test('AC2: $workflow $jobKey pre-installs the NDK before its '
            'Android build step', () {
          final steps = jobSteps(workflow, jobKey);
          final buildIndexes = <int>[];
          final preinstallIndexes = <int>[];
          for (var i = 0; i < steps.length; i++) {
            final step = steps[i] as YamlMap;
            if (step['uses'] == preinstallAction) preinstallIndexes.add(i);
            final run = step['run'];
            if (run is String &&
                androidBuildSignatures.any((re) => re.hasMatch(run))) {
              buildIndexes.add(i);
            }
          }
          expect(
            buildIndexes,
            isNotEmpty,
            reason:
                'precondition: $workflow $jobKey must contain an '
                'Android build step, otherwise this guard pins nothing',
          );
          expect(
            preinstallIndexes,
            isNotEmpty,
            reason:
                '$workflow $jobKey builds an Android APK/AAB without '
                'pre-installing the Flutter-pinned NDK — Gradle '
                'configuration then auto-installs it mid-build with no '
                'retry, and one truncated download reds the leg and the '
                'aggregate Quality gate (gh-1655). Add `uses: '
                '$preinstallAction` before the build step.',
          );
          for (final buildIndex in buildIndexes) {
            for (final preinstallIndex in preinstallIndexes) {
              expect(
                preinstallIndex,
                lessThan(buildIndex),
                reason:
                    '$workflow $jobKey runs the NDK pre-install AFTER its '
                    'Android build step — Gradle configuration resolves '
                    'the NDK at build time, so a post-build pre-install '
                    'never applies',
              );
            }
          }
        });
      }

      test('AC3: $workflow references the pre-install action exactly '
          '(${androidBuildJobs[workflow]!.length} job(s))', () {
        final root = loadYaml(read(workflow)) as YamlMap;
        final jobs = root['jobs'] as YamlMap;
        final usesCount = jobs.values
            .whereType<YamlMap>()
            .map((job) => job['steps'])
            .whereType<YamlList>()
            .expand((steps) => steps)
            .whereType<YamlMap>()
            .where((step) => step['uses'] == preinstallAction)
            .length;
        expect(
          usesCount,
          androidBuildJobs[workflow]!.length,
          reason:
              '$workflow must pre-install through `$preinstallAction` '
              'exactly ${androidBuildJobs[workflow]!.length} time(s) — a '
              'count BELOW means a build job lost the pre-install in a '
              'refactor; ABOVE means a new site appeared that the '
              'androidBuildJobs map must acknowledge (either way the '
              'guard, not the roulette, decides)',
        );
      });
    }

    test('AC4: the app still reads ndkVersion = flutter.ndkVersion', () {
      final gradle = read(appGradlePath);
      expect(
        gradle,
        contains('ndkVersion = flutter.ndkVersion'),
        reason:
            'the action resolves the NDK version from the SDK at runtime; '
            'the app must keep reading `flutter.ndkVersion` so AGP '
            'requests exactly the pre-installed version. A literal pin on '
            'either side breaks the coupling and must update this guard '
            'TOGETHER',
      );
    });

    test('AC5: the extraction pattern matches the locally resolvable '
        'Flutter SDK gradle plugin', () {
      // Same named-skip posture as the gemma seed guard's AC3: the check
      // is env-dependent — it pins the extraction against a real SDK when
      // one is present, and says so out loud when none is resolvable.
      final envRoot = Platform.environment['FLUTTER_ROOT'];
      final candidates = <String>[
        if (envRoot != null && envRoot.isNotEmpty) envRoot,
        ...Directory('/opt/hostedtoolcache/flutter')
            .listSync()
            .whereType<Directory>()
            .map((d) => d.path)
            .where((p) => File('$p/flutter/bin/flutter').existsSync()),
      ];
      if (candidates.isEmpty) {
        print(
          'SKIP (named): no locally resolvable Flutter SDK (set '
          'FLUTTER_ROOT) — the extraction pin is unprovable here',
        );
        return;
      }
      final extensionFile = File(
        '${candidates.first}/packages/flutter_tools/gradle/src/main/'
        'kotlin/FlutterExtension.kt',
      );
      if (!extensionFile.existsSync()) {
        print(
          'SKIP (named): ${extensionFile.path} missing — the Flutter '
          'gradle plugin layout changed; re-derive the extraction pattern '
          'in $actionPath and this guard',
        );
        return;
      }
      final source = extensionFile.readAsStringSync();
      final match = RegExp(ndkVersionDeclPattern).firstMatch(source);
      expect(
        match,
        isNotNull,
        reason:
            'the action extracts the NDK version with '
            '`$ndkVersionDeclPattern` but the resolvable SDK '
            "(${candidates.first}) no longer matches — Flutter restructured "
            'the plugin source and the action would fail loudly '
            '(AC1) instead of pre-installing. Re-derive the pattern in '
            '$actionPath and this guard TOGETHER',
      );
      final version =
          RegExp(r'\d+\.\d+\.\d+').firstMatch(match!.group(0)!)!.group(0);
      expect(
        version,
        isNotEmpty,
        reason: 'the extracted NDK version must be a semver-like triple',
      );
      print('AC5: extraction matches — flutter.ndkVersion = $version');
    });
  });
}
