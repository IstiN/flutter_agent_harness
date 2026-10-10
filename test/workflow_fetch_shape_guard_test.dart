// gh-1477 — the `Derive version` job in build-mobile.yml ran
// actions/checkout with `fetch-depth: 0` (full history + every tag + every
// blob ever written) under `timeout-minutes: 10`. The repo gains a release
// tag + commits daily, so the full fetch only got slower until, on
// 2026-10-10, it outgrew the ceiling: the job was killed exactly 600s in,
// mid-`git fetch`, and the whole TestFlight leg of the daily train
// collapsed to `cancelled` (run 38027695551, issue #1472). A time bomb,
// not a flake — and the twin `Derive version` job in build-macos.yml, the
// daily-publish `plan` job, and a family of ci.yml guard jobs carried the
// same shape.
//
// Deliberately text/YAML-level asserts (the issue's "workflow-shape test"
// never-again, same static-assert pattern as
// nightly_desktop_leg_guard_test.dart / store_automation_guard_test.dart):
//  AC1  every checkout step that asks for full history
//       (`fetch-depth: 0`) must pair it with `filter: blob:none` — the
//       jobs read tags / commit metadata / `git log` ranges, never
//       historical file contents, and a blobless clone skips transferring
//       every blob ever written while git still lazy-fetches the rare
//       blob something actually asks for,
//  AC2  the metadata-only daily-train jobs (derive version ×2, daily
//       plan) whose ONLY pre-timeout work is that fetch must carry a ≥20m
//       ceiling — the 10m seatbelt was the bomb's detonator.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

/// Every checkout step (`uses: actions/checkout…`) across all workflow
/// jobs, as (workflow, jobId, stepIndex, step).
Iterable<(String, String, int, YamlMap)> checkoutSteps(String workflowPath) {
  final jobs = loadYaml(read(workflowPath))['jobs'] as YamlMap;
  final out = <(String, String, int, YamlMap)>[];
  for (final entry in jobs.entries) {
    final steps = (entry.value as YamlMap)['steps'];
    if (steps is! YamlList) continue;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step is! YamlMap) continue;
      final uses = step['uses']?.toString() ?? '';
      if (uses.startsWith('actions/checkout@')) {
        out.add((workflowPath, entry.key as String, i, step));
      }
    }
  }
  return out;
}

bool asksFullHistory(YamlMap step) {
  final depth = (step['with'] as YamlMap?)?['fetch-depth'];
  return depth == 0 || depth == '0';
}

void main() {
  final workflows = Directory('.github/workflows')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yml'))
      .map((f) => f.path)
      .toList()
    ..sort();

  group('AC1 — full-history checkouts are blobless (gh-1477)', () {
    for (final workflow in workflows) {
      test(workflow, () {
        for (final (path, jobId, stepIndex, step)
            in checkoutSteps(workflow)) {
          if (!asksFullHistory(step)) continue;
          final filter = (step['with'] as YamlMap?)?['filter'];
          expect(
            filter,
            'blob:none',
            reason:
                '$path job "$jobId" step $stepIndex pairs `fetch-depth: 0` '
                'with NO `filter: blob:none` — a full clone transfers every '
                'blob ever written and grows daily (gh-1477: the fetch '
                'outgrew its own 10m job timeout and cancelled the daily '
                'TestFlight leg, run 38027695551). The job reads tags / '
                'commit metadata only; blobs are waste.',
          );
        }
      });
    }
  });

  group('AC2 — metadata-only daily-train jobs carry a ≥20m seatbelt', () {
    const metadataOnlyJobs = <String, List<String>>{
      // (workflow, jobId) — the job's only pre-timeout work is a tags/
      // metadata fetch; a cancelled job collapses the whole daily train.
      '.github/workflows/build-mobile.yml': ['version'],
      '.github/workflows/build-macos.yml': ['version'],
      '.github/workflows/daily-publish.yml': ['plan'],
    };
    for (final entry in metadataOnlyJobs.entries) {
      for (final jobId in entry.value) {
        test('${entry.key} job "$jobId"', () {
          final job =
              (loadYaml(read(entry.key))['jobs'] as YamlMap)[jobId]
                  as YamlMap;
          final timeout = job['timeout-minutes'];
          expect(
            timeout,
            isNotNull,
            reason:
                '${entry.key} job "$jobId" lost its explicit ceiling — the '
                '#351 watch-budget arithmetic needs one',
          );
          expect(
            (timeout as num) >= 20,
            isTrue,
            reason:
                '${entry.key} job "$jobId" runs a full-history fetch under '
                'only ${timeout}m — the exact gh-1477 bomb (fetch outgrew '
                'the ceiling → job cancelled → daily leg collapsed). '
                '≥20m is the seatbelt; the blobless filter (AC1) makes the '
                'fetch itself cheap.',
          );
        });
      }
    }
  });
}
