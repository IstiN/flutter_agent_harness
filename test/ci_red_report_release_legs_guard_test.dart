// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2332 (the v1.0.752/753/754 class): tag-run release-train reds must
/// reach ci-red-report. Deliberately text/YAML-level asserts (the repo's
/// workflow-shape never-again pattern, same as
/// ci_main_push_retired_test.dart):
///  AC1  ci-red-report still fires only on `push` events (the tag flow)
///       under always() — PR-dispatch failures stay PR-visible,
///  AC2  ci-red-report's needs cover the WHOLE release train tail: the
///       three quality-gate children (binaries / web-spa / build-extension)
///       plus everything transitively downstream of them
///       (release-provenance, release-asset-smoke, installer-smoke,
///       install-pin-bump, train-draft-guard). gh-1801 moved the train
///       AFTER quality-gate, so quality-gate's verdict is blind to it —
///       v1.0.752/753/754 went red with quality-gate green, ci-red-report
///       skipped, and three releases vanished without a tracker item,
///  AC3  the `if` ORs every covered leg's result == 'failure' — the
///       fa#456 transitive-skip lesson: key on direct results, never
///       transitive skips,
///  AC4  every listed need is a real job key (a phantom key is a workflow
///       parse error), and the derived closure is asserted against the
///       live needs graph so a NEW release-tail leg without reporter
///       coverage fails this test.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap _jobs() =>
    (loadYaml(read('.github/workflows/ci.yml'))['jobs'] as YamlMap);

/// The release train's first-order legs: jobs hanging directly off
/// quality-gate that build/ship release artifacts (gh-1801 train rework).
const _trainSeeds = <String>['binaries', 'web-spa', 'build-extension'];

/// Every job transitively downstream of the seeds (a job joins the closure
/// when any of its `needs` is already in it). ci-red-report itself is
/// excluded — it is the consumer, not a train leg.
Set<String> _trainClosure(YamlMap jobs) {
  final closure = <String>{..._trainSeeds};
  var grew = true;
  while (grew) {
    grew = false;
    jobs.forEach((jobId, job) {
      final needs = (job as YamlMap)['needs'];
      final list = needs is String
          ? <String>[needs]
          : (needs is YamlList
                ? needs.map((n) => n.toString())
                : const <String>[]);
      if (jobId != 'ci-red-report' &&
          !closure.contains(jobId) &&
          list.any(closure.contains)) {
        closure.add(jobId.toString());
        grew = true;
      }
    });
  }
  return closure;
}

List<String> _needsOf(YamlMap jobs, String jobId) {
  final needs = (jobs[jobId] as YamlMap)['needs'];
  expect(needs, isNotNull, reason: '$jobId must declare needs');
  if (needs is String) return <String>[needs];
  return (needs as YamlList).map((n) => n.toString()).toList();
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

  group('AC2 — needs cover the whole release train tail (gh-2332)', () {
    test('derived downstream closure is a subset of ci-red-report needs', () {
      final jobs = _jobs();
      final closure = _trainClosure(jobs);
      final covered = _needsOf(
        jobs,
        'ci-red-report',
      ).map((n) => n.toString()).toSet();
      expect(
        covered.containsAll(closure),
        isTrue,
        reason:
            'release-train legs $closure hang AFTER quality-gate '
            '(gh-1801), so quality-gate\'s verdict is blind to their reds '
            '(v1.0.752/753/754: binaries 422\'d the lazy draft, '
            'quality-gate stayed green, ci-red-report skipped, three '
            'releases vanished without a tracker item). Every tail leg '
            'must be in ci-red-report\'s needs; update the workflow AND '
            'this guard together when the train grows.',
      );
      expect(
        covered,
        contains('quality-gate'),
        reason: 'the original arm (pre-train legs) must stay covered',
      );
    });
  });

  group('AC3 — the if keys on each covered leg directly (fa#456)', () {
    test(
      'every tail leg appears as needs.<key>.result == failure in the if',
      () {
        final jobs = _jobs();
        final ifText = (jobs['ci-red-report'] as YamlMap)['if'].toString();
        for (final leg in _trainClosure(jobs)) {
          expect(
            ifText,
            contains("needs.$leg.result == 'failure'"),
            reason:
                'ci-red-report\'s if must OR the direct result of '
                'release-train leg "$leg" — a leg failing while quality-gate '
                'is green must arm the reporter (gh-2332); transitive skips '
                'are never a substitute (fa#456)',
          );
        }
      },
    );
  });

  group('AC4 — needs entries are real job keys', () {
    test('no phantom keys in ci-red-report needs', () {
      final jobs = _jobs();
      for (final n in _needsOf(jobs, 'ci-red-report')) {
        expect(
          jobs.containsKey(n.toString()),
          isTrue,
          reason:
              'ci-red-report needs "$n" is not a job in ci.yml — a '
              'phantom needs key is a workflow parse error',
        );
      }
    });
  });
}
