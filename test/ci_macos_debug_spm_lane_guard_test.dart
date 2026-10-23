// gh-1806 — lane guard for the ci.yml macOS desktop debug leg. The leg went
// red (CI run 39957271246, v1.0.631, 2026-10-23) when Xcode's SwiftPM
// dependency resolution — the "Adding Swift Package Manager integration"
// pass of `flutter build macos --debug` — git-cloned the Firebase iOS SPM
// packages from github.com single-shot and the transfer died mid-clone:
//
//   Failed to clone repository https://github.com/google/GoogleDataTransport.git:
//   error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)
//   fatal: early EOF
//   xcodebuild: error: Could not resolve package dependencies
//
// The identical SHA went green 34 minutes later in the release-triggered
// run 399572012 (SPM pass 77.2s vs 513.4s in the red run) — a transient
// network flake, not a code regression. The debug leg is hermetic everywhere
// else (Pods cache-restored, WasmRun framework + gema dylibs curl --retry'd)
// except this one un-retried multi-minute SPM clone on every fresh
// GitHub-hosted runner; any HTTP/2 stream cancel reds the leg and the
// required Quality-gate aggregate with it.
//
// The gh-180 lane decision (test/build_macos_spm_lane_guard_test.dart)
// already moved the RELEASE DMG legs to the pure CocoaPods lane with
// FLUTTER_SWIFT_PACKAGE_MANAGER=0; the ci.yml debug leg was left riding the
// fragile SPM migration — the same silent FlutterGeneratedPluginSwiftPackage
// floor bump gh-180 removed, plus this network-failure mode. This guard
// extends the same lane decision to the debug leg: the feature env override
// is read per flutter invocation (flutter_features_config.dart), the SPM
// migration then skips cleanly, and every macOS plugin builds from the
// Podfile.lock pins at the Podfile platform (:osx, '14.0') — the exact
// configuration the release legs ship, so the debug leg verifies what
// ships.
//
// Static workflow-shape assert (the "workflow-shape test never-again"
// pattern of build_macos_spm_lane_guard_test.dart /
// ci_macos_signing_window_guard_test.dart):
//
//   AC1  the ci.yml build-macos job pins FLUTTER_SWIFT_PACKAGE_MANAGER=0 —
//        with the feature on, every fresh runner re-enters the SPM
//        migration whose dependency clone is a single-shot network
//        transfer (run 39957271246: curl 92 mid-clone of GoogleDataTransport);
//   AC2  no step of the job re-enables the feature via a step-level env
//        override — the job pin is the single source of truth for the
//        lane, and a step-level FLUTTER_SWIFT_PACKAGE_MANAGER=1 would
//        silently reintroduce the migration.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/ci.yml';
const jobName = 'build-macos';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

void main() {
  test(
    'AC1 — ci.yml build-macos (debug) job pins FLUTTER_SWIFT_PACKAGE_MANAGER=0 '
    '(gh-1806)',
    () {
      final job = jobsOf(workflowPath)[jobName] as YamlMap;
      final env = job['env'] as YamlMap?;
      expect(
        env,
        isNotNull,
        reason: 'the ci.yml build-macos job must carry an env block',
      );
      final pin = env?['FLUTTER_SWIFT_PACKAGE_MANAGER']?.toString();
      expect(
        pin,
        '0',
        reason:
            'Flutter 3.47 stable ships the SwiftPM feature enabled-by-default; '
            'without the pin the ci.yml debug leg re-enters "Adding Swift '
            'Package Manager integration" on every fresh runner and '
            'git-clones the Firebase iOS SPM packages from github.com '
            'single-shot — run 39957271246 (v1.0.631) died mid-clone of '
            'GoogleDataTransport with "curl 92 HTTP/2 stream 5 was not '
            'closed cleanly: CANCEL (err 8)" and reded the leg plus the '
            'Quality-gate aggregate, while the identical SHA went green in '
            'run 399572012 (SPM pass 77.2s vs 513.4s). With the feature off '
            'the migration skips cleanly and every macOS plugin builds from '
            'the Podfile.lock pins (Pods are cache-restored in this job) — '
            'the pure CocoaPods lane the gh-180 fix already pinned on the '
            'release DMG legs (build-macos.yml).',
      );
    },
  );

  test(
    'AC2 — no build-macos step re-enables the SwiftPM feature (gh-1806)',
    () {
      final steps =
          (jobsOf(workflowPath)[jobName] as YamlMap)['steps'] as YamlList;
      for (final step in steps.whereType<YamlMap>()) {
        final stepEnv = step['env'] as YamlMap?;
        final override = stepEnv?['FLUTTER_SWIFT_PACKAGE_MANAGER']?.toString();
        expect(
          override,
          isNull,
          reason:
              'step "${step['name']}" re-enables the SwiftPM feature with a '
              'step-level env override — that silently reintroduces the '
              'single-shot SPM dependency clone (the exact failure mode of '
              'run 39957271246, gh-1806); the job-level pin is the single '
              'source of truth for the lane',
        );
      }
    },
  );
}
