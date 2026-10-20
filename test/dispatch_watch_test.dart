// Issues #343 + #344 — nightly release orchestration:
//
// #343: the daily-publish Play/TestFlight legs dispatch the SAME workflow
// (build-mobile.yml) as concurrent `needs: plan` siblings and identified
// "their" run by event + a 60s createdAt window only, taking [0] of the
// list — so the Play leg could latch the TestFlight run (or a stale
// same-shaped run from the trailing window) and watch a build that never
// builds Android. The fix: children carry a run-name embedding their
// inputs, and the watcher correlates by exact displayTitle + NEWEST match
// + a tight window.
//
// #344: a self-hosted runner that lost its final job-completion report
// holds a SUCCEEDED job in_progress forever (nothing server-side detects
// a stale self-hosted job below the workflow timeout), blocking the
// single-runner pool and every watcher for the full 300m leg timeout. The
// fix: job-level timeout-minutes on the self-hosted build-mobile jobs, and
// a budgeted watch in the shared dispatcher that cancels a wedged run and
// re-dispatches exactly once before failing.
//
// #351 (timeout arithmetic recompute): the original budgets sat BELOW the
// children's ceilings — the watcher cancelled legitimate slow children
// (testflight 90m budget vs a 220m chain whose submit-ios alone can spend
// 90m waiting for Apple processing + 15m verifying distribution), and the
// website/addin budgets could never even complete their cancel +
// re-dispatch inside the 45m leg timeout (dead self-heal). Now: every job
// in a watched child chain carries an explicit timeout-minutes; child
// worst-case = sum along the serialized critical path; budget =
// worst-case + ~15m margin; leg timeout > budget, and ≥ 2×budget + margin
// whenever that fits under GitHub's 360m job cap so the second-wedge
// fail-fast can actually fire inside the leg.
//
// Structural lint over the workflow YAML plus behavioral tests of
// scripts/dispatch_and_watch.sh against a stubbed `gh` (same style as
// release_hygiene_test.dart). The stub pipes fixtures through the REAL jq
// expression the script passes to `gh run list`, so the correlation logic
// itself (title filter, window, newest-match) is under test.
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
///   `runs.json`        — raw `gh run list --json` array
///   `view-<id>.txt`    — one `<status> <conclusion>` line per
///                        `gh run view <id>` poll; the last line repeats
///                        once exhausted
///   `jobs-<id>.txt`    — one running-job COUNT per watch poll; the last
///                        line repeats; absent file = 1 job always running
///   `jobs-served-<id>.log` — (written by the stub) the jobs body actually
///                        served per poll — ground truth that a fixture
///                        modeled a running job, however the body was built
///   `cancelled-<id>`   — marker created by `gh run cancel`
///   `list-calls`       — internal counter
/// GH_STUB_LIST_EMPTY_FIRST=N makes the first N `run list` calls return [].
/// Any `--jq` argument is applied with the real jq, so the script's own
/// correlation expressions run against the fixtures.
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
        calls=\$(( \$(cat "\$GH_STUB_DIR/list-calls" 2>/dev/null || echo 0) + 1 ))
        echo "\$calls" > "\$GH_STUB_DIR/list-calls"
        runs_file="\$GH_STUB_DIR/runs.json"
        # Once a run has been cancelled, prefer runs2.json when present:
        # models the re-dispatched run appearing only after the cancel.
        if ls "\$GH_STUB_DIR"/cancelled-* >/dev/null 2>&1 && [ -f "\$GH_STUB_DIR/runs2.json" ]; then
          runs_file="\$GH_STUB_DIR/runs2.json"
        fi
        if [ "\$calls" -le "\${GH_STUB_LIST_EMPTY_FIRST:-0}" ]; then
          printf '[]' | apply_jq
        else
          cat "\$runs_file" | apply_jq
        fi
        ;;
      view)
        id="\$3"
        # The watcher polls with ONE combined call — `gh run view --json
        # status,conclusion,jobs` — served from two fixtures consumed in
        # lockstep: view-<id>.txt (one `<status> <conclusion>` line per
        # poll, last repeats) and jobs-<id>.txt (one running-job COUNT per
        # poll, last repeats; absent file = 1 job running (healthy child)
        # so older fixtures without job modeling keep their behavior;
        # cancelled = 0). The body actually served is appended to
        # jobs-served-<id>.log so a test can prove the fixture modeled a
        # running job regardless of how the body was built.
        is_jobs=0
        for ((j = 0; j < \${#args[@]} - 1; j++)); do
          if [ "\${args[\$j]}" = "--json" ] && [[ "\${args[\$((j + 1))]}" == *jobs* ]]; then is_jobs=1; fi
        done
        if [ -f "\$GH_STUB_DIR/cancelled-\$id" ]; then
          status=completed; conclusion=cancelled; jobs_body=""
        else
          f="\$GH_STUB_DIR/view-\$id.txt"
          line=\$(head -1 "\$f")
          sed -i.bak '1d' "\$f" && rm -f "\$f.bak"
          if ! [ -s "\$f" ]; then printf '%s\\n' "\$line" > "\$f"; fi
          status="\${line%% *}"; conclusion="\${line#* }"
          jobs_body=""
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
            # ({"jobs":[]} forever, whatever jobs-<id>.txt says). seq
            # emits the count, sed stamps each line into a running job,
            # paste comma-joins (n=0 → empty body → {"jobs":[]}).
            jobs_body=\$(seq "\$n" | sed 's/.*/{"status":"in_progress"}/' | paste -sd, -)
          fi
        fi
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

/// Runs scripts/dispatch_and_watch.sh with [args]; [stubFiles] seed the
/// stub-gh fixture dir. Time knobs are shrunk so budget/poll loops resolve
/// in ~1s.
DwRun runDw(
  String name,
  List<String> args,
  Map<String, String> stubFiles, {
  Map<String, String> env = const {},
  bool runIdFile = true,
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = stubGh(dir.path);
  for (final e in stubFiles.entries) {
    File('${dir.path}/${e.key}').writeAsStringSync(e.value);
  }
  File('${dir.path}/log').writeAsStringSync('');
  final fullArgs = [
    ...args,
    if (runIdFile) ...['--out-run-id', '${dir.path}/run-id.txt'],
  ];
  final res = Process.runSync(
    'bash',
    [File('scripts/dispatch_and_watch.sh').absolute.path, ...fullArgs],
    workingDirectory: Directory.current.path,
    environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'DW_POLL_SECONDS': '0',
      'DW_APPEAR_POLL_SECONDS': '0',
      'DW_APPEAR_ATTEMPTS': '20',
      'DW_CANCEL_WAIT_SECONDS': '1',
      ...env,
    },
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

String runJson(List<Map<String, Object>> runs) => jsonEncode(runs);

Map<String, Object> run(int id, String title, String createdAt) => {
  'databaseId': id,
  'createdAt': createdAt,
  'displayTitle': title,
};

const playTitle = 'build-mobile (all/none)';
const testflightTitle = 'build-mobile (none/all)';

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
          '--budget-seconds',
          '30',
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
      // Today\'s incident: a stale iOS-only build-mobile run failed 4
      // minutes BEFORE the Play leg dispatched and fell inside the old
      // 60s-trailing filter; here even a stale SAME-titled run must be
      // outside the window.
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

    test('fails loudly when the dispatched run never appears', () {
      final dw = runDw('never-appears', ['pages.yml'], {'runs.json': '[]'});
      expect(dw.exitCode, 1);
      expect(dw.out, contains('never appeared'));
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
        expect(
          dw.log.where((l) => l.startsWith('workflow run')).length,
          1,
          reason: 'a clean build failure is reported, not retried',
        );
      },
    );
  });

  // ── #344 — wedge self-healing ──────────────────────────────────────────
  group('#344 — budgeted watch, cancel + single re-dispatch', () {
    test(
      'wedged run is cancelled and re-dispatched once; the retry succeeds',
      () {
        final dw = runDw(
          'self-heal',
          [
            'build-mobile.yml',
            '--title',
            playTitle,
            '--budget-seconds',
            '1',
            '-f',
            'android_content=all',
          ],
          {
            // Attempt 1: run 111 wedged in_progress; after cancel, view
            // flips to completed/cancelled. Attempt 2: run 222 green (it
            // appears only once the cancel happened — runs2.json).
            'runs.json': runJson([run(111, playTitle, iso(-10))]),
            'runs2.json': runJson([
              run(111, playTitle, iso(-10)),
              run(222, playTitle, iso(-1)),
            ]),
            'view-111.txt': 'in_progress -\n',
            'view-222.txt': 'completed success\n',
          },
        );
        expect(dw.exitCode, 0);
        expect(
          dw.runIdFile,
          '222',
          reason: 'the out-run-id must follow the re-dispatched run',
        );
        expect(
          dw.log,
          anyElement(contains('run cancel 111 --repo OWNER/REPO')),
          reason: 'the wedged run must be cancelled',
        );
        expect(
          dw.log.where((l) => l.startsWith('workflow run')).length,
          2,
          reason: 'exactly one re-dispatch',
        );
        expect(
          dw.out,
          contains('re-dispatch'),
          reason: 'the self-heal must be visible in the leg log',
        );
      },
    );

    test('a second wedge fails fast instead of waiting out the leg timeout', () {
      final dw = runDw(
        'double-wedge',
        [
          'build-mobile.yml',
          '--title',
          playTitle,
          '--budget-seconds',
          '1',
          '-f',
          'android_content=all',
        ],
        {
          'runs.json': runJson([run(111, playTitle, iso(-10))]),
          'runs2.json': runJson([
            run(111, playTitle, iso(-10)),
            run(222, playTitle, iso(-1)),
          ]),
          'view-111.txt': 'in_progress -\n',
          'view-222.txt': 'in_progress -\n',
        },
      );
      expect(dw.exitCode, 1);
      expect(
        dw.log.where((l) => l.startsWith('workflow run')).length,
        2,
        reason: 'never more than one re-dispatch',
      );
      expect(
        dw.out,
        contains('runner pool suspect'),
        reason:
            'the second wedge must point at the pool (issue #344), not just time out',
      );
      expect(dw.out, contains('222'));
      expect(
        dw.log.any((l) => l.contains('run cancel 222 --repo OWNER/REPO')),
        isTrue,
        reason:
            'gh-172 containment: the wedged child is cancelled on the fail '
            'path too — left alive it publishes unattended when the pool revives',
      );
    });
  });

  // ── gh-172 — queue-stall guard (pool-held zombie) ───────────────────────
  // Run 39374894901, 2026-10-20: after the budget self-heal cancelled the
  // wedged run, the re-dispatched child sat `queued` FOREVER — the hung
  // self-hosted worker that ignored its own 90m job ceiling also never
  // processed the run cancellation, so the single-runner pool stayed held.
  // The watcher polls RUN status only, saw `in_progress` throughout, burned
  // the remaining ~107m of leg time, and the leg died at its 360m ceiling
  // with no diagnostic and the orphaned child left in the queue.
  group('gh-172 — a run alive but with nothing running is a wedge too', () {
    test(
      'pool-held child stalls into the one self-heal, then fails fast and cancels the orphan',
      () {
        final dw = runDw(
          'queue-stall',
          [
            'build-mobile.yml',
            '--title',
            testflightTitle,
            '--budget-seconds',
            '3', // stall window (1s) must win before the budget — in RED
            // the old budget path still ends each attempt in ~3s
            '-f',
            'ios_content=all',
          ],
          {
            // Attempt 1: run 111 in_progress but every job queued/done
            // (version completed 09:40:18, build-ios queued on the
            // zombie-held runner). Attempt 2: run 222, same signature.
            'runs.json': runJson([run(111, testflightTitle, iso(-10))]),
            'runs2.json': runJson([
              run(111, testflightTitle, iso(-10)),
              run(222, testflightTitle, iso(-1)),
            ]),
            'view-111.txt': 'in_progress -\n',
            'view-222.txt': 'in_progress -\n',
            'jobs-111.txt': '0\n',
            'jobs-222.txt': '0\n',
          },
          env: {'DW_QUEUE_STALL_SECONDS': '1'},
        );
        expect(dw.exitCode, 1);
        expect(
          dw.log.where((l) => l.startsWith('workflow run')).length,
          2,
          reason: 'the queue stall rides the same ONE self-heal as #344',
        );
        expect(
          dw.log.any((l) => l.contains('run cancel 111 --repo OWNER/REPO')),
          isTrue,
          reason: 'attempt 1 must be cancelled before the re-dispatch',
        );
        expect(dw.out, contains('re-dispatch'));
        expect(
          dw.out,
          contains('runner pool suspect'),
          reason:
              'the second stall must fail fast naming the pool, not burn '
              'the leg ceiling mid-watch (the gh-172 death)',
        );
        expect(dw.out, contains('222'));
        expect(
          dw.out,
          contains('no running job'),
          reason: 'the leg log must carry the queue-stall signature',
        );
        expect(
          dw.out,
          contains('queue-stall window 1s'),
          reason:
              'an explicit DW_QUEUE_STALL_SECONDS must override the '
              'scaled default (and be visible in the leg log)',
        );
        expect(
          dw.log.any((l) => l.contains('run cancel 222 --repo OWNER/REPO')),
          isTrue,
          reason:
              'the orphaned second run must be cancelled on the fail path — '
              'a queued child left behind publishes unattended when the pool revives',
        );
      },
    );

    test(
      'stall window defaults to max(600, budget/8) — sibling-leg occupancy must not false-wedge',
      () {
        // Review (gh-172): a fixed 600s window cannot tell a zombie-held
        // pool from a healthy child queued behind a SIBLING leg's job on
        // the shared single-runner pool (testflight's build-ios and cli's
        // build-macos matrix contend for the same fa-m5-1; one cli matrix
        // leg can hold it for ~150m). The default is therefore scaled off
        // the watch budget, and the effective window is echoed on the
        // watching line so leg logs (and this test) pin it.
        final floorDw = runDw(
          'stall-default-floor',
          ['pages.yml', '--budget-seconds', '800'], // 800/8 = 100s → floor
          {
            'runs.json': runJson([run(555, 'Deploy to GitHub Pages', iso(-2))]),
            'view-555.txt': 'completed success\n',
          },
        );
        expect(floorDw.exitCode, 0);
        expect(
          floorDw.out,
          contains('queue-stall window 600s'),
          reason: 'short budgets keep the fast 10-minute zombie trip',
        );
        // Absent jobs fixture = 1 job running (the documented contract) —
        // the served body must be a real running-job object, which is what
        // keeps the guard quiet on fixtures without job modeling.
        expect(
          servedJobs(floorDw, 555).first,
          '{"status":"in_progress"}',
          reason: 'absent file = 1 job always running (healthy child)',
        );
        final scaledDw = runDw(
          'stall-default-scaled',
          ['pages.yml', '--budget-seconds', '16000'], // 16000/8 = 2000s
          {
            'runs.json': runJson([run(556, 'Deploy to GitHub Pages', iso(-2))]),
            'view-556.txt': 'completed success\n',
          },
        );
        expect(scaledDw.exitCode, 0);
        expect(
          scaledDw.out,
          contains('queue-stall window 2000s'),
          reason:
              'long-budget legs wait out realistic sibling-leg occupancy '
              'before wedging a quiet-but-alive child',
        );
      },
    );

    test('a transient between-jobs pickup gap does not trip the guard', () {
      final dw = runDw(
        'queue-transient',
        [
          'build-mobile.yml',
          '--title',
          playTitle,
          '--budget-seconds',
          '60', // never fires: the whole watch is 4 polls x 3s
          '-f',
          'android_content=all',
        ],
        {
          'runs.json': runJson([run(111, playTitle, iso(-10))]),
          // Poll 1: between jobs (version done, build-ios not yet picked
          // up); poll 2: a job IS running; poll 3: between jobs again
          // (submit hand-off); poll 4: completed. The stall window is 5s
          // and the poll every 3s, so poll 3 only stays under the window
          // if poll 2's running job actually refreshed last_running
          // (3s old) — with a broken refresh the clock still reads poll 1
          // (6s old) and the guard false-wedges this healthy child.
          'jobs-111.txt': '0\n1\n0\n',
          'view-111.txt':
              'in_progress -\nin_progress -\nin_progress -\ncompleted success\n',
        },
        env: {'DW_POLL_SECONDS': '3', 'DW_QUEUE_STALL_SECONDS': '5'},
      );
      expect(dw.exitCode, 0);
      expect(
        dw.log.where((l) => l.startsWith('workflow run')).length,
        1,
        reason: 'a healthy inter-job gap must never cancel a child',
      );
      expect(
        dw.log.where((l) => l.contains('run cancel')),
        isEmpty,
        reason: 'a healthy child must never be cancelled',
      );
      // The stub served a RUNNING job on poll 2 — the fixture is live, so
      // the refresh above was genuinely exercised. (A `seq -f`-broken stub
      // serves {"jobs":[]} on every poll and this test passes vacuously.)
      expect(
        servedJobs(dw, 111),
        ['', '{"status":"in_progress"}', '', ''],
        reason:
            'poll 2 must actually report a running job — an inert fixture '
            'makes the whole guard test vacuous',
      );
      // One combined `gh run view` call per poll, not two.
      expect(
        dw.log.where((l) => l.contains('run view 111 ')).length,
        4,
        reason: 'one combined gh run view call per poll, not two',
      );
    });
  });

  // ── workflow structural lint ───────────────────────────────────────────
  group('workflows — correlation plumbing (#343) and wedge bounds (#344)', () {
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
        // #351: submit-ios must clear the fastlane submit_only lane's own
        // worst case — 90m wait_processing_timeout_duration
        // (TESTFLIGHT_WAIT_TIMEOUT_SECONDS default 5400s) + 15m
        // verify_external_distribution! (TESTFLIGHT_VERIFY_TIMEOUT_SECONDS
        // 900s) = 105m of pure lane time, plus setup/upload ≈ 15m. The
        // old 45m killed healthy slow submits mid-wait.
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
                'issue #344: a wedged self-hosted worker held the slot 5h; '
                '$jobId needs a job-level timeout so GitHub fails it server-side',
          );
          expect(
            t,
            expected,
            reason:
                '$jobId ceiling is part of the #351 budget arithmetic — '
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
                'on a wedged run (#344)',
          );
        }
      },
    );

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

    test('every watched leg passes a stall budget (#344)', () {
      for (final leg in ['testflight', 'play', 'cli', 'website', 'addin']) {
        expect(
          dispatchStepRun(leg),
          contains('--budget-seconds'),
          reason:
              'leg "$leg" must bound its watch so a wedged child run '
              'self-heals instead of eating the whole leg timeout (#344)',
        );
      }
    });

    // ── #351 — timeout arithmetic ──────────────────────────────────────────
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
    // comment in daily-publish.yml and the per-leg comments. budget =
    // worst-case + ≥15m margin (appear window 10m + cancel wait 3m +
    // poll slack); leg timeout > budget, and ≥ 2×budget + 15m whenever
    // that fits under GitHub's 360m job cap (so the second wedge's
    // fail-fast can fire inside the leg — testflight/cli cannot, and are
    // pinned at the 360m cap instead).
    const legArithmetic =
        <String, (String, Set<String>, Map<String, int>, int, int, int)>{
          // leg: (child workflow, skipped jobs, matrix-serialized jobs,
          //       child worst-case m, budget s, leg timeout m)
          'testflight': (
            '.github/workflows/build-mobile.yml',
            {'build-android', 'submit-android'},
            {},
            230,
            15000,
            360,
          ),
          'play': (
            '.github/workflows/build-mobile.yml',
            {'build-ios', 'submit-ios'},
            {},
            95,
            6600,
            240,
          ),
          'cli': (
            '.github/workflows/build-macos.yml',
            {},
            {'build-macos': 2},
            335,
            21000,
            360,
          ),
          'website': ('.github/workflows/pages.yml', {}, {}, 60, 4500, 180),
          'addin': (
            '.github/workflows/office-addin.yml',
            {},
            {},
            45,
            3600,
            150,
          ),
        };

    test(
      'every job in a watched child workflow carries an explicit timeout-minutes (#351)',
      () {
        // The worst-case sums above are only real if every ceiling is
        // explicit — a job without timeout-minutes silently inherits
        // GitHub's 360m default and breaks the arithmetic.
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
                  'watch-budget arithmetic needs an explicit per-job ceiling',
            );
          });
        }
      },
    );

    test(
      'watch budgets and leg timeouts clear the child worst-case (#351 arithmetic)',
      () {
        legArithmetic.forEach((leg, spec) {
          final (workflow, skip, serial, wcMinutes, budgetSeconds, legTimeout) =
              spec;
          final computed = childWorstCase(workflow, skip: skip, serial: serial);
          expect(
            computed,
            wcMinutes,
            reason:
                'leg "$leg": the documented child worst-case drifted — '
                'update the arithmetic table (daily-publish.yml comment AND '
                'this test) together',
          );
          expect(
            budgetSeconds >= 60 * (wcMinutes + 15),
            isTrue,
            reason:
                'leg "$leg": budget ${budgetSeconds}s must exceed the '
                'child worst-case $wcMinutes m by ≥15m margin — otherwise the '
                'watcher cancels legitimate slow children (#351)',
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
            legTimeout > budgetSeconds ~/ 60,
            isTrue,
            reason:
                'leg "$leg": the watcher (budget ${budgetSeconds ~/ 60}m '
                '+ cancel + re-dispatch) must always outlive the child',
          );
          // Second-wedge headroom, capped by GitHub's 360m job maximum.
          final needed = math.min(360, 2 * (budgetSeconds ~/ 60) + 15);
          expect(
            legTimeout >= needed,
            isTrue,
            reason:
                'leg "$leg": $legTimeout m cannot fit the second watch '
                'budget ($needed m) — a second wedge dies as a bare leg '
                'timeout instead of the #344 fail-fast',
          );
          // The workflow text pins the same number the table claims.
          final m = RegExp(
            r'--budget-seconds (\d+)',
          ).firstMatch(dispatchStepRun(leg));
          expect(m, isNotNull, reason: 'leg "$leg" passes no --budget-seconds');
          expect(
            int.parse(m!.group(1)!),
            budgetSeconds,
            reason:
                'leg "$leg": --budget-seconds drifted from the #351 '
                'arithmetic table',
          );
        });
      },
    );

    test(
      'build-mobile concurrency group is per-dispatch — no cross-run cancellation (#351)',
      () {
        // The watcher's wedge self-heal RE-DISPATCHES build-mobile.yml; with
        // the old ref-scoped cancel-in-progress group that re-dispatch (or
        // any concurrent manual dispatch) cancelled whatever build-mobile
        // run was in flight on main — a cross-leg cancellation vector.
        // Choice pinned here: the group is suffixed with run_id so every
        // dispatch is independent (supersede-cancellation #177 is traded
        // away; since #359 the play/testflight legs dispatch this workflow
        // CONCURRENTLY by design — correlation rests on the distinct
        // run-name (#343), not on serialization).
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
