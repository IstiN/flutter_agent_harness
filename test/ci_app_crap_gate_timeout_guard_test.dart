// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2389 — the `app-crap-gate` budget clears the leg's measured wall, and
/// the watchdog scan settles AFTER the leg.
///
/// CI run 45302423375 (tag v1.0.768) red'd the release: `Flutter app CRAP
/// ratchet` (job 138144350678) was killed by its own job-level
/// `timeout-minutes: 6` mid-`crap4dart check`, with every completed step
/// GREEN (config guards, ratchet analyze, artifact upload — all success).
/// The Quality gate followed ("Quality gate FAILED: a leg is cancelled
/// (app-crap-gate)"), the release train stopped, and the downstream
/// `Advance vpinned marker` red'd on the by-design provenance gate
/// (`E_PIN_PROVENANCE_MISSING` — no SHA256SUMS on an unpublishable tag).
///
/// The budget was sized below the leg's real wall. The healthy v1.0.767 tag
/// run (45264822393, job 138018358954) finished in 5m31s — checkout
/// (`fetch-depth: 0`, blobless) alone took 3m53s, the final
/// `dart pub global run crap4dart check` step another 1m16s — leaving 29 s
/// of margin. On v1.0.768 the same checkout took 4m30s (+37 s of ordinary
/// runner variance) and the job died at the 6-minute wall. A budget at ~1.1×
/// the healthy wall means ANY slow checkout reds the whole release with zero
/// product/test failures — the identical class gh-1778 fixed for `test-core`
/// (12 → ≥20 min after a degraded-cache kill). Red tag runs are release-flow
/// failures, triaged and fixed structurally — never quarantined as flakes
/// (AGENTS.md, gh-1537 note).
///
/// The designed remedy for a degraded-runner kill — the watchdog (issue #194
/// point 4, gh-2290 tag arm) — never fired either: its one-shot trip scan
/// completed at 01:26:38Z, 18 s BEFORE the kill landed (01:26:56Z), because
/// `watchdog.needs` omits `app-crap-gate` and the watchdog settled as soon
/// as `coverage-gate` (01:26:14Z) finished. Its own comment states the
/// invariant: "They must be in `needs` or the watchdog fires before they
/// settle — a degraded-runner timeout there would land after the scan and
/// never get its one-shot retrigger." gh-2389 is that sentence, observed.
///
/// Deliberately YAML-level asserts (the ci_core_shard_timeout_guard_test.dart
/// static pattern):
///  AC1  `app-crap-gate` declares `timeout-minutes` >= 12 — headroom over
///       the measured healthy wall (5m31s) plus checkout-variance growth;
///       in line with the sibling 5-min `test-faui` shards (12). A real
///       hang is still killed loudly, just not mid-green-run.
///  AC2  the timeout stays DECLARED — removing it would leave a hung leg on
///       GitHub's 360-minute default, burning the runner pool for hours
///       before the watchdog could react.
///  AC3  `watchdog.needs` contains `app-crap-gate` — the scan must not
///       settle before this leg, or the one-shot retrigger races ahead of
///       the kill exactly as it did on v1.0.768.
///  AC4  the watchdog keeps the gh-2290 legs (`pty-integration-linux`,
///       `pty-visual`) in `needs` — this fix narrows nothing.
///  AC5  `app-crap-gate` keeps its data dependencies
///       (`release-pending`, `release-dedupe`, `changes`, `flutter-tests`)
///       — the merged shard coverage comes from the `flutter-tests` shards
///       and the merge step asserts exactly 2 reports; the budget change
///       must not disturb the leg's wiring.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';

/// The healthy wall measured on tag v1.0.767 (run 45264822393, job
/// 138018358954): 5m31s total, 3m53s of it checkout.
const healthyWallMinutes = 5.5;

/// The new job budget — ~2x the healthy wall (the watchdog doctrine for
/// `timeout-minutes`), aligned with the sibling `test-faui` shards (12);
/// clears the v1.0.768 growth (+37 s checkout variance) with margin.
const minJobTimeoutMinutes = 12;

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
  final crapGate = job('app-crap-gate');
  final watchdog = job('watchdog');

  group('AC1/AC2 — the app-crap-gate budget clears the measured wall', () {
    test(
      'AC1: timeout-minutes >= 12 (healthy wall ~5.5 min, gh-1778 band)',
      () {
        final v = crapGate['timeout-minutes'];
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
              'v1.0.768 (run 45302423375): the leg was killed by its own '
              'timeout-minutes: 6 at 6m15s with every completed step GREEN '
              '— checkout alone took 4m30s of the 6-minute budget; the '
              'healthy v1.0.767 run finished in 5m31s, 29 s under the old '
              'wall. 12 min ≈ 2x the healthy wall (watchdog doctrine) and '
              'matches the sibling test-faui shards',
        );
      },
    );

    test('AC2: the timeout is still declared (no 360-minute default)', () {
      expect(
        crapGate.containsKey('timeout-minutes'),
        isTrue,
        reason:
            'removing the budget entirely would let a hung leg burn '
            "GitHub's default 360 minutes before any remedy fires",
      );
    });
  });

  group('AC3/AC4 — the watchdog scan settles after the leg', () {
    test('AC3: watchdog.needs contains app-crap-gate', () {
      final names = needsOf(watchdog);
      expect(
        names,
        contains('app-crap-gate'),
        reason:
            'gh-2389 (run 45302423375): the watchdog one-shot scan '
            'completed at 01:26:38Z — 18 s BEFORE the app-crap-gate '
            'timeout kill landed (01:26:56Z) — because the leg was not '
            'in `needs`; trip=false, no fresh-allocation retrigger, no '
            'self-heal. The leg must be in `needs` or the watchdog '
            'fires before it settles (the invariant its own comment '
            'states)',
      );
    });

    test('AC4: the gh-2290 long legs stay in watchdog.needs', () {
      final names = needsOf(watchdog);
      expect(
        names,
        containsAll(<String>['pty-integration-linux', 'pty-visual']),
        reason: 'the gh-2290 kill mode IS the pty leg — never narrow it',
      );
    });
  });

  group('AC5 — the leg wiring is untouched', () {
    test('AC5: app-crap-gate keeps its data dependencies', () {
      expect(
        needsOf(crapGate),
        containsAll(<String>[
          'release-pending',
          'release-dedupe',
          'changes',
          'flutter-tests',
        ]),
        reason:
            'the merged shard coverage comes from the flutter-tests '
            'shards (the merge step asserts exactly 2 reports) and the '
            'release pre-checks decide the skip path — the budget fix '
            'must not disturb the wiring',
      );
    });
  });
}
