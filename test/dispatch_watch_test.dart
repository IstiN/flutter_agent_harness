// Issues #343, gh-172 and gh-1903 — nightly release orchestration:
//
// #343: the daily-publish Play/TestFlight legs dispatch the SAME workflow
// (build-mobile.yml) as concurrent `needs: plan` siblings and identified
// "their" run by event + a 60s createdAt window only, taking [0] of the
// list — so the Play leg could latch the TestFlight run. The fix: children
// carry a run-name embedding their inputs, and the watcher correlates by
// exact displayTitle + NEWEST match + a tight window.
//
// gh-172 (run 39374894901, 2026-10-20): a re-dispatched testflight child
// sat queued FOREVER on a zombie self-hosted worker; the leg burned its
// remaining ~107m and died as a bare 360m ceiling kill. That produced the
// #344 budget watch + the gh-172 queue-stall window — and those CAUSED the
// 2026-10-26 incident (daily run 40274465122, issue #1735): two HEALTHY
// QUEUED children were cancelled ~31m into a legitimate wait for the
// single shared runner (the cli sibling chain can hold fa-m5-1 for 335m),
// and a fully-built v1.0.648 release failed solely by losing its place in
// line.
//
// gh-1903 (this file's behavioral contract): the watchdog is gone. The
// watcher dispatches, correlates (#343, unchanged), then waits READ-ONLY:
// no stall timer, no wedge cancel, no re-dispatch — ever. Bounds are the
// child's per-job server-side timeouts (#344, unchanged) and the leg
// timeout-minutes. While the child has not started it logs a read-only
// repo-wide sibling-liveness probe (cannot-observe ⇒ cannot-judge ⇒ never
// a cancel). The ONE cancel path is the orphan-cleanup trap: when the
// LEG is terminated (timeout-minutes fires, manual cancel), the watcher
// cancels ONLY its own NEVER-STARTED child — a child that ever started is
// left to its own job timeouts — so an orphaned queued run can never
// publish unattended when the pool revives.
//
// #351 (timeout arithmetic): every job in a watched child chain carries
// an explicit timeout-minutes; child worst-case = sum along the
// serialized critical path; the leg timeout always exceeds it by ≥ ~15m
// margin (appear window 10m + poll slack 5m). Legs no longer pass a
// watcher budget — the budget/stall machinery was the gh-1903 defect.
//
// Structural lint over the workflow YAML plus behavioral tests of
// scripts/dispatch_and_watch.sh against a stubbed `gh` (same style as
// release_hygiene_test.dart). The stub pipes fixtures through the REAL jq
// expression the script passes to `gh run list`, so the correlation logic
// itself (title filter, window, newest-match) is under test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

// ── stubbed gh ─────────────────────────────────────────────────────────────

final _fixtureRoot = Directory.systemTemp.createTempSync('dispatch-watch-');

/// ISO-8601 seconds-resolution timestamp (GitHub `createdAt` shape) offset
/// from now by [seconds].
String iso(int seconds) {
  final utc = DateTime.now()
      .toUtc()
      .add(Duration(seconds: seconds))
      .toIso8601String();
  return '${utc.substring(0, 19)}Z';
}

/// Installs a stub `gh` that logs every invocation and answers from canned
/// files in [dir]:
///   `runs.json`        — raw `gh run list --json` array (dispatch
///                        correlation polls)
///   `siblings.json`    — raw array for the read-only
///                        `gh run list --status in_progress` liveness
///                        probe (gh-1903); absent = []
///   `view-<id>.txt`    — one `<status> <conclusion>` line per
///                        `gh run view <id>` poll; the last line repeats
///                        once exhausted
///   `jobs-<id>.txt`    — one running-job COUNT per watch poll; the last
///                        line repeats; absent file = 1 job always running
///   `jobs-served-<id>.log` — (written by the stub) the jobs body actually
///                        served per poll — ground truth that a fixture
///                        modeled a running job, however the body was built
///   `view-fail-next`   — holds N: the next N `gh run view` calls fail
///                        (exit 1, no output) — models a gh/API outage
///   `sibling-fail-next`— holds N: the next N sibling-liveness probes fail
///                        (exit 1, no output) — the probe cannot establish
///                        OR exclude pool idleness (gh-1903)
///   `cancelled-<id>`   — marker created by `gh run cancel`
///   `list-calls`       — internal counter
/// GH_STUB_LIST_EMPTY_FIRST=N makes the first N correlation `run list`
/// calls return [].
/// Any `--jq` argument is applied with the real jq, so the script's own
/// correlation/probe expressions run against the fixtures.
String stubGh(String dir) {
  final bin = Directory('$dir/bin')..createSync(recursive: true);
  File('${bin.path}/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
cmd="\$1"; sub="\$2"

jq_arg=""
args=("\$@")
for ((i=0; i<\$#; i++)); do
  if [ "\${args[\$i]}" = "--jq" ]; then jq_arg="\${args[\$((i+1))]}"; fi
done

apply_jq() {
  if [ -n "\$jq_arg" ]; then jq -r "\$jq_arg"; else cat; fi
}

case "\$cmd" in
  workflow) : ;;
  run)
    case "\$sub" in
      list)
        # gh-1903: distinguish the read-only sibling-liveness probe
        # (`--status in_progress`, fixture siblings.json) from the
        # dispatch-correlation listing (runs.json) — both are
        # `gh run list`.
        is_status=0
        for ((j = 0; j < \${#args[@]}; j++)); do
          if [ "\${args[\$j]}" = "--status" ]; then is_status=1; fi
        done
        if [ "\$is_status" = "1" ]; then
          if [ -f "\$GH_STUB_DIR/sibling-fail-next" ]; then
            failN=\$(cat "\$GH_STUB_DIR/sibling-fail-next" 2>/dev/null || echo 0)
            if [ "\$failN" -gt 0 ] 2>/dev/null; then
              echo \$((failN - 1)) > "\$GH_STUB_DIR/sibling-fail-next"
              exit 1
            fi
          fi
          cat "\$GH_STUB_DIR/siblings.json" 2>/dev/null | apply_jq
          exit 0
        fi
        calls=\$(( \$(cat "\$GH_STUB_DIR/list-calls" 2>/dev/null || echo 0) + 1 ))
        echo "\$calls" > "\$GH_STUB_DIR/list-calls"
        if [ "\$calls" -le "\${GH_STUB_LIST_EMPTY_FIRST:-0}" ]; then
          printf '[]' | apply_jq
        else
          cat "\$GH_STUB_DIR/runs.json" | apply_jq
        fi
        ;;
      view)
        id="\$3"
        # view-fail-next holds N: the next N view calls fail (exit 1, no
        # output) — models a gh/API outage exactly like a real network
        # failure would (the script sees an empty poll).
        if [ -f "\$GH_STUB_DIR/view-fail-next" ]; then
          failN=\$(cat "\$GH_STUB_DIR/view-fail-next" 2>/dev/null || echo 0)
          if [ "\$failN" -gt 0 ] 2>/dev/null; then
            echo \$((failN - 1)) > "\$GH_STUB_DIR/view-fail-next"
            exit 1
          fi
        fi
        if [ -f "\$GH_STUB_DIR/cancelled-\$id" ]; then
          status=completed; conclusion=cancelled; jobs_body=""
        else
          f="\$GH_STUB_DIR/view-\$id.txt"
          line=\$(head -1 "\$f")
          sed -i.bak '1d' "\$f" && rm -f "\$f.bak"
          if ! [ -s "\$f" ]; then printf '%s\\n' "\$line" > "\$f"; fi
          status="\${line%% *}"; conclusion="\${line#* }"
          jobs_body=""
          is_jobs=0
          for ((j = 0; j < \${#args[@]} - 1; j++)); do
            if [ "\${args[\$j]}" = "--json" ] && [[ "\${args[\$((j + 1))]}" == *jobs* ]]; then is_jobs=1; fi
          done
          if [ "\$is_jobs" = "1" ]; then
            jf="\$GH_STUB_DIR/jobs-\$id.txt"
            if [ -f "\$jf" ]; then
              n=\$(head -1 "\$jf")
              sed -i.bak '1d' "\$jf" && rm -f "\$jf.bak"
              if ! [ -s "\$jf" ]; then printf '%s\\n' "\$n" > "\$jf"; fi
            else
              n=1
            fi
            # No `seq -f 'literal'`: a %-less format errors on every call,
            # the || true swallows it, and the fixture goes inert
            # ({"jobs":[]} forever, whatever jobs-<id>.txt says). No plain
            # `seq "\$n"` either: BSD seq(1) prints TWO lines for `seq 0`
            # (GNU prints none), so n=0 served two phantom running jobs on
            # macOS and flipped the served-jobs fixtures — a portable
            # count loop stamps exactly n running jobs (n=0 → empty body
            # → {"jobs":[]}).
            jobs_body=''
            i=0
            while [ "\$i" -lt "\$n" ] 2>/dev/null; do
              if [ -n "\$jobs_body" ]; then jobs_body="\$jobs_body,"; fi
              jobs_body="\$jobs_body{\\"status\\":\\"in_progress\\"}"
              i=\$((i + 1))
            done
          fi
        fi
        is_jobs=0
        for ((j = 0; j < \${#args[@]} - 1; j++)); do
          if [ "\${args[\$j]}" = "--json" ] && [[ "\${args[\$((j + 1))]}" == *jobs* ]]; then is_jobs=1; fi
        done
        if [ "\$is_jobs" = "1" ]; then
          printf '%s\\n' "\$jobs_body" >> "\$GH_STUB_DIR/jobs-served-\$id.log"
          printf '{"status":"%s","conclusion":"%s","jobs":[%s]}' "\$status" "\$conclusion" "\$jobs_body" | apply_jq
        else
          printf '{"status":"%s","conclusion":"%s"}' "\$status" "\$conclusion" | apply_jq
        fi
        ;;
      cancel)
        id="\$3"
        : > "\$GH_STUB_DIR/cancelled-\$id"
        ;;
    esac
    ;;
esac
exit 0
''');
  Process.runSync('chmod', ['+x', '${bin.path}/gh']);
  return bin.path;
}

class DwRun {
  DwRun(this.exitCode, this.out, this.log, this.runIdFile, this.dir);

  final int exitCode;
  final String out;
  final List<String> log;
  final String? runIdFile; // content of --out-run-id, when requested
  final Directory dir; // stub fixture dir (jobs-served-*.log lives here)
}

/// The jobs bodies the stub actually served while watching [runId] —
/// ground truth for "the fixture modeled a running job", independent of
/// how the stub built the body.
List<String> servedJobs(DwRun dw, int runId) =>
    File('${dw.dir.path}/jobs-served-$runId.log').readAsLinesSync();

/// Every `gh workflow run` dispatch the stub saw — gh-1903: exactly one
/// per leg run, in EVERY scenario (no re-dispatch exists anymore).
List<String> dispatches(DwRun dw) =>
    dw.log.where((l) => l.startsWith('workflow run')).toList();

Map<String, String> _baseEnv(String bin, String dir) => {
  'PATH': '$bin:${Platform.environment['PATH']}',
  'GITHUB_REPOSITORY': 'OWNER/REPO',
  'GH_TOKEN': 'stub',
  'GH_STUB_DIR': dir,
  'GH_LOG_FILE': '$dir/log',
  'DW_POLL_SECONDS': '0',
  'DW_APPEAR_POLL_SECONDS': '0',
  'DW_APPEAR_ATTEMPTS': '20',
  'DW_DIAG_SECONDS': '0',
};

/// Seeds a stub-gh fixture dir + stub binary for [name]; returns the dir.
Directory _fixtureDir(String name) {
  final dir = Directory(
    '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  return dir;
}

void _seed(Directory dir, Map<String, String> stubFiles) {
  for (final e in stubFiles.entries) {
    File('${dir.path}/${e.key}').writeAsStringSync(e.value);
  }
  File('${dir.path}/log').writeAsStringSync('');
}

/// Runs scripts/dispatch_and_watch.sh to completion with [args];
/// [stubFiles] seed the stub-gh fixture dir. Time knobs are shrunk so
/// poll/diag loops resolve in ~1s.
DwRun runDw(
  String name,
  List<String> args,
  Map<String, String> stubFiles, {
  Map<String, String> env = const {},
  bool runIdFile = true,
}) {
  final dir = _fixtureDir(name);
  final bin = stubGh(dir.path);
  _seed(dir, stubFiles);
  final fullArgs = [
    ...args,
    if (runIdFile) ...['--out-run-id', '${dir.path}/run-id.txt'],
  ];
  final res = Process.runSync(
    'bash',
    [File('scripts/dispatch_and_watch.sh').absolute.path, ...fullArgs],
    workingDirectory: Directory.current.path,
    environment: {..._baseEnv(bin, dir.path), ...env},
  );
  final f = File('${dir.path}/run-id.txt');
  return DwRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/log').readAsLinesSync(),
    runIdFile && f.existsSync() ? f.readAsStringSync().trim() : null,
    dir,
  );
}

/// Starts the watcher as a live process (for signal tests): the caller
/// gets the process, the fixture dir and the stub log path, drives it,
/// then sends TERM/INT to exercise the gh-1903 orphan-cleanup trap.
class DwLive {
  DwLive(this.process, this.dir, this.logFile);

  final Process process;
  final Directory dir;
  final String logFile;

  String get log => File(logFile).readAsStringSync();
  List<String> get logLines => log.split('\n');
  String get out => _outBuf.toString();
  final _outBuf = StringBuffer();

  /// Everything needed to post-mortem a failed signal handoff (issue #1924
  /// validation red, gh-1903 leg): the script's own stdout/stderr (the
  /// `::error::` trap diagnostic names the taken branch), the stub gh log
  /// tail (which polls completed) and any cancelled-* stub artifacts. The
  /// signal tests surface this in the failure reason — a bare
  /// `Expected 143, Actual 2` without it is undebuggable on CI.
  String diagnostics() {
    final buf = StringBuffer()..write(out);
    if (File(logFile).existsSync()) {
      buf
        ..writeln('--- stub gh log (tail) ---')
        ..write(
          logLines.length <= 30
              ? log
              : '${logLines.sublist(logLines.length - 30).join('\n')}\n',
        );
    }
    final cancelled = Directory(dir.path)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('cancelled-'))
        .map((f) => f.uri.pathSegments.last)
        .toList();
    if (cancelled.isNotEmpty) {
      buf.writeln('--- stub cancelled-* artifacts: $cancelled');
    }
    return buf.toString();
  }

  /// Waits until the stub log contains [needle] (the watch has begun) or
  /// the process exits — whichever comes first.
  Future<void> waitForLog(
    String needle, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    process.stdout.transform(utf8.decoder).listen(_outBuf.write);
    process.stderr.transform(utf8.decoder).listen(_outBuf.write);
    while (DateTime.now().isBefore(deadline)) {
      if (File(logFile).existsSync() &&
          File(logFile).readAsStringSync().contains(needle)) {
        return;
      }
      if (exited) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('waitForLog timed out waiting for "$needle"');
  }

  /// Waits until the stub gh log holds [needle] at least [occurrences]
  /// times — a poll-COUNT anchor (issue #1924 validation red): TERM must
  /// land while the script sits in its poll sleep, never blindly inside
  /// the startup window where a sibling suite's process churn can race
  /// the trap installation.
  Future<void> waitForPolls(
    String needle, {
    int occurrences = 2,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (File(logFile).existsSync() &&
          '${File(logFile).readAsStringSync()} '
              .split(needle)
              .length -
              1 >=
          occurrences) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError(
      'waitForPolls timed out waiting for "$needle" x$occurrences — '
      'script is wedged pre-poll; state: ${diagnostics()}',
    );
  }

  /// Waits for the watcher to exit. The default budget is deliberately
  /// generous: a trap fires only after the foreground child it was
  /// deferred behind completes (bash semantics — the stub gh/sleep chain
  /// between polls), and on a starved runner that handoff has outlived
  /// 15s (hostile ambient env red on commit b93d825b: `Bad state: process
  /// did not exit after signal` in the INT orphan-cancel test). On
  /// timeout the watcher is SIGKILLed and the error carries [diagnostics]
  /// — a bare state error here is undebuggable on CI, the same rule the
  /// #1924 hardening applied to the exit-code expectations.
  Future<int> finish({Duration timeout = const Duration(seconds: 30)}) =>
      process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw StateError(
            'process did not exit after signal — diagnostics:\n'
            '${diagnostics()}',
          );
        },
      );
}

Future<DwLive> startDw(
  String name,
  List<String> args,
  Map<String, String> stubFiles, {
  Map<String, String> env = const {},
}) async {
  final dir = _fixtureDir(name);
  final bin = stubGh(dir.path);
  _seed(dir, stubFiles);
  final process = await Process.start(
    'bash',
    [File('scripts/dispatch_and_watch.sh').absolute.path, ...args],
    workingDirectory: Directory.current.path,
    environment: {..._baseEnv(bin, dir.path), ...env},
  );
  return DwLive(process, dir, '${dir.path}/log');
}

String runJson(List<Map<String, Object>> runs) => jsonEncode(runs);

Map<String, Object> run(int id, String title, String createdAt) => {
  'databaseId': id,
  'createdAt': createdAt,
  'displayTitle': title,
};

/// One `in_progress -` line per poll for [polls] polls, then completion.
String longQueuedThen({int polls = 60, String end = 'completed success'}) =>
    '${List.filled(polls, 'in_progress -').join('\n')}\n$end\n';

const playTitle = 'build-mobile (all/none)';
const testflightTitle = 'build-mobile (none/all)';

/// Sibling runs occupying the shared runner while our child waits.
const siblingRuns = [
  {'databaseId': 900, 'displayTitle': 'ci (main)'},
  {'databaseId': 901, 'displayTitle': 'build-macos (create_release=true)'},
];

void main() {
  // ── #343 — run correlation ─────────────────────────────────────────────
  group('#343 — dispatch correlation (title + newest + tight window)', () {
    test('latches OUR run when the sibling leg\'s run lists first', () {
      // Both legs dispatch build-mobile.yml in the same minute; the
      // TestFlight-shaped run is listed FIRST (old code took [0]).
      final dw = runDw(
        'sibling-race',
        [
          'build-mobile.yml',
          '--title',
          playTitle,
          '-f',
          'android_content=all',
          '-f',
          'ios_content=none',
        ],
        {
          'runs.json': runJson([
            run(111, testflightTitle, iso(-5)),
            run(222, playTitle, iso(-2)),
          ]),
          'view-222.txt': 'completed success\n',
        },
      );
      expect(dw.exitCode, 0);
      expect(dw.runIdFile, '222');
      expect(
        dw.log,
        anyElement(contains('run view 222 --repo OWNER/REPO')),
        reason: 'must watch the play-shaped run',
      );
      expect(
        dw.log.where((l) => l.contains('run view 111')),
        isEmpty,
        reason: 'the sibling\'s run must never be watched',
      );
      expect(dispatches(dw).length, 1, reason: 'gh-1903: no re-dispatch');
      expect(
        dw.log,
        anyElement(
          contains(
            'workflow run build-mobile.yml --repo OWNER/REPO --ref main -f android_content=all -f ios_content=none',
          ),
        ),
      );
    });

    test('prefers the NEWEST same-title match inside the window', () {
      final dw = runDw(
        'newest-match',
        ['build-mobile.yml', '--title', playTitle, '-f', 'android_content=all'],
        {
          'runs.json': runJson([
            run(111, playTitle, iso(-20)),
            run(222, playTitle, iso(-2)),
          ]),
          'view-222.txt': 'completed success\n',
        },
      );
      expect(dw.exitCode, 0);
      expect(
        dw.runIdFile,
        '222',
        reason: '[-1] newest, never [0] of the timestamp-ordered list',
      );
    });

    test('ignores same-title runs older than the window (stale-run race)', () {
      // A stale iOS-only build-mobile run failed minutes BEFORE the Play
      // leg dispatched; even a stale SAME-titled run must be outside the
      // window.
      final dw = runDw(
        'stale-run',
        ['build-mobile.yml', '--title', playTitle, '-f', 'android_content=all'],
        {
          'runs.json': runJson([
            run(999, playTitle, iso(-300)),
            run(222, playTitle, iso(-2)),
          ]),
          'view-222.txt': 'completed success\n',
        },
      );
      expect(dw.exitCode, 0);
      expect(dw.runIdFile, '222');
      expect(dw.log.where((l) => l.contains('run view 999')), isEmpty);
    });

    test(
      'without --title still takes the newest in-window dispatch (pages/addin legs)',
      () {
        final dw = runDw(
          'no-title',
          ['pages.yml'],
          {
            'runs.json': runJson([
              run(555, 'Deploy to GitHub Pages', iso(-25)),
              run(556, 'Deploy to GitHub Pages', iso(-2)),
            ]),
            'view-556.txt': 'completed success\n',
          },
        );
        expect(dw.exitCode, 0);
        expect(dw.runIdFile, '556');
      },
    );

    test('polls until the dispatched run appears', () {
      final dw = runDw(
        'appear-poll',
        ['pages.yml'],
        {
          'runs.json': runJson([run(777, 'Deploy to GitHub Pages', iso(-1))]),
          'view-777.txt': 'completed success\n',
        },
        env: {'GH_STUB_LIST_EMPTY_FIRST': '3'},
      );
      expect(dw.exitCode, 0);
      expect(dw.runIdFile, '777');
    });

    test('fails loudly when the dispatched run never appeared', () {
      final dw = runDw('never-appears', ['pages.yml'], {'runs.json': '[]'});
      expect(dw.exitCode, 1);
      expect(dw.out, contains('never appeared'));
      // Nothing was ever correlated — the orphan-cancel trap has no run
      // to touch.
      expect(dw.log.where((l) => l.contains('run cancel')), isEmpty);
    });

    test(
      'a completed non-success conclusion fails the leg, no re-dispatch',
      () {
        final dw = runDw(
          'clean-failure',
          [
            'build-mobile.yml',
            '--title',
            playTitle,
            '-f',
            'android_content=all',
          ],
          {
            'runs.json': runJson([run(111, playTitle, iso(-2))]),
            'view-111.txt': 'completed failure\n',
          },
        );
        expect(dw.exitCode, 1);
        expect(dw.out, contains('concluded failure'));
        expect(dispatches(dw).length, 1, reason: 'no retry exists (gh-1903)');
        expect(
          dw.log.where((l) => l.contains('run cancel')),
          isEmpty,
          reason:
              'the child COMPLETED — it started, so even the orphan-cancel '
              'class does not apply',
        );
      },
    );

    test('rejects the removed --budget-seconds flag loudly (gh-1903)', () {
      final dw = runDw(
        'budget-flag-gone',
        ['pages.yml', '--budget-seconds', '60'],
        {'runs.json': '[]'},
      );
      expect(dw.exitCode, 2, reason: 'no watcher budget exists anymore');
      expect(dw.out, contains('unknown flag'));
      expect(dispatches(dw), isEmpty, reason: 'nothing may be dispatched');
    });
  });

  // ── gh-1903 — dispatch + wait, never kill ────────────────────────────────
  group('gh-1903 — read-only wait, no stall timer, no re-dispatch', () {
    test('(a) child queued 45m with siblings in_progress → NO cancel, leg '
        'keeps waiting, then green', () {
      // The 2026-10-26 incident shape: testflight child queued behind
      // the same daily's cli/macos + CI runs on the single self-hosted
      // runner. Old watchdog: cancelled at ~31m ("queue stall"), twice,
      // then failed the leg. New invariant: keeps waiting, goes green.
      final dw = runDw(
        'healthy-queue',
        [
          'build-mobile.yml',
          '--title',
          testflightTitle,
          '-f',
          'ios_content=all',
        ],
        {
          'runs.json': runJson([run(111, testflightTitle, iso(-2))]),
          // 45m of queue modeled as 60 quiet polls (fixture time, not
          // wall time): the first 30 polls have no job in_progress, a job
          // starts on poll 31, the run completes on poll 61.
          'view-111.txt': longQueuedThen(),
          'jobs-111.txt': '${List.filled(30, '0').join('\n')}\n1\n',
          'siblings.json': runJson(siblingRuns),
        },
      );
      expect(dw.exitCode, 0, reason: 'a long healthy queue ends green');
      expect(
        dw.runIdFile,
        '111',
        reason: 'no re-dispatch — the same run is watched throughout',
      );
      expect(
        File('${dw.dir.path}/cancelled-111').existsSync(),
        isFalse,
        reason: 'a healthy queued child is NEVER cancelled',
      );
      expect(dispatches(dw).length, 1, reason: '(d) no re-dispatch');
      expect(
        dw.out,
        contains('sibling activity'),
        reason: 'sibling in-progress runs must be logged read-only',
      );
      expect(
        dw.out,
        contains('900'),
        reason: 'the diagnostic names the occupying runs',
      );
      expect(
        servedJobs(dw, 111).contains('{"status":"in_progress"}'),
        isTrue,
        reason:
            'the fixture genuinely modeled the job starting after the '
            'queue — an inert jobs fixture would make the test vacuous',
      );
      expect(
        dw.log.where((l) => l.contains('run view 111 ')).length,
        greaterThan(60),
        reason: 'the leg kept polling through the whole queue',
      );
    });

    test('(b) child completes after a long queue with NO siblings in '
        'progress → leg green, idle-pool warning logged, still no cancel', () {
      // Zombie-SHAPED fixture (quiet pool, child not starting) that
      // resolves healthy: the read-only probe may warn, but must never
      // cancel — and a real zombie still surfaces at the leg timeout
      // via the orphan-cancel trap (test below), not mid-watch.
      final dw = runDw(
        'quiet-pool-resolves',
        [
          'build-mobile.yml',
          '--title',
          testflightTitle,
          '-f',
          'ios_content=all',
        ],
        {
          'runs.json': runJson([run(111, testflightTitle, iso(-2))]),
          'view-111.txt': longQueuedThen(polls: 40),
          'jobs-111.txt': '${List.filled(200, '0').join('\n')}\n1\n',
          'siblings.json': '[]',
        },
      );
      expect(dw.exitCode, 0);
      expect(File('${dw.dir.path}/cancelled-111').existsSync(), isFalse);
      expect(dispatches(dw).length, 1);
      expect(
        dw.out,
        contains('pool appears IDLE'),
        reason:
            'an empty repo-wide in_progress list while the child never '
            'started positively establishes pool idleness — the gh-172 '
            'zombie signature must be NAMED read-only',
      );
      expect(
        dw.out,
        contains('NO cancel'),
        reason:
            'even with idleness positively established, mid-watch '
            'cancellation does not exist (gh-1903)',
      );
    });

    test('(e) a failing liveness probe produces the cannot-judge diagnostic '
        'and no cancel either', () {
      final dw = runDw(
        'probe-unreachable',
        [
          'build-mobile.yml',
          '--title',
          testflightTitle,
          '-f',
          'ios_content=all',
        ],
        {
          'runs.json': runJson([run(111, testflightTitle, iso(-2))]),
          'view-111.txt': longQueuedThen(polls: 20),
          'jobs-111.txt': '${List.filled(200, '0').join('\n')}\n1\n',
          // The probe can never answer: idleness can be neither
          // established nor excluded — the worst case for judgment.
          'sibling-fail-next': '99\n',
        },
      );
      expect(dw.exitCode, 0);
      expect(File('${dw.dir.path}/cancelled-111').existsSync(), isFalse);
      expect(dispatches(dw).length, 1);
      expect(
        dw.out,
        contains('cannot observe, cannot judge'),
        reason:
            'gh-172: when the probe fails, the leg log must say so '
            'instead of guessing',
      );
      expect(
        dw.log.where((l) => l.contains('--status in_progress')),
        isNotEmpty,
        reason:
            'the probe itself must stay read-only (a listing, never '
            'a cancel-class call)',
      );
    });

    test('a sustained gh/API outage does not cancel — failed polls just log '
        'and the wait continues', () {
      final dw = runDw(
        'outage-no-cancel',
        ['build-mobile.yml', '--title', playTitle, '-f', 'android_content=all'],
        {
          'runs.json': runJson([run(111, playTitle, iso(-10))]),
          // 4 failed polls (the outage), then the child was running all
          // along and completes.
          'view-fail-next': '4\n',
          'jobs-111.txt': '1\n',
          'view-111.txt': 'in_progress -\nin_progress -\ncompleted success\n',
        },
        env: {'DW_POLL_SECONDS': '1'},
      );
      expect(dw.exitCode, 0);
      expect(dispatches(dw).length, 1);
      expect(
        dw.log.where((l) => l.contains('run cancel')),
        isEmpty,
        reason:
            'during an outage the cancel is unreachable anyway — and '
            'there is nothing to cancel: cannot observe, cannot judge',
      );
      expect(
        dw.out,
        contains('cannot observe, cannot judge'),
        reason: 'failed polls must be visible in the leg log (gh-172)',
      );
    });
  });

  // ── gh-1903 — the ONE cancel path: leg-termination orphan-cleanup ────────
  group('gh-1903 — orphan-cancel fires only when the LEG dies', () {
    test('(c) leg timeout (TERM) with a never-started child → exactly one '
        'targeted cancel of that child, none otherwise', () async {
      final live = await startDw(
        'term-never-started',
        [
          'build-mobile.yml',
          '--title',
          testflightTitle,
          '-f',
          'ios_content=all',
        ],
        {
          'runs.json': runJson([run(111, testflightTitle, iso(-2))]),
          // The child never starts (queued forever on the pool) — the
          // gh-172 zombie, now bounded by the leg timeout instead of a
          // heuristic.
          'view-111.txt': 'in_progress -\n',
          'jobs-111.txt': '0\n',
          'siblings.json': runJson(siblingRuns),
        },
        env: {'DW_POLL_SECONDS': '1'},
      );
      await live.waitForLog('run view 111 --repo OWNER/REPO');
      // Give the watch a couple of polls so the sibling probe has run,
      // then the leg timeout fires (runner → SIGTERM). Poll-anchored, not
      // a blind delay — the handoff must land inside the poll loop
      // (issue #1924 validation red).
      await live.waitForPolls('run view 111 --repo OWNER/REPO');
      expect(
        File('${live.dir.path}/cancelled-111').existsSync(),
        isFalse,
        reason:
            '(e) mid-watch there must be NO cancel even on this '
            'zombie-shaped fixture — diagnostics only',
      );
      live.process.kill(ProcessSignal.sigterm);
      final code = await live.finish();
      expect(
        code,
        143,
        reason:
            'killed by the leg timeout (TERM); diagnostics:\n'
            '${live.diagnostics()}',
      );
      expect(
        File('${live.dir.path}/cancelled-111').existsSync(),
        isTrue,
        reason:
            'exactly the orphaned never-started child is cancelled so it '
            'cannot publish unattended when the pool revives (gh-172 '
            'containment, gh-1903 orphan-cancel)',
      );
      final cancels = live.logLines
          .where((l) => l.contains('run cancel'))
          .toList();
      expect(cancels.length, 1, reason: 'exactly ONE cancel, one target');
      expect(cancels.single, contains('run cancel 111 --repo OWNER/REPO'));
      expect(
        live.logLines.where((l) => l.startsWith('workflow run')).length,
        1,
        reason: '(d) the orphan-cancel must never re-dispatch',
      );
      expect(
        live.out,
        contains('NEVER STARTED'),
        reason: 'the leg-timeout diagnostic names the child state',
      );
      expect(
        live.out,
        contains('run 111'),
        reason: 'the diagnostic names the child run id',
      );
      expect(
        live.out,
        contains('in_progress run(s)'),
        reason: 'the diagnostic names the observed pool activity',
      );
    });

    test('TERM after the child started → NO cancel (never-started children '
        'only), nothing to cancel is logged', () async {
      final live = await startDw(
        'term-after-start',
        ['pages.yml'],
        {
          'runs.json': runJson([run(555, 'Deploy to GitHub Pages', iso(-2))]),
          // The child started long ago and is mid-build when the leg
          // times out: its own per-job timeout (#344) bounds it, the
          // watcher must NOT cancel it.
          'view-555.txt': 'in_progress -\n',
          'jobs-555.txt': '1\n',
          'siblings.json': '[]',
        },
        env: {'DW_POLL_SECONDS': '1'},
      );
      await live.waitForLog('run view 555 --repo OWNER/REPO');
      // Anchor on the SECOND completed poll (issue #1924 validation red):
      // TERM must land while the script sits in its poll sleep with the
      // trap installed and `watch_started` stamped — not blindly inside
      // the startup window where a sibling suite's process churn races
      // the handoff.
      await live.waitForPolls('run view 555 --repo OWNER/REPO');
      live.process.kill(ProcessSignal.sigterm);
      final code = await live.finish();
      expect(
        code,
        143,
        reason:
            'the dw script must die through the orphan-cleanup trap; '
            'diagnostics:\n${live.diagnostics()}',
      );
      expect(
        File('${live.dir.path}/cancelled-555').existsSync(),
        isFalse,
        reason:
            'a child that ever started is left to its own server-side '
            'job timeout — the orphan-cancel is never-started children '
            'ONLY (gh-1903 AC4)',
      );
      expect(
        live.logLines.where((l) => l.contains('run cancel')),
        isEmpty,
        reason: 'not one cancel call may be issued',
      );
      expect(
        live.out,
        contains('nothing to cancel'),
        reason: 'the diagnostic must say WHY no cancel happened',
      );
    });

    test('INT (manual workflow cancel) with a never-started child → the '
        'same single orphan-cancel', () async {
      final live = await startDw(
        'int-never-started',
        ['office-addin.yml'],
        {
          'runs.json': runJson([run(777, 'office-addin-suite', iso(-2))]),
          'view-777.txt': 'in_progress -\n',
          'jobs-777.txt': '0\n',
          'siblings.json': '[]',
        },
        env: {'DW_POLL_SECONDS': '1'},
      );
      await live.waitForLog('run view 777 --repo OWNER/REPO');
      // Same poll anchor as the TERM-after-start test (issue #1924
      // validation red): the handoff must land inside the poll loop.
      await live.waitForPolls('run view 777 --repo OWNER/REPO');
      live.process.kill(ProcessSignal.sigint);
      final code = await live.finish();
      expect(
        code,
        130,
        reason:
            'killed by manual cancel (INT); diagnostics:\n'
            '${live.diagnostics()}',
      );
      expect(File('${live.dir.path}/cancelled-777').existsSync(), isTrue);
      expect(
        live.logLines.where((l) => l.contains('run cancel')).length,
        1,
        reason: 'exactly one targeted cancel',
      );
    });
  });

  // ── DwLive.finish — the wedged signal handoff must self-identify ────────
  // Hostile ambient env red on commit b93d825b (CI job 122558113139): the
  // INT orphan-cancel test above died with the BARE
  // `Bad state: process did not exit after signal` — finish()'s budget
  // fired, SIGKILLed the watcher and threw WITHOUT DwLive.diagnostics(),
  // so the wedge was undebuggable on CI (the last failure surface the
  // #1924 hardening had not covered: the exit-code expectations carry
  // diagnostics, the timeout path did not). The deferral itself is real
  // bash semantics — SIGINT landing while the script sits in a FOREGROUND
  // child (stub gh, sleep) waits for it before running the trap — and
  // under runner-scale fork/exec starvation that handoff outlived 15s.
  group('DwLive.finish — wedged signal handoff self-identifies', () {
    test(
      'the timeout failure carries the diagnostics, not a bare state error',
      () async {
        final dir = _fixtureDir('finish-wedge-diagnostics');
        _seed(dir, const {});
        // The exact deferral shape CI starved past the budget: the signal
        // lands while bash sits in a foreground child; the installed trap
        // waits for it, so the process outlives finish()'s patience. The
        // `ready` handshake mirrors the signal tests' poll anchor (#1924):
        // INT must land AFTER the trap line ran, never inside the startup
        // window.
        final process = await Process.start('bash', [
          '-c',
          'trap "exit 130" INT; echo ready; sleep 5',
        ]);
        final live = DwLive(process, dir, '${dir.path}/log');
        await process.stdout
            .transform(utf8.decoder)
            .firstWhere((chunk) => chunk.contains('ready'));
        process.kill(ProcessSignal.sigint);
        await expectLater(
          live.finish(timeout: const Duration(milliseconds: 300)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('process did not exit after signal'),
                contains('--- stub gh log (tail) ---'),
              ),
            ),
          ),
        );
      },
    );
  });

  // ── workflow structural lint ───────────────────────────────────────────
  group('workflows — correlation plumbing (#343) and gh-1903 bounds', () {
    test(
      'build-mobile.yml run-name embeds both content inputs (displayTitle disambiguator)',
      () {
        final y = loadYaml(read('.github/workflows/build-mobile.yml'));
        final runName = y['run-name'].toString();
        expect(runName, contains('inputs.android_content'));
        expect(runName, contains('inputs.ios_content'));
      },
    );

    test(
      'build-macos.yml run-name embeds create_release (displayTitle disambiguator)',
      () {
        final y = loadYaml(read('.github/workflows/build-macos.yml'));
        expect(y['run-name'].toString(), contains('inputs.create_release'));
      },
    );

    test(
      'self-hosted build-mobile jobs carry a job-level timeout-minutes (server-side wedge bound)',
      () {
        // #344/#351: submit-ios must clear the fastlane submit_only lane's
        // own worst case — 90m wait_processing_timeout_duration
        // (TESTFLIGHT_WAIT_TIMEOUT_SECONDS default 5400s) + 15m
        // verify_external_distribution! (TESTFLIGHT_VERIFY_TIMEOUT_SECONDS
        // 900s) = 105m of pure lane time, plus setup/upload ≈ 15m. The
        // per-job server-side timeout is the bound that replaced the
        // removed watcher budget (gh-1903) — these ceilings are now the
        // ONLY mid-watch failure bound besides the leg timeout.
        const laneWorstCaseMinutes = 90 + 15;
        final ceilings = {'build-ios': 90, 'submit-ios': 120};
        ceilings.forEach((jobId, expected) {
          final job =
              jobsOf('.github/workflows/build-mobile.yml')[jobId] as YamlMap;
          expect(
            job['runs-on'].toString(),
            contains('self-hosted'),
            reason: 'layout drift — $jobId is expected on the self-hosted pool',
          );
          final t = job['timeout-minutes'];
          expect(
            t,
            isNotNull,
            reason:
                'gh-1903: with the watcher budget gone, a wedged self-hosted '
                'job self-fails ONLY via this server-side job timeout',
          );
          expect(
            t,
            expected,
            reason:
                '$jobId ceiling is part of the #351 worst-case arithmetic — '
                'update the daily-publish leg table with it, not just this pin',
          );
        });
        expect(
          ceilings['submit-ios']!,
          greaterThanOrEqualTo(laneWorstCaseMinutes),
          reason:
              '#351 BLOCKER: a submit-ios ceiling below 105m contradicts '
              'the lane it runs — healthy slow TestFlight submits die at the '
              'job timeout while fastlane is still waiting on Apple',
        );
      },
    );

    // The `Dispatch ... and watch` step of a dispatching leg, run text only.
    String dispatchStepRun(String leg) {
      final steps =
          jobsOf('.github/workflows/daily-publish.yml')[leg]['steps']
              as YamlList;
      final step =
          steps.firstWhere(
                (s) =>
                    s is YamlMap &&
                    (s['name']?.toString() ?? '').startsWith('Dispatch '),
              )
              as YamlMap;
      return step['run'].toString();
    }

    test(
      'every dispatching leg routes through dispatch_and_watch.sh (no legacy correlation)',
      () {
        final daily = read('.github/workflows/daily-publish.yml');
        expect(
          daily,
          isNot(contains('[0].databaseId')),
          reason:
              'legacy [0]-of-list correlation is the #343 bug — it must be gone',
        );
        for (final leg in ['testflight', 'play', 'cli', 'website', 'addin']) {
          final runText = dispatchStepRun(leg);
          expect(
            runText,
            contains('dispatch_and_watch.sh'),
            reason: 'leg "$leg" must use the shared watcher',
          );
          expect(
            runText,
            isNot(contains('gh run watch')),
            reason:
                'leg "$leg": gh run watch blocks until the leg timeout '
                'with no diagnostics at all (gh-172)',
          );
        }
      },
    );

    test('gh-1903: no leg passes a watcher budget or stall knob; the '
        'watchdog vocabulary is gone from the workflow', () {
      final daily = read('.github/workflows/daily-publish.yml');
      for (final leg in ['testflight', 'play', 'cli', 'website', 'addin']) {
        final runText = dispatchStepRun(leg);
        expect(
          runText,
          isNot(contains('--budget-seconds')),
          reason:
              'leg "$leg": the watcher budget was the gh-1903 defect — '
              'waiting is bounded solely by the child per-job timeouts '
              '(#344) and the leg timeout-minutes',
        );
        expect(
          runText,
          isNot(contains('DW_QUEUE_STALL_SECONDS')),
          reason: 'leg "$leg": the queue-stall watchdog must be gone',
        );
      }
      expect(
        daily.contains('re-dispatching once'),
        isFalse,
        reason:
            'the self-heal cancel/re-dispatch must not survive anywhere '
            'in the daily workflow (gh-1903 AC1)',
      );
    });

    test(
      'build-mobile/build-macos legs pass --title values matching the child run-name',
      () {
        // The child run-name renders as `build-mobile (<android>/<ios>)` /
        // `build-macos (create_release=<v>)` — the legs must pass exactly
        // those strings or the displayTitle correlation never matches.
        expect(
          dispatchStepRun('testflight'),
          contains("--title 'build-mobile (none/all)'"),
        );
        expect(
          dispatchStepRun('play'),
          contains("--title 'build-mobile (all/none)'"),
        );
        expect(
          dispatchStepRun('cli'),
          contains("--title 'build-macos (create_release=true)'"),
        );
      },
    );

    // ── #351 — timeout arithmetic (leg-timeout sizing) ────────────────────
    // Child worst-case = sum of explicit job timeout-minutes along the
    // serialized critical path of the child DAG, for the exact dispatch
    // shape the leg sends ([skip] = jobs whose `if` skips them there;
    // [serial] = matrix jobs that QUEUE on the single self-hosted runner,
    // so their ceiling counts once per matrix leg). Parallel branches take
    // the max; a skipped dependency contributes 0 (a job like
    // release-mobile with `if: always()` still runs after skipped needs).
    int childWorstCase(
      String workflowPath, {
      Set<String> skip = const {},
      Map<String, int> serial = const {},
    }) {
      final jobs = jobsOf(workflowPath);
      final memo = <String, int>{};
      int finish(String id) => memo.putIfAbsent(id, () {
        final job = jobs[id] as YamlMap;
        var duration = (job['timeout-minutes'] as num).toInt();
        duration *= serial[id] ?? 1;
        final needs = job['needs'];
        final deps = needs is List
            ? needs.cast<String>().toList()
            : needs == null
            ? const <String>[]
            : <String>[needs as String];
        var start = 0;
        for (final d in deps) {
          if (!skip.contains(d)) start = math.max(start, finish(d));
        }
        return start + duration;
      });
      var worst = 0;
      for (final id in jobs.keys.cast<String>()) {
        if (!skip.contains(id)) worst = math.max(worst, finish(id));
      }
      return worst;
    }

    // The #351 arithmetic table — must mirror the "Timeout arithmetic"
    // comment in daily-publish.yml and the per-leg comments. Invariant:
    // leg timeout > child worst-case + ~15m margin (appear window 10m +
    // poll slack 5m). No watcher budget exists anymore (gh-1903) — the
    // leg timeout and the children's per-job timeout-minutes are the only
    // bounds.
    const legArithmetic =
        <String, (String, Set<String>, Map<String, int>, int, int)>{
          // leg: (child workflow, skipped jobs, matrix-serialized jobs,
          //       child worst-case m, leg timeout m)
          'testflight': (
            '.github/workflows/build-mobile.yml',
            {'build-android', 'submit-android'},
            {},
            230,
            360,
          ),
          'play': (
            '.github/workflows/build-mobile.yml',
            {'build-ios', 'submit-ios'},
            {},
            95,
            240,
          ),
          'cli': (
            '.github/workflows/build-macos.yml',
            {},
            {'build-macos': 2},
            335,
            360,
          ),
          'website': ('.github/workflows/pages.yml', {}, {}, 60, 180),
          'addin': ('.github/workflows/office-addin.yml', {}, {}, 45, 150),
        };

    test(
      'every job in a watched child workflow carries an explicit timeout-minutes (#351)',
      () {
        // The worst-case sums above are only real if every ceiling is
        // explicit — a job without timeout-minutes silently inherits
        // GitHub's 360m default and breaks the arithmetic. These same
        // ceilings are now the ONLY mid-watch bound (gh-1903), so a
        // missing one would also leave a wedged job unbounded.
        for (final workflow in {
          '.github/workflows/build-mobile.yml',
          '.github/workflows/build-macos.yml',
          '.github/workflows/pages.yml',
          '.github/workflows/office-addin.yml',
        }) {
          jobsOf(workflow).forEach((id, job) {
            expect(
              (job as YamlMap)['timeout-minutes'],
              isNotNull,
              reason:
                  '$workflow job "$id" has no timeout-minutes — the #351 '
                  'worst-case arithmetic (and the gh-1903 bound that '
                  'replaced the watcher budget) needs an explicit ceiling',
            );
          });
        }
      },
    );

    test(
      'leg timeouts clear the child worst-case with margin (#351 arithmetic)',
      () {
        legArithmetic.forEach((leg, spec) {
          final (workflow, skip, serial, wcMinutes, legTimeout) = spec;
          final computed = childWorstCase(workflow, skip: skip, serial: serial);
          expect(
            computed,
            wcMinutes,
            reason:
                'leg "$leg": the documented child worst-case drifted — '
                'update the arithmetic table (daily-publish.yml comment AND '
                'this test) together',
          );
          final legMinutes =
              (jobsOf('.github/workflows/daily-publish.yml')[leg]
                      as YamlMap)['timeout-minutes']
                  as num;
          expect(
            legMinutes.toInt(),
            legTimeout,
            reason: 'leg "$leg": leg timeout drifted from the #351 table',
          );
          expect(
            legMinutes.toInt(),
            greaterThanOrEqualTo(wcMinutes + 15),
            reason:
                'leg "$leg": the $legTimeout m leg must clear the child '
                'worst-case $wcMinutes m by ≥15m (appear window 10m + poll '
                'slack 5m) — a healthy slow child now rides to its own '
                'per-job timeouts instead of a watcher budget (gh-1903)',
          );
        });
      },
    );

    test(
      'build-mobile concurrency group is per-dispatch — no cross-run cancellation (#351)',
      () {
        // Since #359 the play/testflight legs dispatch build-mobile.yml
        // CONCURRENTLY by design; a ref-scoped cancel-in-progress group
        // would let one sibling's dispatch cancel the other's in-flight
        // run. The group is suffixed with run_id so every dispatch is
        // independent (correlation rests on the distinct run-name (#343),
        // not on serialization).
        final y =
            loadYaml(read('.github/workflows/build-mobile.yml')) as YamlMap;
        final concurrency = y['concurrency'] as YamlMap;
        expect(
          concurrency['group'].toString(),
          contains('github.run_id'),
          reason:
              'the build-mobile concurrency group must be scoped '
              'per-dispatch (run_id suffix) so no dispatch can cancel '
              'another (#351)',
        );
        expect(
          concurrency['cancel-in-progress'],
          isFalse,
          reason:
              'with a per-dispatch group there is never anything to '
              'cancel — cancel-in-progress: true would be dead config '
              'implying the old cross-run vector still exists',
        );
      },
    );

    test(
      'dispatching legs check out the repo (the watcher script lives there)',
      () {
        for (final leg in ['testflight', 'play', 'cli', 'website', 'addin']) {
          final steps =
              jobsOf('.github/workflows/daily-publish.yml')[leg]['steps']
                  as YamlList;
          expect(
            steps.any(
              (s) =>
                  s is YamlMap &&
                  s['uses'].toString().startsWith('actions/checkout'),
            ),
            isTrue,
            reason:
                'leg "$leg" must check out the repo to run scripts/dispatch_and_watch.sh',
          );
        }
      },
    );
  });
}
