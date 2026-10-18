// gh-1692 — the daily-publish TestFlight leg went 5 days dry, and the
// last two runs failed with `** ARCHIVE FAILED **` in fastlane's
// build_app while xcpretty printed NO error line — the real xcodebuild
// error only lived in ~/Library/Logs/gym/ ON the runner, invisible from
// GitHub. The 10-16 run died earlier on a transient single-shot git
// mirror fetch (exit 128, "2876 bytes of body are still expected") and
// cost a whole day of TestFlight.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of workflow_selfhosted_legs_test.dart):
//
//   AC2  the archive failure is diagnosable from the GH run page: the
//        iOS lane pins xcbeautify as the xcodebuild formatter (xcpretty
//        swallows build errors — fastlane's own warning), the workflow
//        installs xcbeautify on the self-hosted runner, and on failure
//        ~/Library/Logs/gym/*.log is uploaded as a job artifact.
//   AC3  the git fetch/clone legs of the iOS chain carry a BOUNDED
//        retry — no single-shot origin transfer may red the leg.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

List<YamlMap> stepsOf(String workflowPath, String job) =>
    ((jobsOf(workflowPath)[job] as YamlMap)['steps'] as YamlList)
        .whereType<YamlMap>()
        .toList();

void main() {
  const mobile = '.github/workflows/build-mobile.yml';

  group('AC2 — archive failure is diagnosable from the GH run page', () {
    test('Fastfile build_app pins xcbeautify, never xcpretty (gh-1692)', () {
      final fastfile = read('flutter_app/fastlane/Fastfile');
      final buildApp = fastfile.indexOf('build_app(');
      expect(buildApp, greaterThan(-1), reason: 'build_app must exist');
      final options = fastfile.substring(
        buildApp,
        fastfile.indexOf("\n    end", buildApp),
      );
      expect(
        options,
        contains('xcodebuild_formatter: "xcbeautify"'),
        reason:
            'xcpretty "can result in missing some build errors" (fastlane '
            'own warning) — the 10-17/10-18 runs printed `** ARCHIVE '
            'FAILED **` with NO error line. xcbeautify keeps error lines '
            'in the GH log (gh-1692).',
      );
      expect(
        options.contains('xcpretty'),
        isFalse,
        reason:
            'the xcpretty formatter must be gone from the iOS build_app '
            'options (gh-1692)',
      );
      // The lane must also dump the newest gym log tail into the GH log
      // on failure, so the real xcodebuild error is readable WITHOUT
      // downloading the artifact.
      expect(
        fastfile,
        contains('print_gym_log_tail'),
        reason:
            'on lane failure the newest ~/Library/Logs/gym/*.log tail '
            'must be printed into the job log — the next archive failure '
            'must surface the real xcodebuild error in the GH log '
            '(gh-1692 AC2)',
      );
    });

    test('build-ios installs xcbeautify before the archive step', () {
      final steps = stepsOf(mobile, 'build-ios');
      final installIdx = steps.indexWhere(
        (s) => (s['name']?.toString() ?? '').contains('xcbeautify'),
      );
      final buildIdx = steps.indexWhere(
        (s) => (s['name']?.toString() ?? '') == 'Build iOS IPA',
      );
      expect(installIdx, greaterThan(-1),
          reason: 'build-ios must install xcbeautify (gh-1692)');
      expect(buildIdx, greaterThan(-1));
      expect(
        installIdx,
        lessThan(buildIdx),
        reason:
            'xcbeautify must be installed BEFORE the archive — a missing '
            'formatter binary must never silently re-introduce the '
            'xcpretty class (gh-1692)',
      );
    });

    test('build-ios uploads ~/Library/Logs/gym as a failure artifact', () {
      final steps = stepsOf(mobile, 'build-ios');
      final upload = steps.where(
        (s) =>
            (s['uses']?.toString() ?? '').contains('upload-artifact') &&
            (s['if']?.toString() ?? '') == 'failure()' &&
            (s['with'] as YamlMap?)?['path']
                    ?.toString()
                    .contains('Logs/gym') ==
                true,
      );
      expect(
        upload,
        hasLength(1),
        reason:
            'exactly one failure-gated artifact upload of '
            '~/Library/Logs/gym/ — the gym log holds the REAL xcodebuild '
            'error, and without it an archive failure is undiagnosable '
            'from GitHub (gh-1692 AC2: no more silent ARCHIVE FAILED)',
      );
    });
  });

  group('AC3 — no single-shot origin transfer in the iOS chain', () {
    for (final job in const ['build-ios', 'submit-ios']) {
      test('$job checkout clone retries a bounded number of times', () {
        final steps = stepsOf(mobile, job);
        final checkout = steps.firstWhere(
          (s) => (s['name']?.toString() ?? '')
              .startsWith('Checkout repository from local mirror'),
        );
        final script = checkout['run'].toString();
        expect(
          script,
          contains('for attempt in'),
          reason:
              'the depth-1 clone pulls tip blobs from origin over the '
              'runner\'s flaky link — the 10-16 submit leg died on '
              '"2876 bytes of body are still expected" (exit 128) with '
              'NO retry and cost a whole TestFlight day (gh-1692 AC3)',
        );
        expect(
          script,
          contains('git clone --reference'),
          reason:
              'the local-mirror clone shape is kept (gh-1600); the retry '
              'wraps it, it does not replace it (gh-1692)',
        );
        expect(
          script,
          contains('CLONE_RETRIES=3'),
          reason:
              'the retry must be BOUNDED and multi-attempt (3 tries) — '
              'a single-shot transfer red the 10-16 submit leg '
              '(gh-1692 AC3)',
        );
        expect(
          script,
          contains(r'[ "$attempt" -eq "$CLONE_RETRIES" ]'),
          reason:
              'retry exhaustion must hard-fail inside the loop — a loop '
              'that falls through after the last failed attempt is not a '
              'retry (gh-1692 AC3)',
        );
        expect(
          script,
          contains('::error::'),
          reason:
              'retry exhaustion must fail loudly with a ::error:: '
              'annotation, never fall through to a later cryptic '
              'failure (gh-1692 AC3)',
        );
        // A failed attempt leaves a partial clone dir behind — the next
        // attempt must clean it or git refuses the non-empty target.
        final forIdx = script.indexOf('for attempt in');
        final cloneIdx = script.indexOf('git clone --reference', forIdx);
        final retryRm = RegExp(r'rm -rf "\$CLONE_TARGET"').allMatches(script);
        expect(
          retryRm.isNotEmpty,
          isTrue,
          reason:
              'a failed clone attempt leaves a partial dir at '
              '\$CLONE_TARGET — the retry loop must remove it before the '
              'next attempt (gh-1692 AC3)',
        );
        expect(
          retryRm.any((m) => m.start > forIdx && m.start > cloneIdx),
          isTrue,
          reason:
              'the partial-dir cleanup must live INSIDE the retry loop '
              '(after the first clone attempt), not before it (gh-1692 '
              'AC3)',
        );
      });
    }

    test('the mirror update itself keeps its bounded retry (gh-1644)', () {
      final steps = stepsOf(mobile, 'submit-ios');
      final mirror = steps.firstWhere(
        (s) => (s['name']?.toString() ?? '') == 'Update local git mirror',
      );
      expect(
        mirror['run'].toString(),
        contains('update_git_mirror.sh'),
        reason:
            'the resilient updater (bounded fetch + recreate retries) '
            'must stay the entry point of the mirror update (gh-1644); '
            'gh-1692 only closes the remaining single-shot clone (gh-1692 '
            'AC3)',
      );
    });
  });
}
