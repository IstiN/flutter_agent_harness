// Issue #282 release-hygiene guards (AC1/AC2/AC3/AC4/AC5) + review of
// #294 hardening + gh-1172/gh-1522: static lint over the workflows/scripts
// plus behavioral tests of the release lifecycle scripts (notes generation,
// ownership-scoped draft guard, race-idempotent attach-or-create, daily
// sweeper, and the gh-1522 TAG-ONLY auto-release: latest tag + 1 →
// `git tag -a` on origin/main → push the tag → `gh release create`, with
// ZERO commits landing on main) against fixture git repos and a stubbed
// `gh` (same style as store_automation_guard_test.dart). The stub enforces
// the GITHUB_TOKEN permissions declared in the workflows, so a missing
// grant fails tests instead of silently killing a production feature.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'release_hygiene_test_support.dart';

void main() {
  // ── AC1 — draft lifecycle invariant (UT-lifecycle) ──────────────────────
  group('AC1 — every draft-capable create has a failure-path guard', () {
    for (final wf in [
      '.github/workflows/build-macos.yml',
      '.github/workflows/build-mobile.yml',
      '.github/workflows/ci.yml',
    ]) {
      test('$wf: asset-carrying create -> guard step in the same job', () {
        final jobs = jobsOf(wf);
        var checked = 0;
        bool draftCapable(dynamic job) {
          // A job is draft-capable when it creates a release with assets —
          // inline, routed through release_attach_or_create.sh (whose
          // create uploads through a draft), or via the gh-1801 lazy draft
          // helper (release_lazy_draft.sh).
          if (job is! Map || !job.containsKey('steps')) return false;
          // continue-on-error jobs (ci.yml web-spa) must NOT guard: on
          // failure the train CONTINUES and needs the draft alive; a true
          // orphan is reclaimed by the 24h sweeper.
          if ((job['continue-on-error']?.toString() ?? 'false') == 'true') {
            return false;
          }
          for (final step in (job['steps'] as YamlList)) {
            if (step is YamlMap && step.containsKey('run')) {
              final run = step['run'].toString();
              if (run.contains('release_attach_or_create.sh')) return true;
              if (run.contains('release_lazy_draft.sh')) return true;
              if (extractCreates(run).any((c) => c.carriesAssets)) return true;
            }
          }
          return false;
        }

        jobs.forEach((jobId, job) {
          if (!draftCapable(job)) return;
          checked++;
          expect(
            draftGuardSteps(job),
            isNotEmpty,
            reason:
                '$wf job "$jobId" creates release with assets '
                '(gh uploads them through a draft) but has no always()/failure() '
                'draft-deletion guard step in the same job',
          );
        });
        expect(
          checked,
          greaterThan(0),
          reason: 'lint must find the known asset-carrying creates',
        );
      });
    }

    test(
      'lint is real: a fixture job that creates a draft and dies is flagged',
      () {
        final fixture = loadYaml(r'''
jobs:
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: create
        run: |
          gh release create "$RELEASE_TAG" \
            --title "$RELEASE_TAG" \
            fa-binary.zip
      - name: upload
        run: exit 1
  good:
    runs-on: ubuntu-latest
    steps:
      - name: create
        run: |
          gh release create "$RELEASE_TAG" \
            --title "$RELEASE_TAG" \
            fa-binary.zip
      - name: Draft lifecycle guard
        if: always() && job.status != 'success'
        run: bash scripts/release_draft_guard.sh "$RELEASE_TAG"
''');
        expect(draftGuardSteps(fixture['jobs']['bad']), isEmpty);
        expect(jobCreates(fixture['jobs']['bad']).single.carriesAssets, isTrue);
        expect(draftGuardSteps(fixture['jobs']['good']), isNotEmpty);
      },
    );

    test('AC6: ci.yml tag-publish path stays draft-capable only via the lazy draft helper', () {
      // gh-1801 rework: ci.yml has NO inline creates anymore — the lazy
      // draft create lives in scripts/release_lazy_draft.sh (curated
      // notes + ownership marker) and the failure-path guard lives in
      // the binaries job itself (AC1).
      final jobs = jobsOf('.github/workflows/ci.yml');
      var creates = 0;
      jobs.forEach((_, job) => creates += jobCreates(job).length);
      expect(
        creates,
        0,
        reason: 'ci.yml must not inline `gh release create` (gh-1801 rework)',
      );
      var helperCalls = 0;
      jobs.forEach((_, job) {
        if (job is! Map || !job.containsKey('steps')) return;
        for (final step in (job['steps'] as YamlList)) {
          if (step is YamlMap &&
              step['run'].toString().contains('release_lazy_draft.sh')) {
            helperCalls++;
          }
        }
      });
      expect(
        helperCalls,
        greaterThan(0),
        reason:
            'the binaries/web-spa upload steps must route their '
            'draft-first create through release_lazy_draft.sh',
      );
    });

    test(
      'guard script: deletes own draft, spares published/missing releases',
      () {
        for (final state in ['true', 'false', 'missing']) {
          final run = runGuard(
            'states-$state',
            state,
            body: '<!-- release-draft-owner: run/111/job/release-macos -->',
          );
          if (state == 'true') {
            expect(
              run.log,
              contains('release delete v1.2.3 --repo OWNER/REPO --yes'),
              reason: 'own draft must be deleted',
            );
          } else {
            expect(
              run.log.where((l) => l.contains('delete')),
              isEmpty,
              reason: 'state $state must not delete',
            );
          }
        }
      },
    );

    test('ownership: a failed leg cannot delete the sibling leg\'s mid-upload draft', () {
      // daily-publish runs the macOS and mobile legs concurrently on the
      // same derived tag: build-mobile run 999 is mid-upload (its draft is
      // stamped run/999/job/release-mobile) when build-macos run 111 fails
      // and its guard fires — it must refuse, not destroy the sibling.
      final run = runGuard(
        'sibling',
        'true',
        body: '<!-- release-draft-owner: run/999/job/release-mobile -->',
        runId: '111',
        job: 'release-macos',
      );
      expect(
        run.log.where((l) => l.contains('release delete')),
        isEmpty,
        reason: 'a draft owned by another run+job must never be deleted',
      );
      expect(run.exitCode, 0, reason: 'refusal is a warning, not a failure');
      expect(
        run.out,
        contains('refusing'),
        reason: 'the refusal must be visible in the job log',
      );
      expect(
        run.out,
        contains('run/999/job/release-mobile'),
        reason: 'the warning must name the actual owner',
      );
    });

    test(
      'ownership: a cross-job draft within the same run is still refused',
      () {
        // build-macos run 111 has three draft-capable jobs; release-linux's
        // guard must not delete release-macos's draft from the same run.
        final run = runGuard(
          'cross-job',
          'true',
          body: '<!-- release-draft-owner: run/111/job/release-macos -->',
          runId: '111',
          job: 'release-linux',
        );
        expect(run.log.where((l) => l.contains('release delete')), isEmpty);
        expect(run.out, contains('refusing'));
      },
    );

    test(
      'ownership: an unmarked draft (legacy/foreign) is left to the sweeper',
      () {
        final run = runGuard(
          'unmarked',
          'true',
          body: 'Some legacy draft body',
        );
        expect(
          run.log.where((l) => l.contains('release delete')),
          isEmpty,
          reason: 'no marker, no proof of ownership — only the >24h sweeper may reclaim',
        );
        expect(run.out, contains('refusing'));
      },
    );

    test('ownership: marker match is exact, not prefix/substring', () {
      final run = runGuard(
        'prefix',
        'true',
        body: '<!-- release-draft-owner: run/1111/job/release-macos -->',
        runId: '111',
        job: 'release-macos',
      );
      expect(
        run.log.where((l) => l.contains('release delete')),
        isEmpty,
        reason: 'run id 1111 must not be mistaken for 111',
      );
    });
  });

  // ── E3 — idempotent attach-or-create (review of #294) ───────────────────
  group('release_attach_or_create.sh — race-idempotent create, ownership-stamped', () {
    AttachOut runAttach(
      String name,
      List<String> viewSeq, {
      bool createFails = false,
      List<String> assetNames = const [],
    }) {
      final dir = Directory(
        '${hygieneFixtureRoot.path}/attach-$name-${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      final bin = stubGh(dir.path);
      File('${dir.path}/view-seq.txt')
          .writeAsStringSync('${viewSeq.join('\n')}\n');
      if (createFails) File('${dir.path}/create-fails').writeAsStringSync('');
      if (assetNames.isNotEmpty) {
        File('${dir.path}/asset-names.txt')
            .writeAsStringSync('${assetNames.join('\n')}\n');
      }
      File('${dir.path}/a.zip').writeAsStringSync('asset-a');
      File('${dir.path}/b.zip').writeAsStringSync('asset-b');
      File('${dir.path}/release-notes.md').writeAsStringSync('curated notes\n');
      File('${dir.path}/log').writeAsStringSync('');
      final res = Process.runSync(
        'bash',
        [
          File('scripts/release_attach_or_create.sh').absolute.path,
          'v1.2.3',
          'a.zip',
          'b.zip',
        ],
        workingDirectory: dir.path,
        environment: {
          'PATH': '$bin:${Platform.environment['PATH']}',
          'GITHUB_REPOSITORY': 'OWNER/REPO',
          'GH_STUB_DIR': dir.path,
          'GH_LOG_FILE': '${dir.path}/log',
          'GITHUB_RUN_ID': '111',
          'GITHUB_JOB': 'release-macos',
        },
      );
      return AttachOut(
        res.exitCode,
        '${res.stdout}${res.stderr}',
        File('${dir.path}/log').readAsLinesSync(),
        File('${dir.path}/last-create-notes.md').existsSync()
            ? File('${dir.path}/last-create-notes.md').readAsStringSync()
            : null,
      );
    }

    test('release exists → attach: upload every asset --clobber, NO publish without SHA256SUMS', () {
      // gh-1801 rework (threads 1/5 + 2/6): a release without the signed
      // checksums cannot serve `fa update` — the attach must not publish
      // or flag latest; the provenance step owns the flip.
      final run = runAttach('exists', ['exists']);
      expect(run.exitCode, 0);
      expect(
        run.log.where((l) => l.contains('release create')),
        isEmpty,
        reason: 'the release already exists — only attach',
      );
      expect(
        run.log,
        contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
      );
      expect(
        run.log,
        contains('release upload v1.2.3 b.zip --clobber --repo OWNER/REPO'),
      );
      expect(
        run.log.where((l) => l.contains('release edit')),
        isEmpty,
        reason:
            'the stub serves no SHA256SUMS asset — an un-servable release '
            'must stay unflipped (publish left to release-provenance)',
      );
    });

    test('release exists and already carries SHA256SUMS → recovery publish + latest', () {
      // The signed checksums are on the release (servable) but it was
      // left a draft (e.g. the provenance job's own flip failed) — the
      // attach recovers publish + latest.
      final run = runAttach(
        'exists-servable',
        ['exists'],
        assetNames: ['SHA256SUMS', 'SHA256SUMS.sig'],
      );
      expect(run.exitCode, 0);
      expect(
        run.log,
        contains(
          'release edit v1.2.3 --draft=false --latest --repo OWNER/REPO',
        ),
        reason:
            'a servable release (signed checksums on board) may be '
            'published + flagged latest by the attach (recovery path)',
      );
    });

    test('missing → create: bare-tag title, DRAFT-only, assets ride the create, body carries the ownership marker', () {
      // gh-1801 rework (threads 2/6): the create is draft-only — a leg
      // that arrives first must never publish, let alone flag latest;
      // the tag-run provenance job owns the flip.
      final run = runAttach('create', ['missing']);
      expect(run.exitCode, 0);
      final createLine = run.log.firstWhere(
        (l) => l.contains('release create'),
      );
      expect(createLine, contains('v1.2.3'));
      expect(createLine, contains('--title v1.2.3'));
      expect(createLine, contains('--draft'));
      expect(
        createLine,
        isNot(contains('--latest')),
        reason: 'a leg create never carries the latest badge (gh-1801)',
      );
      expect(createLine, contains('a.zip'));
      expect(createLine, contains('b.zip'));
      expect(run.createdNotes, isNotNull);
      expect(
        run.createdNotes,
        contains('curated notes'),
        reason: 'the prepared notes must stay the body',
      );
      expect(
        run.createdNotes,
        contains('release-draft-owner: run/111/job/release-macos'),
        reason:
            'the draft body must stamp its owner so the guard can verify it',
      );
    });

    test('E3 race: create loses to a concurrent winner → attach idempotently, exit 0', () {
      // The view said "missing", another job/run created the release
      // before our create landed. Old code failed here — and the failing
      // job's guard then deleted the WINNER's in-flight draft.
      final run = runAttach('race', ['missing', 'exists'], createFails: true);
      expect(
        run.exitCode,
        0,
        reason: 'a lost create race must not fail the job',
      );
      expect(
        run.log.where((l) => l.contains('release create')).length,
        1,
        reason: 'the create was attempted exactly once',
      );
      expect(
        run.log,
        contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
        reason: 'the loser must attach to the winner\'s release',
      );
      expect(
        run.log.where((l) => l.contains('release edit')),
        isEmpty,
        reason:
            'the loser must NOT publish the winner\'s release — without '
            'the signed checksums it cannot serve `fa update`; the '
            'provenance step owns the flip (gh-1801 rework)',
      );
      expect(run.out.toLowerCase(), contains('race'));
    });

    test(
      'create fails and nothing exists → loud failure (not a silent || true)',
      () {
        final run = runAttach('genuine-fail', [
          'missing',
          'missing',
        ], createFails: true);
        expect(run.exitCode, isNot(0));
        expect(
          run.log.where((l) => l.contains('release upload')),
          isEmpty,
          reason: 'nothing to attach to — no blind uploads',
        );
      },
    );

    test('workflows route draft-capable creates through the script (one race-safe path)', () {
      final script = File('scripts/release_attach_or_create.sh');
      expect(
        script.existsSync(),
        isTrue,
        reason: 'release_attach_or_create.sh must exist',
      );
      for (final wf in [
        '.github/workflows/build-macos.yml',
        '.github/workflows/build-mobile.yml',
      ]) {
        expect(
          read(wf),
          contains('release_attach_or_create.sh'),
          reason:
              '$wf must route its asset-carrying create through the shared script',
        );
        jobsOf(wf).forEach((jobId, job) {
          for (final c in jobCreates(job)) {
            expect(
              c.carriesAssets,
              isFalse,
              reason:
                  '$wf job "$jobId": asset-carrying creates must live in '
                  'release_attach_or_create.sh (race-idempotent, marker-stamped)',
            );
          }
        });
      }
      final creates = extractCreates(
        read('scripts/release_attach_or_create.sh'),
      );
      expect(creates, hasLength(1));
      expect(creates.single.carriesAssets, isTrue);
      expect(creates.single.hasTitle, isTrue);
      expect(creates.single.title, creates.single.tag);
      // gh-1801 rework (threads 2/6): the create is DRAFT-only — a leg
      // create never publishes or flags latest.
      expect(creates.single.text, contains('--draft'));
      expect(creates.single.text, isNot(contains('--latest')));
    });
    test('every release_attach_or_create.sh call site exports GH_TOKEN (PAT/App token, never bare GITHUB_TOKEN)', () {
      // PR #1783 review: the script's tag-mint push URL is built ONLY
      // from GH_TOKEN (`git push "${GH_TOKEN:+https://…}"`), so a call
      // site that exports just GITHUB_TOKEN collapses the URL to '' and
      // dies with `fatal: bad repository ''` (run 39766453580,
      // v1.0.626 mobile leg) — the macOS release-macos step had exactly
      // this gap. Pin the script header's documented contract on every
      // caller.
      var checked = 0;
      for (final wf in [
        '.github/workflows/build-macos.yml',
        '.github/workflows/build-mobile.yml',
      ]) {
        jobsOf(wf).forEach((jobId, job) {
          if (job is! Map || !job.containsKey('steps')) return;
          for (final step in (job['steps'] as YamlList)) {
            if (step is! YamlMap) continue;
            final run = step['run']?.toString() ?? '';
            if (!run.contains('release_attach_or_create.sh')) continue;
            checked++;
            final env = step['env'] as YamlMap?;
            final ghToken = env?['GH_TOKEN']?.toString();
            expect(
              ghToken,
              isNotNull,
              reason:
                  '$wf job "$jobId": release_attach_or_create.sh call site '
                  'must export GH_TOKEN (PAT/App token) — the tag-mint '
                  'push URL is built only from GH_TOKEN; without it the '
                  "push runs 'git push \"\"' (fatal: bad repository '')",
            );
            expect(
              ghToken,
              isNot(contains('secrets.GITHUB_TOKEN')),
              reason:
                  '$wf job "$jobId": GH_TOKEN must be a PAT/App token, '
                  'never the workflow GITHUB_TOKEN — GitHub suppresses '
                  'events triggered by it, so the minted tag would never '
                  'fire tag CI',
            );
          }
        });
      }
      expect(
        checked,
        greaterThanOrEqualTo(2),
        reason:
            'the lint must see both release legs (release-macos + mobile) '
            '— any new call site is auto-covered by the loop above',
      );
    });

    test('gh-2026: build-macos lazy-draft call sites export GH_TOKEN (they can reach the missing-ref mint)', () {
      // release_lazy_draft.sh now mints a missing tag through the same
      // CI-firing annotated push (scripts/release_tag_mint.sh) instead of
      // letting `gh release create` REST-mint a push-event-less
      // lightweight tag (v0.1.408 class, issue #597) that strands the
      // draft (v1.0.663 / v1.0.665 recurrence). Only the dispatch-time
      // call sites can reach the mint — the ci.yml tag-run sites always
      // see their own push event's tag — so the lint scopes to
      // build-macos.yml, whose build-macos-cli / build-extension steps
      // must carry the PAT, never the job token.
      var checked = 0;
      const wf = '.github/workflows/build-macos.yml';
      jobsOf(wf).forEach((jobId, job) {
        if (job is! Map || !job.containsKey('steps')) return;
        for (final step in (job['steps'] as YamlList)) {
          if (step is! YamlMap) continue;
          final run = step['run']?.toString() ?? '';
          if (!run.contains('release_lazy_draft.sh')) continue;
          checked++;
          final ghToken = (step['env'] as YamlMap?)?['GH_TOKEN']?.toString();
          expect(
            ghToken,
            isNotNull,
            reason:
                '$wf job "$jobId": the lazy-draft call site can mint a '
                'missing tag (token-URL push) — it must export GH_TOKEN '
                '(PAT/App token)',
          );
          expect(
            ghToken,
            isNot(contains('secrets.GITHUB_TOKEN')),
            reason:
                '$wf job "$jobId": GH_TOKEN must be a PAT/App token — '
                'a GITHUB_TOKEN push can never trigger the tag train',
          );
        }
      });
      expect(
        checked,
        greaterThanOrEqualTo(2),
        reason: 'the lint must see build-macos-cli + build-extension',
      );
    });

    test('gh-2026: every mint-reachable job grants actions:read (the mint train-verification probe)', () {
      // scripts/release_tag_mint.sh polls `gh run list --branch <tag>`
      // after the minted push. The probe authenticates with the RELEASE_PAT
      // (gh prefers GH_TOKEN, and every mint-reachable call site exports
      // it — the lints above pin that), so the job-level grant is
      // defense-in-depth, not the probe's credential (PR #2029 review).
      // It is granted UNIFORMLY on every job that can reach the mint —
      // a mint that wins the race runs from any of them, and a missing
      // grant turns into a spurious red leg the day the probe is ever
      // switched to the job token.
      const expected = {
        '.github/workflows/build-macos.yml': {
          'release-macos',
          'build-macos-cli',
          'build-extension',
        },
        '.github/workflows/build-mobile.yml': {'release-mobile'},
      };
      expected.forEach((wf, jobIds) {
        final jobs = jobsOf(wf);
        for (final jobId in jobIds) {
          final job = jobs[jobId] as YamlMap;
          final perms = job['permissions'] as YamlMap;
          expect(
            perms['actions']?.toString(),
            'read',
            reason:
                '$wf job "$jobId" must grant actions:read for the '
                'mint train-verification probe (defense-in-depth; the '
                'probe authenticates with RELEASE_PAT)',
          );
        }
      });
    });
  });

  // ── AC3 — one naming scheme: bare vX.Y.Z (UT-naming) ────────────────────
  group('AC3 — bare vX.Y.Z titles everywhere', () {
    test('no "Fa " title prefix survives in any release-creating path', () {
      final haystacks = [
        ...workflows.map(read),
        read('scripts/auto_release.sh'),
      ];
      for (final text in haystacks) {
        expect(
          text,
          isNot(contains('--title "Fa ')),
          reason: 'release titles must be bare vX.Y.Z, not "Fa vX.Y.Z"',
        );
      }
    });

    test('every gh release create is titled and the title equals the tag', () {
      for (final wf in workflows) {
        jobsOf(wf).forEach((jobId, job) {
          for (final c in jobCreates(job)) {
            expect(
              c.hasTitle,
              isTrue,
              reason: '$wf job "$jobId": untitled release create is forbidden',
            );
            expect(
              c.title,
              c.tag,
              reason:
                  '$wf job "$jobId": --title must equal the bare tag (${c.tag})',
            );
          }
        });
      }
      // gh-1522 cut the tag-only release; gh-1801 removed the LAST
      // release-create from auto_release.sh: the script resolves an EMPTY
      // asset list, and an asset-less create publishes an empty `latest`
      // (the fa update breaker, v1.0.630). The tag-run binaries job owns
      // creation, draft-first; release_attach_or_create.sh stays the one
      // asset-carrying create path.
      final autoCreates = extractCreates(read('scripts/auto_release.sh'));
      expect(
        autoCreates,
        hasLength(0),
        reason:
            'auto_release.sh must create NO release — it has zero resolved '
            'assets, and publishing an empty latest breaks fa update '
            '(gh-1801)',
      );
      for (final c in autoCreates) {
        expect(c.title, c.tag);
      }
      final attachCreates = extractCreates(
        read('scripts/release_attach_or_create.sh'),
      );
      expect(attachCreates, isNotEmpty);
      for (final c in attachCreates) {
        expect(c.title, c.tag);
      }
    });

    test(
      'lint is real: fixture with "Fa " prefix / missing title is flagged',
      () {
        final bad = extractCreates(r'''
gh release create "$RELEASE_TAG" \
  --title "Fa $RELEASE_TAG" \
  --generate-notes
gh release create "v9.9.9" \
  --generate-notes
''');
        expect(bad.first.title, isNot(bad.first.tag));
        expect(bad.last.hasTitle, isFalse);
      },
    );
  });

  // ── AC5 — generated release notes (UT-notes) ────────────────────────────
  group('AC5 — release_notes.sh', () {
    // release_notes.sh shells out to git — route that subprocess through the
    // resolved real git as well, so a session shim first on PATH can never
    // decide the notes (gh-1172 round-3 suggestion; on the review host a
    // broken shim made these tests read an empty history).
    final gitShimBin = Directory(
      '${hygieneFixtureRoot.path}/gitshim-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    File('${gitShimBin.path}/git').writeAsStringSync(
      '#!/usr/bin/env bash\nexec "${resolveRealGit()}" "\$@"\n',
    );
    Process.runSync('chmod', ['+x', '${gitShimBin.path}/git']);

    String notes(String cwd, List<String> args) {
      final r = Process.runSync(
        'bash',
        [File('scripts/release_notes.sh').absolute.path, ...args],
        workingDirectory: cwd,
        environment: {
          'PATH': '${gitShimBin.path}:${Platform.environment['PATH']}',
        },
      );
      return r.stdout.toString();
    }

    test('CHANGELOG section for the version wins', () {
      final repo = fixtureRepo(
        'notes-changelog',
        ['feat: real work'],
        ['v1.2.2'],
        '''
# Changelog

## 1.2.3

- Curated note alpha
- Curated note beta

## 1.2.2

- Older
''',
      );
      final out = notes(repo, ['1.2.3']);
      expect(out, contains('Curated note alpha'));
      expect(out, contains('Curated note beta'));
      expect(out, isNot(contains('Older')));
      expect(out, isNot(contains('feat: real work')));
    });

    test('gh-1522 preference 1b — a pending curated ## Unreleased section is this release\'s notes', () {
      // The tag-only flow never rewrites CHANGELOG.md in-repo — the
      // stage-time stamper (stamp_staged_release.sh) folds Unreleased
      // under the tag's section — so at cut time a pending Unreleased
      // section with NO '## <version>' section yet IS the release body.
      final repo = fixtureRepo(
        'notes-unreleased-only',
        ['feat: real work'],
        ['v1.2.2'],
        '''
# Changelog

## Unreleased

- Pending curated note alpha
- Pending curated note beta
''',
      );
      final out = notes(repo, ['1.2.3']);
      expect(out, contains('Pending curated note alpha'));
      expect(out, contains('Pending curated note beta'));
      expect(
        out,
        isNot(contains('feat: real work')),
        reason:
            'the curated Unreleased body must win over the conventional-'
            'commit fallback',
      );
    });

    test('gh-1522 preference 1b — the curated ## <version> section still wins over a non-empty Unreleased', () {
      final repo = fixtureRepo(
        'notes-version-over-unreleased',
        ['feat: real work'],
        ['v1.2.2'],
        '''
# Changelog

## 1.2.3

- Versioned curated note

## Unreleased

- Pending curated note
''',
      );
      final out = notes(repo, ['1.2.3']);
      expect(out, contains('Versioned curated note'));
      expect(
        out,
        isNot(contains('Pending curated note')),
        reason:
            'preference 1 (the versioned section) outranks 1b (Unreleased) '
            '— both curated, the per-release one is the truth',
      );
    });

    test('gh-1522 rework — TWO ## Unreleased sections fail loud (silent-drop trap)', () {
      // PR #1526 review: a second (usually empty, bottom-of-file)
      // ## Unreleased is invisible to the preference-1b awk, which stops
      // at the FIRST header — entries in the second section would never
      // ship, with no error anywhere. Duplicate headers must abort the
      // notes generation loudly instead.
      final repo = fixtureRepo(
        'notes-duplicate-unreleased',
        ['feat: real work'],
        ['v1.2.2'],
        '''
# Changelog

## Unreleased

- Pending curated note alpha

## 1.2.2

- Older

## Unreleased
''',
      );
      final r = Process.runSync(
        'bash',
        [File('scripts/release_notes.sh').absolute.path, '1.2.3'],
        workingDirectory: repo,
        environment: {
          'PATH': '${gitShimBin.path}:${Platform.environment['PATH']}',
        },
      );
      expect(
        r.exitCode,
        isNot(0),
        reason:
            'duplicate ## Unreleased sections must fail loud, not '
            'silently drop the second section (PR #1526)',
      );
      expect(
        '${r.stderr}${r.stdout}',
        contains('Unreleased'),
        reason: 'the error names the duplicated section',
      );
    });

    test('fallback: conventional commits since the previous tag, grouped', () {
      final repo = fixtureRepo(
        'notes-group',
        ['chore: seed'],
        ['v2.0.0'],
        null,
        [
          'feat(cli): shiny new thing',
          'fix: crash on start',
          'chore: deps bump',
          'docs: readme',
        ],
      );
      final out = notes(repo, ['2.0.1']);
      expect(out, contains('Features'));
      expect(out, contains('shiny new thing'));
      expect(out, contains('Fixes'));
      expect(out, contains('crash on start'));
      expect(out, contains('Maintenance'));
      expect(out, contains('deps bump'));
      expect(out, contains('readme'));
    });

    test('zero commits since previous tag -> clean "no changes" body (E5)', () {
      final repo = fixtureRepo(
        'notes-empty',
        ['feat: only old work'],
        ['v3.0.0'],
      );
      final out = notes(repo, ['3.0.1']);
      expect(out.toLowerCase(), contains('no changes'));
      expect(out.trim(), isNot(''));
    });

    test('E4: 200 commits -> capped at 50 with an "and N more" line', () {
      final repo = fixtureRepo('notes-cap', ['chore: seed'], ['v4.0.0'], null, [
        for (var i = 1; i <= 200; i++) 'feat: change $i',
      ]);
      final out = notes(repo, ['4.0.1']);
      final bullets = RegExp(r'^- ', multiLine: true).allMatches(out).length;
      expect(bullets, lessThanOrEqualTo(50));
      expect(out, contains('and 150 more'));
      expect(
        out,
        contains('change 200'),
        reason: 'newest commits stay, oldest drop',
      );
    });
  });

  // ── AC2 — daily draft sweeper (IT-sweep) ────────────────────────────────
  group('AC2 — sweep_stale_drafts.sh', () {
    final oldDate = '2020-01-01T00:00:00Z';
    String releasesJson(List<Map<String, Object>> drafts) => jsonEncode(
      drafts
          .map(
            (d) => {
              'tag_name': d['tag'],
              'id': d['id'],
              'draft': true,
              'created_at': d['created'],
              'author': {'login': d['author'], 'type': d['type']},
            },
          )
          .toList(),
    );

    test('old bot draft deleted, fresh untouched, human kept; issue filed naming the run', () {
      final freshDate = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String()
          .substring(0, 19);
      final run = runSweeper('one', {
        'releases.json': releasesJson([
          {
            'tag': 'v0.1.190',
            'id': 111,
            'created': oldDate,
            'author': 'github-actions[bot]',
            'type': 'Bot',
          },
          {
            'tag': 'v9.9.9',
            'id': 222,
            'created': '${freshDate}Z',
            'author': 'github-actions[bot]',
            'type': 'Bot',
          },
          {
            'tag': 'v0.2.0',
            'id': 333,
            'created': oldDate,
            'author': 'somehuman',
            'type': 'User',
          },
        ]),
        'issues.tsv': '',
        'runs.tsv': 'https://github.com/OWNER/REPO/actions/runs/9999\n',
      });
      expect(
        run.log,
        contains('api -X DELETE repos/OWNER/REPO/releases/111'),
        reason: 'stale bot draft must be deleted by release id',
      );
      expect(
        run.log,
        isNot(contains('releases/222')),
        reason: 'fresh (<24h) draft must be untouched',
      );
      expect(
        run.log,
        isNot(contains('releases/333')),
        reason: 'human draft must never be deleted (E1)',
      );
      expect(
        run.log,
        anyElement(contains('issue create')),
        reason: 'dedup issue must be filed',
      );
      expect(run.body, isNotNull, reason: 'an issue body must have been filed');
      expect(
        run.body,
        contains('v0.1.190'),
        reason: 'deleted draft must be named in the issue',
      );
      expect(
        run.body,
        contains('actions/runs/9999'),
        reason: 'the creating run must be named in the issue',
      );
      expect(
        run.body,
        contains('v0.2.0'),
        reason: 'human draft must be listed in the issue',
      );
      expect(
        run.stdoutText,
        contains('v0.1.190'),
        reason: 'deleted draft must be named in the report',
      );
    });
    test('gh-2008: stale PAT-attributed pipeline draft (release-draft-owner marker, human author) is swept; unmarked human draft stays kept (E1)', () {
      // Every pipeline draft is created with GH_TOKEN=RELEASE_PAT (the
      // owner's PAT), so the API reports author=<owner>, type=User — the
      // author-only bot test buckets the release train's own orphaned
      // drafts as "human" and they rot forever (gh-2008: v1.0.663 /
      // v1.0.665). The invisible `release-draft-owner` body marker is the
      // pipeline-ownership signal the guard and dedupe already parse.
      final freshDate = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String()
          .substring(0, 19);
      final run = runSweeper('marker', {
        'releases.json': jsonEncode([
          {
            'tag_name': 'v1.0.663',
            'id': 427501287,
            'draft': true,
            'created_at': oldDate,
            'author': {'login': 'IstiN', 'type': 'User'},
            'body':
                'Release v1.0.663 — see the CHANGELOG.\n'
                '<!-- release-draft-owner: run/40822965933/job/release-mobile -->',
          },
          {
            // Same stale age, same human author — but NO marker: a real
            // human draft must stay listed-not-deleted (E1).
            'tag_name': 'v1.0.999',
            'id': 427501288,
            'draft': true,
            'created_at': oldDate,
            'author': {'login': 'IstiN', 'type': 'User'},
            'body': 'My manual WIP draft — no marker',
          },
          {
            // Fresh + marker: an in-flight run may still own it.
            'tag_name': 'v1.0.674',
            'id': 427501289,
            'draft': true,
            'created_at': '${freshDate}Z',
            'author': {'login': 'IstiN', 'type': 'User'},
            'body': '<!-- release-draft-owner: run/41172095157/job/build-macos-cli-arm64 -->',
          },
        ]),
        'issues.tsv': '',
        'runs.tsv': '',
      });
      expect(
        run.log,
        contains('api -X DELETE repos/OWNER/REPO/releases/427501287'),
        reason:
            'a stale draft carrying the pipeline ownership marker is '
            'pipeline-created (the RELEASE_PAT attribution only makes it '
            'LOOK human) — the sweeper must reclaim it',
      );
      // run.log is a List<String>: contains() there is ELEMENT equality,
      // so the isNot(contains(...)) E1 assertions below must match
      // against the JOINED log text — a bare-substring matcher on the
      // list is vacuously true and would never catch a stray delete.
      final logText = run.log.join('\n');
      expect(
        logText,
        isNot(contains('releases/427501288')),
        reason: 'stale human draft with NO marker must never be deleted (E1)',
      );
      expect(
        logText,
        isNot(contains('releases/427501289')),
        reason: 'fresh (<24h) marker draft must be untouched — an in-flight run may own it',
      );
      expect(run.body, isNotNull, reason: 'an issue body must have been filed');
      expect(
        run.body,
        contains('v1.0.663'),
        reason: 'swept draft must be named in the issue',
      );
      expect(
        run.body,
        contains('actions/runs/40822965933'),
        reason:
            'the marker names the exact creating run — the issue must '
            'point at it (the creating run executed on main, so the '
            'gh-run-list-on-tag heuristic cannot find it)',
      );
      expect(
        run.body,
        contains('v1.0.999'),
        reason: 'kept human draft must be listed in the issue (E1)',
      );
      expect(
        run.body,
        isNot(contains('v1.0.674')),
        reason: 'fresh drafts are never named as swept or kept',
      );
      expect(
        run.stdoutText,
        contains('v1.0.663'),
        reason: 'swept draft must be named in the report',
      );
    });
    test('gh-2008: stale draft whose body only MENTIONS the marker substring (no run/<id>/job/ shape) stays kept (E1)', () {
      // The bucket rule must key on the exact marker shape the pipeline
      // stamps (`release-draft-owner: run/<id>/job/<job>` — what
      // release_lazy_draft.sh / release_attach_or_create.sh write and
      // release_draft_guard.sh parses), NOT the bare substring: human
      // prose quoting or negating the marker, or a malformed marker
      // (`release-draft-owner: unknown`), must never look pipeline-owned
      // or the sweeper silently deletes a human draft (E1 regression,
      // review thread PRRT_kwDOTXdlLc6yOzIh).
      final run = runSweeper('loose-marker', {
        'releases.json': jsonEncode([
          {
            'tag_name': 'v9.0.1',
            'id': 427501290,
            'draft': true,
            'created_at': oldDate,
            'author': {'login': 'alice', 'type': 'User'},
            'body': 'this draft has NO release-draft-owner: marker (prose)',
          },
          {
            // Malformed marker: the substring is there but the
            // run/<id>/job/ shape is not — NOT proof of pipeline
            // ownership.
            'tag_name': 'v9.0.2',
            'id': 427501291,
            'draft': true,
            'created_at': oldDate,
            'author': {'login': 'IstiN', 'type': 'User'},
            'body': 'release-draft-owner: unknown',
          },
          {
            // Control: a properly-stamped stale draft is still swept
            // and still names its creating run.
            'tag_name': 'v9.0.3',
            'id': 427501292,
            'draft': true,
            'created_at': oldDate,
            'author': {'login': 'IstiN', 'type': 'User'},
            'body': '<!-- release-draft-owner: run/40822965933/job/release-mobile -->',
          },
        ]),
        'issues.tsv': '',
        'runs.tsv': '',
      });
      expect(
        run.log,
        contains('api -X DELETE repos/OWNER/REPO/releases/427501292'),
        reason:
            'the control: a well-formed run/<id>/job/ marker is still '
            'pipeline-owned and swept',
      );
      // Substring semantics over the JOINED log (element-contains on the
      // List is vacuous for isNot — see the sibling gh-2008 test).
      final logText = run.log.join('\n');
      expect(
        logText,
        isNot(contains('releases/427501290')),
        reason:
            'prose merely MENTIONING the marker substring is not '
            'ownership — deleting it would be a silent E1 violation',
      );
      expect(
        logText,
        isNot(contains('releases/427501291')),
        reason:
            'a malformed marker (release-draft-owner: unknown, no '
            'run/<id>/job/ shape) is not ownership — the draft stays '
            'kept (E1)',
      );
      expect(
        run.body,
        contains('v9.0.1'),
        reason: 'kept prose-mention draft must be listed in the issue (E1)',
      );
      expect(
        run.body,
        contains('v9.0.2'),
        reason: 'kept malformed-marker draft must be listed in the issue (E1)',
      );
    });

    test(
      'idempotent re-run: comments on the open issue instead of duplicating',
      () {
        final run = runSweeper('two', {
          'releases.json': releasesJson([
            {
              'tag': 'v0.1.190',
              'id': 111,
              'created': oldDate,
              'author': 'github-actions[bot]',
              'type': 'Bot',
            },
          ]),
          'issues.tsv': '12\t[daily-publish] stale release drafts swept\n',
          'runs.tsv': '',
        });
        final creates = run.log.where((l) => l.contains('issue create')).length;
        final comments = run.log
            .where((l) => l.contains('issue comment'))
            .length;
        expect(
          creates,
          0,
          reason: 'open issue exists — no duplicate may be filed',
        );
        expect(comments, 1, reason: 'the existing issue gets a fresh comment');
        expect(
          run.log,
          contains('api -X DELETE repos/OWNER/REPO/releases/111'),
        );
      },
    );

    test(
      'clean sweep auto-closes the open issue (self-closing convention)',
      () {
        final run = runSweeper('three', {
          'releases.json': '[]',
          'issues.tsv': '12\t[daily-publish] stale release drafts swept\n',
          'runs.tsv': '',
        });
        expect(run.log, anyElement(contains('issue close')));
        expect(run.log.where((l) => l.contains('-X DELETE')), isEmpty);
        expect(run.log.where((l) => l.contains('issue create')), isEmpty);
      },
    );
  });

  // AC4 — truthful Latest (provenance-owned `latest`, gh-1801 rework) moved
  // to test/release_empty_latest_guard_test.dart — the gh-1801
  // latest/publish-pin home; same four pins stay green there (loc ratchet).

  // ── AC6 — regression: no "Release v" bodies, atomic flow intact ─────────
  group('AC6 — regression', () {
    test('no "Release vX" filler bodies remain', () {
      final haystacks = [
        ...workflows.map(read),
        read('scripts/auto_release.sh'),
      ];
      for (final text in haystacks) {
        expect(text, isNot(contains('--notes "Release v')));
      }
    });

    test('release flow is tag-only (gh-1522): auto_release.sh cuts + pushes the tag, never touches main or any file', () {
      // gh-1522: the git TAG is the single source of truth for versions.
      // The retired direct-push bump flow (sed/python3/flutter file
      // mutations + a 'chore(release):' commit pushed straight to main,
      // then tag_release.sh cutting the tag) is gone: the release IS
      // `git tag -a v$next origin/main` + `git push origin refs/tags/...`
      // + `gh release create`. ZERO commits land on main, ZERO files are
      // mutated in-repo (the changelog-cap guard moved to stamp time —
      // stamp_staged_release.sh — and the lockfile gates retired with the
      // file bumps).
      final auto = read('scripts/auto_release.sh');
      expect(
        auto,
        isNot(contains('git push origin HEAD')),
        reason:
            'releases never push to main — the tag pins origin/main as of '
            'the fetch; a main that advances mid-run is picked up by a '
            'later release (gh-1522)',
      );
      expect(
        auto,
        isNot(contains('gh pr create')),
        reason: 'release PRs stayed retired (gh-1172/gh-1522)',
      );
      expect(
        auto,
        isNot(contains('chore/release-v')),
        reason: 'no release branch is created anymore',
      );
      expect(
        auto,
        isNot(contains(RegExp(r'\bflutter\b'))),
        reason:
            'no flutter invocation — the lockfile-refresh gate retired '
            'with the file bumps (gh-1522) (the header comment may name '
            r"flutter_app's retired files, but no bare `flutter` call)",
      );
      expect(
        auto,
        isNot(contains('sed -i')),
        reason: 'no in-place file edits — nothing is bumped in-repo',
      );
      expect(
        auto,
        isNot(contains(RegExp(r'^[^#\n]*pubspec\.lock', multiLine: true))),
        reason:
            'no lockfile mutation outside comments — the gh-1299 churn '
            'class is retired',
      );
      expect(
        auto,
        contains('git tag -a'),
        reason: 'the release cuts the annotated tag itself',
      );
      expect(
        auto,
        contains('refs/tags/'),
        reason: 'the tag push is ref-scoped (never a branch push)',
      );
      expect(
        auto,
        contains('RELEASE_DRY_RUN'),
        reason: 'AC1: the dry-run switch must gate the tag push',
      );
      expect(
        jobsOf('.github/workflows/ci.yml').containsKey('release-tag'),
        isFalse,
        reason:
            'the release-tag job (tag_release.sh) is deleted — the release '
            'job owns tag cut + GitHub Release in one step (gh-1522)',
      );
    });

    test('release job authenticates via the fa-release-bot App token (mint step + checkout + GH_TOKEN), no SDK steps', () {
      // gh-1172 fix-contract item 1: the release job mints a job-scoped
      // installation token via actions/create-github-app-token from
      // RELEASE_APP_ID / RELEASE_APP_PRIVATE_KEY and uses it for checkout
      // (tag-push auth) — and exports it as GH_TOKEN for the
      // auto_release.sh step's `gh release create` (the #1093 BLOCK
      // finding: without an explicit token the create was a guaranteed
      // silent no-op). gh-1522: tag cutting is git+gh only — the job no
      // longer installs Flutter or Python (the file-bump tooling is gone).
      final ci = jobsOf('.github/workflows/ci.yml');
      final job = ci['release'] as YamlMap;
      final steps = job['steps'] as YamlList;
      final mint = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) =>
                s['uses']?.toString().startsWith(
                  'actions/create-github-app-token@',
                ) ??
                false,
            orElse: () => throw TestFailure(
              'release must mint the fa-release-bot token via '
              'actions/create-github-app-token',
            ),
          );
      expect(
        mint['id']?.toString(),
        'app-token',
        reason: 'release token step id must be app-token for the wiring below',
      );
      expect(
        mint['with']['app-id']?.toString(),
        equals(r'${{ secrets.RELEASE_APP_ID }}'),
      );
      expect(
        mint['with']['private-key']?.toString(),
        equals(r'${{ secrets.RELEASE_APP_PRIVATE_KEY }}'),
      );
      expect(
        mint['with']['permissions']?.toString(),
        'contents:write',
        reason:
            'release mint must scope the token to contents:write — the App '
            'is the release-path actor, so an unscoped token carries every '
            'permission the installation has (gh-1172 round-2 review, least privilege)',
      );
      final checkout = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) =>
                s['uses']?.toString().startsWith('actions/checkout') ?? false,
          );
      expect(
        checkout['with']['token']?.toString(),
        equals(r'${{ steps.app-token.outputs.token || github.token }}'),
        reason:
            'release checkout must ride the App token — GITHUB_TOKEN tag '
            'pushes never fire tag-scoped jobs (it additionally falls back '
            'to github.token when the dry-run gate skips the mint)',
      );
      final cutStep = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) => s['run']?.toString().contains('auto_release.sh') ?? false,
          );
      // gh-1801 (rework): auto_release.sh no longer calls `gh` at all —
      // the asset-less create published an empty `latest` and broke `fa
      // update`. GH_TOKEN on this step became a dead write-capable
      // credential; the tag push rides the checkout App token above
      // (gh-1172), so the env must stay absent (least privilege).
      expect(
        (cutStep['env'] as YamlMap?)?.containsKey('GH_TOKEN') ?? false,
        isFalse,
        reason:
            'the Cut-release-tag step must not export GH_TOKEN anymore — '
            'auto_release.sh has no gh surface; the push rides the '
            'checkout App token',
      );
      for (final banned in [
        'subosito/flutter-action',
        'actions/setup-python',
      ]) {
        expect(
          steps
              .map((s) => (s as YamlMap)['uses']?.toString() ?? '')
              .any((uses) => uses.startsWith(banned)),
          isFalse,
          reason:
              'gh-1522: the tag-only release job never installs an SDK — '
              'tag cutting is git+gh only (no flutter pub get / no python '
              'file bumps)',
        );
      }
    });
    test('dry-run dispatch carries no bypass credential (mint gated, checkout falls back, job reads)', () {
      // gh-1172 round-3 BLOCK: the AC1 dry-run arm fires on ANY ref, so the
      // dispatched (PR-head) auto_release.sh must never hold the bypass App
      // token — "never pushes" would otherwise be enforced only by the very
      // script under test (a PR can edit it to ignore the flag, or spend
      // the checkout-stored token directly: push HEAD to main, push a v*
      // tag → the OIDC publish job → attacker-controlled pub.dev package).
      // A dry-run needs no push credential at all: the mint is gated off on
      // dry-run, checkout falls back to the plain GITHUB_TOKEN, and the job
      // token itself stays read-only so no write-capable second credential
      // exists on an untrusted ref.
      final ci = jobsOf('.github/workflows/ci.yml');
      final job = ci['release'] as YamlMap;
      final steps = job['steps'] as YamlList;
      final mint = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) =>
                s['uses']?.toString().startsWith(
                  'actions/create-github-app-token@',
                ) ??
                false,
          );
      expect(
        mint['if']?.toString(),
        equals('inputs.releaseDryRun != true'),
        reason:
            'dry-run never pushes — mint NO bypass credential on untrusted '
            'refs (the real arms — push, schedule, releaseDispatch — all see '
            'a non-true releaseDryRun and still mint)',
      );
      final checkout = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) =>
                s['uses']?.toString().startsWith('actions/checkout') ?? false,
          );
      expect(
        checkout['with']['token']?.toString(),
        equals(r'${{ steps.app-token.outputs.token || github.token }}'),
        reason:
            'with the mint skipped, checkout must fall back to the plain '
            'GITHUB_TOKEN (a skipped step emits empty outputs, falsy in GHA)',
      );
      expect(
        (job['permissions'] as YamlMap)['contents'].toString(),
        'read',
        reason:
            'the push rides the checkout App token exclusively — the job '
            'GITHUB_TOKEN never needs write, so a dry-run dispatch of a PR '
            'head holds no write-capable credential at all',
      );
    });

    test(
      'daily-publish.yml carries the sweeper job, ungated by leg results',
      () {
        final jobs = jobsOf('.github/workflows/daily-publish.yml');
        expect(jobs.keys, contains('sweep-drafts'));
        final sweep = jobs['sweep-drafts'] as YamlMap;
        expect(
          sweep['if'].toString(),
          contains('always()'),
          reason: 'hygiene must run even when legs skip',
        );
        expect(
          (sweep['permissions'] as YamlMap).containsKey('contents'),
          isTrue,
        );
        expect(sweep.toString(), contains('sweep_stale_drafts.sh'));
      },
    );

    test('sweep-drafts grants actions:read — gh run list 403s without it (review of #294)', () {
      // The sweeper names each swept draft's creating run via `gh run list`;
      // without actions:read GitHub answers 403 and the script's || true
      // hides it, silently degrading every sweep issue to "no run on ref".
      // The stub enforces the YAML-declared scopes on every AC2 run above;
      // this pins the grant explicitly.
      final perms =
          jobsOf(
                '.github/workflows/daily-publish.yml',
              )['sweep-drafts']['permissions']
              as YamlMap;
      expect(
        perms.containsKey('actions'),
        isTrue,
        reason: 'sweep-drafts must grant actions:read for gh run list',
      );
      expect(perms['actions'].toString(), 'read');
      expect(
        sweepPermissions().split(RegExp(r'\s+')),
        contains('actions'),
        reason: 'the stub-enforced scope list must include actions',
      );
    });
    test('release job never fires from a bare workflow_dispatch (SM validation dispatches pass no inputs)', () {
      // gh-1172 round-2 BLOCK: ci.yml is the repo's dispatch-only CI —
      // machine-sm.yml -> smAgent.js dispatchCiWorkflow() runs
      // `gh workflow run ci.yml --ref <pr-branch>` with NO inputs, and
      // sm-kicker / machine-merge dispatch it the same way. An ungated
      // `|| github.event_name == 'workflow_dispatch'` arm makes every green
      // validation dispatch execute the dispatched (PR-head) ref's
      // auto_release.sh with the bypass App's push credentials — an
      // accidental release and a privilege-escalation path in one. Every
      // dispatch arm must be conjunctive with an explicit inputs.release*
      // opt-in, and the real-push arm must additionally be ref-restricted
      // to main.
      final ci = jobsOf('.github/workflows/ci.yml');
      final releaseIf = (ci['release'] as YamlMap)['if'].toString();

      // Dispatch arms are the parenthesized `(...)` groups whose condition
      // STARTS with the workflow_dispatch check — balanced-paren scan so a
      // nested string containing ')' can never confuse the split.
      const wd = "github.event_name == 'workflow_dispatch'";
      final dispatchArms = <String>[];
      for (var i = 0; i < releaseIf.length; i++) {
        if (releaseIf[i] != '(') continue;
        var depth = 0;
        for (var j = i; j < releaseIf.length; j++) {
          if (releaseIf[j] == '(') {
            depth++;
          } else if (releaseIf[j] == ')') {
            depth--;
            if (depth == 0) {
              final inner = releaseIf.substring(i + 1, j).trim();
              if (inner.startsWith(wd)) dispatchArms.add(inner);
              break;
            }
          }
        }
      }
      // The invariant itself: EVERY occurrence of the workflow_dispatch
      // check must live inside a gated arm. A bare `|| workflow_dispatch`
      // arm shows up as an occurrence no arm accounts for.
      final armOccurrences = dispatchArms.fold<int>(
        0,
        (n, a) => n + a.split(wd).length - 1,
      );
      expect(
        releaseIf.split(wd).length - 1,
        armOccurrences,
        reason:
            'a bare `|| github.event_name == \'workflow_dispatch\'` arm must '
            'never return — SM validation dispatches (machine-sm.yml -> '
            'smAgent.js dispatchCiWorkflow, sm-kicker, machine-merge) pass NO '
            'inputs, so an ungated arm auto-releases from any dispatched ref',
      );
      expect(
        dispatchArms.length,
        2,
        reason:
            'exactly two dispatch arms: the AC1 dry-run (releaseDryRun) and '
            'the manual catch-up release (releaseDispatch on main)',
      );
      for (final arm in dispatchArms) {
        expect(
          RegExp(r"inputs\.release[A-Za-z]*\s*==\s*true").hasMatch(arm),
          isTrue,
          reason:
              'every workflow_dispatch arm must be conjunctive with an explicit '
              'inputs.release* opt-in — a bare dispatch (no inputs) arms nothing; '
              'got: $arm',
        );
        if (!arm.contains('inputs.releaseDryRun')) {
          expect(
            arm.contains("github.ref == 'refs/heads/main'"),
            isTrue,
            reason:
                'the real-push dispatch arm must be ref-restricted to main — a '
                'PR-head dispatch must never reach the tag push; got: $arm',
          );
          expect(
            arm.contains('inputs.releaseDispatch'),
            isTrue,
            reason:
                'the real-push dispatch arm must require the explicit '
                'releaseDispatch opt-in; got: $arm',
          );
        }
      }

      // The typed opt-in input must exist (boolean, default false) so the
      // gate above is satisfiable without accidents.
      final ciRaw = read('.github/workflows/ci.yml');
      expect(
        RegExp(
          r'^\s*releaseDispatch:\n\s+description:[^\n]*\n\s+required: false\n\s+type: boolean\n\s+default: false$',
          multiLine: true,
        ).hasMatch(ciRaw),
        isTrue,
        reason:
            'releaseDispatch must be a typed boolean input defaulting to false',
      );
      // The dry-run env must normalize through == 'true' — the bare
      // `inputs.releaseDryRun || '0'` fallback is dead code (a typed boolean
      // input always arrives as 'true'/'false', and 'false' is truthy in
      // GitHub expressions), so it must never return (gh-1172 round-2 thread 3).
      expect(
        ciRaw,
        isNot(contains('inputs.releaseDryRun ||')),
        reason:
            "the dead `inputs.releaseDryRun || '0'` fallback must not return",
      );
      final steps = (ci['release'] as YamlMap)['steps'] as YamlList;
      final cutStep = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) => s['run']?.toString().contains('auto_release.sh') ?? false,
          );
      expect(
        (cutStep['env'] as YamlMap)['RELEASE_DRY_RUN']?.toString(),
        equals(
          r"${{ github.event.inputs.releaseDryRun == 'true' && '1' || '0' }}",
        ),
        reason: "RELEASE_DRY_RUN must normalize via == 'true' to a literal 1/0",
      );
    });
  });

  // ── gh-1172/gh-1522 — tag-only behavioral coverage ───────────────────────
  // Round-2 review: the PR deleted the gh-1134 PR-path sandbox (bare origin +
  // stubbed gh) together with the code it exercised — correct — but shipped
  // the new path with string-assertions only. The riskiest logic gets the
  // same treatment here: a bare origin IS a real git remote, so
  // `git push origin refs/tags/vX` genuinely executes; a git shim races the
  // tag push by pre-pushing the same tag from a second clone between the
  // script's fetch and its push (E1), and a gh stub logs the release create.
  group('gh-1522 — tag-only release behavioral coverage (dry-run, coalesce, E1 race)', () {
    test('AC1 — dry-run computes the tag, exits before the push; no tag on origin, no gh create, no local leftover', () {
      final r = runAutoReleaseDirect('dry-run', dryRun: true);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('DRY-RUN: would push tag v0.1.496'));
      expect(
        r.originHeadAfter,
        r.originHeadBefore,
        reason: 'AC1: a dry run must not move origin/main',
      );
      expect(
        r.originTagExists('v0.1.496'),
        isFalse,
        reason: 'a dry run must never push the tag',
      );
      expect(r.originTags(), ['v0.1.495']);
      expect(
        r.ghLog(),
        isEmpty,
        reason: 'a dry run must never create the GitHub Release',
      );
      expect(
        r.seedTagExists('v0.1.496'),
        isFalse,
        reason:
            'the dry run deletes its computed local tag — no leftover '
            'pollutes the next real run',
      );
    });

    test('coalesce guard — a tag younger than 2h skips the run entirely (no new tag on origin)', () {
      final r = runAutoReleaseDirect('coalesce', tagAgeHours: 1);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('coalesced'));
      expect(
        r.originHeadAfter,
        r.originHeadBefore,
        reason: 'no release may land inside the coalesce window',
      );
      expect(r.originTags(), [
        'v0.1.495',
      ], reason: 'the guard must not cut v0.1.496');
      expect(r.ghLog(), isEmpty);
    });

    test('coalesce guard measures the TAG date, not the tagged commit date — a tag cut minutes ago coalesces even when its commit sat pending for hours (PR #1526 thread 5)', () {
      // The catch-up path: commits sat on main for hours before the
      // cron/dispatch cut the tag. The 2h window runs from the RELEASE
      // (tag), not from the commit the tag points at — reading the
      // commit date would let extra releases through exactly when the
      // guard (and the pub.dev ~12/day rate limit) exists to stop them.
      final r = runAutoReleaseDirect(
        'coalesce-tagger-date',
        tagAgeHours: 0,
        commitAgeHours: 5,
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('coalesced'));
      expect(r.originTags(), [
        'v0.1.495',
      ], reason: 'a fresh tag must coalesce pending commits');
      expect(r.ghLog(), isEmpty);
    });

    test('E1 race — a tag that appeared mid-run rejects the push; the run re-derives the next version and lands THAT', () {
      final r = runAutoReleaseDirect('race-retry', raceMode: 'once');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('Tag push raced'));
      expect(
        r.originTagExists('v0.1.496'),
        isTrue,
        reason: 'the racer pre-pushed v0.1.496 — it must exist on origin',
      );
      expect(
        r.originTagExists('v0.1.497'),
        isTrue,
        reason:
            'the raced run must re-derive from the freshly fetched tags '
            'and push v0.1.497',
      );
      final creates = r
          .ghLog()
          .where((l) => l.contains('release create'))
          .toList();
      expect(
        creates,
        hasLength(0),
        reason:
            'NO GitHub Release is created per run (gh-1801: the script '
            'resolves an empty asset list — an asset-less create '
            'publishes an empty latest; the binaries job owns creation)',
      );
      expect(
        r.originHeadAfter,
        r.originHeadBefore,
        reason:
            'the race burned only tags — zero commits land on main '
            '(gh-1522)',
      );
    });

    test('E1 exhaustion — a tag race on every attempt exits 1 after 3 tries, creating nothing', () {
      final r = runAutoReleaseDirect('race-exhaust', raceMode: 'always');
      expect(r.exitCode, 1, reason: 'exhaustion must fail loud: ${r.output}');
      expect(r.output, contains('failed after 3 attempts'));
      expect(r.output, contains('Tag push raced'));
      expect(
        r.ghLog().where((l) => l.contains('release create')),
        isEmpty,
        reason: 'a raced-out run must never create a release',
      );
      expect(
        r.originHeadAfter,
        r.originHeadBefore,
        reason: 'a raced-out run must never touch main',
      );
    });

    test('tag sequence — releases cut consecutive tags on origin/main with zero commits on main and one create each', () {
      // gh-1522: the release IS the tag. r1 cuts v0.1.496 on origin/main
      // without landing a single commit; after the coalesce window opens
      // (the tagged commit backdated 3h) and new work lands, a second run
      // cuts v0.1.497 — main history stays clean of bot commits the whole
      // time.
      final r1 = runAutoReleaseDirect('sequence');
      expect(r1.exitCode, 0, reason: r1.output);
      expect(
        r1.originHeadAfter,
        r1.originHeadBefore,
        reason:
            'gh-1522: zero commits land on main — the tag pins the '
            'existing head',
      );
      expect(r1.originTagExists('v0.1.496'), isTrue);
      expect(
        r1.originTagTarget('v0.1.496'),
        r1.originHeadAfter,
        reason: 'the tag must point at origin/main as of the cut',
      );
      expect(
        r1.ghLog().where((l) => l.contains('release create v0.1.496')),
        hasLength(0),
        reason: 'gh-1801: no release object is created by auto_release',
      );
      expect(
        r1.originSubjects(3).where((s) => s.startsWith('chore(release):')),
        isEmpty,
        reason:
            'no chore(release) bot commit may land on main anymore '
            '(gh-1522)',
      );

      // Open the 2h coalesce window: the guard keys on the tagged COMMIT's
      // date (git log %ct dereferences the annotated tag), so amend the
      // tagged commit backdated, then re-create the tag object (also
      // backdated) and force-push both. Then queue the next pending work.
      final backdate = {
        'GIT_COMMITTER_DATE':
            (DateTime.now()
                        .subtract(const Duration(hours: 3))
                        .millisecondsSinceEpoch ~/
                    1000)
                .toString(),
      };
      void git(List<String> args, {Map<String, String> env = const {}}) {
        final res = Process.runSync(
          r1.gitBin,
          args,
          workingDirectory: r1.seedPath,
          environment: env,
          includeParentEnvironment: true,
        );
        expect(res.exitCode, 0, reason: 'sequence git $args: ${res.stderr}');
      }

      git(['commit', '-q', '--amend', '--no-edit'], env: backdate);
      git(['push', '-q', '-f', 'origin', 'HEAD:main']);
      git([
        'tag',
        '-a',
        '-f',
        'v0.1.496',
        '-m',
        'Release v0.1.496',
      ], env: backdate);
      git(['push', '-q', '-f', 'origin', 'v0.1.496']);
      File('${r1.seedPath}/README.md').writeAsStringSync('more work\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'more pending work']);
      git(['push', '-q', 'origin', 'HEAD:main']);

      final r2 = r1.rerun();
      expect(r2.exitCode, 0, reason: r2.output);
      expect(r2.originTagExists('v0.1.497'), isTrue);
      expect(
        r2.originTagTarget('v0.1.497'),
        r2.originHeadAfter,
        reason: 'v0.1.497 pins the new main head (with more pending work)',
      );
      final creates = r2
          .ghLog()
          .where((l) => l.contains('release create'))
          .toList();
      expect(
        creates,
        hasLength(0),
        reason: 'gh-1801: no release object across the sequence',
      );
      expect(
        r2.originSubjects(4).where((s) => s.startsWith('chore(release):')),
        isEmpty,
        reason: 'main history stays clean across the whole sequence',
      );
    });

    test('suite git resolution is host-independent — no session shim decides fixture behavior', () {
      // gh-1172 round-3 suggestion: the pre-existing fixture helpers called
      // bare `Process.runSync('git', ...)`, inheriting whatever git sat first
      // on PATH — on shim-hostile hosts that was a broken git-push-guard copy
      // and the AC5 notes tests failed with "No changes since the previous
      // release." All fixture/notes git traffic now routes through the
      // resolved real binary; pin its invariants.
      final git = resolveRealGit();
      expect(File(git).existsSync(), isTrue, reason: '$git must exist');
      expect(
        git.endsWith('git-push-guard.sh'),
        isFalse,
        reason: 'the resolved git must never be an agent-session guard shim',
      );
      final r = Process.runSync(git, ['--version']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout.toString(), startsWith('git version'));
    });
  });

  // ── gh-1005 — PTY legs are hosted-linux-only, fa-m5-1 never on the PR path
  // The on-prem M5 pool is ONE runner reserved for macOS-specific work
  // (cube-kernel-live). These pins freeze the migration topology: the
  // runner-pick probe is gone, the consolidated linux leg carries coverage
  // + duration reporting, and no PTY screenshot leg sits on macOS.
  group('gh-1005 — PTY legs never route to fa-m5 / hosted macOS', () {
    test('no runner-pick probe and no mac pty-integration leg remains', () {
      final ci = jobsOf('.github/workflows/ci.yml');
      final nightly = jobsOf('.github/workflows/nightly.yml');
      expect(
        ci.containsKey('runner-pick'),
        isFalse,
        reason: 'the M5_POOL probe would route PR legs back onto fa-m5-1',
      );
      expect(
        ci.containsKey('pty-integration'),
        isFalse,
        reason: 'the mac shards merged into pty-integration-linux (gh-1005)',
      );
      expect(nightly.containsKey('runner-pick'), isFalse);
      // The reserved runner's only PR-time consumer stays the macOS kernel E2E.
      expect(
        (ci['cube-kernel-live'] as YamlMap)['runs-on'].toString(),
        contains('macos-m5'),
        reason:
            'cube-kernel-live keeps the genuinely macOS-only gate on fa-m5-1',
      );
    });

    test('every PR PTY leg runs on ubuntu-24.04-arm', () {
      final ci = jobsOf('.github/workflows/ci.yml');
      for (final id in [
        'pty-integration-linux',
        'pty-visual',
        'cli-visual-settings',
      ]) {
        expect(
          (ci[id] as YamlMap)['runs-on'].toString(),
          'ubuntu-24.04-arm',
          reason: '\$id must stay on the hosted linux arm64 pool',
        );
      }
      final nightly = jobsOf('.github/workflows/nightly.yml');
      expect(
        (nightly['pty-integration'] as YamlMap)['runs-on'].toString(),
        'ubuntu-24.04-arm',
      );
      // gh-1538: the nightly cli-visual job is REMOVED — ci.yml's
      // path-blind pty-visual PR leg runs the identical
      // `flutter test test/cli_visual --tags integration` on the same
      // runner pre-merge, so nightly was re-running a gate it duplicates.
    });

    test(
      'the consolidated linux leg carries the coverage + duration reporting',
      () {
        final job =
            jobsOf('.github/workflows/ci.yml')['pty-integration-linux']
                as YamlMap;
        final steps = job['steps'] as YamlList;
        final runText = steps
            .whereType<YamlMap>()
            .map((s) {
              final withBlock = s['with'];
              return '${s['run'] ?? ''} ${s['uses'] ?? ''} ${withBlock ?? ''}';
            })
            .join('\n');
        expect(
          runText,
          contains('--coverage=coverage'),
          reason: 'the leg feeds the CLI coverage ratchet',
        );
        expect(
          runText,
          contains('--file-reporter'),
          reason: 'the leg feeds the #928 duration gate',
        );
        for (final artifact in [
          'pty-coverage-shard-',
          'integration-json-shard-',
        ]) {
          expect(
            runText,
            contains(artifact),
            reason:
                '\$artifact uploads must survive the consolidation '
                '(pty-coverage-gate downloads them)',
          );
        }
        // The gate consumes THIS leg, not a phantom mac leg.
        expect(
          (jobsOf('.github/workflows/ci.yml')['pty-coverage-gate']
                  as YamlMap)['needs']
              .toString(),
          contains('pty-integration-linux'),
        );
      },
    );
  });

  group('committed-artifact hygiene (gh-1033 review thread 11)', () {
    test('no cov-*/ raw coverage dump directories exist in the tree', () {
      final offenders = Directory('.')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .where((name) => name.startsWith('cov-'))
          .toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'scratch coverage runs must write under the ignored '
            'coverage/ dir — a WIP auto-save swept cov-raw2/ (2.8 MB of '
            'VM coverage JSON with absolute runner paths) onto the branch '
            'once already',
      );
    });

    test('.gitignore sweeps future cov-*/ scratch dirs', () {
      expect(
        read('.gitignore').split('\n').map((line) => line.trim()),
        contains('cov-*/'),
        reason:
            'next to the coverage/ entries: a stray cov-* run dir '
            'must never become committable again',
      );
    });
  });
}
