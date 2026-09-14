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
        if [ -f "\$GH_STUB_DIR/cancelled-\$id" ]; then
          status=completed; conclusion=cancelled
        else
          f="\$GH_STUB_DIR/view-\$id.txt"
          line=\$(head -1 "\$f")
          sed -i.bak '1d' "\$f" && rm -f "\$f.bak"
          if ! [ -s "\$f" ]; then printf '%s\\n' "\$line" > "\$f"; fi
          status="\${line%% *}"; conclusion="\${line#* }"
        fi
        printf '{"status":"%s","conclusion":"%s"}' "\$status" "\$conclusion" | apply_jq
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
  DwRun(this.exitCode, this.out, this.log, this.runIdFile);

  final int exitCode;
  final String out;
  final List<String> log;
  final String? runIdFile; // content of --out-run-id, when requested
}

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
  );
}

String runJson(List<Map<String, Object>> runs) => jsonEncode(runs);

Map<String, Object> run(int id, String title, String createdAt) => {
  'databaseId': id,
  'createdAt': createdAt,
  'displayTitle': title,
};

const playTitle = 'build-mobile (app_only/none)';
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
          'android_content=app_only',
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
            'workflow run build-mobile.yml --repo OWNER/REPO --ref main -f android_content=app_only -f ios_content=none',
          ),
        ),
      );
    });

    test('prefers the NEWEST same-title match inside the window', () {
      final dw = runDw(
        'newest-match',
        [
          'build-mobile.yml',
          '--title',
          playTitle,
          '-f',
          'android_content=app_only',
        ],
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
        [
          'build-mobile.yml',
          '--title',
          playTitle,
          '-f',
          'android_content=app_only',
        ],
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
            'android_content=app_only',
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
            'android_content=app_only',
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
          'android_content=app_only',
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
          contains("--title 'build-mobile (app_only/none)'"),
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
            220,
            14400,
            360,
          ),
          'play': (
            '.github/workflows/build-mobile.yml',
            {'build-ios', 'submit-ios'},
            {},
            85,
            6000,
            240,
          ),
          'cli': (
            '.github/workflows/build-macos.yml',
            {},
            {'build-macos': 2},
            325,
            20400,
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
        // away; the daily legs serialize via `needs` instead).
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
