// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-1625: ci.yml double-fires the full quality gate on release tags —
/// the v* tag push fires the gate by design (the release pipeline keys on
/// the tag; the gate runs BEFORE anything publishes, gh-1537/gh-1172), and
/// the `release: published` event for the SAME tag fires a second,
/// identical gate (observed on v1.0.580: push run 38687023638 in_progress
/// + release run 38687023803 pending behind it on the shared `ci-<ref>`
/// concurrency group — doubled release wall time).
///
/// The fix mirrors gh-1551's `release-pending` pre-check: a `release-dedupe`
/// job decides whether the tag's own push run already gates it
/// (`gh run list --branch <tag> --event push`, any status, recent window);
/// dedupe=true short-circuits EVERY quality leg of the release twin to the
/// binaries-attach leg only. Deliberately text/YAML-level asserts (the
/// repo's workflow-shape never-again pattern, same as
/// ci_release_pending_guard_test.dart):
///  AC1  annotated tag push → release published: exactly ONE full-gate
///       run (the push twin); the release twin skips every quality leg and
///       executes only the binaries-attach leg (web-spa/publish stay keyed
///       on the quality-gate result and skip with it),
///  AC2  release published on an old tag (no fresh push run within the
///       window) → dedupe=false → the full gate still runs (safety net),
///  AC3  push/dispatch/schedule behavior unchanged: the check
///       short-circuits in the script on non-release events (no API call)
///       and dedupes nothing — the gate graph for those arms is
///       byte-equivalent to gh-1551's,
///  AC4  the binaries-attach leg stays reachable under dedupe=true via an
///       explicit release-arm clause, and the idempotent `--clobber`
///       last-wins upload is preserved,
///  AC5  the dedupe check fails safe: dedupe defaults false and is only
///       flipped inside a successful release-arm lookup — an `gh run list`
///       error warns and degrades to the full gate,
///  RG   the regression guard: the decision logic is extracted to
///       scripts/release_dedupe_check.sh and fixture-self-tested by
///       scripts/release_dedupe_selftest.sh (aab-gate-selftest pattern),
///       wired into the static gate.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const dedupeClause = "needs.release-dedupe.outputs.dedupe != 'true'";
const pendingClause = "needs.release-pending.outputs.pending == 'true'";

/// Jobs that hang off the gate graph as PRE-CHECKS (guards), not gate
/// legs: the closure walk excludes them, like the AC1 loop below skips
/// release-pending itself.
const preCheckJobs = {'release-pending', 'release-dedupe'};

Set<String> _gateClosure(YamlMap jobs) {
  final closure = <String>{};
  void collect(String name) {
    if (preCheckJobs.contains(name)) return;
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

/// Every job that can execute on a tag/schedule/release arm and therefore
/// must carry BOTH guards: the quality-gate closure plus the satellites
/// that key on `release-pending` but hang outside the aggregate's needs
/// (step-timings is `if: always()`, js-ext-integration and faui-coverage
/// are ungated legs of the same graph).
Set<String> _guardedJobs(YamlMap jobs) =>
    _gateClosure(jobs)
      ..addAll(['step-timings', 'js-ext-integration', 'faui-coverage']);

List<String> _needsOf(YamlMap job) {
  final needs = job['needs'];
  if (needs is String) return [needs];
  if (needs is YamlList) return needs.map((n) => n.toString()).toList();
  return const [];
}

void main() {
  final ciText = read('.github/workflows/ci.yml');
  final ci = loadYaml(ciText) as YamlMap;
  final jobs = ci['jobs'] as YamlMap;

  group('AC1 — the release twin short-circuits the whole gate', () {
    test('the release-dedupe pre-check job exists and mirrors '
        'release-pending', () {
      final job = jobs['release-dedupe'] as YamlMap?;
      expect(job, isNotNull, reason: 'gh-1625: the pre-check job must exist');
      expect(
        (job!['outputs'] as YamlMap)['dedupe'].toString(),
        r'${{ steps.check.outputs.dedupe }}',
      );
      // The check is a pure API pre-check — no checkout, no fetch, no
      // actions at all (one run: step, like release-pending's non-schedule
      // arms).
      final steps = job['steps'] as YamlList;
      expect(steps, hasLength(1), reason: 'one step: the check script');
      final check = steps.first as YamlMap;
      expect(check['id'].toString(), 'check');
      expect(
        check['run'].toString(),
        contains('scripts/release_dedupe_check.sh'),
        reason:
            'the decision logic is extracted + fixture-self-tested '
            '(aab-gate-selftest pattern), never inlined',
      );
      expect(
        check['uses'],
        isNull,
        reason:
            'gh-1625: the pre-check must not even pay a checkout — '
            'the lookup is one gh run list API call',
      );
      expect(
        (job['permissions'] as YamlMap)['actions'].toString(),
        'read',
        reason:
            'gh run list needs actions: read (SEC-08: explicit '
            'minimal job-level permissions)',
      );
      expect((job['permissions'] as YamlMap)['contents'].toString(), 'read');
    });

    test('every release-arm-reachable gate leg ANDs the dedupe guard on '
        'top of its pending guard', () {
      final guarded = _guardedJobs(jobs)..removeAll(preCheckJobs);
      // The walk is not vacuous: canaries from across the graph.
      for (final canary in [
        'changes',
        'static',
        'quality-gate',
        'fa-aot-build',
        'js-ext-integration',
        'faui-coverage',
      ]) {
        expect(
          guarded,
          contains(canary),
          reason:
              'closure walk must reach '
              '$canary — the guarded set is stale',
        );
      }
      expect(guarded.length, greaterThanOrEqualTo(30));
      for (final id in guarded) {
        final job = jobs[id] as YamlMap;
        final ifText = job['if']?.toString() ?? '';
        expect(
          _needsOf(job),
          contains('release-dedupe'),
          reason:
              'gh-1625: `$id` executes on release events — without the '
              'needs edge the guard expression reads an empty output and '
              'the workflow parse fails outright',
        );
        expect(
          ifText,
          contains(dedupeClause),
          reason:
              'gh-1625 AC1: `$id` must skip explicitly (visible '
              'SKIPPED) when the tag\'s push run already gates it',
        );
        expect(
          ifText,
          contains(pendingClause),
          reason:
              'gh-1625: the dedupe guard must be ANDed ON TOP of '
              '`$id`\'s gh-1551 pending guard, never replace it — the '
              'same replacement blind spot ci_release_pending_guard_test '
              'pins for the changes-keyed conditions',
        );
      }
    });

    test('quality-gate itself keeps always() and skips on the deduped '
        'release twin', () {
      final gate = jobs['quality-gate'] as YamlMap;
      final gateIf = gate['if'].toString();
      expect(
        gateIf,
        startsWith('always()'),
        reason: 'the aggregate keeps collecting leg results on real runs',
      );
      expect(gateIf, contains(pendingClause));
      expect(gateIf, contains(dedupeClause));
      // ci_1267_path_triggered_legs_test pins the needs-list TAIL — new
      // edges go to the FRONT.
      final needs = _needsOf(gate);
      expect(needs.first, 'release-pending');
      expect(needs[1], 'release-dedupe');
    });

    test('the release trigger comment documents the dedupe (the old '
        'tolerates-the-double-fire note is gone)', () {
      final triggerAt = ciText.indexOf('release:\n    types: [published]');
      expect(triggerAt, greaterThanOrEqualTo(0));
      // Same clamped-window approach as ci_release_pending_guard_test's
      // AC5: the comment block immediately above the trigger.
      final comment = ciText.substring(
        ciText.lastIndexOf('  # Any release publication', triggerAt),
        triggerAt,
      );
      expect(
        comment,
        contains('release-dedupe'),
        reason:
            'the trigger comment quoted by gh-1625 must describe the '
            'new short-circuit, not the tolerated double-gate',
      );
      expect(
        comment,
        isNot(contains('tolerates')),
        reason:
            'the retired only-the-upload-is-idempotent note must stay '
            'retired',
      );
    });
  });

  group('AC2/AC5 — the check fails safe and keeps the old-tag safety net', () {
    test('the script defaults to dedupe=false and only flips inside a '
        'successful release-arm lookup', () {
      final script = read('scripts/release_dedupe_check.sh');
      final releaseBranchAt = script.indexOf('[ "\$EVENT_NAME" = "release" ]');
      expect(
        releaseBranchAt,
        greaterThanOrEqualTo(0),
        reason: 'only the release arm may dedupe (AC3)',
      );
      // Line-anchored ASSIGNMENT matches — the doc comment narrates both
      // values mid-sentence and must not satisfy the ordering pins.
      final defaults = RegExp(
        r'^dedupe=false\s*$',
        multiLine: true,
      ).allMatches(script).toList();
      expect(
        defaults,
        isNotEmpty,
        reason: 'AC5: the fail-safe default assignment must exist',
      );
      final defaultAt = defaults.first.start;
      final flips = RegExp(
        r'^\s*dedupe=true\s*$',
        multiLine: true,
      ).allMatches(script).toList();
      expect(
        flips,
        isNotEmpty,
        reason: 'the release arm must be able to dedupe',
      );
      final flipAt = flips.first.start;
      expect(
        flipAt,
        greaterThan(releaseBranchAt),
        reason:
            'AC5: dedupe=true may only be reached on a successful '
            'release-arm lookup',
      );
      expect(
        defaultAt,
        lessThan(releaseBranchAt),
        reason: 'AC5: the fail-safe default precedes the release arm',
      );
      expect(
        script,
        contains('::warning::'),
        reason: 'AC5: an API failure degrades loudly, never silently',
      );
      expect(
        script,
        isNot(contains('exit 1')),
        reason:
            'AC5: the pre-check never reddens the run on a check '
            'error — the full gate decides',
      );
    });

    test('the lookup keys on the tag ref, the push event, this workflow, '
        'and ANY run status', () {
      final script = read('scripts/release_dedupe_check.sh');
      expect(
        script,
        contains('--event push'),
        reason: 'gh-1625: the push twin of the tag is the gate',
      );
      expect(
        script,
        contains('--branch'),
        reason:
            'gh-1625: runs are matched per tag ref '
            '(gh run list --branch <tag>)',
      );
      expect(
        script,
        contains('--workflow ci.yml'),
        reason: 'only THIS workflow\'s push runs gate the tag',
      );
      expect(
        script,
        isNot(contains('--status')),
        reason:
            'any status dedupes — in the hot path the push twin is '
            'still in_progress when the release event fires '
            '(run 38687023638 vs 38687023803)',
      );
      expect(
        script,
        contains('DEDUPE_WINDOW_SECS'),
        reason:
            'the recent window bounds the stale-republish edge '
            '(AC2: an old tag\'s release must run the full gate)',
      );
    });
  });

  group('AC3 — push/dispatch/schedule arms stay untouched', () {
    test('non-release arms short-circuit in the script without an API '
        'call', () {
      final script = read('scripts/release_dedupe_check.sh');
      expect(
        script,
        contains('else'),
        reason: 'the non-release arm must exist and short-circuit',
      );
      final ghAt = script.indexOf('gh run list');
      final elseAt = script.indexOf('else');
      expect(
        ghAt,
        greaterThan(elseAt),
        reason:
            'gh-1625 AC3: the gh lookup lives INSIDE the release '
            'arm — push/dispatch/schedule arms never call the API',
      );
    });

    test('the concurrency rule is untouched: tag runs are never cancelled '
        'mid-flight', () {
      final concurrency = ci['concurrency'] as YamlMap;
      expect(concurrency['group'].toString(), 'ci-\${{ github.ref }}');
      expect(
        concurrency['cancel-in-progress'].toString(),
        "\${{ github.event_name == 'pull_request' }}",
        reason:
            'gh-1625: the release twin still queues behind the push '
            'twin — it must never be cancelled, only shortened',
      );
    });

    test('the schedule/dispatch/release flow jobs carry ZERO release-dedupe '
        'references', () {
      // Release-flow legs key on push tags / release events, PR satellites
      // on pull_request/dispatch — none can execute on a deduped release
      // twin, so wiring them would be dead code (and a silent behavior
      // change on the arms gh-1625 promises to leave untouched).
      const untouched = [
        'integration',
        'publish',
        'web-spa',
        'release-provenance',
        'install-pin-bump',
        'installer-smoke',
        'release',
        'watchdog',
        'binaries-pr',
        'binaries-smoke-gate',
        'ci-red-report',
      ];
      for (final id in untouched) {
        final job = jobs[id] as YamlMap;
        expect(
          _needsOf(job),
          isNot(contains('release-dedupe')),
          reason:
              'gh-1625 AC3: `$id` never executes on the release twin — '
              'it must stay untouched',
        );
        expect(
          job['if']?.toString() ?? '',
          isNot(contains('release-dedupe')),
          reason: 'gh-1625 AC3: `$id` must stay untouched',
        );
      }
    });
  });

  group('AC4 — the binaries-attach leg stays the release twin\'s job', () {
    test('binaries runs on the deduped release twin via an explicit '
        'release arm', () {
      final binaries = jobs['binaries'] as YamlMap;
      expect(
        _needsOf(binaries),
        containsAll(['quality-gate', 'release-dedupe']),
      );
      final ifText = binaries['if'].toString();
      expect(ifText, contains('!cancelled()'));
      expect(
        ifText,
        contains("needs.quality-gate.result == 'success'"),
        reason:
            'the push twin and the dedupe=false old-tag release still '
            'gate the matrix on the full quality gate',
      );
      expect(
        ifText,
        contains(
          "(github.event_name == 'release' && "
          "needs.release-dedupe.outputs.dedupe == 'true')",
        ),
        reason:
            'AC1: on a deduped release twin the tag\'s push run IS the '
            'gate — the release twin executes the binaries-attach leg only',
      );
      expect(
        ifText,
        contains("startsWith(github.ref, 'refs/tags/v')"),
        reason: 'the push arm survives verbatim',
      );
    });

    test('the --clobber last-wins upload is preserved (no race window '
        'without an idempotent attach)', () {
      final binaries = (jobs['binaries'] as YamlMap);
      final jobText = (binaries['steps'] as YamlList)
          .map((s) => (s as YamlMap)['run']?.toString() ?? '')
          .join('\n');
      expect(
        jobText,
        contains('--clobber'),
        reason:
            'AC4: both twins may attach the same asset — the upload '
            'must stay idempotent (last wins), exactly as before',
      );
    });

    test('web-spa stays keyed on the quality-gate result (skips with the '
        'deduped gate — binaries-attach only)', () {
      final webSpa = jobs['web-spa'] as YamlMap;
      expect(
        webSpa['if'].toString(),
        contains("needs.quality-gate.result == 'success'"),
        reason:
            'deliberate: the push twin already attached fa-web-spa.zip; '
            'a future edit keying web-spa on the dedupe output would '
            're-run the ~30 min build on every release twin',
      );
    });
  });

  group('RG — the regression guard is wired (aab-gate-selftest pattern)', () {
    test('the static gate fixture-self-tests the extracted check', () {
      final staticJob = jobs['static'] as YamlMap;
      final runs = (staticJob['steps'] as YamlList)
          .map((s) => (s as YamlMap)['run']?.toString() ?? '')
          .join('\n');
      expect(
        runs,
        contains('scripts/release_dedupe_selftest.sh'),
        reason:
            'gh-1625: the release-event short-circuit decision must be '
            'fixture-tested on every PR — a regressed stub contract or '
            'fail-safe default must red the gate, not the next release',
      );
    });

    test('the selftest drives the check against a stubbed gh and pins the '
        'short-circuit scenario', () {
      final selftest = read('scripts/release_dedupe_selftest.sh');
      expect(
        selftest,
        contains('release_dedupe_check.sh'),
        reason: 'the selftest exercises the REAL script',
      );
      expect(
        selftest,
        contains('GH_STUB_FIXTURE'),
        reason:
            'a PATH-stubbed gh serves fixtures — no network, no '
            'token (sm_merge_guard_selftest pattern)',
      );
      expect(
        selftest,
        contains('GH_CALL_LOG'),
        reason:
            'the stub records invocations — the selftest can pin '
            'the lookup shape (--event push / --branch tag) and prove '
            'non-release arms make NO API call',
      );
    });
  });
}
