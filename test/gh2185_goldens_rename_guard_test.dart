// gh-2185 rework — the mechanical `golden/` → `goldens/` rename must not
// outrun its consumers.
//
// The rename merged `flutter_app/test/golden/` + `test/goldens/` into ONE
// `flutter_app/test/goldens/` (and `packages/fa_ui/test/trajectory/golden/`
// → `goldens/`). Three regressions shipped with it and none is catchable by
// the runtime suites (Actions workflows never execute in the PR run):
//   - golden-regen.yml over-replaced to `goldens` (double-s) — the
//     label-triggered macOS baseline-regen workflow pointed at
//     `test/goldens`, a directory that does not exist, and its upload path
//     matched nothing (the regen loop for pixel baselines was dead);
//   - root .gitignore still ignored the OLD singular fa_ui failures path
//     (`.../golden/failures/`), so 24 transient flutter_test failure
//     artifacts (`*_testImage/maskedDiff/isolatedDiff/masterImage.png`)
//     were swept into git — the exact regenerable-dump class gh-2185
//     purges (AC3/AC6);
//   - the reporter dirs moved to `build/test-results/` but four workflow
//     steps still `mkdir -p test-results` (the old dir). The nightly
//     classification step then writes `build/test-results/exit-code` via a
//     shell redirect — which does NOT create parents — so if the runner
//     dies before any report file exists, the exit code is lost.
//
// Deliberately static asserts over the workflow/gitignore text + the git
// index (same style as ci_core_shard_timeout_guard_test.dart and
// root_allowlist_guard_test.dart): cheap, deterministic, and exactly the
// layer the regressions live at.
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

const goldenRegen = '.github/workflows/golden-regen.yml';
const ci = '.github/workflows/ci.yml';
const nightly = '.github/workflows/nightly.yml';
const rootGitignore = '.gitignore';
const appGitignore = 'flutter_app/.gitignore';

/// The double-s token the mechanical rename produced (`goldenss`) — no
/// path in the repo is spelled with it, so any occurrence is a regression.
const doubleS = 'goldenss';

ProcessResult git(List<String> args) =>
    Process.runSync('git', <String>[...args]);

void expectOk(ProcessResult r, String what) {
  expect(r.exitCode, 0, reason: '$what failed: ${r.stderr}');
}

void main() {
  test('golden-regen.yml carries no `goldens` over-replacement token', () {
    final text = read(goldenRegen);
    expect(
      text.contains(doubleS),
      isFalse,
      reason:
          'the rename produced `goldens` (double-s) in $goldenRegen — '
          'no such directory exists; the macOS regen workflow is dead',
    );
  });

  test('golden-regen.yml run/upload targets exist on disk', () {
    final text = read(goldenRegen);
    // The merged goldens dir and its baselines subdir are the only valid
    // targets for the `flutter test <dir> --update-goldens` run and the
    // artifact upload.
    expect(
      Directory('flutter_app/test/goldens').existsSync(),
      isTrue,
      reason: 'merged goldens test dir must exist',
    );
    expect(
      Directory('flutter_app/test/goldens/goldens').existsSync(),
      isTrue,
      reason: 'goldens baselines subdir must exist',
    );
    // Every path-like reference the workflow makes to the goldens tree
    // must resolve under the real merged dir.
    for (final match in RegExp(
      r'flutter_app/test/goldens[a-z/]*',
    ).allMatches(text)) {
      final ref = match.group(0)!;
      expect(
        File(ref).existsSync() || Directory(ref).existsSync(),
        isTrue,
        reason: '$goldenRegen references `$ref` which does not exist',
      );
    }
  });

  test('no transient golden-failure dumps are tracked in git', () {
    final r = git(<String>['ls-files', '*test*/failures/*']);
    expectOk(r, 'git ls-files failures');
    final tracked = r.stdout
        .toString()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    expect(
      tracked,
      isEmpty,
      reason:
          'regressable flutter_test failure artifacts leaked into the '
          'index: $tracked — the failures/ output class must stay untracked',
    );
  });

  test('the purged root memory store never re-tracks notes (gh-2103 merge '
      'recurrence)', () {
    // gh-2185 AC2/AC3: ONE memory home at .fah/memory/ (local-only); the
    // 921-note root memory/ store was purged from the index and .gitignore
    // keeps the PATH ignored — but ignore rules cannot untrack files a
    // merge delivers, and main's gh-2103 landing (#2183) re-delivered two
    // notes under memory/ TRACKED (the root allow-list gate fails on
    // exactly `memory` until they leave the index again). Every future
    // merge from main until this PR lands can re-deliver them, so the
    // invariant is pinned at the index level: nothing under the old root
    // store may be tracked, and the preserved copies must live in the
    // .fah/memory home.
    final r = git(<String>['ls-files', 'memory/']);
    expectOk(r, 'git ls-files memory');
    final tracked = r.stdout
        .toString()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    expect(
      tracked,
      isEmpty,
      reason:
          'the purged root memory/ store re-appeared in the index: $tracked '
          '— preserve the notes into .fah/memory/note/ and git rm them '
          '(.gitignore alone cannot untrack a merge-delivered file)',
    );
    // The .fah home is really ignored, so the preserved copies never
    // re-enter git from the other side either.
    final ignored = git(<String>['check-ignore', '.fah/memory/note/probe.md']);
    expectOk(ignored, 'git check-ignore .fah/memory');
  });

  test('root .gitignore covers the RENAMED fa_ui failures path', () {
    final text = read(rootGitignore);
    expect(
      text.contains('packages/fa_ui/test/trajectory/goldens/failures/'),
      isTrue,
      reason:
          'root .gitignore must ignore the renamed '
          'packages/fa_ui/test/trajectory/goldens/failures/',
    );
    expect(
      text.contains('trajectory/golden/failures/'),
      isFalse,
      reason:
          'root .gitignore still names the pre-rename singular '
          'golden/failures path — it can never match again',
    );
    // The probe must actually be ignored (the rule fires, not just sits).
    final r = git(<String>[
      'check-ignore',
      '-v',
      'packages/fa_ui/test/trajectory/goldens/failures/probe.png',
    ]);
    expectOk(r, 'git check-ignore');
    expect(r.stdout.toString(), contains('goldens/failures'));
  });

  test('flutter_app/.gitignore failures rule stays on the merged dir', () {
    final text = read(appGitignore);
    expect(
      text.contains('test/goldens/failures/'),
      isTrue,
      reason: 'flutter_app/.gitignore keeps ignoring test/goldens/failures/',
    );
    expect(
      text.contains('test/golden/failures/'),
      isFalse,
      reason: 'stale singular test/golden/failures rule must not remain',
    );
  });

  test('no workflow step mkdirs the old `test-results` dir', () {
    for (final wf in <String>[ci, nightly]) {
      final text = read(wf);
      final stale = RegExp(r'mkdir -p test-results\b(?!/)').allMatches(text);
      expect(
        stale,
        isEmpty,
        reason:
            '$wf still runs `mkdir -p test-results` — reporters write '
            'to `build/test-results/` and a bare shell redirect does not '
            'create parents, so the exit-code echo can lose the code',
      );
    }
    // Every test-results mkdir targets the real reporters home.
    for (final wf in <String>[ci, nightly]) {
      final text = read(wf);
      for (final match in RegExp(
        r'mkdir -p \S*test-results\S*',
      ).allMatches(text)) {
        expect(
          match.group(0),
          contains('build/test-results'),
          reason:
              '$wf creates `${match.group(0)}` — test-results dirs live '
              'under build/',
        );
      }
    }
  });
}
