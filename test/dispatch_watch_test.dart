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
// Structural lint over the workflow YAML plus behavioral tests of
// scripts/dispatch_and_watch.sh against a stubbed `gh` (same style as
// release_hygiene_test.dart). The stub pipes fixtures through the REAL jq
// expression the script passes to `gh run list`, so the correlation logic
// itself (title filter, window, newest-match) is under test.
import 'dart:convert';
import 'dart:io';

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
        for (final jobId in ['build-ios', 'submit-ios']) {
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
          expect(t, lessThanOrEqualTo(120));
          expect(t, greaterThanOrEqualTo(30));
        }
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
              'self-heals instead of eating the 300m leg timeout (#344)',
        );
      }
    });

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
