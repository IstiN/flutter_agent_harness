// Copyright (c) 2026, the Flutter Agent Harness authors. Use of this source
// code is governed by a MIT license that can be found in the LICENSE file.

/// gh-2399 rework — the `static` budget clears the leg's measured wall.
///
/// CI run 45409735279 (PR ai/gh-2399, commit e3b6099a) red'd the PR:
/// `Static gates` was killed by its own job-level `timeout-minutes: 8` at
/// 8m02s — the kill landed during the POST steps, with every completed step
/// GREEN (AGENTS guard, root allow-list, web-spa self-test, GEO build,
/// lockfiles, all seven self-tests, full `dart analyze`, publish dry-run
/// with the stamp rehearsal — all success). The Quality gate followed
/// ("Quality gate FAILED: a leg is cancelled (static)"), the exact
/// gh-2389 kill shape for `app-crap-gate`.
///
/// The budget sat at ~1.4x the healthy wall with the margin inside
/// checkout: the healthy base run (45398653579, commit 8fe6cb5f3) finished
/// in 5m47s, but this run's `fetch-depth: 0` blobless checkout alone took
/// 5m26s — the PR run fans out ~60 jobs at once, so the shared hosted
/// runner's clone throughput swings by minutes. A budget that a slow
/// checkout reds with zero product/test failures is the identical class
/// gh-1778 fixed for `test-core` and gh-2389 fixed for `app-crap-gate`
/// (red tag/PR runs are triaged and fixed structurally — never
/// quarantined as flakes, AGENTS.md gh-1537 note).
///
/// Deliberately YAML-level asserts (the ci_app_crap_gate_timeout_guard_test
/// static pattern):
///  AC1  `static` declares `timeout-minutes` >= 15 — ~2.6x the healthy
///       wall (5m47s) and clears the observed 8m02s kill mode (slow
///       checkout under fan-out) with margin; a real hang is still killed
///       loudly, just not mid-green-run.
///  AC2  the timeout stays DECLARED — removing it would leave a hung leg
///       on GitHub's 360-minute default, burning the runner pool for hours.
///  AC3  `static` keeps its data dependencies (`release-pending`,
///       `release-dedupe`, `changes`) — the budget change must not
///       disturb the wiring (the gh-1551 skip path and the classifier
///       feed this leg).
///  AC4  the watchdog keeps `static` in `needs` — the degraded-runner
///       retrigger must never settle before the leg (the gh-2389
///       invariant; this fix narrows nothing).
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';

/// The healthy wall measured on the base run 45398653579 (commit
/// 8fe6cb5f3): 5m47s total, success. The rework run 45409735279 died at
/// 8m02s — 5m26s of it checkout.
const healthyWallMinutes = 5.8;

/// The new job budget — ~2.6x the healthy wall (the gh-1778 watchdog
/// doctrine band: app-crap-gate 12 for a 5.5-min wall, test-core 20+ for
/// its wall); clears the observed 8m02s kill with margin.
const minJobTimeoutMinutes = 15;

YamlMap job(String jobId) {
  final root = loadYaml(read(ci)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[jobId];
  if (job is! YamlMap) throw StateError('job $jobId missing from $ci');
  return job;
}

Set<String> needsOf(YamlMap job) {
  final needs = job['needs'];
  return needs is YamlList
      ? needs.map((n) => n.toString()).toSet()
      : <String>{needs.toString()};
}

void main() {
  final static_ = job('static');
  final watchdog = job('watchdog');

  group('AC1/AC2 — the static budget clears the measured wall', () {
    test(
      'AC1: timeout-minutes >= 15 (healthy wall ~5.8 min, gh-1778 band)',
      () {
        final v = static_['timeout-minutes'];
        final timeout = v is int ? v : int.tryParse(v.toString());
        expect(
          timeout,
          isNotNull,
          reason: 'the job must keep an explicit timeout — see AC2',
        );
        expect(
          timeout,
          greaterThanOrEqualTo(minJobTimeoutMinutes),
          reason:
              'run 45409735279: the leg was killed by its own '
              'timeout-minutes: 8 at 8m02s with every completed step GREEN '
              '— the fetch-depth:0 blobless checkout alone took 5m26s of '
              'the budget (the PR run fans out ~60 jobs at once, clone '
              'throughput swings by minutes); the healthy base run '
              '45398653579 finished in 5m47s. 15 min clears the observed '
              'kill mode with margin and stays in the gh-1778 doctrine '
              'band (app-crap-gate: 12 for a 5.5-min wall)',
        );
      },
    );

    test('AC2: the timeout is still declared (no 360-minute default)', () {
      expect(
        static_.containsKey('timeout-minutes'),
        isTrue,
        reason:
            'removing the budget entirely would let a hung leg burn '
            "GitHub's default 360 minutes before any remedy fires",
      );
    });
  });

  group('AC3/AC4 — the wiring is untouched', () {
    test('AC3: static keeps its data dependencies', () {
      expect(
        needsOf(static_),
        containsAll(<String>['release-pending', 'release-dedupe', 'changes']),
        reason:
            'the gh-1551 release pre-checks decide the skip path and the '
            'classifier scopes the full-analyze/publish-dry-run steps — '
            'the budget fix must not disturb the wiring',
      );
    });

    test('AC4: watchdog.needs still contains static', () {
      expect(
        needsOf(watchdog),
        contains('static'),
        reason:
            'the degraded-runner one-shot retrigger must never settle '
            'before the leg — the gh-2389 invariant ("they must all be '
            'in `needs` or the watchdog fires before they settle"); the '
            'budget change narrows nothing',
      );
    });
  });
}
