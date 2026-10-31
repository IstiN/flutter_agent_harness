// CI rework (PR #1909 leg, gh-1842 red head 591b539a) — the Office add-in
// e2e "playwright install" bounded retry could never recover from its own
// timeout kill.
//
// Observed on the red head (run 40347596895, Office add-in suite):
//  - attempt 1 starved on the apt mirror and hit `timeout 600` (15:23:06 →
//    15:33:06);
//  - the timeout kills the npx WRAPPER, but its `sudo apt-get` child
//    survived it (pid 4135) still holding /var/lib/dpkg/lock-frontend —
//    the log shows it downloading on through 15:34+;
//  - attempts 2 and 3 therefore died in ~16s each on
//    "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by
//    process 4135 (apt-get)" — never re-attempting the install;
//  - the loop declared "playwright install failed after 3 attempts" and
//    the required Quality gate reddened via the platform-leg cascade
//    (#1368) — a transient apt starvation became a hard merge blocker.
//
// A bounded-retry loop that cannot succeed on its MOST LIKELY failure
// path (the timeout kill it was built for, cf. the 2026-10-23 40m stall
// comment in the step) is a config bug, not infra. This guard pins the
// recovery in BOTH copies of the step (ci.yml PR gate + office-addin.yml
// daily dispatch leg — the ci_1659 drift guard already forces parity, so
// this file pins the SHAPE independently of it):
//  AC1  inside the retry loop, before each new attempt, wait (bounded)
//       for a stale apt-get orphaned by the killed attempt to release the
//       dpkg lock — the orphan is doing the same install we want, so
//       waiting is strictly better than failing;
//  AC2  if the stale holder is still alive after the bounded wait, stop
//       it before retrying;
//  AC3  clear half-configured dpkg state (`dpkg --configure -a`) before
//       the retry — a killed apt can leave packages mid-configure, which
//       fails the next --with-deps apt run even with a free lock;
//  AC4  the recovery is INSIDE the `for attempt` loop and sits BEFORE the
//       `timeout 600` invocation — recovery outside the loop never runs
//       before the second attempt;
//  AC5  the two workflow copies keep byte-identical e2e run bodies
//       (local drift pin; the suite-wide parity lives in
//       ci_1659_office_addin_matrix_test.dart).
//
// Deliberately YAML-level asserts (the ci_pub_get_retry_guard_test.dart
// static pattern): the suite itself is exercised by CI on GitHub runners,
// not locally.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const addin = '.github/workflows/office-addin.yml';

/// The e2e run body of the "Playwright e2e (chromium + webkit)" step in
/// [workflowPath] (must contain the bounded-retry install + the test run).
String e2eRunBody(String workflowPath) {
  final root = loadYaml(read(workflowPath)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  for (final job in jobs.values) {
    final steps = (job as YamlMap)['steps'];
    if (steps is! YamlList) continue;
    for (final step in steps.whereType<YamlMap>()) {
      final run = step['run'];
      if (run is String &&
          run.contains('npx playwright install --with-deps') &&
          run.contains('npx playwright test')) {
        return run;
      }
    }
  }
  fail('$workflowPath: the Playwright e2e step was not found');
}

void main() {
  group('office-addin e2e — the install retry survives its timeout kill', () {
    for (final workflow in [ci, addin]) {
      group(workflow, () {
        final body = e2eRunBody(workflow);

        test('AC1: each retry waits, bounded, for the stale dpkg lock', () {
          expect(
            body,
            contains('pgrep -x apt-get'),
            reason:
                'a `timeout` kill takes the npx wrapper but orphans its '
                'apt-get child, which keeps /var/lib/dpkg/lock-frontend '
                '(2026-10-26: attempts 2 and 3 died in ~16s on "Could not '
                'get lock", so the retry could never recover). The loop '
                'must wait for the stale holder before retrying.',
          );
          // Bounded: a wait with no ceiling can hold the 45m job budget
          // hostage on a wedged holder.
          expect(
            body,
            contains(RegExp(r'seq \d+ \d+')),
            reason:
                'the lock wait must be bounded (a counted loop), '
                'not an unbounded poll',
          );
          expect(body, contains('sleep 5'));
        });

        test('AC2: a holder stuck past the bounded wait is stopped', () {
          expect(
            body,
            contains('pkill -x apt-get'),
            reason:
                'if the orphaned apt-get is wedged (dead connection '
                'holding the lock), the bounded wait alone would exhaust '
                'and retry against a still-held lock — kill it as the '
                'last resort before the retry',
          );
        });

        test(
          'AC3: half-configured dpkg state is repaired before the retry',
          () {
            expect(
              body,
              contains('dpkg --configure -a'),
              reason:
                  'a killed apt can leave packages mid-configure; the next '
                  '--with-deps apt run fails on that even with a free lock',
            );
          },
        );

        test('AC4: the recovery sits INSIDE the loop, before the timeout', () {
          final loopAt = body.indexOf('for attempt in 1 2 3');
          final recoveryAt = body.indexOf('pgrep -x apt-get');
          final timeoutAt = body.indexOf('timeout 600 npx playwright install');
          expect(loopAt, greaterThan(-1));
          expect(
            recoveryAt,
            greaterThan(loopAt),
            reason: 'recovery must run per attempt, inside the loop',
          );
          expect(
            recoveryAt,
            lessThan(timeoutAt),
            reason:
                'recovery must run BEFORE the next install attempt — '
                'recovery after the final attempt never helps a retry',
          );
        });
      });
    }

    test('AC5: the two workflow copies keep identical e2e run bodies', () {
      expect(
        e2eRunBody(ci),
        e2eRunBody(addin),
        reason:
            'the PR gate (ci.yml) and the daily leg (office-addin.yml) '
            'must run the identical e2e pipeline — fix both copies '
            'together (the ci_1659 drift guard pins the whole step list; '
            'this pins the run body the retry fix touched)',
      );
    });
  });
}
