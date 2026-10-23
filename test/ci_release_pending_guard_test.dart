// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-1551: slim the 2h schedule tick. The schedule (cron `23 */2 * * *`)
/// is the release-arming mechanism (gh-1537 retired the post-merge main
/// run), but a tick with ZERO commits on main since the last v* tag runs
/// the full ~35-40 min quality gate for nothing (observed: run
/// 38147581679). A cheap `release-pending` pre-check compares main HEAD
/// against the latest v* tag and every gate leg ANDs its output into its
/// `if`, so an empty tick short-circuits the whole graph in seconds.
/// Deliberately text/YAML-level asserts (the repo's workflow-shape
/// never-again pattern, same as ci_main_push_retired_test.dart):
///  AC1  empty tick: `release-pending` exports pending=false, every
///       schedule-reachable gate job requires it and ANDs
///       `needs.release-pending.outputs.pending == 'true'` into its `if`
///       (explicit SKIPPED, visible in the run — never silently absent),
///  AC2  non-empty tick: the guard is a pure AND — pending=true falls
///       through to the exact gh-1537 graph (classifier + full gate +
///       tag cut),
///  AC3  tag pushes, `release: published` events and both dispatch arms
///       (releaseDryRun / releaseDispatch, incl. every SM validation
///       dispatch) stay untouched: the check only ever fetches on
///       schedule events and short-circuits to pending=true otherwise;
///       the tag/release-chain jobs keep ZERO reference to
///       release-pending,
///  AC4  fail-open: the check defaults to pending=true and only flips to
///       false inside the zero-commits branch — a flaky pre-check must
///       never silently suppress a release,
///  AC5  the ci.yml comment blocks document the contract: the schedule is
///       the release arming mechanism, empty ticks short-circuit.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

/// Same transitive-needs closure as ci_main_push_retired_test.dart:
/// quality-gate and everything it aggregates — the legs that run on a
/// schedule tick.
Set<String> _gateClosure(YamlMap jobs) {
  final closure = <String>{};
  void collect(String name) {
    // gh-1625: the pre-check jobs (release-pending, release-dedupe) hang
    // off the gate graph as GUARDS, not gate legs — the closure walk
    // excludes them (the AC1 loop below skips release-pending for the
    // same reason; release-dedupe never enters the set).
    if (_preCheckJobs.contains(name)) return;
    if (!closure.add(name)) return;
    final needs = (jobs[name] as YamlMap)['needs'];
    if (needs is String) {
      collect(needs);
    } else if (needs is YamlList) {
      for (final n in needs) {
        collect(n.toString());
      }
    }
  }

  collect('quality-gate');
  return closure;
}

/// The jobs that can execute on a `schedule` event and therefore must
/// carry the gh-1551 guard: the whole quality-gate closure (incl. the
/// `changes` classifier and `quality-gate` itself) plus the three
/// always()/ungated satellites that also run on schedule ticks
/// (step-timings is `if: always()`, js-ext-integration has no job-level
/// condition, release arms on the schedule).
Set<String> _guardedJobs(YamlMap jobs) => _gateClosure(jobs)
  ..addAll(['step-timings', 'release', 'js-ext-integration']);

/// gh-1625: the pre-check jobs are guards, not gate legs (see the closure
/// walk above).
const _preCheckJobs = {'release-pending', 'release-dedupe'};

List<String> _needsOf(YamlMap job) {
  final needs = job['needs'];
  if (needs is String) return [needs];
  if (needs is YamlList) return needs.map((n) => n.toString()).toList();
  return const [];
}

/// Legs whose `if` legitimately carries NO `needs.changes.outputs.*`
/// reference — the classifier itself (it *produces* those outputs), the
/// `always()` aggregates, the three-armed `release` job, and the
/// path-blind legs that run on every pending tick by design. Every other
/// guarded leg must keep its changes-keyed condition ANDed under the
/// guard: a future edit that *replaced* the path condition with the
/// guard (e.g. `if: needs.release-pending.outputs.pending == 'true'`)
/// would pass the plain presence pin while silently killing path
/// classification — the exact blind spot this never-again pin family
/// exists to close.
const pathBlindLegs = {
  'changes',
  'quality-gate',
  'step-timings',
  'release',
  'static',
  'test-core',
  'pty-visual',
  'coverage-gate',
  'guards',
  // gh-1788: step-level changes keying (the checkout/setup/pub-get/test
  // steps), job-if carries the gh-1551 guard only — same shape as `guards`.
  'model-switch-reg',
  'dep-audit',
  'supply-chain',
  'installer-verify',
  'install-pin-gate',
  'fa-aot-build',
  'pty-integration-linux',
  'pty-coverage-gate',
  'js-ext-integration',
};

void main() {
  final jobs = loadYaml(read('.github/workflows/ci.yml'))['jobs'] as YamlMap;

  group('AC1 — empty schedule tick short-circuits the whole gate', () {
    test('release-pending job exists with a pending output and the '
        'tag-vs-HEAD comparison', () {
      final job = jobs['release-pending'] as YamlMap?;
      expect(job, isNotNull, reason: 'gh-1551: the pre-check job must exist');
      expect(
        (job!['outputs'] as YamlMap)['pending'].toString(),
        r'${{ steps.check.outputs.pending }}',
      );
      final steps = job['steps'] as YamlList;
      final checkout = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) => s['uses']?.toString().startsWith('actions/checkout') ??
                false,
            orElse: () => throw TestFailure('release-pending must check out '
                'the repo (tag math needs the full tag graph)'),
          );
      // AC3 half: the fetch is schedule-only — tag/dispatch arms must not
      // even pay the checkout.
      expect(
        checkout['if'].toString(),
        "github.event_name == 'schedule'",
        reason: 'gh-1551 AC3: non-schedule events short-circuit in the '
            'script and never fetch',
      );
      final check = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) => s['id']?.toString() == 'check',
            orElse: () =>
                throw TestFailure('release-pending must have a check step'),
          );
      final script = check['run'].toString();
      expect(script, contains('git tag --sort=-v:refname'),
          reason: 'the latest v* tag drives the comparison');
      expect(script, contains('git rev-list'),
          reason: 'commits-since-tag = rev-list count (the cheap pre-check)');
    });

    test('every schedule-reachable gate job requires release-pending and '
        'ANDs the guard into its if', () {
      for (final id in _guardedJobs(jobs)) {
        if (id == 'release-pending') continue; // the pre-check guards itself
        final job = jobs[id] as YamlMap;
        expect(
          _needsOf(job),
          contains('release-pending'),
          reason: 'gh-1551: `$id` runs on schedule ticks — without the '
              'needs edge the guard expression reads an empty output and '
              'the leg would run on empty ticks anyway',
        );
        final ifText = job['if']?.toString() ?? '';
        expect(
          ifText,
          contains("needs.release-pending.outputs.pending == 'true'"),
          reason: 'gh-1551: `$id` must skip explicitly (visible SKIPPED) '
              'when the tick has nothing to release — an empty tick must '
              'not burn the full gate',
        );
        if (!pathBlindLegs.contains(id)) {
          expect(
            ifText,
            contains(RegExp(r"needs\.changes\.outputs\.[a-z0-9-]+")),
            reason: 'gh-1551: the guard must be ANDed ON TOP of `$id`\'s '
                'changes-keyed condition, not replace it — a replacement '
                'edit would pass the presence pin while silently killing '
                'path classification (every dispatch run pays the full '
                'gate)',
          );
        }
      }
      // quality-gate aggregates with `if: always()` — the guard must be
      // ANDed, not replace always(), or leg results would stop being
      // collected on real runs.
      final gateIf = (jobs['quality-gate'] as YamlMap)['if'].toString();
      expect(gateIf, startsWith('always()'),
          reason: 'gh-1551 AC2: the aggregate keeps collecting leg results '
              'on every real run');
    });
  });

  group('AC3 — tag/release events and both dispatch arms stay untouched', () {
    test('the check short-circuits to pending=true on every non-schedule '
        'event', () {
      final job = jobs['release-pending'] as YamlMap;
      final steps = job['steps'] as YamlList;
      final check = steps
          .map((s) => s as YamlMap)
          .firstWhere((s) => s['id']?.toString() == 'check');
      final script = check['run'].toString();
      expect(script, contains(r'[ "$EVENT_NAME" = "schedule" ]'),
          reason: 'gh-1551: only the schedule arm performs the comparison');
      expect(script, contains('else'),
          reason: 'the non-schedule arm must exist and short-circuit');
    });

    test('the tag/release chain and PR-only satellites carry ZERO '
        'release-pending references', () {
      // Release-flow legs key on v* tag pushes / release events and PR-
      // only satellites key on pull_request/dispatch — none of them can
      // execute on a schedule tick, so wiring the guard into them would
      // be dead code (and a silent behavior change on the arms gh-1551
      // promised to leave untouched).
      const untouched = [
        'integration',
        'publish',
        'binaries',
        'web-spa',
        'release-provenance',
        'install-pin-bump',
        'installer-smoke',
        'watchdog',
        'binaries-pr',
        'binaries-smoke-gate',
        'ci-red-report',
      ];
      for (final id in untouched) {
        final job = jobs[id] as YamlMap;
        expect(
          _needsOf(job),
          isNot(contains('release-pending')),
          reason: 'gh-1551 AC3: `$id` is never schedule-reachable — it '
              'must stay untouched',
        );
        expect(
          job['if']?.toString() ?? '',
          isNot(contains('release-pending')),
          reason: 'gh-1551 AC3: `$id` must stay untouched',
        );
      }
    });

    test('the release job keeps its three gh-1537 arming arms with the '
        'guard ANDed on top', () {
      final job = jobs['release'] as YamlMap;
      expect(_needsOf(job), contains('quality-gate'));
      expect(_needsOf(job), contains('release-pending'));
      final ifText = job['if'].toString();
      expect(ifText, contains("github.event_name == 'schedule'"));
      expect(ifText, contains('inputs.releaseDryRun'));
      expect(ifText, contains('inputs.releaseDispatch'));
      expect(ifText, contains("needs.release-pending.outputs.pending == 'true'"),
          reason: 'gh-1551 AC1: the empty tick skips the release '
              'explicitly (visible SKIPPED, not silently absent)');
    });
  });

  group('AC4 — the check is fail-open', () {
    test('pending defaults to true; false only inside the zero-commits '
        'branch', () {
      final job = jobs['release-pending'] as YamlMap;
      final steps = job['steps'] as YamlList;
      final check = steps
          .map((s) => s as YamlMap)
          .firstWhere((s) => s['id']?.toString() == 'check');
      final script = check['run'].toString();
      final trueDefault = RegExp(r'pending=true\s*(#.*)?$',
              multiLine: true)
          .allMatches(script)
          .length;
      expect(trueDefault, greaterThanOrEqualTo(1),
          reason: 'fail-open default: a check error must never silently '
              'suppress a release — the full gate decides');
      expect(script, contains('pending=false'),
          reason: 'the zero-commits branch must be able to skip the gate');
      // The false assignment must live INSIDE the schedule/zero-commits
      // arm: assert it appears after the schedule branch opens and there
      // is no unconditional assignment to false.
      final scheduleAt = script.indexOf(r'[ "$EVENT_NAME" = "schedule" ]');
      final falseAt = script.indexOf('pending=false');
      expect(scheduleAt, greaterThanOrEqualTo(0));
      expect(falseAt, greaterThan(scheduleAt),
          reason: 'gh-1551 AC4: pending=false may only be reached on the '
              'schedule arm');
      expect(script, isNot(contains('exit 1')),
          reason: 'gh-1551 AC4: the pre-check never reddens the run on a '
              'check error — fail-open with a warning instead');
    });
  });

  group('AC5 — the comment block documents the contract', () {
    test('the schedule comment names the release arming + empty-tick '
        'short-circuit', () {
      final ci = read('.github/workflows/ci.yml');
      final scheduleAt = ci.indexOf("cron: '23 */2 * * *'");
      expect(scheduleAt, greaterThanOrEqualTo(0));
      // The comment block immediately above the cron mentions gh-1551.
      // Clamp the window start: if a future edit ever shrinks the comment
      // block so the cron sits fewer than 1200 chars into the file, an
      // unclamped `scheduleAt - 1200` would throw a confusing RangeError
      // instead of the real failure ("the comment moved/shrank").
      final comment = ci.substring(math.max(0, scheduleAt - 1200), scheduleAt);
      expect(comment, contains('gh-1551'),
          reason: 'gh-1551 AC5: the schedule trigger comment must document '
              'that empty ticks short-circuit via release-pending');
      expect(
        ci.indexOf('release-pending'),
        greaterThanOrEqualTo(0),
        reason: 'the gate-graph overview must mention the new pre-check',
      );
    });
  });
}
