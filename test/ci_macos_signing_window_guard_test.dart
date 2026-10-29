// gh-1798 — the keychain auto-lock window class is RETIRED with per-job
// keychains; what replaces it is an explicit unlock at point of use.
//
// HISTORY: the daily-publish cli leg (build-macos.yml, run 39905803673,
// 2026-10-23, first run on the Xcode 27 runner) failed on BOTH matrix
// archs with `error: No certificate for team 'YP9HC3USZ3' matching '***'
// found` at codesign. The certificate imports fine every day; what changed
// is the import→codesign GAP:
//
//   green 10-22 (Xcode 26): unlock 05:37:30Z → codesign done 05:55Z
//                           (≈ 18 min, well inside the window)
//   red   10-23 (Xcode 27): unlock 05:33:30Z → "Adding Swift Package
//                           Manager integration... 3365.3s" (56 min of
//                           first-time SwiftPM resolution) + pod install
//                           443s → first codesign evaluation 06:46Z
//                           (73+ min AFTER unlock)
//
// The signing step armed the per-job keychain's auto-lock with
// `security set-keychain-settings -t 3600` (1 hour); Xcode 27's SwiftPM
// resolution blew through the window and the keychain auto-locked
// mid-job. The gh-1852-era fix widened the window to cover the whole job
// ceiling. Both are retired: per-job keychains no longer exist, the
// persistent ci-signing.keychain-db runs with NO inactivity auto-lock
// (`set-keychain-settings -u`, managed by ci-sign install), and the
// Fastfile unlocks it explicitly right before the archive.
//
//   AC1  build-macos signing steps contain NO per-job keychain settings —
//        no `set-keychain-settings` may reappear in workflow-land.
//   AC2  the Fastfile build_only lane unlocks the signing keychain via
//        ci-sign immediately before the archive (point-of-use unlock —
//        immune to any gap length by construction).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String path) => loadYaml(read(path))['jobs'] as YamlMap;

String executableScriptOf(YamlMap job) {
  final steps = job['steps'] as YamlList? ?? YamlList();
  return steps
      .whereType<YamlMap>()
      .map((s) => s['run']?.toString() ?? '')
      .map(_stripComments)
      .join('\n');
}

String _stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

void main() {
  test('AC1 — build-macos has NO per-job keychain auto-lock windows '
      '(gh-1798 class retired by ci-sign)', () {
    final script = executableScriptOf(jobsOf(workflowPath)[jobName] as YamlMap);
    expect(
      script,
      isNot(contains('set-keychain-settings')),
      reason:
          'build-macos.yml arms a per-job keychain auto-lock window — '
          'per-job keychains are retired (gh-1865 model v3): the '
          'persistent ci-signing.keychain-db is no-timeout by design and '
          'the archive unlocks it at point of use. A workflow-level '
          'set-keychain-settings would mean a hidden keychain came back; '
          'the gh-1798 failure (1h window vs 73+ min Xcode 27 SwiftPM '
          'gap, run 39905803673) is what any such window reimplements.',
    );
  });

  test('AC2 — Fastfile unlocks the signing keychain at point of use '
      '(gh-1798 replacement)', () {
    final fastfile = read('flutter_app/fastlane/Fastfile');
    final unlockIdx = fastfile.indexOf('sh(ci_sign, "unlock")');
    final gymIdx = fastfile.indexOf('build_app(');
    expect(
      unlockIdx,
      greaterThanOrEqualTo(0),
      reason:
          'the Fastfile must unlock the persistent signing keychain via '
          'ci-sign — hours can pass between the workflow\'s provision '
          'step and the archive, and point-of-use unlock is immune to '
          'any gap length (the retired gh-1798 window hack was not)',
    );
    expect(
      gymIdx,
      greaterThan(unlockIdx),
      reason:
          'the `ci-sign unlock` call must precede the archive '
          '(build_app) in the Fastfile — an unlock after the archive '
          'protects nothing',
    );
  });
}
