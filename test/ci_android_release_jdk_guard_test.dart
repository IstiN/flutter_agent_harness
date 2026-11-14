// gh-2176 — the daily-publish `play` leg (build-mobile.yml) red'd on
// 2026-11-12/13/14: every Android RELEASE build died with
// `Gradle task bundleStoreRelease/assemble*Release failed with exit code 1`
// and the gradle failure was
//   Execution failed for task ':file_selector_android:lintVitalAnalyzeRelease'
//   > Unexpected failure during lint analysis of FileUtils.java
//     Message: 'java.lang.Object java.util.List.removeLast()'
//     The crash seems to involve the detector `com.android.tools.lint.checks.CommentDetector`.
// `java.util.List.removeLast()` is the JDK 21 `SequencedCollection` API:
// AGP 9.3.1's bundled lint (the #2112 3.50-train bump, 9.0.1 → 9.3.1)
// embeds an IntelliJ-platform Java parser compiled against it, and the
// workflow ran Gradle on temurin **17** — where the method does not
// exist. The call throws NoSuchMethodError, lint's CommentDetector marks
// the analysis failed, and AGP fails the whole release build. `lintVital*`
// runs for RELEASE variants only, which is exactly why the PR-gate
// ci.yml android leg (`flutter build apk --debug`) stayed green on the
// same tree while every daily release lane red'd.
//
// The cure: run the release lanes on JDK 21 (the runtime lint's parser
// requires), mirroring the gh-1757 style: a reviewed JDK literal
// cross-checked against the pinned AGP via a map — an AGP bump fails this
// guard until the JDK pin is re-derived TOGETHER (AGP's lint JDK floor is
// not resolvable from disk before Gradle runs).
//
// Deliberately YAML-level asserts (the static-pattern style of
// ci_android_ndk_preinstall_guard_test.dart):
//  AC1  every Android release build job in build-mobile.yml (build-android
//       AAB, build-android-apks) pins the AGP-derived JDK,
//  AC2  nightly.yml's build-release android row pins the same JDK (same
//       release lint, same crash waiting for the next nightly),
//  AC3  the JDK pin is a reviewed literal coupled to the pinned AGP in
//       flutter_app/android/settings.gradle.kts — a version missing from
//       the map fails here until re-derived,
//  AC4  fleet coherence: every OTHER setup-java in build-mobile.yml
//       (submit-android, test-android-emulator) pins the same JDK — the
//       mobile lane never runs mixed JDKs, so a debug/IT job cannot drift
//       back onto a version the release lane cannot lint under.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const mobileWorkflowPath = '.github/workflows/build-mobile.yml';
const nightlyWorkflowPath = '.github/workflows/nightly.yml';
const appSettingsGradlePath = 'flutter_app/android/settings.gradle.kts';

/// The pinned AGP in flutter_app/android/settings.gradle.kts → the JDK the
/// workflow must run Gradle on. AGP 9.0.1's lint tolerated JDK 17; AGP
/// 9.3.1's bundled lint (IntelliJ-platform JavaDocParser) calls the JDK-21
/// `List.removeLast()` — a release build under 17 crashes exactly as
/// gh-2176 witnessed. A NEW AGP version is an UNKNOWN: the map has no key,
/// this guard fails, and the JDK floor must be re-derived before the pin
/// merges (same coupling discipline as agpVersionToDefaultCmake in
/// ci_android_ndk_preinstall_guard_test.dart).
const agpVersionToGradleJdk = <String, String>{
  '9.0.1': '17',
  '9.3.1': '21', // the 3.50-train pin: lint's embedded parser needs 21
};

/// Every (workflow, job) that builds an Android APK/AAB in RELEASE — the
/// lanes `lintVital*` actually runs on (debug builds never run it, so the
/// ci.yml PR-gate debug leg is deliberately absent here).
const androidReleaseBuildJobs = {
  mobileWorkflowPath: ['build-android', 'build-android-apks'],
  nightlyWorkflowPath: ['build-release'],
};

String? pinnedAgpVersion() {
  final text = read(appSettingsGradlePath);
  final match =
      RegExp(r'id\("com\.android\.application"\) version "([^"]+)"')
          .firstMatch(text);
  return match?.group(1);
}

YamlMap? setupJavaStep(YamlMap job) {
  final steps = job['steps'] as YamlList?;
  if (steps == null) return null;
  for (final step in steps) {
    final map = step as YamlMap;
    final uses = map['uses'];
    if (uses is String && uses.startsWith('actions/setup-java')) return map;
  }
  return null;
}

String? javaVersionOf(YamlMap step) {
  final with_ = step['with'];
  if (with_ is! YamlMap) return null;
  final version = with_['java-version'];
  return version?.toString();
}

void main() {
  test('gh-2176: the pinned AGP has a reviewed Gradle JDK entry', () {
    final agp = pinnedAgpVersion();
    expect(agp, isNotNull,
        reason: 'cannot resolve the com.android.application pin in '
            '$appSettingsGradlePath');
    expect(
      agpVersionToGradleJdk.keys,
      contains(agp),
      reason: 'AGP $agp is not mapped to a reviewed Gradle JDK — derive the '
          'lint/IntelliJ JDK floor for it and add it to agpVersionToGradleJdk '
          'TOGETHER with the settings.gradle.kts bump (gh-2176 discipline)',
    );
  });

  test('gh-2176 AC1/AC2: android release build jobs pin the AGP-derived JDK',
      () {
    final agp = pinnedAgpVersion()!;
    final expectedJdk = agpVersionToGradleJdk[agp]!;
    androidReleaseBuildJobs.forEach((workflowPath, jobKeys) {
      final root = loadYaml(read(workflowPath)) as YamlMap;
      final jobs = root['jobs'] as YamlMap;
      for (final jobKey in jobKeys) {
        final job = jobs[jobKey] as YamlMap?;
        expect(job, isNotNull,
            reason: '$workflowPath lost the `$jobKey` job — update '
                'androidReleaseBuildJobs with the rename');
        final step = setupJavaStep(job!);
        expect(step, isNotNull,
            reason: '$workflowPath:$jobKey builds Android in release but has '
                'no actions/setup-java step');
        final version = javaVersionOf(step!);
        expect(version, expectedJdk,
            reason: '$workflowPath:$jobKey runs Gradle on JDK $version while '
                'the pinned AGP $agp needs JDK $expectedJdk for its bundled '
                'lint (gh-2176: JDK 17 reds every Android release build with '
                "NoSuchMethodError 'java.util.List.removeLast()' in "
                'lintVitalAnalyzeRelease)');
      }
    });
  });

  test('gh-2176 AC4: build-mobile.yml runs one JDK across its whole fleet',
      () {
    final root = loadYaml(read(mobileWorkflowPath)) as YamlMap;
    final jobs = root['jobs'] as YamlMap;
    final versions = <String, List<String>>{};
    jobs.forEach((jobKey, jobValue) {
      final step = setupJavaStep(jobValue as YamlMap);
      if (step == null) return;
      final version = javaVersionOf(step);
      versions.putIfAbsent(version ?? '<missing>', () => []).add(jobKey);
    });
    expect(versions.keys, hasLength(1),
        reason: 'build-mobile.yml Android jobs run mixed JDKs: $versions — '
            'the mobile lane must stay on one Gradle JDK (gh-2176)');
    expect(versions.keys.first, agpVersionToGradleJdk[pinnedAgpVersion()!],
        reason: 'the fleet JDK must match the AGP-derived pin');
  });
}
