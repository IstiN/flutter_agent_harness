// Behavioral missing-ref tests for scripts/release_lazy_draft.sh
// (gh-2026): `gh release create --draft` for a MISSING tag REST-mints a
// lightweight API tag with NO push event — the v0.1.408 silent class
// (issue #597). When the fast build-macos.yml legs (build-extension /
// build-macos-cli, ubuntu/hosted, ~10 min) beat the attach legs
// (release-macos / release-mobile), the silent mint wins the race, every
// attach leg finds the tag existing and skips the CI-firing annotated
// push, and the draft is stranded forever (swept by the daily sweeper —
// the gh-2026 recurrence). The lazy create must mint the missing tag
// through the same CI-firing annotated push the attach path uses
// (scripts/release_tag_mint.sh) BEFORE creating the draft.
import 'package:test/test.dart';

import 'release_mint_test_support.dart';

void main() {
  test(
    'gh-2026: a lazy draft for a MISSING tag mints it via the CI-firing annotated push first',
    () {
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-with-token',
        ghToken: 'pat-token-for-test',
        seedExtraheader: true,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          // Keep the mint's train verification off the wall clock.
          'RELEASE_TRAIN_VERIFY_TRIES': '2',
          'RELEASE_TRAIN_VERIFY_SLEEP': '0',
        },
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.pushes, hasLength(1));
      expect(r.pushes.single, contains('x-access-token:'));
      expect(r.pushes.single, contains('pat-token-for-test'));
      expect(r.pushes.single, contains('refs/tags/v1.2.3'));
      // The silent REST mint would let `gh release create` create the tag;
      // the annotated push must precede the draft create.
      final pushIdx = r.gitLog.indexWhere((l) => l.startsWith('push '));
      final createIdx = r.ghLog.indexWhere(
        (l) => l.contains('release create v1.2.3'),
      );
      expect(pushIdx, greaterThanOrEqualTo(0));
      expect(createIdx, greaterThanOrEqualTo(0));
      expect(
        r.ghLog.take(createIdx).where((l) => l.contains('run list')).isNotEmpty,
        isTrue,
        reason: 'the train verification runs before the draft create',
      );
    },
  );

  test(
    'gh-2026: a lazy draft whose mint fired no workflow run fails loud, no draft',
    () {
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-silent-train',
        ghToken: 'pat-token-for-test',
        seedExtraheader: true,
        trainRunning: false,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          'RELEASE_TRAIN_VERIFY_TRIES': '2',
          'RELEASE_TRAIN_VERIFY_SLEEP': '0',
        },
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.output, contains('::error::'));
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        isEmpty,
        reason: 'no draft may be created for a tag with no train',
      );
      // The mint push ran, and the failed verification rolled the
      // untrained ref back (PR #2029 review) — captured as the delete push.
      expect(
        r.pushes.where(
          (l) => l.contains('refs/tags/v1.2.3') && !l.contains(':refs/tags/'),
        ),
        hasLength(1),
      );
      expect(r.pushes.where((l) => l.contains(':refs/tags/')), hasLength(1));
    },
  );

  test(
    'gh-2337: a lazy draft whose create fails (body too long) fails loud — never "✅ lazy draft ready"',
    () {
      // Run 44680647719 (v1.0.756): the curated `## Unreleased` notes body
      // (131,072 bytes) exceeded GitHub's 125,000-character release-body
      // cap; `gh release create` answered HTTP 422 "body is too long",
      // the `|| true` swallowed it, the script printed "✅ lazy draft
      // ready", and the attach gate failed with "release not found". The
      // create failure must surface: exit ≠ 0 with a ::error::, and no
      // success line.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-create-fails',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        ghCreateFails: true,
        githubRunId: '222',
        githubJob: 'build-extension',
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.output, contains('::error::'));
      expect(
        r.output,
        isNot(contains('✅ lazy draft ready')),
        reason: 'the success line must never print for a failed create',
      );
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        hasLength(1),
        reason: 'the create was attempted exactly once',
      );
    },
  );

  test(
    'gh-2337: a lazy draft whose create loses the view→create race still exits 0',
    () {
      // The ORIGINAL `|| true` intent (gh-1801): a sibling leg may create
      // the release between our view and create; the loser must exit 0
      // and let the caller upload into the winner's release. A failed
      // create followed by a release that NOW exists is exactly that
      // race — not an error.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-create-race',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        ghCreateFails: true,
        viewFoundAfterFirst: true,
        githubRunId: '222',
        githubJob: 'build-extension',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.output,
        contains('✅ lazy draft ready'),
        reason: 'the race-won path keeps the tolerant contract',
      );
    },
  );

  test(
    'gh-2337 rework: an over-cap lazy draft body still carries the release-draft-owner marker',
    () {
      // The cap helper truncates from the TAIL, so a marker stamped
      // before the cap is cut off — the created draft then carries no
      // ownership proof: release_draft_guard.sh resolves `<unmarked>`
      // and refuses to reclaim, the daily sweeper buckets it human
      // (the legs run with GH_TOKEN=RELEASE_PAT) and keeps it, and
      // dedupe ignores it — a forever-orphaned draft (gh-282). The
      // body must be bounded BEFORE the marker is stamped; the bounded
      // body (≤ 120,000) plus the marker stays far under the
      // 125,000-character API cap.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-marker-survives-cap',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        seedOversizeChangelog: true,
        githubRunId: '222',
        githubJob: 'build-extension',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.notesCapture, isNotEmpty, reason: 'the create carried notes');
      expect(
        r.notesCapture,
        contains('truncated'),
        reason: 'the seeded 131k-class curated body must actually be bounded',
      );
      expect(
        r.notesCapture,
        contains('release-draft-owner: run/222/job/build-extension'),
        reason:
            'the ownership marker must survive the body cap — the guard, '
            'sweeper and dedupe all match it in the release body',
      );
      expect(
        r.notesCapture.length,
        lessThanOrEqualTo(125_000),
        reason: 'the created body must stay under the API cap',
      );
    },
  );

  test(
    'gh-2432: a transient HTTP 500 on the draft create is retried and the leg goes green',
    () {
      // Run 45643151796 (v1.0.778): every hosted binaries leg's
      // single-shot create got `HTTP 500 (…/releases)` (the body was
      // already bounded — this was NOT the gh-237 422), no in-run retry
      // re-checked, three legs went red, release-provenance (the sole
      // publish point) was skipped, and the staged draft rotted until
      // the daily sweeper reclaimed it. A TRANSIENT server 5xx must be
      // retried with the existing race re-view at the boundary — the
      // next attempt answers and the leg ships.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-create-transient-500-retried',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          'GH_STUB_CREATE_FAILS_5XX_N': '1',
          'RELEASE_LAZY_CREATE_TRIES': '3',
          'RELEASE_LAZY_CREATE_SLEEP': '0',
        },
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('✅ lazy draft ready'));
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        hasLength(2),
        reason: 'the 500 was retried once — two create attempts, one success',
      );
    },
  );

  test(
    'gh-2432: a 500 whose create landed server-side is healed by the retry-boundary re-view',
    () {
      // The precise v1.0.778 healing shape: the 500'd POST actually
      // CREATED the draft server-side (it was visible minutes later to
      // the macOS legs), but the failure path's single re-view ran too
      // soon and the leg went red. With the retry in place, the
      // re-view at the retry boundary resolves the release and the leg
      // exits 0 WITHOUT a second create racing another draft into
      // existence.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-create-500-landed-healed',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        viewFoundAfterFirst: true,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          'GH_STUB_CREATE_FAILS_5XX_N': '1',
          'RELEASE_LAZY_CREATE_TRIES': '3',
          'RELEASE_LAZY_CREATE_SLEEP': '0',
        },
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('✅ lazy draft ready'));
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        hasLength(1),
        reason:
            'the landed 500 must heal through the re-view — no second '
            'create may twin the already-staged draft',
      );
    },
  );

  test(
    'gh-2432: a 500 on every attempt fails loud after the bounded tries',
    () {
      // The retry is bounded: an API that keeps 500ing must still fail
      // the leg loud (gh-237 contract — never "✅ lazy draft ready" for
      // a create that did not happen), after exactly TRIES attempts.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-create-500-exhausted',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          'GH_STUB_CREATE_FAILS_5XX_N': '99',
          'RELEASE_LAZY_CREATE_TRIES': '2',
          'RELEASE_LAZY_CREATE_SLEEP': '0',
        },
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.output, contains('::error::'));
      expect(r.output, isNot(contains('✅ lazy draft ready')));
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        hasLength(2),
        reason: 'exactly RELEASE_LAZY_CREATE_TRIES attempts, then loud failure',
      );
    },
  );

  test(
    'gh-2432: a deterministic 422 body-too-long is never retried',
    () {
      // gh-237 pins the loud single-attempt failure for the 422 cap —
      // the retry must key on TRANSIENT 5xx only: a deterministic
      // validation failure cannot answer differently on attempt 2.
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-create-422-not-retried',
        ghToken: 'pat-token-for-test',
        seedTag: true,
        ghCreateFails: true,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          'RELEASE_LAZY_CREATE_TRIES': '3',
          'RELEASE_LAZY_CREATE_SLEEP': '0',
        },
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.output, contains('::error::'));
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        hasLength(1),
        reason: 'a 4xx failure is deterministic — attempted exactly once',
      );
    },
  );
}
