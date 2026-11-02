// gh-2042 — release_attach_or_create.sh against a PUBLISHED release.
//
// The attach-or-create script's existing-release path (`upload_all`) is the
// v1.0.680 hole: it uploaded with --clobber into whatever release the tag
// resolved to — draft or published. Under AC1 the attach routes every asset
// through scripts/release_asset_gate.sh (published → skip attached fa-* /
// refuse unattached fa-* / allow non-fa), and the recovery publish+latest
// flip NEVER fires on a published release — `gh release edit --latest` on an
// older published release would drag the `latest` badge (and `fa update`)
// backwards to a downgrade.
//
// Reuses the release_hygiene_test.dart fixture harness (stubbed gh).
import 'dart:io';

import 'package:test/test.dart';

import 'release_hygiene_test_support.dart';

void main() {
  AttachOut runAttach(
    String name, {
    String? releaseState,
    List<String> attachedNames = const [],
    List<String> viewSeq = const ['exists'],
  }) {
    final dir = Directory(
      '${hygieneFixtureRoot.path}/immutable-$name-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final bin = stubGh(dir.path);
    if (releaseState != null) {
      File('${dir.path}/release-state.txt').writeAsStringSync('$releaseState\n');
    }
    if (attachedNames.isNotEmpty) {
      File(
        '${dir.path}/asset-names.txt',
      ).writeAsStringSync('${attachedNames.join('\n')}\n');
    }
    File('${dir.path}/view-seq.txt').writeAsStringSync('${viewSeq.join('\n')}\n');
    File('${dir.path}/a.zip').writeAsStringSync('asset-a');
    File('${dir.path}/b.zip').writeAsStringSync('asset-b');
    File('${dir.path}/release-notes.md').writeAsStringSync('curated notes\n');
    File('${dir.path}/log').writeAsStringSync('');
    final res = Process.runSync('bash', [
      File('scripts/release_attach_or_create.sh').absolute.path,
      'v1.2.3',
      'a.zip',
      'b.zip',
    ], workingDirectory: dir.path, environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GITHUB_RUN_ID': '111',
      'GITHUB_JOB': 'release-macos',
    });
    return AttachOut(
      res.exitCode,
      '${res.stdout}${res.stderr}',
      File('${dir.path}/log').readAsLinesSync(),
      File('${dir.path}/last-create-notes.md').existsSync()
          ? File('${dir.path}/last-create-notes.md').readAsStringSync()
          : null,
    );
  }

  test('published release + unattached fa-* assets → attach refuses loud, nothing uploaded', () {
    // a.zip/b.zip stand in for the fa-* DMG/zip stable names the daily
    // release-macos leg attaches (the v1.0.680 shape).
    final run = runAttach('published-fa', releaseState: 'false',
        attachedNames: ['fa-web-spa.zip']);
    expect(run.exitCode, isNot(0), reason: run.out);
    expect(run.out, contains('::error::'));
    expect(
      run.log.where((l) => l.contains('release upload')),
      isEmpty,
      reason: 'a refused attach uploads nothing',
    );
    expect(run.log.where((l) => l.contains('release create')), isEmpty,
        reason: 'the release exists — a refusal must not create a twin');
    expect(run.log.where((l) => l.contains('release edit')), isEmpty);
  });

  test('published release + already-attached assets → immutable skip, exit 0, no upload', () {
    final run = runAttach('published-skip', releaseState: 'false',
        attachedNames: ['a.zip', 'b.zip']);
    expect(run.exitCode, 0, reason: run.out);
    expect(run.log.where((l) => l.contains('release upload')), isEmpty);
    expect(run.out.toLowerCase(), contains('skip'));
  });

  test('published release + non-fa assets only → clobber-refresh attaches, exit 0', () {
    // The mobile leg (AAB/IPA/APK — not provenance-covered) keeps its
    // store-refresh contract on published releases.
    final run = runAttach('published-nonfa', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz']);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log.where((l) => l.contains('release upload v1.2.3 a.zip')),
      isNotEmpty,
      reason: 'non-fa assets keep the clobber-refresh path',
    );
  });

  test('published release + servable (SHA256SUMS attached) → NO publish flip (latest never drags backwards)', () {
    // Regression guard for the recovery path: on a DRAFT servable release
    // the attach publishes + flags latest (existing behavior, pinned by
    // release_hygiene_test.dart); on a PUBLISHED one the flip must stay
    // off — `--latest` here would move the badge to an older release.
    final run = runAttach('published-servable', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz', 'SHA256SUMS', 'SHA256SUMS.sig']);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log.where((l) => l.contains('release edit')),
      isEmpty,
      reason:
          'a published release is never re-flaged latest by the attach '
          '(gh-2042: latest must never move backwards)',
    );
  });

  test('draft release + fa-* assets → attach unchanged (uploads --clobber)', () {
    // Default fixture state (no release-state.txt) = draft.
    final run = runAttach('draft-fa', attachedNames: []);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log,
      contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
    );
    expect(run.log.where((l) => l.contains('release edit')), isEmpty,
        reason: 'un-servable draft stays unflipped (gh-1801, unchanged)');
  });

  test('draft release + servable → recovery publish + latest (unchanged)', () {
    final run = runAttach('draft-servable',
        attachedNames: ['SHA256SUMS', 'SHA256SUMS.sig']);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log,
      contains('release edit v1.2.3 --draft=false --latest --repo OWNER/REPO'),
      reason: 'the draft recovery path stays (gh-1801 rework)',
    );
  });

  test('release_lazy_draft.sh on a published release → still a no-op skip (the gate owns refusal)', () {
    // lazy_draft only CREATES; its callers' uploads are gated. Its
    // existing-release skip must stay a green no-op for all states.
    final dir = Directory(
      '${hygieneFixtureRoot.path}/immutable-lazy-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final bin = stubGh(dir.path);
    File('${dir.path}/release-state.txt').writeAsStringSync('false\n');
    File('${dir.path}/log').writeAsStringSync('');
    final res = Process.runSync('bash', [
      File('scripts/release_lazy_draft.sh').absolute.path,
      'v1.2.3',
    ], workingDirectory: dir.path, environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GITHUB_RUN_ID': '111',
      'GITHUB_JOB': 'binaries-linux-x64',
    });
    expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
    final log = File('${dir.path}/log').readAsLinesSync();
    expect(log.where((l) => l.contains('release create')), isEmpty);
  });
}
