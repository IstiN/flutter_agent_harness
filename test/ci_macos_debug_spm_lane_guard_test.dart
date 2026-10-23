// gh-1814 — lane guard for the ci.yml macOS desktop debug leg. Retires the
// gh-1806 pure-CocoaPods pin the same way gh-1814 retired it on the release
// DMG legs (build-macos.yml): upstream REMOVED the
// FLUTTER_SWIFT_PACKAGE_MANAGER disable knob between 3.47.4 and 3.47.7
// (flutter/flutter#193978), and this job pins `flutter-version: '3.47.x'` —
// a floating stable that already resolves past the removal. The "0" pin is
// therefore a silent no-op: the knob is not read by the resolved tool
// anymore, and the debug leg has been riding the SwiftPM lane (green) —
// run 399572012's 77.2s SPM pass is the shape. Keeping the pin would
// advertise a lane decision ("pure CocoaPods") the tool no longer honors,
// and the old comment above it ("with the feature off the SPM migration
// skips cleanly") was false on the resolved stable — there is no "feature
// off" anymore. Both lanes must document the same reality.
//
// gh-1806 history (why the pin existed, and why its failure mode is
// tolerated now): the debug leg went red (CI run 39957271246, v1.0.631)
// when the SPM migration git-cloned the Firebase iOS SPM packages from
// github.com single-shot and the transfer died mid-clone ("curl 92 HTTP/2
// stream 5 was not closed cleanly: CANCEL (err 8)"). The identical SHA went
// green 34 minutes later (run 399572012) — a transient network flake, not a
// code regression, and it is the mode the lane already lives with on
// 3.47.7. The release DMG legs adopt the same lane with floor enforcement
// (scripts/assert_macos_min_platform.sh, gh-1814); this job has no
// min-platform gate, but it has no sub-floor floor state either (Runner
// pbxproj 3×14.0, Podfile :osx, '14.0' — audited by
// test/macos_min_platform_gate_test.dart AC9 against HEAD).
//
// Static workflow-shape assert (the "workflow-shape test never-again"
// pattern of build_macos_spm_lane_guard_test.dart /
// ci_macos_signing_window_guard_test.dart):
//
//   AC1  the ci.yml build-macos job carries NO FLUTTER_SWIFT_PACKAGE_MANAGER
//        env — the knob is removed in 3.47.7 (no-op since
//        flutter/flutter#193978); keeping it (or re-adding it) would pin a
//        lane decision the resolved tool ignores, exactly the dead config
//        gh-1814 stripped from build-macos.yml;
//   AC2  no step of the job sets the knob either — any value (0 or 1)
//        re-introduces dead configuration: the env name no longer exists in
//        flutter_tools, so neither a "pin" nor a "re-enable" does anything.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/ci.yml';
const jobName = 'build-macos';
const deadSwiftPmKnob = 'FLUTTER_SWIFT_PACKAGE_MANAGER';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

void main() {
  test(
    'AC1 — the ci.yml build-macos (debug) job carries NO SwiftPM disable '
    'pin (knob removed upstream in 3.47.7, flutter/flutter#193978 — '
    'gh-1814)',
    () {
      final job = jobsOf(workflowPath)[jobName] as YamlMap;
      final env = job['env'] as YamlMap?;
      final pin = env?[deadSwiftPmKnob]?.toString();
      expect(
        pin,
        isNull,
        reason:
            'Flutter 3.47.7 removed the FLUTTER_SWIFT_PACKAGE_MANAGER '
            'disable knob (flutter/flutter#193978) and this job pins the '
            'floating \'3.47.x\' stable — it resolves past the removal, so '
            'the "0" pin is a silent no-op that advertises the retired '
            'pure-CocoaPods lane decision. The debug leg rides the SwiftPM '
            'lane and is green that way (run 399572012, SPM pass 77.2s — '
            'the same lane gh-1814 adopted on the release DMG legs). '
            'Keeping or re-adding the pin would mean one lane documents '
            'the knob as dead while the other still praises it — the '
            'asymmetry the gh-1814 review flagged.',
      );
    },
  );

  test(
    'AC2 — no build-macos step sets the SwiftPM knob at all (gh-1814)',
    () {
      final steps =
          (jobsOf(workflowPath)[jobName] as YamlMap)['steps'] as YamlList;
      for (final step in steps.whereType<YamlMap>()) {
        final stepEnv = step['env'] as YamlMap?;
        final override = stepEnv?[deadSwiftPmKnob]?.toString();
        expect(
          override,
          isNull,
          reason:
              'step "${step['name']}" sets FLUTTER_SWIFT_PACKAGE_MANAGER — '
              'the env name was removed from flutter_tools in 3.47.7 '
              '(flutter/flutter#193978), so any value is dead configuration '
              'either way: "0" no longer suppresses the SwiftPM migration '
              'and "1" no longer enables anything. The lane decision lives '
              'in the tool version + the floor gate '
              '(scripts/assert_macos_min_platform.sh), not in a knob the '
              'tool stopped reading',
        );
      }
    },
  );
}
