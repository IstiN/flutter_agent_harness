// gh-1814 — lane guard for the macOS desktop DMG legs (build-macos.yml).
// History: gh-180 moved the legs to the pure CocoaPods lane with
// FLUTTER_SWIFT_PACKAGE_MANAGER=0 after a silently-skipped generated-package
// floor bump reded run 39905803673. Upstream then REMOVED the disable knob
// between 3.47.4 and 3.47.7 (flutter/flutter#193978 — the exact day the
// gh-180 comment predicted): on the pinned-3.47.7 runners the --config-only
// pass adds SwiftPM integration regardless (runs 39991663029 /
// 40022900373), so the env pin is a NO-OP and the gh-180 gate forbidding
// SwiftPM state became the failure itself. The #1813 escape (pin 3.47.4)
// is operationally dead — the runners' ~60kB/s link cannot fetch that SDK
// (run 40034163885). Owner ruling (gh-1814): the minimum macOS version may
// be raised — the lane ADOPTS SwiftPM with every floor ≥ 14.0.
//
// The floor audit (gh-1814 step 1): the original gh-180 sub-14.0 target was
// the generated FlutterGeneratedPluginSwiftPackage at its 12.0 tool default
// with a silently-skipped showBuildSettings bump. On 3.47.7 the bump works
// (failing-run diagnostics: `generated floor: 14.0`), and the committed
// floors are already at the app minimum — Runner pbxproj 3×14.0, Podfile
// platform 14.0, vendored flutter_inappwebview_macos podspec 14.0 (its
// Package.swift stays deleted: the plugin rides the CocoaPods half of the
// hybrid lane, pinned in Podfile.lock). Nothing needed raising; what
// changed is the CONTRACT: scripts/assert_macos_min_platform.sh now
// ASSERTS the SPM lane (SwiftPM state expected, floors audited) instead of
// forbidding it.
//
// Static workflow-shape assert (the "workflow-shape test never-again"
// pattern of ci_macos_signing_window_guard_test.dart /
// workflow_selfhosted_legs_test.dart):
//
//   AC1  the build-macos job carries NO FLUTTER_SWIFT_PACKAGE_MANAGER pin —
//        the knob is removed in 3.47.7 (no-op since flutter/flutter#193978);
//        keeping it would advertise a lane decision ("pure CocoaPods") the
//        workflow no longer makes;
//   AC1b the Setup Flutter step pins 3.47.7 — the #1813 3.47.4 revert
//        (gh-1814 step 4): 3.47.4 is unfetchable on the runners and the
//        SPM lane removes the only reason for it;
//   AC2  the Build macOS release step runs `flutter build macos
//        --config-only` + scripts/assert_macos_min_platform.sh 14.0 BEFORE
//        the real `flutter build macos --release` — the gate must see the
//        post-config state and fail before any compile minute is spent;
//   AC3  the committed pbxproj keeps the Runner-target floor shape the
//        gate asserts (3×14.0, nothing else) and stays free of the
//        FlutterGeneratedPluginSwiftPackage marker — the SPM integration
//        is added by the tool at build time, never committed.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos';
const buildStepPrefix = 'Build macOS release (';
const pinnedFlutterVersion = '3.47.7';
const deadSwiftPmKnob = 'FLUTTER_SWIFT_PACKAGE_MANAGER';

String read(String path) => File(path).readAsStringSync();

/// The COMMITTED content of a tracked file. A local SwiftPM-enabled flutter
/// build migrates the checkout IN PLACE (the pbxproj gains the
/// FlutterGeneratedPluginSwiftPackage marker and a gitignored ephemeral
/// package tree appears), without changing what ships. The guards below
/// assert the committed shape, so they read `git show HEAD:` — the root
/// `dart test` suite (incl. the pre-commit fast gate) then behaves
/// identically on Linux CI and on a migrated macOS dev checkout.
String readCommitted(String path) {
  final r = Process.runSync('git', ['show', 'HEAD:$path']);
  if (r.exitCode != 0) {
    throw StateError('git show HEAD:$path failed: ${r.stderr}');
  }
  return r.stdout as String;
}

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

void main() {
  test(
    'AC1 — the build-macos job carries NO SwiftPM disable pin '
    '(knob removed upstream in 3.47.7, flutter/flutter#193978)',
    () {
      final job = jobsOf(workflowPath)[jobName] as YamlMap;
      final env = job['env'] as YamlMap?;
      final pin = env?[deadSwiftPmKnob]?.toString();
      expect(
        pin,
        isNull,
        reason:
            'Flutter 3.47.7 removed the FLUTTER_SWIFT_PACKAGE_MANAGER '
            'disable knob (flutter/flutter#193978): setting it to "0" no '
            'longer suppresses the SwiftPM migration, so the pin is a '
            'silent no-op that advertises the retired pure-CocoaPods lane '
            'decision. gh-1814 adopts the SPM lane (every floor ≥ 14.0, '
            'asserted post-config by scripts/assert_macos_min_platform.sh) '
            '— the job env must not carry the dead knob. Observed no-op '
            'evidence: runs 39991663029 / 40022900373 added SwiftPM '
            'integration WITH the pin set.',
      );
    },
  );

  test(
    'AC1b — Setup Flutter pins 3.47.7 (the #1813 3.47.4 revert, gh-1814)',
    () {
      final steps =
          (jobsOf(workflowPath)[jobName] as YamlMap)['steps'] as YamlList;
      final setup = steps.whereType<YamlMap>().firstWhere(
        (s) => (s['name']?.toString() ?? '') == 'Setup Flutter environment',
      );
      final with_ = setup['with'] as YamlMap?;
      final version = with_?['flutter-version']?.toString();
      expect(
        version,
        pinnedFlutterVersion,
        reason:
            'gh-1814 step 4 reverts the #1813 pin: 3.47.4 is the last '
            'flag-honoring patch but the runners cannot download it '
            '(run 40034163885 died in the SDK download on the ~60kB/s '
            'link), and with the SPM lane adopted there is no reason to '
            'stay on it — the release legs ride the same 3.47.7 the '
            'extension/pages legs pin',
      );
    },
  );

  test('AC2 — Build macOS release step: config-only + min-platform gate '
      'before the release build', () {
    final steps =
        (jobsOf(workflowPath)[jobName] as YamlMap)['steps'] as YamlList;
    final buildStep = steps.whereType<YamlMap>().firstWhere(
      (s) => (s['name']?.toString() ?? '').startsWith(buildStepPrefix),
    );
    final script = buildStep['run'].toString();

    expect(
      script,
      contains('flutter build macos --config-only'),
      reason:
          'the gate must run against the state a REAL tool pass produced — '
          'config-only drives the SPM migration + pod install without '
          'compiling',
    );
    expect(
      script,
      contains('scripts/assert_macos_min_platform.sh 14.0'),
      reason:
          'the gh-1814 SPM-lane gate must be invoked from the build step '
          'with the app minimum',
    );

    final gateIdx = script.indexOf('scripts/assert_macos_min_platform.sh');
    final releaseIdx = script.indexOf('flutter build macos --release');
    expect(releaseIdx, greaterThan(-1));
    expect(
      gateIdx,
      lessThan(releaseIdx),
      reason:
          'fail loud at build time, not at release time: the gate must '
          'reject a drifted floor BEFORE the long release build starts',
    );
  });

  test('AC3 — the committed pbxproj keeps the Runner-target floor shape the '
      'gate asserts (3×14.0, nothing else)', () {
    // Committed state, not the live file: a local SwiftPM-enabled build
    // adds the FlutterGeneratedPluginSwiftPackage marker to the working
    // tree without changing what ships (see readCommitted).
    final pbxproj = readCommitted(
      'flutter_app/macos/Runner.xcodeproj/project.pbxproj',
    );
    final entries = RegExp(
      r'MACOSX_DEPLOYMENT_TARGET = ([^;]+);',
    ).allMatches(pbxproj);
    expect(entries, isNotEmpty);
    for (final m in entries) {
      expect(
        m.group(1),
        '14.0',
        reason:
            'every MACOSX_DEPLOYMENT_TARGET in the macOS Runner project '
            'must equal the app minimum (14.0) — the Runner target pins it '
            'per-config, and the gate audits the generated package and '
            'every product floor against it (gh-1814: floors stay ≥ 14.0 '
            'on the adopted SPM lane)',
      );
    }
    // The Runner target must pin all three configs explicitly — the
    // aggregate/tests targets inherit Xcode defaults and are not allowed
    // to consume package products.
    expect(
      RegExp(r'MACOSX_DEPLOYMENT_TARGET = 14\.0;').allMatches(pbxproj).length,
      3,
      reason: 'Runner Debug/Release/Profile — the gh-1798-era shape',
    );
    expect(
      pbxproj.contains('FlutterGeneratedPluginSwiftPackage'),
      isFalse,
      reason:
          'the committed project must stay free of SwiftPM integration — '
          'the tool adds it at build time during --config-only and the '
          'gate asserts the RESULT (post-config state), never the '
          'committed file',
    );
  });
}
