// gh-2126 — the daily-publish play leg went red on the build-mobile.yml
// Android jobs (Build Android AAB + Build Android APK store/god) at the
// shared `flutter pub get --enforce-lockfile` step with
// "Unable to satisfy `pubspec.yaml` using `pubspec.lock`": the four hosted
// jobs installed Flutter with `channel: stable` and NO flutter-version
// pin, so the stable float 3.47.7 → 3.50.0 (released 2026-11-09) landed
// in the leg. 3.50.0's SDK-hosted flutter_test exactly pins test_api
// 0.7.14, while the committed flutter_app/pubspec.lock (gh-1265: CI
// resolves against the COMMITTED lockfile) pins test_api 0.7.12 — the
// flutter_test@3.47.7 pin. A deterministic skew cannot retry, so the
// composite action fail-fasted every Android leg (PR #1268 review thread
// 3). The workflow's own self-hosted iOS lane already pins 3.47.7 exactly
// (gh-1826, #1431 discipline) and gh-2120 pinned office-addin-suite to
// 3.47.7 for the identical enforce-lockfile float — the four hosted
// subosito/flutter-action setups were the remaining floaters in a
// workflow whose lanes all resolve ONE committed lockfile.
//
// Deliberately YAML-level asserts (the store_automation_guard /
// nightly_desktop_leg_guard static pattern):
//  AC1  every hosted flutter-action setup pins an EXACT 3.47.x patch —
//       no absent pin (a float on `channel: stable`) and no wildcard
//       `3.47.x` (#1431: a wildcard re-resolves a freshly released patch
//       whose flutter_test/test_api pins the lockfile does not carry),
//  AC2  the hosted pins agree with the workflow's own self-hosted
//       setup-flutter-selfhosted pin — one workflow, one SDK; bumping one
//       side without the other (and without the regenerated lockfile)
//       reds here,
//  AC3  the four known hosted setups are all still accounted for
//       (build-android, submit-android, build-android-apks,
//       test-android-emulator) — a refactor that adds or drops one must
//       update this guard in the same PR.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-mobile.yml';
const flutterActionPrefix = 'subosito/flutter-action@';
const selfHostedAction = './.github/actions/setup-flutter-selfhosted';

/// The exact patch the committed flutter_app/pubspec.lock is a resolution
/// of (flutter_test@3.47.7 → test_api 0.7.12) — also the self-hosted iOS
/// lane pin (gh-1826) and the office-addin-suite pin (gh-2120). Bump ONLY
/// together with a regenerated lockfile, in the same PR.
const expectedSdkLine = '3.47.7';

YamlMap loadWorkflow() =>
    loadYaml(File(workflowPath).readAsStringSync()) as YamlMap;

/// (job, step) for every step that installs Flutter on a GitHub-hosted
/// runner through subosito/flutter-action.
List<MapEntry<String, Map>> hostedFlutterSetups() {
  final yaml = loadWorkflow();
  final found = <MapEntry<String, Map>>[];
  for (final entry in (yaml['jobs'] as Map).entries) {
    final steps = (entry.value as Map)['steps'] as List? ?? const [];
    for (final step in steps) {
      final uses = (step as Map)['uses'];
      if (uses is String && uses.startsWith(flutterActionPrefix)) {
        found.add(MapEntry(entry.key as String, step));
      }
    }
  }
  return found;
}

/// The flutter-version pin of the workflow's self-hosted lane
/// (./.github/actions/setup-flutter-selfhosted).
Set<String> selfHostedPins() {
  final yaml = loadWorkflow();
  final pins = <String>{};
  for (final entry in (yaml['jobs'] as Map).entries) {
    final steps = (entry.value as Map)['steps'] as List? ?? const [];
    for (final step in steps) {
      final uses = (step as Map)['uses'];
      if (uses is String && uses == selfHostedAction) {
        // `step` is already promoted to `Map` by the cast above — a second
      // cast here trips unnecessary_cast under --fatal-infos.
      final withBlock = step['with'] as Map? ?? const {};
        final pin = withBlock['flutter-version']?.toString();
        expect(pin, isNotNull,
            reason:
                'the self-hosted lane must pin flutter-version explicitly '
                '(gh-1826) — an unpinned bootstrap floats stable and '
                're-opens the gh-2126 skew class');
        pins.add(pin!);
      }
    }
  }
  return pins;
}

void main() {
  test(
    'AC1: every hosted flutter-action setup pins an exact 3.47.x patch '
    '(gh-2126: the absent pin floated stable to 3.50.0, whose '
    'flutter_test test_api 0.7.14 deterministically skew-failed the '
    'committed lockfile under --enforce-lockfile)',
    () {
      final setups = hostedFlutterSetups();
      expect(setups, isNotEmpty,
          reason:
              'build-mobile.yml must still install Flutter on the hosted '
              'Android legs — the guard scanned nothing');
      for (final setup in setups) {
        final withBlock = setup.value['with'] as Map? ?? const {};
        final pin = withBlock['flutter-version']?.toString();
        expect(pin, isNotNull,
            reason: 'job `${setup.key}` installs Flutter with no '
                'flutter-version pin — it floats on `channel: stable`, '
                'and the next stable release deterministically skew-fails '
                'flutter_app/pubspec.lock under --enforce-lockfile '
                '(gh-2126; gh-2120 pinned office-addin-suite for the '
                'identical float)');
        expect(pin, matches(RegExp(r'^3\.47\.\d+$')),
            reason: 'job `${setup.key}` pins `$pin` — the pin must be an '
                'EXACT 3.47.x patch (#1431 discipline, gh-1826): a '
                'wildcard or a foreign line resolves a flutter_test whose '
                'exact test_api pin the committed lockfile does not '
                'carry');
      }
    },
  );

  test(
    'AC2: the hosted pins match the self-hosted lane pin — one workflow '
    'resolving one committed lockfile must run one SDK',
    () {
      final pins = selfHostedPins();
      expect(pins, {expectedSdkLine},
          reason: 'the self-hosted iOS lane pin drifted from '
              '$expectedSdkLine — bump it ONLY with the regenerated '
              'flutter_app/pubspec.lock and this guard in the same PR '
              '(gh-1826: "Bump the pin consciously, matching the desktop '
              'lane")');
      for (final setup in hostedFlutterSetups()) {
        final withBlock = setup.value['with'] as Map? ?? const {};
        final pin = withBlock['flutter-version']?.toString();
        expect(pin, expectedSdkLine,
            reason: 'hosted job `${setup.key}` pins `$pin` while the '
                'self-hosted lane pins $expectedSdkLine — the two lanes '
                'resolve the same flutter_app/pubspec.lock and must ride '
                'the same SDK (gh-2126)');
      }
    },
  );

  test(
    'AC3: the four known hosted flutter-action setups are all still '
    'accounted for',
    () {
      final jobs = hostedFlutterSetups().map((e) => e.key).toSet();
      expect(jobs, {
        'build-android', // Build Android AAB
        'submit-android', // Play upload (fastlane/bundletool host)
        'build-android-apks', // Build Android APK store/god matrix
        'test-android-emulator', // Android emulator ITs
      }, reason:
          'the hosted flutter-action site set changed — a dropped setup '
          'silently lost its SDK pin, an added one would float; update '
          'this guard in the same PR (gh-2126)');
    },
  );
}
