// gh-1724 — the `test-core` shard jobs' artifact uploads ride the same
// bounded one-shot retry the pty leg got in gh-1412.
//
// CI run 39432336443 (tag v1.0.611) red'd `Core tests (shard 3/4)` with
// every shard test GREEN: the `junit-shard-3` upload died with
// `Failed to FinalizeArtifact: Received non-retryable error: Failed
// request: (404) Not Found: artifact not found` — one transient error on
// GitHub's blob-storage finalize call failed the shard, the aggregate
// Quality gate followed (`Quality gate FAILED: a leg is failure
// (test-core)`), and the whole release run went red. This is the same
// failure class gh-1412 fixed for the pty-integration-linux leg (run
// 37807820733, ECONNRESET at finalize, 68/68 tests green) — but the
// `test-core` evidence uploads (`coverage-shard-N`, `junit-shard-N`)
// never got the companion retry. The retry is the follow-up step
// re-running the SAME pinned upload-artifact action: the failed attempt
// leaves the artifact half-registered, so the retry must carry
// `overwrite: true` (with the default `overwrite: false` the retry dies
// on "already exists" and guards nothing); a genuinely dead endpoint
// still fails the shard loudly.
//
// Deliberately YAML-level asserts (the ci_pty_artifact_upload_retry_guard_test.dart
// / ci_pub_get_retry_guard_test.dart static pattern):
//  AC1  every primary upload-artifact step in `test-core` carries an `id`
//       — the retry references it,
//  AC2  each primary upload is followed by a retry step running the SAME
//       digest pin with `overwrite: true` and the same artifact name,
//       gated on `steps.<id>.outcome == 'failure'` — a transient finalize
//       failure gets one more attempt, a real failure still reds the
//       shard loudly,
//  AC3  the retries stay `always()`-reachable (the uploads exist so the
//       coverage merge and the weekly rebalancer keep their evidence; a
//       retry keyed without `always()` would be skipped outright after a
//       failed step) and never `continue-on-error` (a dead blob endpoint
//       must still fail the shard — the coverage gate merges these
//       lcovs).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const coreJobId = 'test-core';

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

List<YamlMap> jobSteps(String jobId) {
  final root = loadYaml(read(ci)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[jobId];
  if (job is! YamlMap) throw StateError('job $jobId missing from $ci');
  return (job['steps'] as YamlList).whereType<YamlMap>().toList();
}

void main() {
  group('gh-1724 — test-core artifact uploads ride a retry', () {
    final steps = jobSteps(coreJobId);
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

    test('the leg carries the two evidence uploads and their retries', () {
      expect(
        primaries,
        hasLength(2),
        reason:
            'coverage-shard, junit-shard — the guards below '
            'key on exactly these',
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

    test('AC2: each primary upload is followed by an overwrite:true retry', () {
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
    });

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
                'loudly — the coverage merge asserts on these artifacts',
          );
        }
      },
    );

    test('primaries keep their scope gate, retries keep the same scope', () {
      // test-core's uploads only run for core/shared changes (the scope
      // fastpass green-skips the rest) — the retries must not widen that
      // scope.
      for (final step in primaries) {
        expect(
          step['if']?.toString(),
          contains("needs.changes.outputs.core == 'true'"),
          reason: 'test-core uploads keep the core/shared scope gate',
        );
      }
      for (final retry in retries) {
        expect(
          retry['if']?.toString(),
          contains("needs.changes.outputs.core == 'true'"),
          reason:
              'the retry inherits the primary scope — it must never upload '
              'outside the core/shared scope the fastpass skipped',
        );
      }
    });
  });
}
