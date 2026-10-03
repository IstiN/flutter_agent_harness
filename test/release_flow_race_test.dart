// gh-1192 — release-flow race hardening (2026-10-03 incident, issue #1189).
//
// Two independent defects:
//   Defect A — daily-publish's pub.dev verify had no «release in flight»
//     class: between `git push <tag>` and the tag's ci.yml run becoming
//     visible/completing, the check read «no run» and false-errored —
//     auto-filing #1189 one minute before the healthy tag run completed.
//     The classification now lives in scripts/verify_pubdev_release.sh.
//   Defect B — tag_release.sh tagged current main HEAD, so a commit landing
//     between the bump push and the tag job got captured inside the version
//     tag (v1.0.498 pointed at the #1178 interloper, not the bump).
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
  final r = Process.runSync(_resolveRealGit(), args,
      workingDirectory: cwd, environment: env);
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

  File('${bin.path}/git').writeAsStringSync('''
#!/usr/bin/env bash
exec "\$FA_REAL_GIT" "\$@"
''');

  // pub.dev package API: before the tag-run rerun lands, pub.dev serves the
  // OLD version; once $GH_STUB_DIR/rerun-done exists (planted by the gh
  // stub's `run rerun`), it serves the new one.
  File('${bin.path}/curl').writeAsStringSync('''
#!/usr/bin/env bash
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
        f="$GH_STUB_DIR/runs-$branch.json"
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
        f="$GH_STUB_DIR/run-$id.json"
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
  *) exit 0 ;;
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
/// pubdev leg's check): a bare origin whose main carries `version:
/// [version]` in a commit named [bumpSubject] backdated [bumpAge], an
/// optional annotated tag `v[version]` backdated [tagAge] (the annotated
/// tagger date is what %(creatordate:unix) reads back), a job clone the
/// script runs in, and stub gh/curl fixtures. [runsJson] is what
/// `gh run list --branch v<version>` serves ('[]' = the run is not visible
/// yet); [conclusion] is the completed run's conclusion (served once the
/// stub sees the run id); [rerunToSuccess] makes the post-rerun view green.
VerifyRun runVerify(
  String name, {
  String version = '0.1.497',
  String publishedVersion = '0.1.496',
  bool tagPresent = true,
  Duration tagAge = const Duration(seconds: 60),
  String bumpSubject = 'chore(release): v0.1.497',
  Duration bumpAge = const Duration(seconds: 90),
  int commitsOnTop = 0, // ordinary PRs that landed on main after the bump
  bool publishToNone = false,
  String? runsJson = '[]',
  String conclusion = 'success',
  bool rerunToSuccess = false,
  Map<String, String> extraEnv = const {},
}) {
  final dir = Directory(
          '${_fixtureRoot.path}/verify-$name-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
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
  File('$seed/pubspec.yaml').writeAsStringSync('name: demo\nversion: $version\n'
      '${publishToNone ? 'publish_to: none\n' : ''}');
  _git(['add', '-A'], cwd: seed);
  _git(['commit', '-q', '-m', bumpSubject], cwd: seed, env: {
    'GIT_COMMITTER_DATE': '${_epoch(now.subtract(bumpAge))}',
    'GIT_AUTHOR_DATE': '${_epoch(now.subtract(bumpAge))}',
  });
  for (var i = 1; i <= commitsOnTop; i++) {
    _git(['commit', '-q', '--allow-empty', '-m', 'feat: follow-up $i'], cwd: seed);
  }
  if (tagPresent) {
    _git(['tag', '-a', 'v$version', '-m', 'Release v$version'], cwd: seed,
        env: {
          'GIT_COMMITTER_DATE': '${_epoch(now.subtract(tagAge))}',
        });
    _git(['push', '-q', 'origin', 'refs/tags/v$version'], cwd: seed);
  }
  _git(['push', '-q', 'origin', 'main'], cwd: seed);
  // The daily's checkout is SHALLOW (actions/checkout default fetch-depth
  // 1) — file:// so git honors --depth on the local transport.
  _git(['clone', '-q', '--depth', '1', 'file://$origin', job], cwd: dir.path);

  File('${dir.path}/pubdev.json')
      .writeAsStringSync('{"latest":{"version":"$publishedVersion"}}');
  File('${dir.path}/pubdev-new.json')
      .writeAsStringSync('{"latest":{"version":"$version"}}');
  File('${dir.path}/runs-v$version.json').writeAsStringSync(runsJson ?? '[]');
  if (runsJson != null && runsJson != '[]') {
    final id = RegExp(r'"databaseId":\s*(\d+)').firstMatch(runsJson)?.group(1);
    if (id != null) {
      File('${dir.path}/run-$id.json').writeAsStringSync(
          '{"status":"completed","conclusion":"$conclusion"}');
      if (rerunToSuccess) {
        File('${dir.path}/run-$id-post.json')
            .writeAsStringSync('{"status":"completed","conclusion":"success"}');
      }
    }
  }

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

class TagReleaseRun {
  TagReleaseRun(this.exitCode, this.output, this.ghLog, this.originDir,
      this.bumpSha, this.interloperSha);

  final int exitCode;
  final String output;
  final List<String> ghLog;
  final String originDir;
  final String bumpSha; // the chore(release) commit the tag must pin
  final String? interloperSha; // the commit that raced onto main after it

  /// The commit `v[version]` points at in origin, or null when absent.
  String? tagCommit(String version) {
    final r = Process.runSync(_resolveRealGit(), [
      '--git-dir',
      originDir,
      'rev-parse',
      '-q',
      '--verify',
      'refs/tags/v$version^{commit}',
    ]);
    return r.exitCode == 0 ? r.stdout.toString().trim() : null;
  }

  String fileInTag(String version, String path) {
    final r = Process.runSync(
        _resolveRealGit(), ['--git-dir', originDir, 'show', 'v$version:$path']);
    if (r.exitCode != 0) fail('git show v$version:$path failed: ${r.stderr}');
    return r.stdout.toString();
  }
}

/// Sandbox for scripts/tag_release.sh reproducing Defect B: the seed clone
/// pushes the `chore(release): v0.1.496` bump, [interloper] lands an
/// unrelated commit on main afterwards (the #1178 FIFO capture), and the
/// job clone — the drifted release-tag checkout — runs the script with
/// [bumpShaEnv] as BUMP_SHA (null = the history-search fallback path).
TagReleaseRun runTagRelease(
  String name, {
  bool interloper = true,
  String? bumpShaEnv,
  bool preExistingTag = false,
  String seedSubject = 'chore(release): v0.1.496',
}) {
  final dir = Directory(
          '${_fixtureRoot.path}/tagrel-$name-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
  final origin = '${dir.path}/origin.git';
  final seed = '${dir.path}/seed';
  final racer = '${dir.path}/racer';
  final job = '${dir.path}/job';
  final stub = _installStubs(dir.path);

  Directory(origin).createSync();
  _git(['init', '-q', '--bare', '-b', 'main', origin], cwd: dir.path);
  _git(['clone', '-q', origin, seed], cwd: dir.path);
  _git(['config', 'user.email', 't@t'], cwd: seed);
  _git(['config', 'user.name', 't'], cwd: seed);
  File('$seed/pubspec.yaml').writeAsStringSync('name: demo\nversion: 0.1.495\n');
  File('$seed/CHANGELOG.md').writeAsStringSync('# Changelog\n\n## Unreleased\n');
  _git(['add', '-A'], cwd: seed);
  _git(['commit', '-q', '-m', 'seed'], cwd: seed);
  _git(['tag', 'v0.1.495'], cwd: seed);
  _git(['push', '-q', 'origin', 'main', 'refs/tags/v0.1.495'], cwd: seed);

  // The bump — the commit the version tag must pin (gh-1192 AC3).
  File('$seed/pubspec.yaml').writeAsStringSync('name: demo\nversion: 0.1.496\n');
  File('$seed/CHANGELOG.md').writeAsStringSync(
      '# Changelog\n\n## 0.1.496\n\n- curated release note\n\n## Unreleased\n');
  _git(['add', '-A'], cwd: seed);
  _git(['commit', '-q', '-m', seedSubject], cwd: seed);
  _git(['push', '-q', 'origin', 'main'], cwd: seed);
  final bumpSha = _gitOut(['rev-parse', 'HEAD'], cwd: seed);

  String? interloperSha;
  if (interloper) {
    _git(['clone', '-q', origin, racer], cwd: dir.path);
    _git(['config', 'user.email', 't@t'], cwd: racer);
    _git(['config', 'user.name', 't'], cwd: racer);
    File('$racer/README.md')
        .writeAsStringSync('landed via the FIFO queue in the race window\n');
    _git(['add', '-A'], cwd: racer);
    _git(['commit', '-q', '-m', 'fix: unrelated interloper (#1178)'], cwd: racer);
    _git(['push', '-q', 'origin', 'main'], cwd: racer);
    interloperSha = _gitOut(['rev-parse', 'HEAD'], cwd: racer);
  }

  // The release-tag checkout: main AFTER the interloper — the drifted tree
  // the 2026-10-03 tag was cut from.
  _git(['clone', '-q', origin, job], cwd: dir.path);
  if (preExistingTag) {
    _git(['tag', '-a', 'v0.1.496', '-m', 'Release v0.1.496', bumpSha], cwd: job);
    _git(['push', '-q', 'origin', 'refs/tags/v0.1.496'], cwd: job);
  }

  final env = <String, String>{
    'PATH': '${stub.bin}:${Platform.environment['PATH']}',
    'FA_REAL_GIT': stub.realGit,
    'GITHUB_REPOSITORY': 'OWNER/REPO',
    'GH_TOKEN': 'stub',
    'GH_STUB_DIR': dir.path,
    'GH_LOG_FILE': '${dir.path}/gh.log',
  };
  if (bumpShaEnv != null) env['BUMP_SHA'] = bumpShaEnv;

  final res = Process.runSync(
    'bash',
    [File('scripts/tag_release.sh').absolute.path],
    workingDirectory: job,
    environment: env,
  );
  return TagReleaseRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/gh.log').existsSync()
        ? File('${dir.path}/gh.log').readAsLinesSync()
        : <String>[],
    origin,
    bumpSha,
    interloperSha,
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
          '${_fixtureRoot.path}/report-$name-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
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
        expect(r.outputs['run_url'] ?? '', isEmpty,
            reason: 'no run exists to link');
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
        final r = runVerify('run-$status',
            runsJson: '[{"databaseId":4242,"status":"$status","conclusion":null}]');
        expect(r.exitCode, 0, reason: r.output);
        expect(r.inFlight, isTrue, reason: r.output);
        expect(r.errored, isFalse, reason: r.output);
        expect(r.outputs['run_url'],
            'https://github.com/OWNER/REPO/actions/runs/4242');
      }
    });

    test('E1: run queued far past the grace window still skips, never alarms',
        () {
      final r = runVerify('starved-run',
          tagAge: const Duration(hours: 3),
          runsJson: '[{"databaseId":4242,"status":"queued","conclusion":null}]');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.inFlight, isTrue, reason: r.output);
      expect(r.errored, isFalse, reason: r.output);
    });

    test('tag not cut yet + fresh bump on main -> skip (release-tag pending)',
        () {
      final r = runVerify('tag-pending',
          tagPresent: false, bumpAge: const Duration(seconds: 60));
      expect(r.exitCode, 0, reason: r.output);
      expect(r.inFlight, isTrue, reason: r.output);
      expect(r.errored, isFalse, reason: r.output);
    });

    test(
        'tag not cut yet + bump already buried under later commits -> still in flight',
        () {
      // The bump landed minutes ago; ordinary PRs landed on top of it while
      // release-tag's gate runs. The bump is no longer main's HEAD, but it
      // is reachable and fresh — the tag is merely pending.
      final r = runVerify('tag-pending-buried',
          tagPresent: false,
          commitsOnTop: 2,
          bumpAge: const Duration(seconds: 120));
      expect(r.exitCode, 0, reason: r.output);
      expect(r.inFlight, isTrue, reason: r.output);
      expect(r.errored, isFalse, reason: r.output);
    });

    test('grace is tunable (RELEASE_FLIGHT_GRACE_SECS): 2h-old tag inside a 3h grace skips',
        () {
      final r = runVerify('grace-knob',
          tagAge: const Duration(hours: 2),
          runsJson: '[]',
          extraEnv: {'RELEASE_FLIGHT_GRACE_SECS': '10800'});
      expect(r.inFlight, isTrue, reason: r.output);
      expect(r.errored, isFalse, reason: r.output);
    });
  });

  // ── AC2 — genuine trigger failure still alarms, unchanged text ──────────
  group('AC2 — genuine failures keep the existing alarm', () {
    const expectedError = 'v0.1.497 has no ci.yml run — the tag-publish never '
        'triggered. Manual fix: re-push the tag (git push origin v0.1.497 '
        '--force) or run ci.yml on the tag ref.';

    test('tag past grace with NO run -> the exact current error text', () {
      final r = runVerify('expired-no-run',
          tagAge: const Duration(hours: 2), runsJson: '[]');
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.errored, isTrue);
      expect(r.output, contains(expectedError));
    });

    test('tag never cut + bump wedged past the horizon -> same alarm', () {
      // auto_release.sh declares release-tag wedged after 1h; the daily
      // must alarm too or the next bump silently absorbs a never-published
      // release.
      final r = runVerify('wedged-untagged',
          tagPresent: false, bumpAge: const Duration(hours: 2));
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.errored, isTrue);
      expect(r.output, contains(expectedError));
    });

    test('tag never cut + no bump commit on main at all -> alarm', () {
      final r = runVerify('untagged-no-bump',
          tagPresent: false,
          bumpSubject: 'feat: unrelated work, no release in flight',
          bumpAge: const Duration(seconds: 60));
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.errored, isTrue);
      expect(r.output, contains(expectedError));
    });

    test('completed run succeeded but pub.dev behind -> publish-did-not-upload alarm',
        () {
      final r = runVerify('success-but-behind',
          runsJson:
              '[{"databaseId":4242,"status":"completed","conclusion":"success"}]');
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.errored, isTrue);
      expect(r.output, contains('publish did not upload'));
      expect(r.ghLog.where((l) => l.contains('run rerun')), isEmpty,
          reason: 'a green run must not be rerun');
    });

    test('completed run failed -> the existing rerun recovery path fires', () {
      final r = runVerify('rerun-recovers',
          runsJson:
              '[{"databaseId":4242,"status":"completed","conclusion":"failure"}]',
          conclusion: 'failure',
          rerunToSuccess: true);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'recovered');
      expect(
        r.ghLog.where((l) => l.contains('run rerun 4242') && l.contains('--failed')),
        hasLength(1),
      );
    });

    test('E4: re-pushed OLD tag with a fresh run never reads «never triggered»',
        () {
      final r = runVerify('repushed-old-tag',
          tagAge: const Duration(hours: 2),
          runsJson: '[{"databaseId":4242,"status":"queued","conclusion":null}]');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.errored, isFalse, reason: r.output);
      expect(r.output, isNot(contains('never triggered')),
          reason: 'the re-push manual fix path must keep working (E4)');
    });
  });

  // ── unchanged paths pinned ────────────────────────────────────────────────
  group('verify — unchanged paths', () {
    test('up-to-date: pub.dev serves the pubspec version -> green no-op', () {
      final r = runVerify('up-to-date', publishedVersion: '0.1.497');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'up-to-date');
      expect(r.ghLog.where((l) => l.contains('run rerun')), isEmpty);
    });

    test('private package (publish_to: none) -> green no-op before any queries',
        () {
      final r = runVerify('private', publishToNone: true);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.status, 'private');
      expect(r.ghLog, isEmpty, reason: 'nothing to verify on pub.dev');
    });

    test('E2: only the tag matching the CURRENT pubspec version is evaluated',
        () {
      final r = runVerify('e2-current-tag-only');
      expect(r.inFlight, isTrue, reason: r.output);
      final branches = r.ghLog
          .map((l) => RegExp(r'--branch (\S+)').firstMatch(l)?.group(1))
          .whereType<String>()
          .toSet();
      expect(branches, {'v0.1.497'},
          reason: 'stale older tags are out of scope (E2)');
    });
  });

  // ── AC1 — the report job files nothing for a release-in-flight leg ───────
  group('AC1 — report job files nothing for a release-in-flight leg', () {
    test('pubdev green + release-in-flight override -> no issue lifecycle action',
        () {
      final r = runReport('in-flight');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.ghLog.where((l) => l.contains('issue create')), isEmpty,
          reason: 'a release in flight is not a failure');
      expect(r.ghLog.where((l) => l.contains('issue comment')), isEmpty);
      expect(r.summary, contains('skipped: release in flight'));
      expect(r.output, isNot(contains('::error::')));
    });
  });

  // ── AC3 — the tag pins the bump commit, not moving main ─────────────────
  group('AC3 — tag_release.sh pins the bump commit', () {
    test(
      'simulated race: a commit landing on main between bump-push and '
      'tag-create must NOT appear in the tagged tree; tag commit == bump sha',
      () {
        final r = runTagRelease('race');
        expect(r.exitCode, 0, reason: r.output);
        // Fixture sanity: the checkout the script ran in really had drifted.
        expect(r.interloperSha, isNot(r.bumpSha));
        final tagged = r.tagCommit('0.1.496');
        expect(tagged, isNotNull, reason: 'the tag must be pushed');
        expect(tagged, r.bumpSha,
            reason:
                'the tag must pin the bump commit (9839a8b7d), not the '
                'interloper main had advanced to (065c2c67)');
        expect(r.fileInTag('0.1.496', 'pubspec.yaml'), contains('version: 0.1.496'));
        // The create command's --notes carries newlines, so the stub log
        // entry spans several lines — join the entry before asserting.
        final start = r.ghLog.indexWhere((l) => l.contains('release create'));
        final createText = r.ghLog.skip(start).take(10).join('\n');
        expect(createText, contains('--title v0.1.496'));
        expect(createText, contains('--latest'));
        expect(createText, contains('curated release note'),
            reason: 'notes must come from the pinned bump tree, not the drifted checkout');
      },
    );

    test('fallback: no BUMP_SHA (older wiring) — history search still pins the bump',
        () {
      final r = runTagRelease('fallback');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.tagCommit('0.1.496'), r.bumpSha,
          reason: 'the fallback must resolve the bump commit, never HEAD');
    });

    test('drifted BUMP_SHA (the incident mechanism) is rejected; the bump wins',
        () {
      // Whatever GitHub resolved github.sha to, a candidate that is not the
      // v0.1.496 bump must never be tagged — the script warns and falls
      // through to the history search.
      final r = runTagRelease('drifted', bumpShaEnv: 'INTERLOPER');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('is not the v0.1.496 bump'));
      expect(r.tagCommit('0.1.496'), r.bumpSha);
    });

    test('unresolvable bump -> loud failure, NO tag pushed, no release create',
        () {
      final r = runTagRelease('unresolvable',
          interloper: false, seedSubject: 'chore: not a release bump');
      expect(r.exitCode, isNot(0), reason: 'refusing to tag a moving HEAD');
      expect(r.output, contains('refusing'));
      expect(r.tagCommit('0.1.496'), isNull);
      expect(r.ghLog.where((l) => l.contains('release create')), isEmpty);
    });

    test('idempotent: an existing tag is a no-op before any sha resolution',
        () {
      final r = runTagRelease('idempotent', preExistingTag: true);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('already exists'));
      expect(r.ghLog.where((l) => l.contains('release create')), isEmpty);
      expect(r.tagCommit('0.1.496'), r.bumpSha);
    });
  });

  // ── wiring — the workflows must actually use the hardened paths ──────────
  group('wiring — workflows route through the hardened scripts', () {
    test('daily-publish.yml pubdev check calls verify_pubdev_release.sh', () {
      final daily = read('.github/workflows/daily-publish.yml');
      expect(daily, contains('scripts/verify_pubdev_release.sh'),
          reason: 'the check step must run the extracted, tested script');
      expect(daily, contains('Verify pub.dev serves the pubspec version'),
          reason: 'the step name stays (log-excerpt correlation keys on it)');
    });

    test('verify script default grace is 15 min (AC1 suggestion)', () {
      expect(read('scripts/verify_pubdev_release.sh'),
          contains('RELEASE_FLIGHT_GRACE_SECS:-900'));
    });

    test('ci.yml release-tag pins the tag to the push event bump sha', () {
      final ci = read('.github/workflows/ci.yml');
      expect(
        ci,
        contains('BUMP_SHA: \${{ github.event.head_commit.id || github.sha }}'),
        reason:
            'head_commit.id is frozen at push time — the checkout/github.sha '
            'can drift to a main that moved (the #1178 interloper capture)',
      );
    });

    test('report script renders the release-in-flight override neutrally', () {
      final report = read('scripts/daily_publish_report.sh');
      expect(report, contains('release-in-flight'));
      expect(report, contains('skipped: release in flight'));
    });
  });
}
