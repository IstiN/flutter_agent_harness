// gh-1192 — release-flow race hardening (2026-10-03 incident, issue #1189),
// reworked gh-1522: the git TAG is the single source of truth for versions
// (the committed pubspec carries the 0.0.0-dev placeholder) and the
// release-bot file-bump flow is retired — auto_release.sh cuts the tag
// directly off main. Defect B's tag_release.sh race sandbox is gone with
// the retired flow.
//
// Defect A — daily-publish's pub.dev verify had no «release in flight»
//   class: between `git push <tag>` and the tag's ci.yml run becoming
//   visible/completing, the check read «no run» and false-errored —
//   auto-filing #1189 one minute before the healthy tag run completed.
//   The classification now lives in scripts/verify_pubdev_release.sh,
//   which derives the version under test from the LATEST REMOTE TAG.
//
// Behavioral coverage follows the release_hygiene_test.dart style: fixture
// git repos (bare origin + clones) and stubbed `gh`/`curl` on PATH. Git
// resolves to the real binary — the session PATH may carry shims
// (git-push-guard) that must never decide fixture behavior.
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

final _fixtureRoot = Directory.systemTemp.createTempSync('release-race-');

/// The real git binary for sandbox shims AND fixture helpers: the session
/// PATH may carry git-push-guard.sh shims — skip any copy of those plus
/// [skipDir] (the sandbox's own shim dir) so every git call resolves to a
/// real binary (same defense as release_hygiene_test.dart).
String _resolveRealGit([String? skipDir]) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty || dir == skipDir) continue;
    final cand = '$dir/git';
    if (!File(cand).existsSync()) continue;
    final resolved = File(cand).resolveSymbolicLinksSync();
    if (resolved.endsWith('git-push-guard.sh')) continue;
    return resolved;
  }
  return '/usr/bin/git';
}

void _git(
  List<String> args, {
  String? cwd,
  Map<String, String> env = const {},
}) {
  final r = Process.runSync(
    _resolveRealGit(),
    args,
    workingDirectory: cwd,
    environment: env,
  );
  if (r.exitCode != 0) fail('fixture git $args failed: ${r.stderr}');
}

String _gitOut(List<String> args, {String? cwd}) {
  final r = Process.runSync(_resolveRealGit(), args, workingDirectory: cwd);
  if (r.exitCode != 0) fail('fixture git $args failed: ${r.stderr}');
  return r.stdout.toString().trim();
}

int _epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// Stub `bin/` dir: pass-through `git` (the resolved real binary), canned
/// `curl` (serves the pub.dev package API from GH_STUB_DIR), and a `gh`
/// stub answering `run list`/`run view` from canned JSON while logging
/// every invocation.
class StubEnv {
  StubEnv(this.bin, this.realGit);
  final String bin; // prepend to PATH
  final String realGit; // exported as FA_REAL_GIT for the git shim
}

StubEnv _installStubs(String dir) {
  final bin = Directory('$dir/bin')..createSync(recursive: true);
  final realGit = _resolveRealGit(bin.path);

  File('${bin.path}/git').writeAsStringSync(r'''
#!/usr/bin/env bash
# Fixture seam: a planted lsremote-fail-first marker makes the FIRST
# `git ls-remote` fail (a transient remote-visibility failure) while later
# calls pass through to the real binary.
if [ "$1" = "ls-remote" ] && [ -n "$GH_STUB_DIR" ] \
    && [ -f "$GH_STUB_DIR/lsremote-fail-first" ]; then
  c="$GH_STUB_DIR/lsremote-count"
  n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
  [ "$n" -eq 1 ] && exit 1
fi
exec "$FA_REAL_GIT" "$@"
''');

  // pub.dev package API: before the tag-run rerun lands, pub.dev serves the
  // OLD version; once $GH_STUB_DIR/rerun-done exists (planted by the gh
  // stub's `run rerun`), it serves the new one. A $GH_STUB_DIR/curl-fail
  // marker simulates an API outage; every invocation is logged to curl.log
  // so tests can assert the read happened (or never did).
  File('${bin.path}/curl').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_STUB_DIR/curl.log"
if [ -f "\$GH_STUB_DIR/curl-fail" ]; then
  echo "curl: simulated pub.dev API failure" >&2
  exit 1
fi
if [ -f "\$GH_STUB_DIR/rerun-done" ] && [ -f "\$GH_STUB_DIR/pubdev-new.json" ]; then
  cat "\$GH_STUB_DIR/pubdev-new.json"
else
  cat "\$GH_STUB_DIR/pubdev.json"
fi
''');

  File('${bin.path}/gh').writeAsStringSync(r'''
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG_FILE"
cmd="$1"; shift || true
case "$cmd" in
  run)
    sub="$1"; shift || true
    case "$sub" in
      list)
        branch=""; jqf="."
        while [ $# -gt 0 ]; do
          case "$1" in
            --branch) branch="$2"; shift 2 ;;
            --jq) jqf="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        # Nth read of the same branch: runs-<branch>.N.json overrides the
        # base fixture when present — the past-grace re-read test (review
        # thread 2) plants a run on the SECOND read.
        cf="$GH_STUB_DIR/list-count-$branch"
        n=$(cat "$cf" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$cf"
        f="$GH_STUB_DIR/runs-$branch.$n.json"
        [ -f "$f" ] || f="$GH_STUB_DIR/runs-$branch.json"
        [ -f "$f" ] || f="$GH_STUB_DIR/runs.json"
        [ -f "$f" ] || { echo "stub: no fixture for branch '$branch'" >&2; exit 1; }
        jq -r "$jqf" "$f"
        ;;
      view)
        id="$1"; shift || true
        jqf="."
        while [ $# -gt 0 ]; do
          case "$1" in --jq) jqf="$2"; shift 2 ;; *) shift ;; esac
        done
        # Nth read of the same run: run-<id>.N.json overrides the base
        # fixture when present — the terminal-wait tests plant a queued
        # first read and a completed later one (#1368).
        cf="$GH_STUB_DIR/view-count-$id"
        n=$(cat "$cf" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$cf"
        f="$GH_STUB_DIR/run-$id.$n.json"
        [ -f "$f" ] || f="$GH_STUB_DIR/run-$id.json"
        if [ -f "$GH_STUB_DIR/rerun-done" ] && [ -f "$GH_STUB_DIR/run-$id-post.json" ]; then
          f="$GH_STUB_DIR/run-$id-post.json"
        fi
        [ -f "$f" ] || { echo "stub: no fixture for run '$id'" >&2; exit 1; }
        jq -r "$jqf" "$f"
        ;;
      watch) exit 0 ;;
      rerun) touch "$GH_STUB_DIR/rerun-done"; exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  label) exit 0 ;;
  issue)
    case "$1" in
      list) cat "$GH_STUB_DIR/issues.tsv" 2>/dev/null; exit 0 ;;
      close|comment|create) echo "https://github.com/OWNER/REPO/issues/99" ;;
      *) exit 0 ;;
    esac
    ;;
  release)
    # auto_release.sh's GitHub Release creation — expected, quiet success.
    exit 0 ;;
  *)
    # gh-1192 review thread 3: a silently-swallowed unknown subcommand lets
    # script drift read green (a grown `gh api` call would no-op and every
    # fixture stays vacuous). Fail loudly so drift turns into a red test.
    echo "stub: unexpected gh invocation: $*" >&2
    exit 1 ;;
esac
''');

  for (final f in ['git', 'curl', 'gh']) {
    Process.runSync('chmod', ['+x', '${bin.path}/$f']);
  }
  return StubEnv(bin.path, realGit);
}

Map<String, String> _parseOutputs(String path) {
  final out = <String, String>{};
  for (final line in File(path).readAsLinesSync()) {
    final i = line.indexOf('=');
    if (i > 0) out[line.substring(0, i)] = line.substring(i + 1);
  }
  return out;
}

class VerifyRun {
  VerifyRun(this.exitCode, this.output, this.outputs, this.ghLog);

  final int exitCode;
  final String output; // stdout+stderr
  final Map<String, String> outputs; // GITHUB_OUTPUT key=values
  final List<String> ghLog; // stubbed gh invocations

  String get status => outputs['status'] ?? '';
  bool get errored => output.contains('::error::');
  bool get inFlight => status == 'release-in-flight' && exitCode == 0;
}

/// Full sandbox for scripts/verify_pubdev_release.sh (the daily-publish
/// pubdev leg's check): a bare origin whose main carries the 0.0.0-dev
/// placeholder pubspec (seeded ONLY for the publish_to: none check —
/// gh-1522: the committed pubspec never carries the version) plus an
/// optional annotated tag `v[version]` backdated [tagAge] — the tag
/// DEFINES the version under test, which the script derives from
/// `git ls-remote --tags origin 'refs/tags/v*'` (a real git call against
/// this real origin, so no shim is needed for it). The annotated tagger
/// date is what %(creatordate:unix) reads back. A SHALLOW job clone the
/// script runs in, and stub gh/curl fixtures. [tagPresent]: false = no v*
/// tag on the remote at all → nothing has ever been released → the script
/// no-ops up-to-date. [staleTags] seeds older lightweight tags (E2: only
/// the LATEST tag is evaluated). [runsJson] is what
/// `gh run list --branch v<version>` serves ('[]' = the run is not visible
/// yet); [secondReadJson] overrides the SECOND read of that branch (the
/// past-grace re-read, review thread 2); [conclusion] is the completed
/// run's conclusion (served once the stub sees the run id);
/// [rerunToSuccess] makes the post-rerun view green;
/// [lsremoteFailFirst] makes the FIRST `git ls-remote` (the version
/// derivation) fail transiently — the script must fail OPEN (no tag read →
/// up-to-date), never alarm.
VerifyRun runVerify(
  String name, {
  String version = '0.1.497',
  String publishedVersion = '0.1.496',
  bool tagPresent = true,
  Duration tagAge = const Duration(seconds: 60),
  List<String> staleTags = const [],
  bool publishToNone = false,
  String? runsJson = '[]',
  String? secondReadJson,
  String conclusion = 'success',
  bool rerunToSuccess = false,
  // #1368 fixture seams: the run-view Nth-read override (run-<id>.1.json)
  // serves a queued status before the base completed one — the
  // terminal-wait flip.
  bool lsremoteFailFirst = false,
  String? firstViewJson,
  Map<String, String> extraEnv = const {},
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/verify-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final origin = '${dir.path}/origin.git';
  final seed = '${dir.path}/seed';
  final job = '${dir.path}/job';
  final stub = _installStubs(dir.path);
  final now = DateTime.now().toUtc();

  Directory(origin).createSync();
  _git(['init', '-q', '--bare', '-b', 'main', origin], cwd: dir.path);
  _git(['clone', '-q', origin, seed], cwd: dir.path);
  _git(['config', 'user.email', 't@t'], cwd: seed);
  _git(['config', 'user.name', 't'], cwd: seed);
  // gh-1522: the committed pubspec is the 0.0.0-dev placeholder — seeded
  // ONLY for the publish_to: none check; the version under test comes from
  // the remote tag below, never from this file.
  File('$seed/pubspec.yaml').writeAsStringSync(
    'name: demo\n'
    'version: 0.0.0-dev\n'
    '${publishToNone ? 'publish_to: none\n' : ''}',
  );
  _git(['add', '-A'], cwd: seed);
  _git(['commit', '-q', '-m', 'seed'], cwd: seed);
  // Stale older tags (E2 out-of-scope shape) — lightweight is fine, only
  // the annotated latest tag's tagger date is read back.
  for (final stale in staleTags) {
    _git(['tag', 'v$stale'], cwd: seed);
    _git(['push', '-q', 'origin', 'refs/tags/v$stale'], cwd: seed);
  }
  if (tagPresent) {
    // The annotated tag DEFINES the version under test; its tagger date is
    // backdated [tagAge].
    _git(
      ['tag', '-a', 'v$version', '-m', 'Release v$version'],
      cwd: seed,
      env: {'GIT_COMMITTER_DATE': '${_epoch(now.subtract(tagAge))}'},
    );
    _git(['push', '-q', 'origin', 'refs/tags/v$version'], cwd: seed);
  }
  _git(['push', '-q', 'origin', 'main'], cwd: seed);
  // The daily's checkout is SHALLOW (actions/checkout default fetch-depth
  // 1) — file:// so git honors --depth on the local transport.
  _git(['clone', '-q', '--depth', '1', 'file://$origin', job], cwd: dir.path);

  File(
    '${dir.path}/pubdev.json',
  ).writeAsStringSync('{"latest":{"version":"$publishedVersion"}}');
  File(
    '${dir.path}/pubdev-new.json',
  ).writeAsStringSync('{"latest":{"version":"$version"}}');
  File('${dir.path}/runs-v$version.json').writeAsStringSync(runsJson ?? '[]');
  if (secondReadJson != null) {
    File('${dir.path}/runs-v$version.2.json').writeAsStringSync(secondReadJson);
  }
  if (lsremoteFailFirst) {
    File('${dir.path}/lsremote-fail-first').writeAsStringSync('');
  }

  // The run-view fixture mirrors EVERY listed run's status: a queued/
  // in_progress entry stays pending on `run view` (the terminal-wait polls
  // it); a completed one serves [conclusion]. With [firstViewJson] the FIRST
  // entry's first view serves that (still queued) and the base flips to
  // completed — the «reaches terminal within the wait» shape. Post-rerun,
  // the stub serves the -post.json success when [rerunToSuccess].
  void plantRun(String listJson) {
    if (listJson.isEmpty || listJson == '[]') return;
    final objs = RegExp(
      r'\{[^}]*\}',
    ).allMatches(listJson).map((m) => m.group(0)!).toList();
    var first = true;
    for (final obj in objs) {
      final id = RegExp(r'"databaseId":\s*(\d+)').firstMatch(obj)?.group(1);
      if (id == null) continue;
      final listed =
          RegExp(r'"status":\s*"([^"]+)"').firstMatch(obj)?.group(1) ??
          'completed';
      final base = (firstViewJson != null && first) || listed == 'completed'
          ? '{"status":"completed","conclusion":"$conclusion"}'
          : '{"status":"$listed","conclusion":null}';
      File('${dir.path}/run-$id.json').writeAsStringSync(base);
      if (rerunToSuccess) {
        File(
          '${dir.path}/run-$id-post.json',
        ).writeAsStringSync('{"status":"completed","conclusion":"success"}');
      }
      if (firstViewJson != null && first) {
        File('${dir.path}/run-$id.1.json').writeAsStringSync(firstViewJson);
      }
      first = false;
    }
  }

  if (runsJson != null) plantRun(runsJson);
  if (secondReadJson != null) plantRun(secondReadJson);

  final outPath = '${dir.path}/github_output';
  final res = Process.runSync(
    'bash',
    [File('scripts/verify_pubdev_release.sh').absolute.path],
    workingDirectory: job,
    environment: {
      'PATH': '${stub.bin}:${Platform.environment['PATH']}',
      'FA_REAL_GIT': stub.realGit,
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/gh.log',
      'GITHUB_OUTPUT': outPath,
      // Test seams — production defaults live in the script.
      'PUBDEV_READ_SLEEP_SECS': '0',
      'PUBDEV_POLL_SLEEP_SECS': '0',
      ...extraEnv,
    },
  );
  return VerifyRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File(outPath).existsSync() ? _parseOutputs(outPath) : {},
    File('${dir.path}/gh.log').existsSync()
        ? File('${dir.path}/gh.log').readAsLinesSync()
        : <String>[],
  );
}

class ReportRun {
  ReportRun(this.exitCode, this.output, this.ghLog, this.summary);
  final int exitCode;
  final String output;
  final List<String> ghLog;
  final String summary;
}

/// Runs scripts/daily_publish_report.sh with the pubdev leg green and the
/// release-in-flight status override — the AC1 «no auto-filed issue» end of
/// the pipeline (issue filing lives in the report job, not the leg).
ReportRun runReport(String name) {
  final dir = Directory(
    '${_fixtureRoot.path}/report-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final stub = _installStubs(dir.path);
  File('${dir.path}/issues.tsv').writeAsStringSync('');
  final summaryPath = '${dir.path}/summary.md';
  final res = Process.runSync(
    'bash',
    [File('scripts/daily_publish_report.sh').absolute.path],
    workingDirectory: dir.path,
    environment: {
      'PATH': '${stub.bin}:${Platform.environment['PATH']}',
      'FA_REAL_GIT': stub.realGit,
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GITHUB_RUN_ID': '555',
      'GITHUB_SERVER_URL': 'https://github.com',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/gh.log',
      'GITHUB_STEP_SUMMARY': summaryPath,
      'NEXT_TAG': 'v0.1.498',
      'DAILY_PUBLISH_ASSIGNEE': 'ai-teammate',
      'LEG_TESTFLIGHT': 'skipped',
      'LEG_PLAY': 'skipped',
      'LEG_CLI': 'skipped',
      'LEG_WEBSITE': 'skipped',
      'LEG_ADDIN': 'skipped',
      'LEG_PUBDEV': 'success',
      'LEG_PUBDEV_STATUS': 'release-in-flight',
      'LEG_PUBDEV_PUBSPEC': '0.1.497',
      'LEG_PUBDEV_PUBLISHED': '0.1.496',
    },
  );
  return ReportRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/gh.log').existsSync()
        ? File('${dir.path}/gh.log').readAsLinesSync()
        : <String>[],
    File(summaryPath).existsSync() ? File(summaryPath).readAsStringSync() : '',
  );
}

class PlanRun {
  PlanRun(this.exitCode, this.output, this.outputs, this.ghLog, this.curlLog);
  final int exitCode;
  final String output;
  final Map<String, String> outputs; // GITHUB_OUTPUT key=values
  final List<String> ghLog; // stubbed gh invocations
  final List<String> curlLog; // stubbed curl invocations

  bool get changed => outputs['changed'] == 'true';
}

/// Sandbox for scripts/daily_plan.sh (the daily-publish plan job's
/// «Detect main movement and derive versions» step): an origin whose main
/// carries the 0.0.0-dev placeholder pubspec plus an optional annotated
/// latest tag `v[latestTag]` (gh-1522: the tag is the single source of
/// truth — the script derives the re-arm comparison version and the
/// `pubspec_version` output from `git tag --sort=-v:refname` in the job
/// clone), a FULL job clone (the plan job checks out with fetch-depth: 0,
/// so `git rev-parse origin/main` and the tag sort must resolve), the
/// shared gh/curl stubs, and a `gh run list --branch main` fixture.
/// [tagPresent]: false = no v* tag at all → nothing has been released, so
/// the re-arm cannot fire and `pubspec_version` is empty.
/// [lastGreen]: 'head' — the newest successful scheduled daily ran at
/// main's current sha; 'older' — at an older sha (main moved); null — no
/// green all-legs daily recorded. [servedVersion] is what the pub.dev API
/// fixture serves (the re-arm compares it against `v[latestTag]`);
/// [pubdevApiDown] makes every curl fail (the re-arm must fail OPEN, never
/// block on an API outage).
PlanRun runPlan(
  String name, {
  String latestTag = '0.1.497',
  bool tagPresent = true,
  String? lastGreen,
  bool force = false,
  String? servedVersion,
  bool pubdevApiDown = false,
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/plan-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final origin = '${dir.path}/origin.git';
  final seed = '${dir.path}/seed';
  final job = '${dir.path}/job';
  final stub = _installStubs(dir.path);

  Directory(origin).createSync();
  _git(['init', '-q', '--bare', '-b', 'main', origin], cwd: dir.path);
  _git(['clone', '-q', origin, seed], cwd: dir.path);
  _git(['config', 'user.email', 't@t'], cwd: seed);
  _git(['config', 'user.name', 't'], cwd: seed);
  // gh-1522: the committed pubspec is the 0.0.0-dev placeholder — the plan
  // gate reads only git tags and the pub.dev API.
  File(
    '$seed/pubspec.yaml',
  ).writeAsStringSync('name: demo\nversion: 0.0.0-dev\n');
  _git(['add', '-A'], cwd: seed);
  _git(['commit', '-q', '-m', 'seed'], cwd: seed);
  if (tagPresent) {
    _git(['tag', '-a', 'v$latestTag', '-m', 'Release v$latestTag'], cwd: seed);
    _git(['push', '-q', 'origin', 'main', 'refs/tags/v$latestTag'], cwd: seed);
  } else {
    _git(['push', '-q', 'origin', 'main'], cwd: seed);
  }
  final headSha = _gitOut(['rev-parse', 'HEAD'], cwd: seed);
  // The plan job's checkout is FULL (fetch-depth: 0) — origin/main and the
  // pushed tag must both resolve in the job clone.
  _git(['clone', '-q', origin, job], cwd: dir.path);

  File(
    '${dir.path}/pubdev.json',
  ).writeAsStringSync('{"latest":{"version":"${servedVersion ?? latestTag}"}}');
  final green = switch (lastGreen) {
    null => '[]',
    'head' =>
      '[{"headSha":"$headSha","event":"schedule","displayTitle":"Daily"}]',
    _ =>
      '[{"headSha":"0000000000000000000000000000000000000000","event":"schedule","displayTitle":"Daily"}]',
  };
  File('${dir.path}/runs-main.json').writeAsStringSync(green);
  if (pubdevApiDown) File('${dir.path}/curl-fail').writeAsStringSync('');

  final outPath = '${dir.path}/github_output';
  final res = Process.runSync(
    'bash',
    [File('scripts/daily_plan.sh').absolute.path],
    workingDirectory: job,
    environment: {
      'PATH': '${stub.bin}:${Platform.environment['PATH']}',
      'FA_REAL_GIT': stub.realGit,
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/gh.log',
      'GITHUB_OUTPUT': outPath,
      if (force) 'FORCE': 'true',
    },
  );
  return PlanRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File(outPath).existsSync() ? _parseOutputs(outPath) : {},
    File('${dir.path}/gh.log').existsSync()
        ? File('${dir.path}/gh.log').readAsLinesSync()
        : <String>[],
    File('${dir.path}/curl.log').existsSync()
        ? File('${dir.path}/curl.log').readAsLinesSync()
        : <String>[],
  );
}

void main() {
  // ── AC1/AC4 — «release in flight» is neutral, never an alarm ────────────
  group('AC1/AC4 — verify classifies release-in-flight, no ::error::', () {
    test(
      '2026-10-03 timeline: tag 60s old, tag-run not visible yet -> neutral skip',
      () {
        final r = runVerify('incident-timeline');
        expect(r.exitCode, 0, reason: r.output);
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: 'the #1189 false-alarm class');
        expect(
          r.outputs['run_url'] ?? '',
          isEmpty,
          reason: 'no run exists to link',
        );
        expect(r.output, contains('release in flight'));
        expect(
          r.ghLog.where((l) => l.contains('--branch v0.1.497')),
          hasLength(1),
          reason: 'the classification reads the tag-run list exactly once',
        );
      },
    );

    test('tag-run queued or in_progress -> skip, run linked', () {
      for (final status in ['queued', 'in_progress']) {
        final r = runVerify(
          'run-$status',
          runsJson:
              '[{"databaseId":4242,"status":"$status","conclusion":null,"event":"push"}]',
          extraEnv: const {'PUBDEV_MAX_POLLS': '2'},
        );
        expect(r.exitCode, 0, reason: r.output);
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
        expect(
          r.outputs['run_url'],
          'https://github.com/OWNER/REPO/actions/runs/4242',
        );
      }
    });

    test(
      'E1: run queued far past the grace window still skips, never alarms',
      () {
        final r = runVerify(
          'starved-run',
          tagAge: const Duration(hours: 3),
          runsJson:
              '[{"databaseId":4242,"status":"queued","conclusion":null,"event":"push"}]',
          extraEnv: const {'PUBDEV_MAX_POLLS': '2'},
        );
        expect(r.exitCode, 0, reason: r.output);
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
      },
    );

    test(
      'grace is tunable (RELEASE_FLIGHT_GRACE_SECS): 2h-old tag inside a 3h grace skips',
      () {
        final r = runVerify(
          'grace-knob',
          tagAge: const Duration(hours: 2),
          runsJson: '[]',
          extraEnv: {'RELEASE_FLIGHT_GRACE_SECS': '10800'},
        );
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
      },
    );
  });

  // ── AC2 — genuine trigger failure still alarms, unchanged text ──────────
  group('AC2 — genuine failures keep the existing alarm', () {
    const expectedError =
        'v0.1.497 has no ci.yml run — the tag-publish never '
        'triggered (no run registered past the 900s grace window). Manual '
        'fix: re-push the tag (git push origin v0.1.497 --force) or run '
        'ci.yml on the tag ref.';

    test('tag past grace with NO run -> the exact current error text', () {
      final r = runVerify(
        'expired-no-run',
        tagAge: const Duration(hours: 2),
        runsJson: '[]',
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.errored, isTrue);
      expect(r.output, contains(expectedError));
      expect(
        r.ghLog.where((l) => l.contains('--branch v0.1.497')),
        hasLength(2),
        reason:
            'the alarm fires only after one spaced re-read (review thread 2)',
      );
    });

    test('review thread 2 (E4 residual): run registers between the reads -> '
        'the past-grace re-read finds it and the leg skips, never alarms', () {
      // An operator re-pushed the stale tag while the daily was between its
      // `git ls-remote` and the `gh run list`: the first read saw nothing,
      // the tag is past the grace — the old code false-errored here. The
      // re-read must find the fresh (queued) run and classify in-flight.
      final r = runVerify(
        'repush-second-read',
        tagAge: const Duration(hours: 2),
        runsJson: '[]',
        secondReadJson:
            '[{"databaseId":4242,"status":"queued","conclusion":null,"event":"push"}]',
        extraEnv: const {'PUBDEV_MAX_POLLS': '2'},
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.inFlight, isTrue, reason: r.output);
      expect(r.errored, isFalse, reason: 'the #1189 false-alarm class');
      expect(
        r.outputs['run_url'],
        'https://github.com/OWNER/REPO/actions/runs/4242',
      );
      expect(
        r.ghLog.where((l) => l.contains('--branch v0.1.497')),
        hasLength(2),
        reason: 'exactly one spaced re-read, then the run governs (E1)',
      );
    });

    test(
      'completed run succeeded but pub.dev behind -> publish-did-not-upload alarm',
      () {
        final r = runVerify(
          'success-but-behind',
          runsJson:
              '[{"databaseId":4242,"status":"completed","conclusion":"success","event":"push"}]',
        );
        expect(r.exitCode, isNot(0), reason: r.output);
        expect(r.errored, isTrue);
        expect(r.output, contains('publish did not upload'));
        expect(
          r.ghLog.where((l) => l.contains('run rerun')),
          isEmpty,
          reason: 'a green run must not be rerun',
        );
      },
    );

    test('completed run failed -> the existing rerun recovery path fires', () {
      final r = runVerify(
        'rerun-recovers',
        runsJson:
            '[{"databaseId":4242,"status":"completed","conclusion":"failure","event":"push"}]',
        conclusion: 'failure',
        rerunToSuccess: true,
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'recovered');
      expect(
        r.ghLog.where(
          (l) => l.contains('run rerun 4242') && l.contains('--failed'),
        ),
        hasLength(1),
      );
    });

    test(
      'E4: re-pushed OLD tag with a fresh run never reads «never triggered»',
      () {
        final r = runVerify(
          'repushed-old-tag',
          tagAge: const Duration(hours: 2),
          runsJson:
              '[{"databaseId":4242,"status":"queued","conclusion":null,"event":"push"}]',
          extraEnv: const {'PUBDEV_MAX_POLLS': '2'},
        );
        expect(r.exitCode, 0, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
        expect(
          r.output,
          isNot(contains('never triggered')),
          reason: 'the re-push manual fix path must keep working (E4)',
        );
      },
    );
  });

  // ── #1368 — twin-run selection, bounded waits, true-state errors ─────────
  group('#1368 — push-twin selection and the bounded waits', () {
    test(
      'release-event-only runs past grace -> «never triggered», the exit-65 arm named',
      () {
        // The old release arm: the release twin attempted the publish pub.dev
        // OIDC always rejects. Its failure must read as never-published, and
        // recovery must never rerun THAT twin. The tag is aged past the 900s
        // grace (20 min) — INSIDE the grace the selection correctly keeps the
        // leg in the neutral in-flight class (pinned by the young-tag
        // companion case below); the alarm branch is grace-expired only.
        final r = runVerify(
          'release-twin-only',
          tagAge: const Duration(minutes: 20),
          runsJson:
              '[{"databaseId":77,"status":"completed","conclusion":"failure","event":"release"}]',
        );
        expect(r.exitCode, isNot(0), reason: r.output);
        expect(r.errored, isTrue);
        expect(
          r.output,
          contains(
            'never triggered (only non-push run(s) exist — the publish job fires on push-event tag runs only)',
          ),
        );
        expect(
          r.ghLog.where((l) => l.contains('run rerun')),
          isEmpty,
          reason: 'rerunning the release twin can never publish',
        );
      },
    );

    test(
      'young tag with release-only runs visible -> grace skip, never alarms',
      () {
        // #1370 review: auto_release.sh creates the GitHub Release in the same
        // run that pushes the tag — a release-event twin can register while
        // the push twin has not. Within the grace window (60s-old tag <
        // 900s) this is release-in-flight, NOT «never triggered» (the #1189
        // false-alarm class). Companion to the grace-expired alarm case
        // above: both branches pinned.
        final r = runVerify(
          'young-release-twin',
          runsJson:
              '[{"databaseId":77,"status":"queued","conclusion":null,"event":"release"}]',
        );
        expect(r.exitCode, 0, reason: r.output);
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
        expect(r.output, isNot(contains('never triggered')));
      },
    );

    test(
      'release-only run registers on the spaced re-read -> still alarms (past grace)',
      () {
        final r = runVerify(
          'release-twin-second-read',
          tagAge: const Duration(hours: 2),
          runsJson: '[]',
          secondReadJson:
              '[{"databaseId":77,"status":"completed","conclusion":"failure","event":"release"}]',
        );
        expect(r.exitCode, isNot(0), reason: r.output);
        expect(r.errored, isTrue);
        expect(r.output, contains('only non-push run(s) exist'));
      },
    );

    test('twin runs: recovery targets the PUSH twin, never the release twin', () {
      final r = runVerify(
        'twin-runs',
        runsJson:
            '[{"databaseId":55,"status":"completed","conclusion":"failure","event":"release"},'
            '{"databaseId":4242,"status":"completed","conclusion":"failure","event":"push"}]',
        conclusion: 'failure',
        rerunToSuccess: true,
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'recovered');
      expect(
        r.outputs['run_url'],
        'https://github.com/OWNER/REPO/actions/runs/4242',
        reason: 'the push twin is the only OIDC-valid publisher',
      );
      expect(
        r.ghLog.where(
          (l) => l.contains('run rerun 4242') && l.contains('--failed'),
        ),
        hasLength(1),
      );
      expect(r.ghLog.where((l) => l.contains('run rerun 55')), isEmpty);
    });

    test('pending push run reaches terminal within the wait -> classified', () {
      final r = runVerify(
        'terminal-flip',
        runsJson:
            '[{"databaseId":4242,"status":"queued","conclusion":null,"event":"push"}]',
        firstViewJson: '{"status":"queued","conclusion":null}',
        conclusion: 'failure',
        rerunToSuccess: true,
        extraEnv: const {'PUBDEV_MAX_POLLS': '4'},
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'recovered', reason: r.output);
      expect(
        r.ghLog.where(
          (l) => l.contains('run rerun 4242') && l.contains('--failed'),
        ),
        hasLength(1),
      );
    });

    test(
      'pending push run past the terminal-wait budget -> neutral skip, no error',
      () {
        // Acceptance 3: a simulated slow tag-ci (queued) must NOT fail the
        // verify with the «never triggered» message — the outcome is merely
        // unobserved.
        final r = runVerify(
          'terminal-budget-lapse',
          runsJson:
              '[{"databaseId":4242,"status":"queued","conclusion":null,"event":"push"}]',
          extraEnv: const {'PUBDEV_MAX_POLLS': '2'},
        );
        expect(r.exitCode, 0, reason: r.output);
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
        expect(r.output, contains('unobserved'));
        expect(r.output, isNot(contains('never triggered')));
      },
    );
  });

  // ── unchanged paths pinned ────────────────────────────────────────────────
  group('verify — unchanged paths', () {
    test('up-to-date: pub.dev serves the tag version -> green no-op', () {
      final r = runVerify('up-to-date', publishedVersion: '0.1.497');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'up-to-date');
      expect(r.ghLog.where((l) => l.contains('run rerun')), isEmpty);
    });

    test(
      'private package (publish_to: none) -> green no-op before any queries',
      () {
        final r = runVerify('private', publishToNone: true);
        expect(r.exitCode, 0, reason: r.output);
        expect(r.status, 'private');
        expect(r.ghLog, isEmpty, reason: 'nothing to verify on pub.dev');
      },
    );

    test(
      'gh-1522: no v* tags on the remote -> up-to-date no-op, never an alarm',
      () {
        // The tag IS the version under test (gh-1522) — with no remote tag
        // nothing has ever been released: the script no-ops, and must not
        // touch gh (no runs to classify) or curl (nothing to compare).
        final r = runVerify('no-tags', tagPresent: false);
        expect(r.exitCode, 0, reason: r.output);
        expect(r.status, 'up-to-date');
        expect(
          r.outputs['pubspec'],
          '',
          reason: 'no tag -> the kept pubspec= key is empty',
        );
        expect(r.errored, isFalse, reason: r.output);
        expect(r.ghLog, isEmpty);
      },
    );

    test(
      'a transient ls-remote failure fails OPEN: no tag read -> up-to-date',
      () {
        // The version derivation is a real `git ls-remote` — a transient
        // failure must read as «no tags» (up-to-date no-op), never an alarm.
        final r = runVerify('lsremote-transient', lsremoteFailFirst: true);
        expect(r.exitCode, 0, reason: r.output);
        expect(r.status, 'up-to-date');
        expect(r.errored, isFalse, reason: r.output);
        expect(r.ghLog, isEmpty);
      },
    );

    test('E2: only the LATEST remote tag is evaluated', () {
      final r = runVerify(
        'e2-current-tag-only',
        staleTags: ['0.1.495', '0.1.496'],
      );
      expect(r.inFlight, isTrue, reason: r.output);
      final branches = r.ghLog
          .map((l) => RegExp(r'--branch (\S+)').firstMatch(l)?.group(1))
          .whereType<String>()
          .toSet();
      expect(branches, {
        'v0.1.497',
      }, reason: 'stale older tags are out of scope (E2)');
      expect(
        r.outputs['pubspec'],
        '0.1.497',
        reason:
            'the version under test is the latest tag, never the '
            '0.0.0-dev pubspec',
      );
    });
  });

  // ── AC1 — the report job files nothing for a release-in-flight leg ───────
  group('AC1 — report job files nothing for a release-in-flight leg', () {
    test(
      'pubdev green + release-in-flight override -> no issue lifecycle action',
      () {
        final r = runReport('in-flight');
        expect(r.exitCode, 0, reason: r.output);
        expect(
          r.ghLog.where((l) => l.contains('issue create')),
          isEmpty,
          reason: 'a release in flight is not a failure',
        );
        expect(r.ghLog.where((l) => l.contains('issue comment')), isEmpty);
        expect(r.summary, contains('skipped: release in flight'));
        expect(r.output, isNot(contains('::error::')));
      },
    );
  });

  // ── wiring — the workflows must actually use the hardened paths ──────────
  group('wiring — workflows route through the hardened scripts', () {
    test('daily-publish.yml pubdev check calls verify_pubdev_release.sh', () {
      final daily = read('.github/workflows/daily-publish.yml');
      expect(
        daily,
        contains('scripts/verify_pubdev_release.sh'),
        reason: 'the check step must run the extracted, tested script',
      );
      expect(
        daily,
        contains('Verify pub.dev serves the pubspec version'),
        reason: 'the step name stays (log-excerpt correlation keys on it)',
      );
    });

    test('verify script default grace is 15 min (AC1 suggestion)', () {
      expect(
        read('scripts/verify_pubdev_release.sh'),
        contains('RELEASE_FLIGHT_GRACE_SECS:-900'),
      );
    });

    test(
      'gh-1522: ci.yml has NO release-tag job; the tag-only flow needs none',
      () {
        final ci = read('.github/workflows/ci.yml');
        expect(
          ci,
          isNot(contains('release-tag')),
          reason:
              'the release-tag job (and scripts/tag_release.sh) retired with '
              'the file-bump flow — auto_release.sh cuts the tag directly',
        );
        expect(
          ci,
          isNot(contains('tag_release.sh')),
          reason: 'the script is deleted from the repo',
        );
      },
    );

    test('#1368: publish gates on dart_ok and PUSH-event tags only', () {
      final ci = read('.github/workflows/ci.yml');
      expect(
        ci,
        contains(
          "!cancelled() && needs.quality-gate.outputs.dart_ok == 'true' &&",
        ),
        reason: 'a red native/PTY leg must never block the Dart publish',
      );
      expect(
        ci,
        contains("needs.integration.result == 'success' &&"),
        reason: 'the Provider smoke stays a hard publish gate (#551)',
      );
      expect(
        ci,
        isNot(
          contains(
            "(github.event_name == 'release' && startsWith(github.ref, 'refs/tags/v')))",
          ),
        ),
        reason:
            'the release arm is gone — pub.dev OIDC accepts push/workflow_'
            'dispatch events only; its attempts were the exit-65 failures',
      );
    });

    test(
      '#1368: quality-gate exports dart_ok; platform legs cannot redden it',
      () {
        final ci = read('.github/workflows/ci.yml');
        expect(
          ci,
          contains('dart_ok: \${{ steps.gate.outputs.dart_ok }}'),
          reason: 'publish consumes the output',
        );
        // The gate verdicts (review-thread fix on #1370): package legs feed
        // dart_blocker (dart_ok + aggregate), platform legs feed ONLY
        // platform_red (aggregate) — and dart_ok is exported BEFORE the fail
        // so it is always 'true'/'false', never ''.
        expect(
          ci,
          contains('platform_red=false'),
          reason: 'platform reds are tracked separately from dart_ok',
        );
        expect(
          ci,
          contains(
            'if [ -n "\$dart_blocker" ]; then dart_ok=false; else dart_ok=true; fi',
          ),
          reason: 'the export is explicit and precedes the aggregate fails',
        );
        // The exclusion list inside the gate step: the full platform case
        // pattern, verbatim.
        expect(
          ci,
          contains(
            'build-web|build-android|build-ios|build-macos|fa-aot-build|'
            'installer-verify|install-pin-gate|cube-kernel-live|'
            'cli-visual-settings|pty-integration-linux|pty-coverage-gate|'
            'pty-visual)',
          ),
          reason: 'every platform/native/PTY leg must be publish-exempt',
        );
      },
    );

    test(
      '#1368: the Provider smoke runs off dart_ok, not the aggregate result',
      () {
        final ci = read('.github/workflows/ci.yml');
        expect(
          ci,
          contains(
            "!cancelled() && needs.quality-gate.outputs.dart_ok != 'false' &&",
          ),
          reason:
              'a platform-only red must not transitively skip the smoke and '
              'with it the publish',
        );
      },
    );

    test('#1368: report renders release-in-flight as a skip, never ✅', () {
      final report = read('scripts/daily_publish_report.sh');
      expect(report, contains('release-in-flight'));
      expect(report, contains('skipped: release in flight'));
      expect(
        report,
        contains('== "skipped:"*'),
        reason:
            'the neutral-skip override must downgrade ✅ to ⏭️ and '
            'keep the leg issue open',
      );
      expect(report, contains('outcome unobserved'));
    });

    test('report script renders the release-in-flight override neutrally', () {
      final report = read('scripts/daily_publish_report.sh');
      expect(report, contains('release-in-flight'));
      expect(report, contains('skipped: release in flight'));
    });

    test('plan job change detection runs the extracted, tested script', () {
      final daily = read('.github/workflows/daily-publish.yml');
      expect(
        daily,
        contains('scripts/daily_plan.sh'),
        reason:
            'the plan gate (baseline + gh-1192 release-unresolved re-arm) '
            'must be the shell-harness tested script, not inline drift',
      );
      expect(
        daily,
        contains('Detect main movement and derive versions'),
        reason: 'the step name stays (log-excerpt correlation keys on it)',
      );
    });
  });

  // ── review thread 1 — the release-unresolved re-arm ──────────────────────
  // A release-in-flight pubdev leg exits 0, so that daily goes GREEN and
  // becomes the plan job's new baseline AT THE TAG'S sha. If main then
  // stays quiet, every later daily would skip all legs — AC1's «the next
  // scheduled daily re-verifies» and the failed-run `rerun --failed`
  // recovery would stall until an unrelated push. The gate must therefore
  // force the legs while the LATEST TAG's version is not served by pub.dev
  // (gh-1522: the tag is the single source of truth, never the pubspec).
  group('plan gate — re-arms the daily while a release is unresolved', () {
    test(
      'main moved since the last green daily -> legs run, pub.dev not consulted',
      () {
        final r = runPlan('main-moved', lastGreen: 'older');
        expect(r.exitCode, 0, reason: r.output);
        expect(r.changed, isTrue, reason: r.output);
        expect(
          r.curlLog,
          isEmpty,
          reason: 'the baseline decision already forces the legs',
        );
      },
    );

    test(
      'main quiet + pub.dev serves the latest tag version -> all legs skip (unchanged)',
      () {
        final r = runPlan('quiet-served', lastGreen: 'head');
        expect(r.exitCode, 0, reason: r.output);
        expect(r.changed, isFalse, reason: r.output);
        expect(r.outputs['latest_tag'], 'v0.1.497');
        expect(r.outputs['next_tag'], 'v0.1.498');
        expect(
          r.outputs['pubspec_version'],
          '0.1.497',
          reason:
              'gh-1522: the kept key name now carries the LATEST TAG '
              'version, not a pubspec read',
        );
      },
    );

    test(
      'main quiet + pub.dev BEHIND the latest tag (release-in-flight green '
      'became the baseline) -> re-armed: changed=true, next daily re-verifies',
      () {
        final r = runPlan(
          'quiet-release-unresolved',
          lastGreen: 'head',
          servedVersion: '0.1.496',
        );
        expect(r.exitCode, 0, reason: r.output);
        expect(
          r.changed,
          isTrue,
          reason: 'AC1 re-verification must not stall on a quiet main',
        );
        expect(r.output, contains('release unresolved'));
        expect(r.outputs['latest_tag'], 'v0.1.497');
        expect(
          r.outputs['next_tag'],
          'v0.1.498',
          reason: 'version derivation still runs after the re-arm',
        );
        expect(r.outputs['pubspec_version'], '0.1.497');
      },
    );

    test('gh-1522: no tags at all -> no re-arm (changed stays false)', () {
      // Nothing has ever been released — main movement is the only re-arm
      // trigger, and a first release IS main movement, so the baseline
      // cannot skip it.
      final r = runPlan(
        'no-tags',
        tagPresent: false,
        lastGreen: 'head',
        servedVersion: '0.1.496',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.changed, isFalse, reason: r.output);
      expect(
        r.curlLog,
        isEmpty,
        reason: 'with no tag the re-arm read is skipped entirely',
      );
      expect(r.outputs['latest_tag'], 'none');
      expect(
        r.outputs['next_tag'],
        'v0.1.0',
        reason: 'the first tag the auto-release will cut',
      );
      expect(
        r.outputs['pubspec_version'],
        '',
        reason:
            r'`echo "pubspec_version=${latest_tag#v}"` with an empty '
            'tag prints the empty value',
      );
    });

    test(
      'pub.dev read fails -> fail OPEN: the baseline skip stands, exit 0',
      () {
        final r = runPlan('api-down', lastGreen: 'head', pubdevApiDown: true);
        expect(r.exitCode, 0, reason: r.output);
        expect(
          r.changed,
          isFalse,
          reason: 'an API outage must not force daily legs by itself',
        );
      },
    );

    test('FORCE=true forces the legs without consulting pub.dev', () {
      final r = runPlan('forced', lastGreen: 'head', force: true);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.changed, isTrue, reason: r.output);
      expect(
        r.curlLog,
        isEmpty,
        reason: 'FORCE short-circuits before the re-arm',
      );
    });

    test(
      'no green all-legs daily recorded -> legs run (first-run path unchanged)',
      () {
        final r = runPlan('first-run', lastGreen: null);
        expect(r.exitCode, 0, reason: r.output);
        expect(r.changed, isTrue, reason: r.output);
        expect(r.curlLog, isEmpty);
      },
    );
  });

  // ── review thread 3 — the fixture must not swallow unknown gh calls ──────
  group('fixture hygiene — the gh stub fails loudly on unexpected commands', () {
    late Directory dir;
    late StubEnv stub;
    setUp(() {
      dir = Directory(
        '${_fixtureRoot.path}/stub-strict-${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      stub = _installStubs(dir.path);
    });

    Map<String, String> stubEnv() => {
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/gh.log',
    };

    test('an unknown subcommand exits non-zero with a loud stderr', () {
      final r = Process.runSync('${stub.bin}/gh', [
        'api',
        'repos/OWNER/REPO',
      ], environment: stubEnv());
      expect(r.exitCode, isNot(0), reason: 'script drift must turn red');
      expect(r.stderr, contains('unexpected gh invocation'));
    });

    test('gh release create stays a quiet success (auto_release.sh path)', () {
      final r = Process.runSync('${stub.bin}/gh', [
        'release',
        'create',
        'v0.1.496',
        '--title',
        'v0.1.496',
        '--notes',
        'notes',
        '--latest',
        '--repo',
        'OWNER/REPO',
      ], environment: stubEnv());
      expect(r.exitCode, 0, reason: r.stderr);
    });

    test('the known subcommands still answer (no over-tightening)', () {
      File(
        '${dir.path}/runs-v1.json',
      ).writeAsStringSync('[{"databaseId":7,"status":"queued"}]');
      final list = Process.runSync('${stub.bin}/gh', [
        'run',
        'list',
        '--branch',
        'v1',
        '--jq',
        '.[0].databaseId',
      ], environment: stubEnv());
      expect(list.exitCode, 0, reason: list.stderr);
      expect(list.stdout.trim(), '7');
      final label = Process.runSync('${stub.bin}/gh', [
        'label',
        'create',
        'daily-publish',
      ], environment: stubEnv());
      expect(label.exitCode, 0, reason: label.stderr);
    });
  });
}
