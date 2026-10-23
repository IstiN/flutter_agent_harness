// gh-180 — lane guard for the macOS desktop DMG legs. The legs went red
// (v1.0.630, build-macos run 39905803673, 2026-10-23) when the tool's
// best-effort FlutterGeneratedPluginSwiftPackage floor bump skipped on the
// first Xcode 27 run while a 14.0-floored SwiftPM product still existed.
// The gh-180 fix moves BOTH matrix arch legs to the pure CocoaPods lane
// (every macOS plugin is already pinned in flutter_app/macos/Podfile.lock)
// and adds a build-time REG gate so a lane or floor drift fails in seconds
// with the remediation instead of Xcode's cryptic
// "requires minimum platform version" error after a 50+-minute pass.
//
// Static workflow-shape assert (the "workflow-shape test never-again"
// pattern of ci_macos_signing_window_guard_test.dart /
// workflow_selfhosted_legs_test.dart):
//
//   AC1  the build-macos job pins FLUTTER_SWIFT_PACKAGE_MANAGER=0 — the
//        feature env override is read per flutter invocation
//        (flutter_features_config.dart), the SPM migration then skips
//        cleanly, and the Podfile platform (:osx, '14.0') — not a silent
//        tool bump — is the authority for the effective pod floors;
//   AC2  the Build macOS release step runs `flutter build macos
//        --config-only` + scripts/assert_macos_min_platform.sh BEFORE the
//        real `flutter build macos --release` — the gate must see the
//        post-config state and fail before any compile minute is spent;
//   AC3  the no-sandbox flavor rides the same job env, so it is covered
//        by the same lane pin (no separate assertion needed — asserted
//        here anyway as a doc pin that the step invokes plain flutter).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos';
const buildStepPrefix = 'Build macOS release (';

String read(String path) => File(path).readAsStringSync();

/// The COMMITTED content of a tracked file. A local SwiftPM-enabled flutter
/// build migrates the checkout IN PLACE (the exact mechanism the
/// build-macos lane pins off — gh-180): the pbxproj gains the
/// FlutterGeneratedPluginSwiftPackage marker and a gitignored ephemeral
/// package tree appears, without changing what ships. The guards below
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

/// The `run` script of the named step in the named job of the workflow.
String stepScriptOf(String workflowPath, String job, String stepName) {
  final steps = (jobsOf(workflowPath)[job] as YamlMap)['steps'] as YamlList;
  return steps
      .whereType<YamlMap>()
      .firstWhere((s) => (s['name']?.toString() ?? '') == stepName)['run']
      .toString();
}

void main() {
  test(
    'AC1 — build-macos job pins FLUTTER_SWIFT_PACKAGE_MANAGER=0 (gh-180)',
    () {
      final job = jobsOf(workflowPath)[jobName] as YamlMap;
      final env = job['env'] as YamlMap?;
      expect(
        env,
        isNotNull,
        reason: 'the build-macos job must carry an env block',
      );
      final pin = env?['FLUTTER_SWIFT_PACKAGE_MANAGER']?.toString();
      expect(
        pin,
        '0',
        reason:
            'Flutter 3.47 stable ships the SwiftPM feature enabled-by-default; '
            'without the pin every fresh-clone build re-enters the '
            'FlutterGeneratedPluginSwiftPackage lane whose 12.0 floor bump '
            'depends on a silent xcodebuild -showBuildSettings read — the '
            'exact mechanism that red run 39905803673 (gh-180) when a '
            '14.0-floored product existed. The pods lane (Podfile.lock) '
            'builds every macOS plugin at the Podfile platform instead.',
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
          'config-only drives the SPM migration (or its clean skip) and pod '
          'install without compiling',
    );
    expect(
      script,
      contains('scripts/assert_macos_min_platform.sh'),
      reason: 'the gh-180 REG gate must be invoked from the build step',
    );

    final gateIdx = script.indexOf('scripts/assert_macos_min_platform.sh');
    final releaseIdx = script.indexOf('flutter build macos --release');
    expect(releaseIdx, greaterThan(-1));
    expect(
      gateIdx,
      lessThan(releaseIdx),
      reason:
          'fail loud at build time, not at release time: the gate must '
          'reject a drifted lane/floor BEFORE the long release build starts',
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
            'per-config; a second, lower value is a silent '
            'deployment-target regression the gate would reject on the '
            'runner (gh-180 AC: every SPM/pods target ≥ 14.0)',
      );
    }
    // The Runner target must pin all three configs explicitly — the
    // aggregate/tests targets inherit Xcode defaults and are not allowed
    // to consume package products (the pods lane keeps the pbxproj free
    // of FlutterGeneratedPluginSwiftPackage).
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
          'the tool adds it only when the feature is enabled, and the '
          'build-macos job pins the feature off (gh-180)',
    );
  });
}
