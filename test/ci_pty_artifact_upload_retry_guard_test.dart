// gh-1412 — the PTY/CLI integration leg's `if: always()` artifact uploads
// ride a bounded one-shot retry.
//
// The gh-1412 validation run 37807820733 went red on a head whose 68 shard
// tests ALL passed: the `integration-json-shard-0` upload died with
// `Failed to FinalizeArtifact: Unable to make request: ECONNRESET` — one
// transient reset on GitHub's blob-storage finalize call failed the job,
// the aggregate Quality gate followed, and the machine merge aborted. The
// same class already has house precedent: gh-1310 ("Connection reset by
// peer" kills a green leg → shared bounded-retry action) and the
// step-timings leg ("a single 502 failed the whole telemetry leg" →
// 3-attempt retry loop). An actions/upload-artifact step cannot loop on
// itself, so the bounded retry here is a follow-up step re-running the
// SAME pinned action: upload-artifact registers the artifact before
// finalize, so the retry must carry `overwrite: true` (the half-registered
// artifact from the failed attempt is deleted and re-uploaded — with the
// default `overwrite: false` the retry would die on "already exists" and
// guard nothing).
//
// Deliberately YAML-level asserts (the ci_pub_get_retry_guard_test.dart /
// nightly_desktop_leg_guard_test.dart static pattern):
//  AC1  every primary upload-artifact step in `pty-integration-linux`
//       carries an `id` — the retry references it,
//  AC2  each primary upload is followed by a retry step running the SAME
//       digest pin with `overwrite: true` and the same artifact name,
//       gated on `steps.<id>.outcome == 'failure'` — a transient reset
//       gets one more attempt, a real failure still reds the leg loudly,
//  AC3  the retries stay `if: always()`-reachable (the evidence uploads
//       exist precisely so red legs keep their timing/coverage evidence —
//       a retry keyed on plain `failure()` would never run on the red
//       legs the evidence is for), and never `continue-on-error` (a dead
//       blob endpoint must still fail the shard, not drop the evidence
//       the gate below asserts on).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const ptyJobId = 'pty-integration-linux';

/// The digest pin every upload-artifact step (retry included) must carry —
/// the same line test/release_hygiene_test.dart pins repo-wide (gh-995:
/// the gate's download-artifact digest-validates every download).
const artifactPin =
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a';

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
  group('gh-1412 — pty-integration-linux artifact uploads ride a retry', () {
    final steps = jobSteps(ptyJobId);
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

    test('the leg carries the three evidence uploads and their retries', () {
      expect(
        primaries,
        hasLength(3),
        reason:
            'integration-json, junit, pty-coverage — the guards below '
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
              'the gate below downloads',
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
                'the gh-1412 retries must stay reachable on red legs — '
                'the evidence uploads run if: always() so a red run keeps '
                'its timing/coverage evidence (the retry inherits that '
                'contract)',
          );
          expect(
            retry['continue-on-error'],
            isNot(true),
            reason:
                'a genuinely dead blob endpoint must still fail the shard '
                'loudly — the pty-coverage-gate asserts on these artifacts',
          );
        }
      },
    );
  });
}
