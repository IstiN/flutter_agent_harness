// gh-1798 — the daily-publish cli leg (build-macos.yml, run 39905803673,
// 2026-10-23, first run on the Xcode 27 runner) failed on BOTH matrix archs
// with `error: No certificate for team 'YP9HC3USZ3' matching '***' found`
// at codesign. The certificate imports fine every day; what changed is the
// import→codesign GAP:
//
//   green 10-22 (Xcode 26): unlock 05:37:30Z → codesign done 05:55Z
//                           (≈ 18 min, well inside the window)
//   red   10-23 (Xcode 27): unlock 05:33:30Z → "Adding Swift Package
//                           Manager integration... 3365.3s" (56 min of
//                           first-time SwiftPM resolution) + pod install
//                           443s → first codesign evaluation 06:46Z
//                           (73+ min AFTER unlock)
//
// The signing step arms the keychain auto-lock with
// `security set-keychain-settings -t 3600` (1 hour). The Xcode 27 SPM
// resolution phase blew straight through that window, the keychain
// auto-locked mid-job, and codesign found no usable identity.
//
// Static workflow-shape assert (the "workflow-shape test never-again"
// pattern of workflow_selfhosted_legs_test.dart /
// workflow_fetch_shape_guard_test.dart):
//
//   AC1  the build-macos signing keychain's auto-lock timeout
//        (`set-keychain-settings -t <N>`) must cover the WHOLE job —
//        N ≥ the job's timeout-minutes ceiling in seconds. The import→
//        codesign gap legitimately spans the entire job today (56-min SPM
//        fetch measured in gh-1798; the job ceiling is 150 min), so any
//        window shorter than the job ceiling is a time bomb.
//
// The lazy keychain re-create in the TestFlight PKG step deliberately sets
// no settings — it only runs when the import step's keychain is missing
// and inherits the import step's configuration otherwise.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos';
const signingStepName = 'Import macOS signing certificate';

String read(String path) => File(path).readAsStringSync();

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
  test('AC1 — build-macos keychain auto-lock covers the whole job ceiling '
      '(gh-1798)', () {
    final job = jobsOf(workflowPath)[jobName] as YamlMap;
    final timeoutMinutes = job['timeout-minutes'] as int;
    final jobCeilingSeconds = timeoutMinutes * 60;

    final script = stepScriptOf(workflowPath, jobName, signingStepName);
    final match = RegExp(
      r'security\s+set-keychain-settings\s+-t\s+(\d+)',
    ).firstMatch(script);
    expect(
      match,
      isNotNull,
      reason:
          '$signingStepName in $jobName must arm a keychain auto-lock '
          'timeout via `security set-keychain-settings -t <seconds>` — '
          'without an explicit window the runner default (300s) locks the '
          'keychain before the build even starts',
    );

    final seconds = int.parse(match!.group(1)!);
    expect(
      seconds,
      greaterThanOrEqualTo(jobCeilingSeconds),
      reason:
          '$workflowPath $jobName/$signingStepName arms the keychain '
          'auto-lock at ${seconds}s, but the job ceiling is $timeoutMinutes '
          'min ($jobCeilingSeconds s). The unlock→codesign gap legitimately '
          'spans the whole job (gh-1798: 56 min of Xcode 27 SwiftPM '
          'resolution + 443s pod install put the first codesign evaluation '
          '73+ min after unlock — the 1h window auto-locked the keychain '
          'mid-build and codesign lost the signing identity). The window '
          'must be ≥ the job timeout.',
    );
  });
}
