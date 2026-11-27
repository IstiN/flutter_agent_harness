// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2332 (the v1.0.752/753/754 class): every post-gate leg that can
/// redden a tag run must arm ci-red-report. Deliberately text/YAML-level
/// asserts (the repo's workflow-shape never-again pattern, same as
/// ci_main_push_retired_test.dart):
///  AC1  ci-red-report still fires only on `push` events (the tag flow)
///       under always() — PR-dispatch failures stay PR-visible,
///  AC2  ci-red-report's needs cover EVERY tag-run red source, DERIVED
///       from the live needs graph rather than a hardcoded list: a job is
///       a red source iff it is outside quality-gate's upstream closure
///       (gh-1801 moved the artifact train AFTER the gate — its verdict
///       is blind to it; v1.0.752/753/754 went red with quality-gate
///       green and three releases vanished without a tracker item),
///       carries no job-level continue-on-error (downstream needs see
///       SUCCESS — web-spa/build-extension cannot redden a run), and is
///       armed on tag pushes (its `if` is absent, event-agnostic, or
///       mentions push). quality-gate itself is the pre-gate arm,
///  AC3  the `if` ORs every covered leg's direct result — 'failure' OR
///       'cancelled' (fa#456 transitive-skip lesson: key on direct
///       results, never transitive skips). Cancelled is a red source,
///       not a skip (gh-2436 / v1.0.782 run 45830131519: the hung
///       binaries-macos-x64 leg hit timeout-minutes:45 and concluded
///       CANCELLED — invisible to failure-only arms; the report fired
///       only through the downstream fail-closed install-pin-bump
///       symptom, and a mid-flight run cancel with zero failures would
///       have left every in-flight leg cancelled: silent vanish).
///       No dead clauses either: every needs entry must appear in the
///       if (the continue-on-error review finding),
///  AC4  every listed need is a real job key (a phantom key is a
///       workflow parse error).
///
/// Excluded from coverage, deliberately (pinned by the expected set):
///  - `release`, `binaries-pr`, `binaries-smoke-gate`: schedule-,
///    dispatch- or PR-scoped — never run on tag pushes,
///  - `web-spa`, `build-extension`: job-level continue-on-error,
///  - everything upstream of quality-gate: rides its verdict.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap _jobs() =>
    (loadYaml(read('.github/workflows/ci.yml'))['jobs'] as YamlMap);

List<String> _needsOf(YamlMap jobs, String jobId, {bool required = true}) {
  final needs = (jobs[jobId] as YamlMap)['needs'];
  if (needs == null) {
    if (required) {
      expect(needs, isNotNull, reason: '$jobId must declare needs');
    }
    return const <String>[];
  }
  if (needs is String) return <String>[needs];
  return (needs as YamlList).map((n) => n.toString()).toList();
}

/// Transitive upstream closure of quality-gate — the population whose
/// verdict the gate already aggregates. Root jobs (release-pending)
/// declare no needs and contribute nothing upstream.
Set<String> _gateClosure(YamlMap jobs) {
  final closure = <String>{};
  void collect(String name) {
    if (!closure.add(name)) return;
    for (final n in _needsOf(jobs, name, required: false)) {
      collect(n);
    }
  }

  collect('quality-gate');
  return closure;
}

/// Whether the job's `if` allows it to run on a v* tag push: absent `if`
/// (runs on every event), an event-agnostic `if`, or an `if` mentioning
/// push. (`event_name != 'push'` negations would slip through this
/// contains() check; ci.yml carries none — asserted in AC2.)
bool _runsOnTagPush(YamlMap job) {
  final ifText = job['if']?.toString() ?? '';
  return ifText.isEmpty ||
      !ifText.contains('github.event_name') ||
      ifText.contains("== 'push'");
}

/// Every job that can redden a v* tag run while quality-gate is green:
/// outside the gate's closure, no job-level continue-on-error, armed on
/// tag pushes. ci-red-report itself is the consumer, not a red source.
Set<String> _tagRunRedSources(YamlMap jobs) {
  final gated = _gateClosure(jobs);
  return jobs.entries
      .map((e) => e.key.toString())
      .where(
        (id) =>
            id != 'ci-red-report' &&
            !gated.contains(id) &&
            (jobs[id] as YamlMap)['continue-on-error'].toString() != 'true' &&
            _runsOnTagPush(jobs[id] as YamlMap),
      )
      .toSet();
}

void main() {
  group('AC1 — ci-red-report arms on tag pushes only', () {
    test('always() + push event gate survive the widening', () {
      final job =
          _jobs()['ci-red-report'] as YamlMap? ??
          (fail('ci-red-report job must exist in ci.yml'));
      final ifText = job['if'].toString();
      expect(
        ifText,
        contains('always()'),
        reason: 'the reporter must evaluate even when needs are skipped',
      );
      expect(
        ifText,
        contains("github.event_name == 'push'"),
        reason:
            'PR-dispatch failures are visible on the PR itself; the '
            'reporter exists for the tag flow whose reds live only in '
            'the tag-filtered Actions tab',
      );
    });
  });

  group('AC2 — needs cover every derived tag-run red source (gh-2332)', () {
    test('the push filter has no event_name negations', () {
      // The _runsOnTagPush contains() check would misclassify
      // `github.event_name != 'push'` arms as push-armed; pin their
      // absence so the derivation stays sound.
      expect(read('.github/workflows/ci.yml'), isNot(contains("!= 'push'")));
    });

    test('derived red-source set matches the pinned leg list', () {
      // Drift alarm for the derivation itself: when a leg legitimately
      // enters/leaves the set (new tag leg, a leg grows continue-on-error,
      // a leg loses its push arm), this list and the ci.yml coverage must
      // change together.
      final derived = _tagRunRedSources(_jobs());
      expect(
        derived,
        <String>{
          'binaries', // artifact matrix (gh-1801 train)
          'integration', // Provider smoke — the #551 hard publish gate
          'js-ext-integration',
          'publish', // the pub.dev leg
          'watchdog', // degraded-runner retrigger
          'step-timings',
          'faui-coverage',
          'release-provenance',
          'release-asset-smoke',
          'installer-smoke',
          'install-pin-bump',
          'train-draft-guard',
        },
        reason:
            'the derivation walked a changed graph — re-audit '
            'ci-red-report coverage AND this pin together (gh-2332 class: '
            'an un-derived leg is an un-filed red)',
      );
    });

    test(
      'ci-red-report needs cover quality-gate + every derived red source',
      () {
        final jobs = _jobs();
        final derived = _tagRunRedSources(jobs);
        final covered = _needsOf(jobs, 'ci-red-report').toSet();
        expect(
          covered.containsAll(<String>{'quality-gate', ...derived}),
          isTrue,
          reason:
              'legs $derived run after quality-gate and are invisible to '
              'its verdict (v1.0.752/753/754: binaries 422\'d the lazy '
              'draft, quality-gate stayed green, ci-red-report skipped, '
              'three releases vanished without a tracker item). Update the '
              'workflow AND this guard together when the tag graph grows.',
        );
      },
    );
  });

  group('AC3 — the if keys on each covered leg directly (fa#456)', () {
    test('every needs entry arms on failure AND cancelled', () {
      final jobs = _jobs();
      final ifText = (jobs['ci-red-report'] as YamlMap)['if'].toString();
      final covered = _needsOf(jobs, 'ci-red-report');
      for (final leg in covered) {
        expect(
          ifText,
          contains("needs.$leg.result == 'failure'"),
          reason:
              'ci-red-report\'s if must OR the direct result of '
              '"$leg" — dead needs entries (a leg with continue-on-error '
              'can never conclude failure) only delay the report; '
              'transitive skips are never a substitute (fa#456)',
        );
        expect(
          ifText,
          contains("needs.$leg.result == 'cancelled'"),
          reason:
              '"$leg" concluding CANCELLED must arm the report too — '
              'cancelled is a red source, not a skip (v1.0.782 run '
              '45830131519: the hung binaries-macos-x64 leg was '
              'cancelled at timeout-minutes:45 and failure-only arms '
              'never saw it; only the downstream fail-closed '
              'install-pin-bump symptom filed the ticket, and a '
              'mid-flight run cancel with zero failures would have '
              'vanished silently)',
        );
      }
    });

    test('the filed issue names cancelled legs, not just failures', () {
      expect(
        read('.github/workflows/ci.yml'),
        contains(
          'select(.conclusion == "failure" or .conclusion == "cancelled")',
        ),
        reason:
            'the tracker item must list the ROOT leg — v1.0.782 (run '
            '45830131519) filed only the downstream fail-closed symptom '
            '("Advance vpinned marker") while the actually-hung '
            'binaries-macos-x64 leg, cancelled at timeout-minutes, was '
            'filtered out by the failure-only conclusion query',
      );
    });
  });

  group('AC4 — needs entries are real job keys', () {
    test('no phantom keys in ci-red-report needs', () {
      final jobs = _jobs();
      for (final n in _needsOf(jobs, 'ci-red-report')) {
        expect(
          jobs.containsKey(n),
          isTrue,
          reason:
              'ci-red-report needs "$n" is not a job in ci.yml — a '
              'phantom needs key is a workflow parse error',
        );
      }
    });
  });
}
