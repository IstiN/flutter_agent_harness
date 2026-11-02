// gh-2039 — the daily-publish cli leg (build-macos.yml, run
// 41393469972, 2026-11-02) lost the x86_64 "Build and package
// no-sandbox release" job with `error: no identity found` at
// codesign — the xcode_backend sign of App.framework INSIDE
// `flutter build macos --release`, 7m02s after the step's last
// keychain activity (the DMG codesigns at 06:27:23Z). The identity
// itself was healthy: `ci-sign install fa-macos` verified it at
// 06:07:38Z, the same SHA-1 (43AEC254…) signed the DMG at 06:27, the
// certificate is valid to 2026-12-30, and the arm64 leg's identical
// no-sandbox build passed 30 minutes earlier. The release signing
// path depends on AMBIENT persistent-keychain state (host keychain
// unlocked + ci-signing in the search list) that raw `codesign`
// cannot assert and that the 60s unlock watchdog provably does not
// guarantee across a multi-minute build window on this host.
//
// The arm64 leg only survived because its arm64-only TestFlight PKG
// step happened to re-run `ci-sign install` right before its own
// no-sandbox build — the incidental point-of-use re-assert the
// x86_64 leg never got. This codifies that re-assert for BOTH archs
// and adds a cheap pre-flight so a recurrence fails in ~1s with a
// self-explaining error instead of after a 5-minute build:
//
//   AC1  the build-macos.yml no-sandbox step re-asserts the signing
//        state (`ci-sign install fa-macos` — unlock + identity
//        validity verify + search-list defensive rewrite, idempotent)
//        immediately BEFORE build_macos_nosandbox.sh, gated on a
//        pinned identity (signed=true shape) so ad-hoc/local runs are
//        untouched;
//   AC2  build_macos_nosandbox.sh pre-flights the pinned identity via
//        `security find-identity -v -p codesigning` — the same search
//        list codesign reads — and fails loud with the ci-sign
//        remediation hint BEFORE `flutter build macos --release`
//        (the gh-1798 point-of-use principle: "immune to any gap
//        length by construction").
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const scriptPath = 'flutter_app/scripts/build_macos_nosandbox.sh';

YamlMap _jobSteps() {
  final jobs = loadYaml(File(workflowPath).readAsStringSync())['jobs']
      as YamlMap;
  final job = jobs['build-macos'] as YamlMap;
  final matrixArchs = ((job['strategy'] as YamlMap?)?['matrix'] as YamlMap?)
      ?['arch'];
  expect(matrixArchs, isNotNull, reason: 'build-macos must stay a matrix');
  return job;
}

String _stepRun(YamlMap job, String stepName) {
  final steps = job['steps'] as YamlList;
  for (final s in steps.whereType<YamlMap>()) {
    if (s['name']?.toString() == stepName) return s['run']?.toString() ?? '';
  }
  fail('step "$stepName" not found in $workflowPath');
}

void main() {
  test('AC1 — the no-sandbox step re-asserts the signing state at point of use, before the build', () {
    final run = _stepRun(_jobSteps(), 'Build and package no-sandbox release');

    final pou = run.indexOf('ci-sign install fa-macos');
    final build = run.indexOf('build_macos_nosandbox.sh');
    expect(pou, greaterThan(-1), reason: 'the step must run the ci-sign '
        'point-of-use re-assert (gh-1798 principle: immune to any gap '
        'length by construction) — the x86_64 leg of run 41393469972 '
        'died at codesign because nothing re-asserted the ambient '
        'persistent-keychain state between the DMG codesigns (06:27) '
        'and the flutter build codesign (06:34)');
    expect(build, greaterThan(-1));
    expect(pou, lessThan(build), reason: 'the re-assert must run BEFORE '
        'build_macos_nosandbox.sh — that script contains the flutter '
        'build whose xcode_backend codesign failed in gh-2039');

    // Gated on a pinned identity: the sha1-bearing env/vars only exist
    // on the signed path; ad-hoc ("-" identity) and local runs must not
    // depend on ~/bin/ci-sign existing.
    expect(
      run.contains('ci-sign install fa-macos'),
      isTrue,
    );
    final reassertBlock = run.substring(0, pou);
    expect(
      reassertBlock.contains('FA_CODE_SIGN_IDENTITY') ||
          reassertBlock.contains('signed'),
      isTrue,
      reason: 'the re-assert must be gated on the pinned-identity path '
          'so unsigned/ad-hoc runs never require ci-sign',
    );
  });

  test('AC2 — build_macos_nosandbox.sh pre-flights the pinned identity before spending the build', () {
    final script = File(scriptPath).readAsStringSync();
    final flutterBuild = script.indexOf('flutter build macos --release');
    expect(flutterBuild, greaterThan(-1));

    final preflight = script.indexOf(
      'security find-identity -v -p codesigning',
    );
    expect(preflight, greaterThan(-1), reason: 'the script must verify '
        'the pinned identity is resolvable BEFORE the multi-minute '
        'flutter build — a miss must fail in ~1s with the remediation '
        'hint, not after a 5-minute build (gh-2039)');
    expect(preflight, lessThan(flutterBuild), reason: 'the pre-flight '
        'must precede flutter build macos --release');

    // The failure path must be actionable: name the ci-sign fix, not a
    // bare exit.
    final errorLine = script
        .split('\n')
        .firstWhere((l) => l.contains('::error::'), orElse: () => '');
    expect(
      errorLine,
      contains('ci-sign install fa-macos'),
      reason: 'the pre-flight error must point at the exact remediation '
          '(the same re-assert the workflow runs at point of use)',
    );
  });
}
