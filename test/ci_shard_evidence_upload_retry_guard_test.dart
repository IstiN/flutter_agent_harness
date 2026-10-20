// gh-1724 review follow-up — the remaining sharded evidence legs ride the
// gh-1412 one-shot retry.
//
// The gh-1724 fix gave `test-core`'s shard uploads the gh-1412 companion
// retry; the automated review flagged that `test-faui` (fa_ui tests,
// matrix ×3) still uploads `faui-coverage-shard-N` / `junit-faui-shard-N`
// with no step ids and no retries — its merge gate (`faui-coverage`)
// hard-fails on `count != 3`, so a single transient
// `Failed to FinalizeArtifact` from GitHub's blob storage can still red a
// `v*` tag run through the faui leg (the exact gh-1724 failure class: run
// 39432336443 red'd shard 3 with every test GREEN). The same sweep applies
// to `flutter-tests` (matrix ×2): its `app-coverage-shard-N` upload feeds
// `app-crap-gate`'s `count != 2` merge — identical class, identical
// exposure. This guard pins the gh-1412 retry shape on both legs:
//  AC1  every primary upload-artifact step carries an `id` — the retry
//       references it,
//  AC2  each primary upload is followed by a retry step running the SAME
//       digest pin with `overwrite: true`, the same artifact name, the
//       same `path` and the same `retention-days`, gated on
//       `steps.<id>.outcome == 'failure'` — a transient finalize failure
//       gets one more attempt, a real failure still reds the shard
//       loudly. `path` matters as much as the name: a drifted retry path
//       would upload wrong/empty content under the correct artifact name
//       and silently poison what the merge gates download,
//  AC3  the retries stay `always()`-reachable and never
//       `continue-on-error` (a dead blob endpoint must still fail the
//       shard — the merge gates hard-count these artifacts),
//  AC4  the scope stays with the job-level gate (app/core/shared +
//       release pending/dedupe) — these legs' primaries carry no
//       step-level `if`, so the job `if` scopes every step including the
//       retries.
//
// Deliberately YAML-level asserts (the ci_core_shard_upload_retry_guard_test.dart
// / ci_pty_artifact_upload_retry_guard_test.dart static pattern).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';

/// The digest pin every upload-artifact step (retry included) must carry —
/// the same line test/release_hygiene_test.dart pins repo-wide (gh-995:
/// the gate's download-artifact digest-validates every download).
const artifactPin =
    'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9';

bool isUploadStep(YamlMap step) =>
    (step['uses']?.toString() ?? '').startsWith('actions/upload-artifact@');

/// A gh-1412 retry step: keyed on the primary upload's failed outcome.
bool isRetryStep(YamlMap step) =>
    (step['if']?.toString() ?? '').contains("outcome == 'failure'");

YamlMap job(String jobId) {
  final root = loadYaml(read(ci)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[jobId];
  if (job is! YamlMap) throw StateError('job $jobId missing from $ci');
  return job;
}

List<YamlMap> jobSteps(String jobId) =>
    (job(jobId)['steps'] as YamlList).whereType<YamlMap>().toList();

void main() {
  // jobId → how many primary evidence uploads the leg carries.
  final legs = <String, int>{
    'test-faui': 2, // faui-coverage-shard-N, junit-faui-shard-N
    'flutter-tests': 1, // app-coverage-shard-N
  };

  legs.forEach((jobId, primaryCount) {
    group('gh-1724 follow-up — $jobId artifact uploads ride a retry', () {
      final steps = jobSteps(jobId);
      // Primary uploads only — the retries are keyed on a failed outcome,
      // a primary upload never is.
      final primaries = [
        for (final step in steps)
          if (isUploadStep(step) && !isRetryStep(step)) step,
      ];
      final retries = [
        for (final step in steps)
          if (isUploadStep(step) && isRetryStep(step)) step,
      ];

      test('the leg carries the evidence uploads and their retries', () {
        expect(
          primaries,
          hasLength(primaryCount),
          reason: 'the guards below key on exactly these',
        );
        expect(
          retries,
          hasLength(primaries.length),
          reason: 'every primary upload gets its one-shot gh-1412 retry',
        );
      });

      test(
        'AC1: every primary upload step carries an id the retry references',
        () {
          for (final step in primaries) {
            expect(
              step['id'],
              isA<String>(),
              reason:
                  'primary upload step "${step['name'] ?? step['uses']}" '
                  'lost its id — the gh-1412 retry keys on '
                  'steps.<id>.outcome',
            );
          }
        },
      );

      test(
        'AC2: each primary upload is followed by an overwrite:true retry',
        () {
          for (var i = 0; i < steps.length; i++) {
            final step = steps[i];
            if (!isUploadStep(step) || isRetryStep(step)) continue;
            final id = step['id'] as String;
            expect(
              i + 1,
              lessThan(steps.length),
              reason: 'primary upload "$id" has no retry step after it',
            );
            final retry = steps[i + 1];
            expect(
              isUploadStep(retry) && isRetryStep(retry),
              isTrue,
              reason:
                  'the step after primary upload "$id" must be its '
                  'gh-1412 retry (an upload-artifact step keyed on '
                  "steps.$id.outcome == 'failure')",
            );
            expect(
              retry['uses'],
              artifactPin,
              reason:
                  'the retry of "$id" must ride the same digest-validating '
                  'upload-artifact line (gh-995 pin, release_hygiene_test.dart)',
            );
            expect(
              retry['if']?.toString(),
              contains("steps.$id.outcome == 'failure'"),
              reason: 'the retry of "$id" must fire only on the failed upload',
            );
            expect(
              (retry['with'] as YamlMap)['overwrite'],
              true,
              reason:
                  'the retry of "$id" must overwrite the half-registered '
                  'artifact a finalize-class failure leaves behind — with the '
                  'default overwrite:false the retry dies on "already exists"',
            );
            expect(
              (retry['with'] as YamlMap)['name'],
              (step['with'] as YamlMap)['name'],
              reason:
                  'the retry of "$id" must re-upload the SAME artifact name '
                  'the coverage merge / rebalancer downloads',
            );
            expect(
              (retry['with'] as YamlMap)['path'],
              (step['with'] as YamlMap)['path'],
              reason:
                  'the retry of "$id" must re-upload the SAME path '
                  'the coverage merge / rebalancer reads — a drifted path '
                  'would upload wrong/empty content under the correct '
                  'artifact name and silently poison the evidence',
            );
            expect(
              (retry['with'] as YamlMap)['retention-days'],
              (step['with'] as YamlMap)['retention-days'],
              reason:
                  'the retry of "$id" must keep the SAME retention-days — '
                  'a re-upload that outlives (or dies before) the window '
                  'its consumer expects silently shifts the evidence contract',
            );
          }
        },
      );

      test(
        'AC3: retries stay always()-reachable and never continue-on-error',
        () {
          for (final retry in retries) {
            expect(
              retry['if']?.toString(),
              contains('always()'),
              reason:
                  'the gh-1724 retries must stay reachable after a failed '
                  'upload step — without always() GitHub skips every later '
                  'step of a failing job and the retry would never fire',
            );
            expect(
              retry['continue-on-error'],
              isNot(true),
              reason:
                  'a genuinely dead blob endpoint must still fail the shard '
                  'loudly — the merge gates hard-count these artifacts',
            );
          }
        },
      );

      test(
        'AC4: the job-level gate still scopes every upload (incl. retries)',
        () {
          final jobIf = job(jobId)['if']?.toString() ?? '';
          expect(
            jobIf,
            contains("needs.changes.outputs.app == 'true'"),
            reason:
                '$jobId uploads (primaries and retries) are scoped by the '
                'job-level gate — these legs carry no step-level `if`, so '
                'the job `if` is what keeps the retries inside the '
                'app/core/shared scope the fastpass skipped',
          );
          expect(
            jobIf,
            contains("needs.release-pending.outputs.pending == 'true'"),
            reason:
                '$jobId is a release leg — the pending gate must keep '
                'scoping its evidence uploads',
          );
        },
      );
    });
  });
}
