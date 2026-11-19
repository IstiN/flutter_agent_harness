// gh-2318 fresh-draft reclaim coverage, split from release_hygiene_test.dart
// to keep both suites below the whole-tree 2800-line loc ratchet.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'release_hygiene_test_support.dart';

void main() {
  // ── gh-2318 — sweep reclaims never-publishable fresh drafts ──────────────
  // v1.0.739 shape: a daily-child draft-staging leg mints the tag
  // (release_tag_mint.sh) + stages the draft, then the freshly fired tag
  // train fails upstream of release-provenance. When that happens the
  // gh-2230 train-draft-guard either has not run yet (draft created after
  // the guard — long attach legs) or kept the draft (owner run in-flight at
  // train end) — and the 24h sweeper was the ONLY remaining net, re-filing
  // the recurring sweep issue a day later. The sweep itself must apply the
  // gh-2230 criterion: a FRESH draft is reclaimable NOW when its ownership
  // marker names a COMPLETED run and the tag's newest concluded ci.yml push
  // train failed with release-provenance SKIPPED (rerun --failed cannot
  // resurrect skipped jobs — nobody will ever publish it). Everything else
  // keeps current semantics: unmarked/human fresh drafts untouched (E1),
  // in-flight owner untouched (mid-upload fail-safe), FAILED provenance is
  // the rerunnable rerun --failed recovery vessel (gh-1899 — waits for the
  // 24h sweep), any lookup failure keeps (never delete blind).
  group(
    'gh-2318 — sweep reclaims never-publishable fresh drafts (failed train)',
    () {
      final freshDate = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String()
          .substring(0, 19);
      Map<String, Object> freshMarkerDraft(String tag, int id) => {
        'tag_name': tag,
        'id': id,
        'draft': true,
        'created_at': '${freshDate}Z',
        'author': {'login': 'IstiN', 'type': 'User'},
        'body':
            'Release $tag\n'
            '<!-- release-draft-owner: run/427501287/job/release-macos -->',
      };
      final trainUrl = 'https://github.com/OWNER/REPO/actions/runs/44024131629';
      // The failed v1.0.739 train shape: core tests + quality gate red,
      // release-provenance ("Sign release checksums") SKIPPED — the publish
      // point is unreachable, rerun --failed never resurrects it.
      const deadTrainJobs = {
        'jobs': [
          {'name': 'Core tests (shard 3/4)', 'conclusion': 'failure'},
          {'name': 'Quality gate', 'conclusion': 'failure'},
          {'name': 'Sign release checksums', 'conclusion': 'skipped'},
          {'name': 'Advance vpinned marker', 'conclusion': 'failure'},
        ],
      };
      Map<String, String> fixtures({
        String trainRuns = '',
        String trainJobs = '',
        String runStatus = '',
      }) => {
        'issues.tsv': '',
        'runs.tsv': '',
        if (trainRuns.isNotEmpty) 'train-runs.json': trainRuns,
        if (trainJobs.isNotEmpty) 'train-jobs.json': trainJobs,
        if (runStatus.isNotEmpty) 'run-status.json': runStatus,
      };

      test(
        'a fresh marker draft whose owner completed and whose train failed with '
        'skipped provenance is reclaimed NOW (multi-item: twins share the tag)',
        () {
          final run = runSweeper(
            'reclaim-fresh',
            fixtures(
                trainRuns: jsonEncode([
                  {
                    'databaseId': 44024131629,
                    'conclusion': 'failure',
                    'url': trainUrl,
                  },
                ]),
                trainJobs: jsonEncode(deadTrainJobs),
              )
              ..['releases.json'] = jsonEncode([
                freshMarkerDraft('v1.0.739', 739001),
                freshMarkerDraft('v1.0.739', 739002),
              ]),
          );
          final logText = run.log.join('\n');
          expect(
            logText,
            contains('api -X DELETE repos/OWNER/REPO/releases/739001'),
            reason:
                'the fresh draft is provably never-publishable (owner '
                'completed, train failed with skipped provenance) — the '
                'sweep must reclaim it NOW, not at 24h (gh-2318)',
          );
          expect(
            logText,
            contains('api -X DELETE repos/OWNER/REPO/releases/739002'),
            reason: 'the gh-1899 twin must be reclaimed too (multi-item)',
          );
          expect(run.body, isNotNull, reason: 'the sweep issue is still filed');
          expect(
            run.body,
            contains('v1.0.739'),
            reason: 'the reclaimed draft is named in the issue',
          );
          expect(
            run.body,
            contains('actions/runs/44024131629'),
            reason: 'the failed train is named — it is the broken step',
          );
          expect(
            run.body,
            contains('concluded failure'),
            reason: 'the train conclusion rides the issue',
          );
          expect(
            run.body,
            contains('Core tests (shard 3/4)'),
            reason: 'the failed jobs ride the issue (gh-2105 diagnosis)',
          );
          expect(
            run.body,
            contains('Reclaimed early'),
            reason:
                'the reclaim must be visible as an early (<24h) action, '
                'distinct from the stale >24h sweep deletions',
          );
          expect(
            run.body,
            contains('publish point is unreachable'),
            reason: 'the reclaim reason is stated in the issue',
          );
          expect(
            run.body,
            isNot(contains('died between asset upload and publish')),
            reason:
                'the generic create-death prose must NOT fire when the '
                'real blocker is the failed train',
          );
          expect(
            run.stdoutText,
            contains('reclaimed-early=v1.0.739'),
            reason: 'the job summary line names the early reclaims',
          );
          expect(
            run.stdoutText,
            isNot(contains('::error::')),
            reason: 'the sweep stays green through the reclaim path',
          );
        },
      );

      test('a fresh marker draft whose owner run is STILL IN-FLIGHT is kept '
          '(mid-upload fail-safe — the 24h sweep remains the backstop)', () {
        final run = runSweeper(
          'reclaim-inflight',
          fixtures(
              trainRuns: jsonEncode([
                {
                  'databaseId': 44024131629,
                  'conclusion': 'failure',
                  'url': trainUrl,
                },
              ]),
              trainJobs: jsonEncode(deadTrainJobs),
              runStatus: '{"status":"in_progress"}',
            )
            ..['releases.json'] = jsonEncode([
              freshMarkerDraft('v1.0.739', 739003),
            ]),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          isNot(contains('-X DELETE')),
          reason:
              'an in-flight owner run may still be attaching assets — '
              'never delete a possibly mid-upload draft',
        );
        expect(run.log.where((l) => l.contains('--workflow')), isEmpty);
      });

      test('a fresh marker draft whose tag has an in-flight train newer than '
          'a failed train is kept — the live train may still publish it', () {
        final run = runSweeper(
          'reclaim-newer-train-inflight',
          fixtures(
              trainRuns: jsonEncode([
                {
                  'databaseId': 44024131631,
                  'conclusion': null,
                  'url': trainUrl,
                },
                {
                  'databaseId': 44024131629,
                  'conclusion': 'failure',
                  'url': trainUrl,
                },
              ]),
              trainJobs: jsonEncode(deadTrainJobs),
            )
            ..['releases.json'] = jsonEncode([
              freshMarkerDraft('v1.0.739', 739008),
            ]),
        );
        expect(
          run.log.join('\n'),
          isNot(contains('-X DELETE')),
          reason:
              'the older failed train does not own the draft exclusively — '
              'the newer in-flight train may still publish it, so the fresh '
              'reclaim must keep it regardless of the skipped provenance '
              'diagnosis from the older run',
        );
      });

      test('a fresh marker draft whose train failed but provenance FAILED '
          '(rerunnable) is kept — it is the rerun --failed recovery vessel '
          '(gh-1899 convention)', () {
        final rerunnableJobs = {
          'jobs': [
            {'name': 'Quality gate', 'conclusion': 'failure'},
            {'name': 'Sign release checksums', 'conclusion': 'failure'},
          ],
        };
        final run = runSweeper(
          'reclaim-rerunnable',
          fixtures(
              trainRuns: jsonEncode([
                {
                  'databaseId': 44024131629,
                  'conclusion': 'failure',
                  'url': trainUrl,
                },
              ]),
              trainJobs: jsonEncode(rerunnableJobs),
            )
            ..['releases.json'] = jsonEncode([
              freshMarkerDraft('v1.0.739', 739004),
            ]),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          isNot(contains('-X DELETE')),
          reason:
              'a FAILED provenance IS rerunnable — the staged draft stays '
              'as the rerun --failed recovery vessel until the 24h sweep '
              '(gh-1899 convention, same criterion as the train guard)',
        );
      });

      test('a fresh marker draft with NO failed train (green or in-flight) is '
          'kept — ordinary fresh semantics', () {
        // Green train.
        final green = runSweeper(
          'reclaim-green-train',
          fixtures(
              trainRuns: jsonEncode([
                {
                  'databaseId': 44024131630,
                  'conclusion': 'success',
                  'url': trainUrl,
                },
              ]),
              trainJobs: jsonEncode(deadTrainJobs),
            )
            ..['releases.json'] = jsonEncode([
              freshMarkerDraft('v1.0.739', 739005),
            ]),
        );
        expect(
          green.log.join('\n'),
          isNot(contains('-X DELETE')),
          reason: 'a green train may still publish the draft — untouched',
        );
        // Train still in flight (conclusion null) — no concluded failure.
        final inFlightTrain = runSweeper(
          'reclaim-train-inflight',
          fixtures(
              trainRuns: jsonEncode([
                {
                  'databaseId': 44024131631,
                  'conclusion': null,
                  'url': trainUrl,
                },
              ]),
              trainJobs: jsonEncode(deadTrainJobs),
            )
            ..['releases.json'] = jsonEncode([
              freshMarkerDraft('v1.0.739', 739006),
            ]),
        );
        expect(
          inFlightTrain.log.join('\n'),
          isNot(contains('-X DELETE')),
          reason:
              'a train that has not concluded cannot be diagnosed as dead — '
              'the draft stays with its in-flight owner',
        );
      });

      test('an undiagnosable publish point (provenance job absent from the '
          'train jobs) keeps the draft — never delete blind', () {
        final run = runSweeper(
          'reclaim-failsafe',
          fixtures(
              trainRuns: jsonEncode([
                {
                  'databaseId': 44024131629,
                  'conclusion': 'failure',
                  'url': trainUrl,
                },
              ]),
              trainJobs: jsonEncode({
                'jobs': [
                  {'name': 'Quality gate', 'conclusion': 'failure'},
                ],
              }),
            )
            ..['releases.json'] = jsonEncode([
              freshMarkerDraft('v1.0.739', 739007),
            ]),
        );
        expect(
          run.log.join('\n'),
          isNot(contains('-X DELETE')),
          reason:
              'without a provable SKIPPED publish point the reclaim must '
              'not fire — fail-safe keeps, the 24h sweeper backstops',
        );
      });

      test('static pin: the sweep matches the publish point by its ci.yml job '
          'name — a rename must break this test, not production silently', () {
        final ci = jobsOf('.github/workflows/ci.yml');
        final prov = ci['release-provenance'] as YamlMap;
        expect(
          prov['name'],
          equals('Sign release checksums'),
          reason:
              'sweep_stale_drafts.sh identifies the publish point by this '
              'exact job name when deciding the reclaim (gh-2318) — update '
              'both together',
        );
      });
    },
  );
}
