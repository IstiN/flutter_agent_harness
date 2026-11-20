// gh-236 artefact-cache draft lifecycle coverage, split into its own suite
// to keep release_hygiene_test.dart below the whole-tree 2800-line loc
// ratchet (gh-2318 precedent).
//
// The machine loop (dmtools-agents factory: timerAutoCommitAndSave.js →
// releaseArtefacts.uploadRawFile → github_get_or_create_draft_release, tag
// template `ai-{ticketKey}`) writes every fa leg's session/output snapshots
// as assets of a per-ticket DRAFT release `ai-gh-<n>` / `ai-pr-<n>` in this
// repo, created with the ai-teammate token — User-typed, marker-less, no
// Actions run owns it. Those drafts are caches by design (never published),
// but the sweeper's only bucket for them was the generic gh-2287 `bot`
// bucket: swept after 24h AND counted as sweep findings, so normal
// machine-loop traffic perpetually re-filed the sweep issue (gh-2287 →
// gh-2318 → gh-236). The lifecycle the class was missing:
//
//   ticket cycle ENDED (issue/PR closed) → reclaim NOW, any age — not a
//       sweep finding (a closed cycle never resumes; the pack's restore is
//       non-fatal and recreates the cache on "first run");
//   ticket still open, draft >24h (parked leg) → 24h backstop sweep as
//       before — silently, not a finding;
//   ticket open + fresh → kept untouched (an in-flight leg may own it);
//   ticket state UNKNOWN (lookup fails) → fail-safe: no reclaim, only the
//       24h backstop;
//   HUMAN-authored ai-* drafts → never lifecycle-deleted (E1 holds);
//   machine-authored NON-artifact drafts (vX.Y.Z) → remain bot-bucket
//       findings (the guard must not swallow real train drafts).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'release_hygiene_test_support.dart';

void main() {
  group(
    'gh-236 — machine-loop artefact-cache drafts (ai-gh-*/ai-pr-*) have a lifecycle',
    () {
      final freshDate = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String()
          .substring(0, 19);
      const oldDate = '2020-01-01T00:00:00Z';

      Map<String, Object> artDraft(
        String tag,
        int id, {
        String created = oldDate,
        String author = 'ai-teammate',
      }) => {
        'tag_name': tag,
        'id': id,
        'draft': true,
        'created_at': created,
        'author': {'login': author, 'type': 'User'},
        'body': '',
      };

      Map<String, String> fixtures(
        List<Map<String, Object>> drafts, {
        Map<String, String> tickets = const {},
        String openIssuesTsv = '',
      }) => {
        'releases.json': jsonEncode(drafts),
        'issues.tsv': openIssuesTsv,
        'runs.tsv': '',
        ...tickets,
      };

      test('fresh drafts whose ticket cycle has ENDED are reclaimed NOW — '
          'and no sweep issue is filed (not a finding)', () {
        // The exact gh-236 shape: machine-loop caches for ticket gh-2288
        // and PR pr-2293, both cycles closed (PR merged, issue closed by
        // the merge pipeline) — yet both drafts rotted 24h and re-filed
        // the recurring sweep issue.
        final run = runSweeper(
          'art-reclaim-closed',
          fixtures(
            [
              artDraft('ai-gh-2288', 228801, created: '${freshDate}Z'),
              artDraft('ai-pr-2293', 229301, created: '${freshDate}Z'),
            ],
            tickets: {
              'issue-2288.json': '{"state":"closed"}',
              'issue-2293.json': '{"state":"closed"}',
            },
          ),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/228801'),
          reason:
              'a closed-cycle artefact cache is garbage the moment the '
              'cycle ends — reclaim NOW, not at 24h (gh-236)',
        );
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/229301'),
          reason: 'the ai-pr-* sibling cycle is closed too (multi-item)',
        );
        expect(
          run.body,
          isNull,
          reason:
              'reclaiming an ended-cycle cache is routine lifecycle work, '
              'not a stale-draft FINDING — no issue may be filed',
        );
        expect(
          run.log.where((l) => l.contains('issue create')),
          isEmpty,
          reason: 'no dedup issue when the only traffic is cache reclaims',
        );
        expect(
          run.stdoutText,
          contains('ai-gh-2288'),
          reason: 'the job summary names the reclaimed caches',
        );
        expect(
          run.stdoutText,
          isNot(contains('::error::')),
          reason: 'the sweep stays green through the reclaim path',
        );
      });

      test('a fresh closed-cycle cache is reclaimed AND a stale-open sweep '
          'issue AUTO-CLOSES — clean sweep, hygiene noise ends', () {
        final run = runSweeper(
          'art-reclaim-autoclose',
          fixtures(
            [artDraft('ai-gh-2288', 228802, created: '${freshDate}Z')],
            tickets: {'issue-2288.json': '{"state":"closed"}'},
            openIssuesTsv: '12\t[daily-publish] stale release drafts swept\n',
          ),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/228802'),
          reason: 'the closed-cycle cache is reclaimed',
        );
        expect(
          run.log,
          anyElement(contains('issue close')),
          reason:
              'with only cache traffic the sweep is CLEAN — the recurring '
              'issue must auto-close (this is what retires gh-236)',
        );
        expect(
          run.log.where((l) => l.contains('issue create')),
          isEmpty,
          reason: 'a clean sweep never re-files',
        );
      });

      test('a fresh cache draft whose ticket is still OPEN is kept — '
          'an in-flight leg may own it', () {
        final run = runSweeper(
          'art-keep-open-fresh',
          fixtures(
            [artDraft('ai-gh-2219', 221901, created: '${freshDate}Z')],
            tickets: {'issue-2219.json': '{"state":"open"}'},
          ),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          isNot(contains('-X DELETE')),
          reason:
              'an open ticket leg may be writing snapshots right now — '
              'never delete a live cache',
        );
        expect(
          run.body,
          isNull,
          reason: 'a kept cache draft is not a finding either',
        );
      });

      test('a STALE cache draft with the ticket still open is swept as the '
          '24h backstop — silently, not a finding (parked-leg cache)', () {
        final run = runSweeper(
          'art-backstop-open-stale',
          fixtures(
            [artDraft('ai-gh-2208', 220801)],
            tickets: {'issue-2208.json': '{"state":"open"}'},
          ),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/220801'),
          reason:
              'the 24h backstop still applies to parked-leg caches '
              '(gh-2287 semantics preserved)',
        );
        expect(
          run.body,
          isNull,
          reason:
              'a parked cache sweep is routine lifecycle work — it must '
              'not file or keep the sweep issue open',
        );
      });

      test(
        'a STALE cache draft with an UNKNOWN ticket state (lookup fails) is '
        'swept as the backstop — gh-2287 semantics preserved, not a finding',
        () {
          // No issue-210.json fixture → the stub answers {} → unknown.
          final run = runSweeper(
            'art-backstop-unknown-stale',
            fixtures([artDraft('ai-pr-210', 210001)]),
          );
          final logText = run.log.join('\n');
          expect(
            logText,
            contains('api -X DELETE repos/OWNER/REPO/releases/210001'),
            reason:
                'an unresolvable ticket state must not block the existing '
                '24h sweep — it only blocks the early reclaim',
          );
          expect(run.body, isNull, reason: 'not a finding');
        },
      );

      test('a FRESH cache draft with an UNKNOWN ticket state is kept — '
          'never delete blind', () {
        final run = runSweeper(
          'art-keep-unknown-fresh',
          fixtures([artDraft('ai-gh-2314', 231401, created: '${freshDate}Z')]),
        );
        expect(
          run.log.join('\n'),
          isNot(contains('-X DELETE')),
          reason:
              'without a provably ended cycle a fresh cache stays '
              '(fail-safe, mirrors the gh-2318 keep-on-lookup-failure)',
        );
      });

      test('E1 holds: a HUMAN-authored ai-* draft is never lifecycle-deleted, '
          'even with the ticket closed — it stays a listed finding', () {
        final run = runSweeper(
          'art-e1-human',
          fixtures(
            [artDraft('ai-gh-999', 999001, author: 'IstiN')],
            tickets: {'issue-999.json': '{"state":"closed"}'},
          ),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          isNot(contains('-X DELETE')),
          reason:
              'the lifecycle guard is keyed on the machine account — a '
              'human ai-* draft is a human draft (E1: listed, kept)',
        );
        expect(
          run.body,
          isNotNull,
          reason: 'a kept human draft is still a finding (E1 listing)',
        );
        expect(
          run.body,
          contains('ai-gh-999'),
          reason: 'the human draft is listed in the issue (E1)',
        );
      });

      test(
        'a machine-authored NON-artifact draft (vX.Y.Z) remains a bot-bucket '
        'sweep finding — the guard must not swallow train drafts',
        () {
          final run = runSweeper(
            'art-machine-vtag-stays-finding',
            fixtures([artDraft('v1.0.750', 750001)]),
          );
          final logText = run.log.join('\n');
          expect(
            logText,
            contains('api -X DELETE repos/OWNER/REPO/releases/750001'),
            reason:
                'a stale machine-authored vX.Y.Z draft is a release-train '
                'orphan — swept and REPORTED as before (gh-2287 behavior)',
          );
          expect(
            run.body,
            isNotNull,
            reason: 'it IS a finding — the issue is filed',
          );
          expect(run.body, contains('v1.0.750'));
          expect(
            run.body,
            contains('ai-teammate'),
            reason: 'the machine account is named as the creator',
          );
        },
      );

      test('mixed traffic: cache reclaims ride along an issue filed for real '
          'findings, clearly separated from the release-failure sections', () {
        final run = runSweeper(
          'art-mixed',
          fixtures(
            [
              artDraft('ai-gh-2288', 228803, created: '${freshDate}Z'),
              {
                'tag_name': 'v0.2.0',
                'id': 228804,
                'draft': true,
                'created_at': oldDate,
                'author': {'login': 'somehuman', 'type': 'User'},
                'body': 'my WIP draft',
              },
            ],
            tickets: {'issue-2288.json': '{"state":"closed"}'},
          ),
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/228803'),
          reason: 'the closed-cycle cache is reclaimed',
        );
        expect(
          logText,
          isNot(contains('releases/228804')),
          reason: 'the human draft stays kept (E1)',
        );
        expect(
          run.body,
          isNotNull,
          reason: 'the kept human draft is a finding — the issue is filed',
        );
        expect(
          run.body,
          contains('v0.2.0'),
          reason: 'the human finding rides the issue as before',
        );
        expect(
          run.body,
          contains('ai-gh-2288'),
          reason:
              'the cache reclaim is mentioned in the filed issue — visible, '
              'but in its own lifecycle section',
        );
        expect(
          run.body,
          contains('cycle ended'),
          reason: 'the reclaim names the lifecycle reason',
        );
        expect(
          run.body,
          isNot(contains('died between asset upload and publish')),
          reason:
              'the release-failure prose must never be attached to cache '
              'reclaims — nothing died, nothing failed to publish',
        );
      });

      test('the 24h-backstop prose names the swept cohort truthfully — '
          'ticket still open OR its state unknown (lookup failures are '
          'swept too, only the early reclaim is blocked)', () {
        // Review thread (⚠️ IMPORTANT): the prose on the swept lines and
        // the E1 footer described the swept cohort as "ticket still open"
        // while the backstop ALSO sweeps state-UNKNOWN caches — a lookup
        // failure blocks only the EARLY reclaim. An auditor tracing a
        // deleted state-unknown cache must not read a broken keep-promise.
        final run = runSweeper(
          'art-backstop-prose-truthful',
          fixtures([
            artDraft('ai-gh-2208', 220802), // stale, state unknown
            artDraft('ai-pr-210', 210002), // stale, state unknown
            {
              'tag_name': 'v0.2.1',
              'id': 220804,
              'draft': true,
              'created_at': oldDate,
              'author': {'login': 'somehuman', 'type': 'User'},
              'body': 'my WIP draft',
            }, // kept human finding — fires the E1 footer prose
          ]),
        );
        expect(
          run.body,
          contains(
            'swept after 24h with the ticket still open or its state unknown',
          ),
          reason:
              'the swept-cohort prose must include state-UNKNOWN caches — '
              'the backstop deletes them (a lookup failure only blocks the '
              'early reclaim, art-backstop-unknown-stale)',
        );
        expect(
          run.body,
          contains(
            'swept after 24h when the ticket stays open or its state is '
            'unknown',
          ),
          reason: 'the E1-footer prose carries the same carve-out',
        );
        final logText = run.log.join('\n');
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/220802'),
          reason:
              'backstop sweeps the stale state-unknown cache — behavior '
              'unchanged, prose truthful (gh-2287 semantics preserved)',
        );
        expect(
          logText,
          contains('api -X DELETE repos/OWNER/REPO/releases/210002'),
          reason:
              'multi-item: the ai-pr-* sibling is swept by the backstop too',
        );
        expect(
          logText,
          isNot(contains('releases/220804')),
          reason: 'the human draft stays kept (E1)',
        );
      });

      test('docs/ci.md states the lookup-failure carve-out exactly as '
          'implemented — kept, then only the 24h backstop applies', () {
        // Review thread (⚠️ IMPORTANT): docs/ci.md promised "kept on ANY
        // ticket-state lookup failure" while the implemented — and tested
        // — behavior is narrower: the failure blocks only the EARLY
        // reclaim; a stale (>24h) cache is still deleted by the 24h
        // backstop. The doc sentence must mirror the script header so an
        // auditor tracing a deleted state-unknown cache reads the
        // carve-out, not a broken keep-promise.
        final docs = File(
          'docs/ci.md',
        ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
        expect(
          docs,
          contains(
            'kept on any ticket-state lookup failure (never delete blind) '
            '— only the 24h backstop then applies',
          ),
          reason:
              'the artefact-cache doc sentence must carry the backstop '
              'carve-out, mirroring the scripts/sweep_stale_drafts.sh '
              'header',
        );
        expect(
          docs,
          isNot(contains('kept on ANY ticket-state lookup failure')),
          reason:
              'the unqualified keep-promise (the pre-rework wording) must '
              'be gone — it contradicts art-backstop-unknown-stale',
        );
      });

      test('the gh stub requires the issues scope for api .../issues/<n> — '
          'a dropped issues: grant fails loud, not silent', () {
        // Review thread (💡 SUGGESTION): the stub mapped EVERY `gh api`
        // call to need=contents, so the per-ticket cycle-state lookup
        // (repos/<o>/<r>/issues/<n>) passed enforcement even though
        // production needs the issues scope — a dropped issues: grant
        // stayed green while production 403s every lookup and the early
        // reclaim silently dies. Mirror the #294 precedent the stub
        // comment cites: scope follows the resource path.
        final dir = Directory(
          '${hygieneFixtureRoot.path}/stub-issues-scope-'
          '${DateTime.now().microsecondsSinceEpoch}',
        )..createSync(recursive: true);
        final bin = stubGh(dir.path);
        Map<String, String> probeEnv() => {
          'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
          'GH_STUB_PERMISSIONS': 'contents',
          'GH_LOG_FILE': '${dir.path}/log',
          'GH_STUB_DIR': dir.path,
        };
        final probe = Process.runSync('$bin/gh', [
          'api',
          'repos/OWNER/REPO/issues/228',
        ], environment: probeEnv());
        expect(
          probe.exitCode,
          1,
          reason:
              'api repos/*/issues/<n> maps to the issues scope — the stub '
              'must 403 when only contents is granted (#294 precedent)',
        );
        expect(
          probe.stderr,
          contains("needs 'issues'"),
          reason:
              "the 403 names the missing scope, like every other "
              "stub enforcement",
        );
        // api repos/*/releases/* stays contents (the lookup tightening
        // must not disturb the release-path calls).
        final releasesProbe = Process.runSync('$bin/gh', [
          'api',
          '-X',
          'DELETE',
          'repos/OWNER/REPO/releases/9',
        ], environment: probeEnv());
        expect(
          releasesProbe.exitCode,
          0,
          reason:
              'the -X DELETE releases path keeps need=contents — deleting '
              'draft releases is the contents grant, unchanged',
        );
        // End-to-end: with only contents granted the lookup 403s → state
        // unknown → the fail-safe keep blocks the early reclaim (visible
        // here; before the tightening this run silently reclaimed).
        final run = runSweeper(
          'art-no-issues-grant-failsafe',
          fixtures(
            [artDraft('ai-gh-228', 228005, created: '${freshDate}Z')],
            tickets: {'issue-228.json': '{"state":"closed"}'},
          ),
          extraEnv: {'GH_STUB_PERMISSIONS': 'contents'},
        );
        expect(
          run.log.join('\n'),
          isNot(contains('-X DELETE repos/OWNER/REPO/releases/228005')),
          reason:
              'lookup 403 → state unknown → never reclaim blind; every '
              'other runSweper test enforces the real workflow grant',
        );
        expect(
          run.stdoutText,
          isNot(contains('::error::')),
          reason:
              'the fail-safe keep stays green — the dropped grant fails '
              'the permission probe above, not the sweep',
        );
      });
    },
  );
}
