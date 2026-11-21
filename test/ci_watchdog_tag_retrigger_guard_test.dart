// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2290: the v1.0.745 release-gate run (4424840840) went red with zero
/// self-heal. A PTY shard's suite VM wedged on the vendored pty2 fork's
/// blocking-`waitpid` isolate (`Attempt:N waiting for isolate
/// _waitForExitCode to check in`, vendor/pty2/lib/src/pty_core.dart:19 —
/// the gh-2208/#2122 wedge class) under arm-pool load; `dart test` never
/// completed, the shard burned its whole 40-minute budget and GitHub
/// concluded the JOB `cancelled` (not `failure`), the quality-gate
/// aggregate failed on `platform_red`, and the ci-red-report leg filed
/// this ticket. The repo's designed remedy for exactly this class — the
/// watchdog ("a timed-out leg means a degraded runner allocation", issue
/// #194 point 4) — never ran: it is `pull_request`-only, and since gh-1537
/// retired main-push CI the v* tag push is the ONLY push arm the workflow
/// receives, i.e. the release gate has no watchdog at all. Even on PRs
/// the trip detector misses this kill mode: it scans
/// `select(.conclusion=="failure")` jobs only, but a job-level timeout
/// kill lands with job conclusion `cancelled` (verified on the two hung
/// shard jobs 134588877581 / 134566192421).
///
/// The fix gives the release path the same degraded-runner self-heal PRs
/// already have:
///  AC1  the watchdog runs on v* tag pushes too (same-repo PR arm kept
///       unchanged),
///  AC2  the trip decision is extracted to a repo script
///       (scripts/watchdog_trip_check.sh) that trips ONLY on the
///       timeout-kill signature — job conclusion `failure` OR `cancelled`
///       with at least one `cancelled` step (the mid-flight cut) and NO
///       `failed` step — or, the gh-2358 runner-death shape, at least one
///       UNCONCLUDED (`null`) step: the v1.0.759 tag run
///       (44868070949, job 136736814346) lost its self-hosted runner
///       `fa-m5-1` mid-`flutter build ios`; GitHub concluded the JOB
///       `failure` but froze the mid-flight step — and every trailing
///       step — at `conclusion: null` (nothing ever reported), so a
///       `cancelled`-step-only detector was blind to it and the release
///       train sat red until a manual full rerun. The trip guard stays
///       "NO `failed` step": a real test failure ends with a failed step
///       (runner death AFTER a real red freezes only the trailing
///       steps), and a fresh allocation cannot fix a defect — a skip, or a
///       clean/empty job; the script is network-free (jobs JSON in,
///       `trip=<bool>` out),
///  AC3  the trip step runs the repo script, which requires the file to
///       be present BEFORE the trip step — an unconditional pinned
///       checkout precedes it (the exit-127 lesson: runs
///       38696670029/38696668627 had the check run with no checkout),
///  AC4  the tag arm retriggers with a FRESH allocation by dispatching
///       ci.yml on the tag ref (`gh workflow run ci.yml --ref <tag>`;
///       GITHUB_TOKEN may trigger workflow_dispatch — 2022-09-08
///       changelog; release-pending never blocks dispatch arms and
///       release-dedupe is false for non-release events, so the dispatch
///       re-runs the full gate on the tag's exact tree), guarded to fire
///       ONCE per tag (a prior workflow_dispatch run for the tag ref
///       suppresses re-firing — the loop-guard rule),
///  AC5  the retrigger needs `actions: write` on the job,
///  RG   the regression guard: the trip decision is fixture-self-tested
///       by scripts/watchdog_trip_selftest.sh (PATH-stubbed, no network,
///       the release-dedupe #1100 pattern) and the static gate runs the
///       self-test so the script cannot rot silently before the next
///       red tag.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

List<YamlMap> _jobSteps(YamlMap jobs, String name) =>
    (((jobs[name] as YamlMap)['steps'] as YamlList).map(
      (s) => s as YamlMap,
    )).toList();

void main() {
  final ciText = read('.github/workflows/ci.yml');
  final ci = loadYaml(ciText) as YamlMap;
  final jobs = ci['jobs'] as YamlMap;
  final watchdog = jobs['watchdog'] as YamlMap?;

  group('AC1 — the watchdog covers the release path (v* tag pushes)', () {
    test('watchdog exists and its if runs on tag pushes', () {
      expect(
        watchdog,
        isNotNull,
        reason: 'gh-2290: the watchdog job must exist',
      );
      final condition = watchdog!['if'].toString();
      expect(
        condition,
        contains("github.event_name == 'pull_request'"),
        reason: 'the same-repo PR arm stays as-is (empty-commit retrigger)',
      );
      expect(
        condition,
        matches(RegExp(r"github\.event_name == 'push'")),
        reason:
            'gh-1537 retired main-push CI; v* tag pushes are the ONLY '
            'push arm left and they are the release gate — the watchdog '
            'must run there too',
      );
      expect(
        condition,
        contains('startsWith(github.ref'),
        reason:
            'the push arm must be scoped to v* tags only, never broad '
            'pushes',
      );
      expect(
        condition,
        contains('always()'),
        reason: 'the watchdog must evaluate even when legs fail',
      );
    });

    test('watchdog still waits for the long legs before scanning', () {
      // The watchdog must keep the longest legs in `needs` or it fires
      // before they settle and its one-shot retrigger lands early.
      final needs = watchdog!['needs'];
      final names = needs is YamlList
          ? needs.map((n) => n.toString()).toSet()
          : <String>{needs.toString()};
      expect(
        names,
        containsAll(<String>['pty-integration-linux', 'pty-visual']),
        reason:
            'the gh-2290 kill mode IS the pty leg — it must be in '
            'needs or the watchdog fires before it settles',
      );
    });
  });

  group('AC2 — the trip decision is a network-free repo script', () {
    test('scripts/watchdog_trip_check.sh exists and contracts trip=<bool>', () {
      final script = File('scripts/watchdog_trip_check.sh');
      expect(
        script.existsSync(),
        isTrue,
        reason:
            'the trip decision must live in a repo script so fixtures '
            'can exercise it (#1100 pattern)',
      );
      final text = script.readAsStringSync();
      expect(
        text,
        contains('trip='),
        reason: 'the output contract is exactly one trip=<bool> line',
      );
    });

    test('trips on the gh-2290 kill mode: cancelled job, cancelled step, '
        'trailing evidence steps', () {
      final out = _runScript(
        _jobsJson([
          _job('PTY/CLI integration (linux, shard 2/3)', 'cancelled', [
            _step(
              'dart test --tags integration (linux, shard 2/3)',
              'cancelled',
            ),
            _step('junit durations (shard 2)', 'skipped'),
            _step('Retry coverage upload (gh-1412)', 'skipped'),
            _step('Post Native-assets hook cache', 'skipped'),
          ]),
        ]),
      );
      expect(
        out.trip,
        isTrue,
        reason:
            'the REAL kill shape (hung shards 134588877581/'
            '134566192421): a job-level timeout kill lands as '
            'conclusion=cancelled with the mid-flight step cancelled and '
            'the if:always() evidence steps skipped — the watchdog MUST '
            'see it',
      );
    });

    test('trips on the classic kill mode: failed job, cut step, no failed '
        'step', () {
      final out = _runScript(
        _jobsJson([
          _job('Core tests (shard 3/4)', 'failure', [
            _step('dart test (core shard 3)', 'cancelled'),
          ]),
        ]),
      );
      expect(
        out.trip,
        isTrue,
        reason:
            "the original detector's shape: a job-level timeout the "
            'runner reports as failure with a cut mid-flight step and '
            'nothing genuinely failed',
      );
    });

    test('trips on the gh-2358 runner-death mode: failed job, UNCONCLUDED '
        '(null) mid-flight step', () {
      final out = _runScript(
        _jobsJson([
          _jobRaw('Build iOS (debug, unsigned)', 'failure', [
            '{"name": "Restore vendored WasmRun iOS framework", "conclusion": "success"}',
            '{"name": "flutter build ios (debug, unsigned)", "conclusion": null}',
            '{"name": "Post Run ./.github/actions/flutter-pub-get", "conclusion": null}',
            '{"name": "Post Cache CocoaPods (iOS)", "conclusion": null}',
          ]),
        ]),
      );
      expect(
        out.trip,
        isTrue,
        reason:
            'gh-2358 (v1.0.759 tag run 44868070949, job 136736814346): '
            'the self-hosted fa-m5-1 runner lost communication ~11 min '
            'into `flutter build ios (debug, unsigned)`; the jobs API '
            'froze that step — and every trailing step — at conclusion '
            '`null` while the JOB concluded `failure` (the check-run '
            'annotation: "The self-hosted runner lost communication '
            'with the server"). A mid-flight cut with no failed step is '
            'a degraded-runner kill whether GitHub concluded the cancel '
            '(`cancelled`) or nothing ever concluded (`null`) — the '
            'watchdog must dispatch the fresh-allocation retrigger',
      );
    });

    test('trips on the runner-death mode under the cancelled conclusion '
        'too', () {
      final out = _runScript(
        _jobsJson([
          _jobRaw('Build iOS (debug, unsigned)', 'cancelled', [
            '{"name": "flutter build ios (debug, unsigned)", "conclusion": null}',
            '{"name": "Post Cache CocoaPods (iOS)", "conclusion": null}',
          ]),
        ]),
      );
      expect(
        out.trip,
        isTrue,
        reason:
            'a run-level cancel racing the lost heartbeat can land the '
            'same frozen-steps shape under job conclusion `cancelled` — '
            'still a mid-flight cut, still no failed step',
      );
    });

    test('does NOT trip when the runner died after a REAL test failure '
        '(failed step + frozen trailing nulls)', () {
      final out = _runScript(
        _jobsJson([
          _jobRaw('Core tests (shard 1/4)', 'failure', [
            '{"name": "dart test (core shard 1)", "conclusion": "failure"}',
            '{"name": "junit durations (shard 1)", "conclusion": null}',
            '{"name": "Post Native-assets hook cache", "conclusion": null}',
          ]),
        ]),
      );
      expect(
        out.trip,
        isFalse,
        reason:
            'the red dart test step FAILED before the box vanished; the '
            'frozen `null` tail is the always() evidence steps that '
            'never reported — a fresh runner allocation cannot fix a '
            'genuine red, so the no-failed-step guard must dominate',
      );
    });

    test('does NOT trip on a real test failure (a step FAILED)', () {
      final out = _runScript(
        _jobsJson([
          _job('Core tests (shard 0/4)', 'failure', [
            _step('dart test (core shard 0)', 'failure'),
            _step('junit durations (shard 0)', 'success'),
          ]),
        ]),
      );
      expect(
        out.trip,
        isFalse,
        reason:
            'a genuine red must never be retrigged — a fresh runner '
            'allocation cannot fix a product/test defect. In these '
            'shards the red dart test step FAILED and the if:always() '
            'evidence steps trail with success, so the LAST step is '
            'success — the failed step, not the last step, is the '
            'signal',
      );
    });

    test('does NOT trip on success, skipped, or empty jobs', () {
      final out = _runScript(
        _jobsJson([
          _job('Static gates', 'success', [_step('analyze', 'success')]),
          _job('Golden suite (macOS baselines)', 'skipped', null),
          _job('Binaries smoke gate', 'cancelled', null),
        ]),
      );
      expect(
        out.trip,
        isFalse,
        reason:
            'green/skipped legs and cancelled jobs without a '
            'cancelled step (run-level cancels of never-started jobs) '
            'are not degraded-runner timeouts',
      );
    });

    test('does NOT trip when there is nothing red', () {
      final out = _runScript('{"jobs": []}');
      expect(out.trip, isFalse);
    });
  });

  group('AC3 — the trip step runs the repo script (file present first)', () {
    test('an unconditional pinned checkout precedes the trip step', () {
      final steps = _jobSteps(jobs, 'watchdog');
      final checkoutIndex = steps.indexWhere(
        (s) => (s['uses']?.toString() ?? '').startsWith('actions/checkout'),
      );
      final tripIndex = steps.indexWhere(
        (s) => (s['run']?.toString() ?? '').contains(
          'scripts/watchdog_trip_check',
        ),
      );
      expect(
        tripIndex,
        greaterThanOrEqualTo(0),
        reason: 'the trip step must invoke the repo script',
      );
      expect(
        checkoutIndex,
        greaterThanOrEqualTo(0),
        reason:
            'a hosted runner workspace has no scripts/ — the exit-127 '
            'class (runs 38696670029/38696668627)',
      );
      expect(
        checkoutIndex,
        lessThan(tripIndex),
        reason:
            'the script must be checked out BEFORE the trip step runs '
            'it',
      );
      final checkout = steps[checkoutIndex];
      expect(
        checkout.containsKey('if'),
        isFalse,
        reason:
            'the checkout must be UNCONDITIONAL — every arm that can '
            'run the trip step needs the file (a skipped pre-check would '
            'empty the trip output)',
      );
    });

    test('the trip step invokes watchdog_trip_check.sh EXACTLY once '
        '(one trip= line in GITHUB_OUTPUT)', () {
      final steps = _jobSteps(jobs, 'watchdog');
      final tripStep = steps
          .where(
            (s) => (s['run']?.toString() ?? '').contains(
              'scripts/watchdog_trip_check',
            ),
          )
          .single;
      final run = tripStep['run'].toString();
      final invocations = RegExp(
        r'bash scripts/watchdog_trip_check\.sh',
      ).allMatches(run).length;
      expect(
        invocations,
        1,
        reason:
            'each invocation appends one trip=<bool> line to '
            'GITHUB_OUTPUT (the RG3 contract in '
            'scripts/watchdog_trip_selftest.sh) — a duplicated '
            'invocation lands TWO trip= lines in one output file and '
            'doubles the ::notice:: diagnostics in every watchdog log '
            '(review PRRT_kwDOTXdlLc644EjI). The script is pure — same '
            'input file, no network, no state — so a second run cannot '
            'change the verdict; there is no retry semantics to preserve',
      );
    });
  });

  group('AC4 — the tag arm retriggers once via a dispatch on the tag', () {
    test('a tag retrigger step dispatches ci.yml on the tag ref', () {
      final steps = _jobSteps(jobs, 'watchdog');
      final tagStep = steps
          .where(
            (s) => (s['run']?.toString() ?? '').contains('gh workflow run'),
          )
          .toList();
      expect(
        tagStep,
        hasLength(1),
        reason:
            'gh-2290: the tag arm needs its own retrigger — tags '
            'cannot take an empty-commit push (moving a v* tag would '
            're-trigger the release flow)',
      );
      final run = tagStep.single['run'].toString();
      expect(
        run,
        contains('gh workflow run ci.yml'),
        reason: 'the dispatch must re-run THIS workflow',
      );
    });

    test('the tag retrigger is one-shot per tag (loop guard)', () {
      final steps = _jobSteps(jobs, 'watchdog');
      final tagStep = steps
          .where(
            (s) => (s['run']?.toString() ?? '').contains('gh workflow run'),
          )
          .single;
      final run = tagStep['run'].toString();
      expect(
        run,
        contains('--event workflow_dispatch'),
        reason:
            'the one-shot guard looks for a PRIOR dispatch run on the '
            'tag ref — without it a stuck-pool day re-fires a dispatch '
            'chain (the watchdog doctrine: ONE retrigger max)',
      );
    });

    test('the PR arm keeps its empty-commit retrigger', () {
      final stepsText = ciText;
      expect(
        stepsText,
        contains('ci: watchdog retrigger (degraded runner pool)'),
        reason: 'the PR-arm remedy is unchanged',
      );
    });
  });

  group('AC5 — permissions', () {
    test('watchdog may dispatch workflows', () {
      final perms = watchdog!['permissions'] as YamlMap;
      expect(
        perms['actions'].toString(),
        contains('write'),
        reason: 'gh workflow run needs actions:write on the job',
      );
    });
  });

  group('RG — the self-test is wired into the static gate', () {
    test('static gates run scripts/watchdog_trip_selftest.sh', () {
      final staticSteps = _jobSteps(jobs, 'static');
      final selftest = staticSteps
          .where(
            (s) => (s['run']?.toString() ?? '').contains(
              'bash scripts/watchdog_trip_selftest.sh',
            ),
          )
          .toList();
      expect(
        selftest,
        hasLength(1),
        reason:
            'the trip decision must be fixture-self-tested in the '
            'static gate (#1100 pattern) so it cannot rot silently '
            'before the next red tag',
      );
    });

    test('the self-test script exists and covers the kill modes', () {
      final text = read('scripts/watchdog_trip_selftest.sh');
      expect(
        text,
        contains('watchdog_trip_check.sh'),
        reason: 'the self-test exercises the real script',
      );
    });
  });
}

// ── fixture plumbing for the behavioral RG asserts ──────────────────

class _TripResult {
  _TripResult(this.trip, this.output);
  final bool trip;
  final String output;
}

_TripResult _runScript(String jobsJson) {
  final tmp = Directory.systemTemp.createTempSync('watchdog_trip_test_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final file = File('${tmp.path}/jobs.json')..writeAsStringSync(jobsJson);
  final result = Process.runSync('bash', [
    'scripts/watchdog_trip_check.sh',
    file.path,
  ]);
  if (result.exitCode != 0) {
    fail(
      'watchdog_trip_check.sh exited ${result.exitCode}:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  final stdout = result.stdout.toString();
  final match = RegExp(
    r'^trip=(true|false)$',
    multiLine: true,
  ).firstMatch(stdout);
  expect(
    match,
    isNotNull,
    reason:
        'the script must print exactly one trip=<bool> line, '
        'got:\n$stdout',
  );
  return _TripResult(match!.group(1) == 'true', stdout);
}

String _jobsJson(List<String> jobJson) => '{"jobs": [${jobJson.join(",")}]}';

String _job(String name, String conclusion, List<String>? steps) {
  final stepsJson = steps == null
      ? '[]'
      : '[${steps.map((s) => s.split('|')).map((p) => '{"name":'
            '"${p.first}", "conclusion": "${p.last}"}').join(',')}]';
  return '{"name": "$name", "conclusion": "$conclusion", '
      '"steps": $stepsJson}';
}

String _step(String name, String conclusion) => '$name|$conclusion';

/// Like [_job] but the steps are given as raw JSON objects, so a frozen
/// (unconcluded) step can be expressed as `"conclusion": null` — the
/// gh-2358 runner-death shape the `name|conclusion` helper cannot emit.
String _jobRaw(String name, String conclusion, List<String> stepJson) =>
    '{"name": "$name", "conclusion": "$conclusion", '
    '"steps": [${stepJson.join(",")}]}';
