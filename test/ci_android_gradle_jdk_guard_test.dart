// gh-2153 — the daily-publish play leg went red on all three Android
// release builds (Build Android AAB + Build Android APK store/god) with
// `Execution failed for task ':file_selector_android:lintVitalAnalyzeRelease'
// ... NoSuchMethodError: 'java.lang.Object java.util.List.removeLast()'`.
//
// Root cause: #2112 (57c5441) bumped com.android.application 9.0.1 → 9.3.1
// (+ Gradle 9.5.0) but left the workflows' actions/setup-java at
// java-version '17'. AGP 9.3.1's bundled lint rides an IntelliJ platform
// whose javadoc parser is compiled against the JDK 21 class library —
// `List.removeLast()` exists only since JDK 21 (JEP 431, Sequenced
// Collections). On a JDK 17 daemon, the first javadoc lint's
// CommentDetector parses in a plugin module (file_selector_android's
// FileUtils.java) reaches JavaDocParser.parseDataItem and throws
// NoSuchMethodError → lintVitalAnalyzeRelease fails → every
// `flutter build appbundle/apk --release` exits 1. Debug builds never run
// lintVital*, which is why ci.yml's debug-only android job stayed green.
//
// Fix shape: run the Android gradle builds on JDK ≥ 21 (the AGP 9.3 lint
// minimum). The daemon JDK is independent of the bytecode target —
// compileOptions/jvmTarget stay VERSION_17.
//
// Deliberately YAML-level asserts (the ci_mobile_sdk_pin_guard_test.dart /
// ci_pub_get_retry_guard_test.dart static pattern):
//  AC1  every job that runs a release Android gradle build (direct
//       `flutter build apk|appbundle --release`, the `fastlane android
//       build_release` lane that wraps it, or a release android matrix
//       row) must set up JDK ≥ 21 — AGP 9.3's lint cannot run on the
//       older daemon (gh-2153),
//  AC2  the classified-lane census is pinned — build-mobile.yml classifies
//       exactly {build-android, build-android-apks} and nightly.yml
//       exactly {build-release}; a refactor that adds a release android
//       lane on an old JDK reds here, and one that DROPS the fastlane
//       build_release / matrix-cmd invocations must update this guard in
//       the same PR,
//  AC3  ci.yml's android job must stay DEBUG-only (`flutter build apk
//       --debug` runs no lintVital*) — the exemption is intentional and
//       visible: the moment that job gains a release build, AC1/AC2 red
//       until its JDK moves to ≥ 21 too.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The minimum daemon JDK the AGP 9.3.x bundled lint runs on: its javadoc
/// parser calls java.util.List.removeLast(), a JDK 21-only method (JEP
/// 431). Bump together with AGP only if the new lint drops the 21 floor.
const minJdkMajor = 21;

const workflows = <String>[
  '.github/workflows/build-mobile.yml',
  '.github/workflows/nightly.yml',
  '.github/workflows/ci.yml',
];

/// Matches a step script that invokes a RELEASE Android gradle build,
/// directly (`flutter build apk|appbundle ... --release`) or through the
/// fastlane lane that wraps it (`fastlane android build_release` — the
/// gradle invocation lives in flutter_app/fastlane/Fastfile, so the
/// workflow-level scan must match the lane call).
final releaseGradleRe = RegExp(
  r'flutter build (apk|appbundle)\b[^\n]*--release'
  r'|fastlane android build_release\b'
  r'|\./gradlew\b[^\n]*\b(assemble|bundle)\w*[Rr]elease\b',
);

class JobScan {
  final String workflow;
  final String job;
  final Set<int> jdkMajors;
  final bool releaseAndroidGradle;
  JobScan(this.workflow, this.job, this.jdkMajors, this.releaseAndroidGradle);
}

int? jdkMajorOf(dynamic version) {
  if (version == null) return null;
  final m = RegExp(r'\d+').firstMatch(version.toString());
  return m == null ? null : int.parse(m.group(0)!);
}

/// Classify every job of a workflow: which JDKs its setup-java steps pin
/// and whether any step (or android matrix row cmd) runs a release
/// Android gradle build.
List<JobScan> scanWorkflow(String path) {
  final yaml = loadYaml(File(path).readAsStringSync()) as YamlMap;
  final scans = <JobScan>[];
  for (final entry in (yaml['jobs'] as Map).entries) {
    final job = entry.key as String;
    final body = entry.value as Map;
    final steps = (body['steps'] as List? ?? const []).cast<Map>();
    final majors = <int>{};
    var releaseAndroidGradle = false;
    for (final step in steps) {
      if ((step['uses'] as String? ?? '').startsWith('actions/setup-java@')) {
        final major = jdkMajorOf((step['with'] as Map? ?? const {})['java-version']);
        if (major != null) majors.add(major);
      }
      final run = step['run']?.toString() ?? '';
      if (releaseGradleRe.hasMatch(run)) releaseAndroidGradle = true;
    }
    // Matrix rows: the script lives in `matrix.include[].cmd` and steps
    // reference it via ${{ matrix.cmd }} — nightly build-release.
    final include = (((body['strategy'] as Map? ?? const {})['matrix']
            as Map? ?? const {})['include'] as List? ?? const [])
        .cast<Map>();
    for (final row in include) {
      final isAndroid = row['target']?.toString() == 'android';
      final cmd = row['cmd']?.toString() ?? '';
      if (isAndroid && releaseGradleRe.hasMatch(cmd)) {
        releaseAndroidGradle = true;
      }
    }
    scans.add(JobScan(path, job, majors, releaseAndroidGradle));
  }
  return scans;
}

void main() {
  final allScans = [for (final w in workflows) ...scanWorkflow(w)];

  test(
    'AC1: every release Android gradle lane sets up JDK >= $minJdkMajor '
    '(gh-2153: AGP 9.3.1 lint — List.removeLast() — crashes lintVital on '
    'the JDK 17 daemon)',
    () {
      final releaseLanes =
          allScans.where((s) => s.releaseAndroidGradle).toList();
      expect(releaseLanes, isNotEmpty,
          reason: 'the guard classified no release Android gradle lane — '
              'the detector regexes or the workflows changed; update this '
              'guard in the same PR');
      for (final lane in releaseLanes) {
        expect(lane.jdkMajors, isNotEmpty,
            reason: '${lane.workflow} job `${lane.job}` runs a release '
                'Android gradle build with no actions/setup-java step — '
                'the daemon JDK is whatever the runner image ships');
        for (final major in lane.jdkMajors) {
          expect(major, greaterThanOrEqualTo(minJdkMajor),
              reason: '${lane.workflow} job `${lane.job}` runs a release '
                  'Android gradle build (lintVital*) on JDK $major — AGP '
                  '9.3.x bundled lint is compiled for JDK 21 '
                  '(NoSuchMethodError List.removeLast(), gh-2153); bump '
                  'the setup-java java-version');
        }
      }
    },
  );

  test(
    'AC2: the classified release-lane census is pinned',
    () {
      final byWorkflow = <String, Set<String>>{};
      for (final s in allScans.where((s) => s.releaseAndroidGradle)) {
        byWorkflow.putIfAbsent(s.workflow, () => {}).add(s.job);
      }
      expect(byWorkflow, {
        '.github/workflows/build-mobile.yml': {
          'build-android', // Build Android AAB — fastlane android build_release
          'build-android-apks', // Build Android APK store/god — flutter build apk --release
        },
        '.github/workflows/nightly.yml': {
          'build-release', // android matrix row — flutter build apk --flavor store --release
        },
      }, reason:
          'the release Android gradle lane set changed — a new lane on an '
          'old JDK re-opens the gh-2153 crash class, a dropped invocation '
          'silently lost its JDK pin; update this guard in the same PR');
    },
  );

  test(
    'AC3: ci.yml stays debug-only on android — no release gradle lane may '
    'appear there without JDK >= $minJdkMajor',
    () {
      final ciJobs = scanWorkflow('.github/workflows/ci.yml')
          .where((s) => s.releaseAndroidGradle)
          .map((s) => s.job)
          .toSet();
      expect(ciJobs, isEmpty,
          reason: 'ci.yml gained a release Android gradle build — debug '
              'variants never run lintVital* (that is why the JDK 17 '
              'debug leg stayed green through the gh-2153 crash), but a '
              'release build there needs JDK >= $minJdkMajor first: move '
              'the job to JDK $minJdkMajor and record it in AC2');
    },
  );
}
