// Behavioral mint-path tests for scripts/release_attach_or_create.sh
// (PR #1783 review, gh-2026): when the release tag is DEFINITELY missing
// (`git ls-remote --exit-code` rc 2), the script mints an annotated tag
// and pushes it through the GH_TOKEN URL. Guards:
//  - GH_TOKEN unset → fail fast with a self-explaining ::error:: BEFORE
//    the push (the push URL would collapse to '' — git's cryptic
//    `fatal: bad repository ''`, run 39766453580 / v1.0.626 mobile leg);
//  - GH_TOKEN set → the push rides the token URL and the release create
//    follows. The static call-site env contract lives in
//    release_hygiene_test.dart ('every release_attach_or_create.sh call
//    site exports GH_TOKEN …').
//
// gh-2026 (v1.0.663 / v1.0.665 stale drafts): two more guards on the same
// mint, because the creating runs were GREEN while the tag train never
// started:
//  - actions/checkout persists the job token as
//    `http.<host>/.extraheader` in the local git config; that header
//    outranks the URL-embedded PAT on the wire, so the push authenticated
//    as GITHUB_TOKEN and GitHub never fired workflows for it (GITHUB_TOKEN
//    pushes are trigger-suppressed). The mint must strip the persisted
//    extraheader(s) BEFORE the push;
//  - the mint must verify the train actually started (any workflow run on
//    the tag ref) within a bounded budget, and fail loud otherwise — a
//    green run + no train is exactly the stranded-draft shape the daily
//    sweeper kept sweeping.
import 'package:test/test.dart';

import 'release_mint_test_support.dart';

void main() {
  test('tag mint with GH_TOKEN unset fails fast: ::error:: names the env gap, no empty-URL push', () {
    // PR #1783 review: the root symptom of run 39766453580 was git's
    // cryptic `fatal: bad repository ''` — the push URL collapses to ''
    // when GH_TOKEN is unset. The script must self-explain BEFORE the
    // push.
    final r = runReleaseMintFixture(
      'scripts/release_attach_or_create.sh',
      args: const ['v1.2.3', 'a.zip'],
      name: 'no-token',
      ghToken: null,
    );
    expect(r.exitCode, isNot(0));
    expect(
      r.output,
      contains('::error::'),
      reason: 'the failure must be a self-explaining Actions error',
    );
    expect(r.output, contains('GH_TOKEN is not set'));
    expect(
      r.pushes,
      isEmpty,
      reason: 'no push may be attempted without a credential',
    );
  });

  test('tag mint with GH_TOKEN set pushes the annotated tag through the token URL, then creates the release', () {
    final r = runReleaseMintFixture(
      'scripts/release_attach_or_create.sh',
      args: const ['v1.2.3', 'a.zip'],
      name: 'with-token',
      ghToken: 'pat-token-for-test',
    );
    expect(r.exitCode, 0, reason: r.output);
    expect(r.pushes, hasLength(1));
    expect(r.pushes.single, contains('x-access-token:'));
    expect(r.pushes.single, contains('pat-token-for-test'));
    expect(r.pushes.single, contains('@github.com/OWNER/REPO.git'));
    expect(r.pushes.single, contains('refs/tags/v1.2.3'));
    expect(
      r.ghLog.where((l) => l.contains('release create v1.2.3')),
      hasLength(1),
      reason: 'the mint ends in the release create',
    );
  });

  test('gh-2026: the mint strips the persisted checkout extraheader BEFORE the push', () {
    // actions/checkout persists GITHUB_TOKEN as
    // http.https://github.com/.extraheader; that Authorization outranks
    // the URL's PAT, so GitHub saw the push as a GITHUB_TOKEN push and
    // suppressed the tag train (v1.0.663 / v1.0.665 — green runs, zero
    // workflow runs on the tag refs, drafts swept 24h later). The mint
    // must unset the persisted extraheader(s) before pushing.
    final r = runReleaseMintFixture(
      'scripts/release_attach_or_create.sh',
      args: const ['v1.2.3', 'a.zip'],
      name: 'strip-header',
      ghToken: 'pat-token-for-test',
      seedExtraheader: true,
    );
    expect(r.exitCode, 0, reason: r.output);
    expect(r.pushes, hasLength(1), reason: r.output);
    final configIdx = r.gitLog.indexWhere(
      (l) =>
          l.contains('config') &&
          l.contains('--unset-all') &&
          l.contains('http.https://github.com/.extraheader'),
    );
    final pushIdx = r.gitLog.indexWhere((l) => l.startsWith('push '));
    expect(configIdx, greaterThanOrEqualTo(0), reason: r.output);
    expect(
      configIdx < pushIdx,
      isTrue,
      reason:
          'the extraheader strip must precede the push '
          '(git log: ${r.gitLog})',
    );
  });

  test('gh-2026: the mint verifies the tag train started before creating the draft', () {
    final r = runReleaseMintFixture(
      'scripts/release_attach_or_create.sh',
      args: const ['v1.2.3', 'a.zip'],
      name: 'verify-happy',
      ghToken: 'pat-token-for-test',
      trainRunning: true,
      extraEnv: const {
        'RELEASE_TRAIN_VERIFY_TRIES': '2',
        'RELEASE_TRAIN_VERIFY_SLEEP': '0',
      },
    );
    expect(r.exitCode, 0, reason: r.output);
    expect(
      r.gitLog.any((l) => l.startsWith('push ')),
      isTrue,
      reason: 'the push precedes the verification',
    );
    expect(
      r.ghLog.any(
        (l) =>
            l.contains('run list') &&
            l.contains('--branch v1.2.3') &&
            l.contains('OWNER/REPO'),
      ),
      isTrue,
      reason:
          'the mint must poll for a workflow run on the tag ref '
          '(gh log: ${r.ghLog})',
    );
    expect(
      r.ghLog.where((l) => l.contains('release create v1.2.3')),
      hasLength(1),
      reason: 'the draft create follows a verified train',
    );
  });

  test('gh-2026: a mint whose push fired no workflow run fails loud and never creates the draft', () {
    // The v1.0.663 / v1.0.665 shape: the push succeeds, no tag run ever
    // appears, the leg stays green, and the draft is swept a day later.
    // The mint must fail the step instead — the caller's draft lifecycle
    // guard and the red leg then own the failure.
    final r = runReleaseMintFixture(
      'scripts/release_attach_or_create.sh',
      args: const ['v1.2.3', 'a.zip'],
      name: 'verify-silent',
      ghToken: 'pat-token-for-test',
      trainRunning: false,
      extraEnv: const {
        'RELEASE_TRAIN_VERIFY_TRIES': '2',
        'RELEASE_TRAIN_VERIFY_SLEEP': '0',
      },
    );
    expect(r.exitCode, isNot(0), reason: r.output);
    expect(r.output, contains('::error::'));
    expect(r.output, contains('v1.2.3'));
    expect(
      r.output.contains('no workflow run'),
      isTrue,
      reason: 'the error must name the suppressed-train failure shape',
    );
    expect(
      r.ghLog.where((l) => l.contains('release create v1.2.3')),
      isEmpty,
      reason: 'no draft may be created for a tag with no train',
    );
    expect(r.pushes, hasLength(1), reason: 'the push itself was attempted');
  });
}
