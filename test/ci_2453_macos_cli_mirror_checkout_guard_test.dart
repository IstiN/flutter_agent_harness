// gh-2453 (run 45945536578, 2026-11-27) — why build-macos-cli must never
// go back to a raw actions/checkout on the self-hosted macos-m5 pool.
//
// HISTORY: the daily-publish cli leg red'd because the `Build macOS CLI
// arm64` job sat in its checkout step for 45 minutes: the raw
// actions/checkout (fetch-depth: 0, filter: blob:none) full-history
// `git fetch --unshallow` negotiated refs at 06:16:40 and then STALLED
// with zero output for 44m45s — no stall guard, no retry — until the
// job's timeout-minutes: 45 fired ("The job has exceeded the maximum
// execution time of 45m0s"). The sibling `Build macOS CLI x64` ran the
// identical fetch in 2.25s on a warm workspace — pure link roulette on
// the flaky-link fa-m5 pool (gh-2013: ONE Mac hosting the fa-m5 /
// fa-m5-2 / fa-m5-3 registrations).
//
// This is the exact failure class gh-1644 already fixed for the rest of
// the pool (run 38855793382: a ~1 h unguarded transfer died "error: 2931
// bytes of body are still expected" → scripts/update_git_mirror.sh +
// mirror-seeded checkouts for the build-macos desktop matrix and the
// build-mobile iOS legs) — build-macos-cli was simply left on the raw
// fragile path.
//
//   AC1  build-macos-cli carries NO actions/checkout step — the
//        un-guarded full-history fetch is banned on this pool.
//   AC2  the job updates the persistent local git mirrors FIRST, via the
//        bootstrapped scripts/update_git_mirror.sh (commit-pinned raw URL
//        with the mirror copy as the no-network fallback — gh-1644/1665
//        bootstrap contract).
//   AC3  the checkout clones mirror-seeded (--reference) and BLOBLESS
//        FULL (--filter=blob:none, no --depth): the gh-1801 rework gave
//        this job full blobless history so release_lazy_draft.sh →
//        release_notes.sh can fall back to conventional commits since the
//        previous tag (gh-1477 precedent) — a --depth=1 desktop-style
//        checkout would silently degrade the fallback to one commit.
//   AC4  every network git command of the checkout (clone + the detached
//        sha checkout's lazy blob fetches) runs under the gh-1644 stall
//        guard (http.lowSpeedLimit + http.lowSpeedTime) so a wedged
//        transfer aborts in ~60s instead of holding the job to its
//        ceiling.
//   AC5  the clone and the sha checkout are bounded-retried with a
//        ::error on exhaustion (update_git_mirror.sh semantics: N
//        attempts, sleep between, never a silent single attempt).
//   AC6  the checkout is detached at $GITHUB_SHA (workflow_dispatch runs;
//        the mirror update ran first, so the sha is present).
//   AC7  ordering: mirror update → checkout → dart pub get → sqlite3
//        prewarm → dart build cli (the existing sqlite3 guards pin the
//        second half of this chain; the mirror swap must not disturb it).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos-cli';
const checkoutStepName = 'Checkout repository from local mirrors';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String path) => loadYaml(read(path))['jobs'] as YamlMap;

YamlList stepsOf(YamlMap job) => job['steps'] as YamlList;

String scriptOf(Object step) => (step as YamlMap)['run']?.toString() ?? '';

String nameOf(Object step) => (step as YamlMap)['name']?.toString() ?? '';

String _stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

String executableScriptOf(Object step) => _stripComments(scriptOf(step));

/// Index of the first step whose `uses:` ends with [actionSuffix].
int stepIndexUsing(YamlMap job, String actionSuffix) {
  final steps = stepsOf(job).toList();
  final i = steps.indexWhere((s) =>
      ((s as YamlMap)['uses']?.toString() ?? '').endsWith(actionSuffix));
  if (i == -1) fail('no build-macos-cli step uses <$actionSuffix>');
  return i;
}

/// The single merged, comment-stripped shell of the whole job.
String jobScript(YamlMap job) =>
    stepsOf(job).map((s) => executableScriptOf(s)).join('\n');

/// Index of the first step whose executable script matches [pattern].
int stepIndexMatching(YamlMap job, Pattern pattern) {
  final steps = stepsOf(job).toList();
  final i = steps.indexWhere((s) => executableScriptOf(s).contains(pattern));
  if (i == -1) {
    fail('no build-macos-cli step script contains <$pattern>');
  }
  return i;
}

/// Index of the first step NAMED [name].
int stepIndexNamed(YamlMap job, String name) {
  final steps = stepsOf(job).toList();
  final i = steps.indexWhere((s) => nameOf(s) == name);
  if (i == -1) fail('no build-macos-cli step named <$name>');
  return i;
}

void main() {
  final jobs = jobsOf(workflowPath);
  final job = jobs[jobName] as YamlMap;
  final script = jobScript(job);

  test('AC1: build-macos-cli has NO actions/checkout step (gh-2453)', () {
    final uses = stepsOf(job)
        .map((s) => (s as YamlMap)['uses']?.toString() ?? '')
        .toList();
    expect(
      uses.where((u) => u.startsWith('actions/checkout')),
      isEmpty,
      reason:
          'a raw actions/checkout on the self-hosted macos-m5 pool runs an '
          'un-guarded, un-retried full-history fetch that can hold the job '
          'until its 45m ceiling (gh-2453, run 45945536578)',
    );
  });

  test('AC2: job updates the local git mirrors via the bootstrapped script',
      () {
    stepIndexNamed(job, 'Update local git mirrors');
    expect(script, contains('scripts/update_git_mirror.sh'));
    // gh-1644/gh-1665 bootstrap: commit-pinned raw URL, mirror fallback.
    expect(script, contains('raw.githubusercontent.com'));
    expect(script, contains(r'${{ github.sha }}'));
  });

  test(
      'AC3: checkout is mirror-seeded (--reference) and blobless FULL '
      '(--filter=blob:none, no --depth)', () {
    expect(script, contains('--reference'));
    expect(script, contains('--filter=blob:none'));
    // Full history for release_notes.sh's conventional-commits fallback
    // (gh-1801): the clone must not be shallow.
    final checkoutScript = executableScriptOf(
      stepsOf(job)[stepIndexNamed(job, checkoutStepName)],
    );
    expect(
      checkoutScript,
      isNot(contains('--depth')),
      reason:
          'a --depth clone would break release_lazy_draft.sh → '
          'release_notes.sh history fallback (gh-1801 contract)',
    );
    expect(checkoutScript, contains('--no-checkout'));
    // Working tree materialized separately (tip blobs via promisor origin).
    expect(checkoutScript, contains('checkout --detach'));
  });

  test('AC4: stall guard (http.lowSpeedLimit + http.lowSpeedTime) on the '
      'network git commands', () {
    expect(script, contains('http.lowSpeedLimit'));
    expect(script, contains('http.lowSpeedTime'));
    final checkoutScript = executableScriptOf(
      stepsOf(job)[stepIndexNamed(job, checkoutStepName)],
    );
    expect(
      checkoutScript,
      allOf(
        contains('http.lowSpeedLimit'),
        contains('http.lowSpeedTime'),
      ),
      reason:
          'gh-1644 semantics: an attempt moving <1 KB/s for 60s is dead — '
          'abort and retry instead of holding the step for an hour',
    );
  });

  test('AC5: clone and sha checkout are bounded-retried with ::error on '
      'exhaustion', () {
    // Bounded retry loop per network phase (clone + sha checkout):
    // counted attempts, never a silent single attempt (the gh-2453 bug).
    final boundedLoop = RegExp(
      r'for\s*\(\(?\s*attempt\s*=\s*1\s*;\s*attempt\s*<=[^;]+;',
    );
    final checkoutScript = executableScriptOf(
      stepsOf(job)[stepIndexNamed(job, checkoutStepName)],
    );
    expect(
      boundedLoop.allMatches(checkoutScript).length,
      greaterThanOrEqualTo(2),
      reason:
          'both the mirror-seeded clone and the detached sha checkout need '
          'their own bounded retry loop — a single-attempt git command is '
          'the gh-2453 bug',
    );
    expect(checkoutScript, contains('::error::'));
  });

  test('AC6: checkout detaches at GITHUB_SHA', () {
    final checkoutScript = executableScriptOf(
      stepsOf(job)[stepIndexNamed(job, checkoutStepName)],
    );
    expect(checkoutScript, contains('GITHUB_SHA'));
  });

  test('AC7: ordering mirror update → checkout → pub get → prewarm → build',
      () {
    final update = stepIndexMatching(job, 'update_git_mirror.sh');
    final checkout = stepIndexNamed(job, checkoutStepName);
    final pubGet = stepIndexMatching(job, 'dart pub get');
    final prewarm = stepIndexUsing(job, 'sqlite3-native-assets-prewarm');
    final build = stepIndexMatching(job, 'dart build cli');
    expect(update, lessThan(checkout), reason: 'mirror seeded before clone');
    expect(checkout, lessThan(pubGet), reason: 'clone before pub get');
    expect(pubGet, lessThan(prewarm),
        reason: 'prewarm reads .dart_tool/package_config.json (gh-2072)');
    expect(prewarm, lessThan(build));
  });
}
