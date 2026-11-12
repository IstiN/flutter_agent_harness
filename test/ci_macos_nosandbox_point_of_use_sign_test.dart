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
//        `security find-identity -p codesigning` — VALID identities
//        only (no `-v`: an expired identity still prints its SHA-1
//        under `-v`, tagged with its failure reason, which would let
//        the exact "expired cert" case this guard exists to catch slip
//        through into the 5-minute build) — and fails loud with the
//        ci-sign remediation hint BEFORE
//        `flutter build macos --release` (the gh-1798 point-of-use
//        principle: "immune to any gap length by construction");
//   AC3  an EXPIRED pinned identity is rejected by the pre-flight
//        before the build is spent: `find-identity -v` lists invalid
//        identities with their SHA-1 (CSSMERR_TP_CERT_EXPIRED et al.),
//        so the guard must consult the valid-only listing — proven
//        with a stubbed `security` that exposes the identity ONLY in
//        its `-v` mode and a stubbed `flutter` that must never run.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const scriptPath = 'flutter_app/scripts/build_macos_nosandbox.sh';

YamlMap _jobSteps() {
  final jobs =
      loadYaml(File(workflowPath).readAsStringSync())['jobs'] as YamlMap;
  final job = jobs['build-macos'] as YamlMap;
  final matrixArchs =
      ((job['strategy'] as YamlMap?)?['matrix'] as YamlMap?)?['arch'];
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
  test(
    'AC1 — the no-sandbox step re-asserts the signing state at point of use, before the build',
    () {
      final run = _stepRun(_jobSteps(), 'Build and package no-sandbox release');

      final pou = run.indexOf('ci-sign install fa-macos');
      final build = run.indexOf('build_macos_nosandbox.sh');
      expect(
        pou,
        greaterThan(-1),
        reason:
            'the step must run the ci-sign '
            'point-of-use re-assert (gh-1798 principle: immune to any gap '
            'length by construction) — the x86_64 leg of run 41393469972 '
            'died at codesign because nothing re-asserted the ambient '
            'persistent-keychain state between the DMG codesigns (06:27) '
            'and the flutter build codesign (06:34)',
      );
      expect(build, greaterThan(-1));
      expect(
        pou,
        lessThan(build),
        reason:
            'the re-assert must run BEFORE '
            'build_macos_nosandbox.sh — that script contains the flutter '
            'build whose xcode_backend codesign failed in gh-2039',
      );

      // Gated on a pinned identity: the sha1-bearing env/vars only exist
      // on the signed path; ad-hoc ("-" identity) and local runs must not
      // depend on ~/bin/ci-sign existing.
      expect(run.contains('ci-sign install fa-macos'), isTrue);
      final reassertBlock = run.substring(0, pou);
      expect(
        reassertBlock.contains('FA_CODE_SIGN_IDENTITY') ||
            reassertBlock.contains('signed'),
        isTrue,
        reason:
            'the re-assert must be gated on the pinned-identity path '
            'so unsigned/ad-hoc runs never require ci-sign',
      );
    },
  );

  test(
    'AC2 — build_macos_nosandbox.sh pre-flights the pinned identity before spending the build',
    () {
      final script = File(scriptPath).readAsStringSync();
      // The first flutter spend is the configuration pass (SPM migration +
      // pod install) feeding the ReleaseNoSandbox xcodebuild — #2132
      // review 5876405113 consumption order.
      final flutterBuild = script.indexOf('flutter build macos --config-only');
      expect(flutterBuild, greaterThan(-1));

      // The pre-flight lives in the gh-2039 block, between its marker
      // comment and the readonly APP line. Isolate THAT block — the
      // script's earlier local-development-identity discovery legitimately
      // still uses `-v` (it reads identity NAMES, which only the verbose
      // listing carries) and must not satisfy assertions meant for the
      // pre-flight.
      final blockStart = script.indexOf('# gh-2039 pre-flight');
      final blockEnd = script.indexOf('readonly APP=');
      expect(
        blockStart,
        greaterThan(-1),
        reason:
            'the gh-2039 pre-flight '
            'block must exist — the script must verify the pinned identity '
            'is resolvable BEFORE the multi-minute flutter build — a miss '
            'must fail in ~1s with the remediation hint, not after a '
            '5-minute build (gh-2039)',
      );
      expect(blockEnd, greaterThan(blockStart));
      final preflightBlock = script.substring(blockStart, blockEnd);
      expect(
        blockEnd,
        lessThan(flutterBuild),
        reason:
            'the pre-flight '
            'must precede flutter build macos --release',
      );

      // gh-2039 rework review thread 1: `find-identity -v` lists INVALID
      // identities too (each tagged with its failure reason, e.g.
      // CSSMERR_TP_CERT_EXPIRED) — an expired pinned identity would
      // match the pre-flight and slip into the 5-minute build. The
      // pre-flight must consult the VALID-only listing (`-p codesigning`
      // without `-v`), which is also the closer approximation of what
      // codesign will accept.
      expect(preflightBlock, contains('security find-identity -p codesigning'));
      expect(
        preflightBlock.contains('find-identity -v'),
        isFalse,
        reason:
            'the pre-flight must NOT use `find-identity -v` — the '
            'verbose listing includes invalid identities (expired, '
            'malformed) whose SHA-1 still matches the pinned value, so '
            'the "expired" case the error text promises to catch would '
            'slip through (gh-2039 review thread 1)',
      );

      // Secondary nit, same thread: codesign --sign <SHA1> and ci-sign's
      // own validity check are case-insensitive — the pre-flight must be
      // no stricter than its consumers.
      expect(
        preflightBlock,
        contains('grep -Fiq'),
        reason:
            'the pinned-identity match must be case-insensitive: '
            'codesign --sign and ci-sign resolve the fingerprint '
            'case-insensitively (scripts/ci-sign uses grep -qi)',
      );

      // The failure path must be actionable: name the ci-sign fix, not a
      // bare exit — and describe the command the operator can actually
      // run (the valid-only listing, not the `-v` variant the fix
      // removed).
      final errorLine = script
          .split('\n')
          .firstWhere((l) => l.contains('::error::'), orElse: () => '');
      expect(
        errorLine,
        contains('ci-sign install fa-macos'),
        reason:
            'the pre-flight error must point at the exact remediation '
            '(the same re-assert the workflow runs at point of use)',
      );
      expect(
        errorLine,
        contains("security find-identity -p codesigning"),
        reason:
            'the error text must name the command the guard actually '
            'runs — a `-v` reference in the message would document a '
            'check the script no longer performs',
      );
    },
  );

  test(
    'AC3 — an EXPIRED pinned identity is rejected by the pre-flight BEFORE the build (find-identity -v lists invalid identities too)',
    () {
      // gh-2039 review thread 1, executable form. `security find-identity
      // -v -p codesigning` lists invalid identities as well, each with
      // its failure reason and — crucially — its SHA-1. An expired pinned
      // identity therefore MATCHED the pre-flight grep, the guard waved
      // the leg through, and codesign still died ~5 minutes later — the
      // exact failure mode this pre-flight exists to compress to ~1s.
      // The stub below exposes the identity ONLY in the `-v` listing
      // (tagged CSSMERR_TP_CERT_EXPIRED); the valid-only listing is
      // empty, exactly what codesign would act on.
      final tmp = Directory.systemTemp.createTempSync('nosandbox-preflight-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final bin = '${tmp.path}/bin';
      Directory(bin).createSync();
      const fakeSha = '43AEC254DEADBEEF0123456789ABCDEF01234567';
      File('$bin/security').writeAsStringSync('''
#!/usr/bin/env bash
case " \$* " in
  *" -v "*)
    printf '  1) $fakeSha "Apple Distribution: Fa (TEAM123)" (CSSMERR_TP_CERT_EXPIRED)\n'
    printf '     1 identities found\n'
    ;;
  *)
    printf 'No identities found\n'
    ;;
esac
exit 0
''');
      // The build must never be reached when the pre-flight rejects the
      // identity — the marker records any flutter invocation.
      final flutterMarker = '${tmp.path}/flutter-was-invoked';
      File('$bin/flutter').writeAsStringSync('''
#!/usr/bin/env bash
echo "flutter \$*" >> '$flutterMarker'
exit 42
''');
      Process.runSync('chmod', ['+x', '$bin/security', '$bin/flutter']);

      final r = Process.runSync(
        'bash',
        [File(scriptPath).absolute.path],
        environment: {
          'PATH': '$bin:${Platform.environment['PATH']}',
          'HOME': tmp.path,
          'FA_CODE_SIGN_IDENTITY': fakeSha,
          'FA_DEVELOPMENT_TEAM': 'TEAM123',
        },
      );

      expect(
        r.exitCode,
        isNot(0),
        reason:
            'an expired identity must fail '
            'the pre-flight (stdout+stderr: ${r.stdout}${r.stderr})',
      );
      expect(
        '${r.stdout}${r.stderr}',
        contains('::error::'),
        reason:
            'the rejection must be the loud pre-flight error, not a '
            'later build failure',
      );
      expect(
        File(flutterMarker).existsSync(),
        isFalse,
        reason:
            'the pre-flight must abort BEFORE `flutter build macos '
            '--release` — the expired identity slipped through the `-v` '
            'listing and the multi-minute build was spent anyway '
            '(gh-2039 review thread 1)',
      );
    },
  );
}
