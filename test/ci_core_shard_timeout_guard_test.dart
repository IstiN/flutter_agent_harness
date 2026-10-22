// gh-1778 — the `test-core` shard budget survives a degraded cache service.
//
// CI run 39704649488 (tag v1.0.621) red'd the release: `Core tests
// (shard 2/4)` was killed by its own job-level `timeout-minutes: 12` with
// 2535/2761 tests (92%) completed, every one GREEN — the Quality gate
// followed (`Quality gate FAILED: a leg is cancelled (test-core)`), the
// publish and the vpinned marker advance died downstream. The budget was
// sized for warm-cache runs: on the SAME commit (53721b2) 15 minutes
// earlier (run 39703080550, green) the shard walls were 525/499/460/515 s
// with both caches hitting (`Cache restored from key: pub-Linux-` in ~5 s).
// On the release run GitHub's cache service degraded: BOTH cache steps in
// every core shard stalled ~133 s and then reported misses for keys that
// existed (`Cache not found for input keys: pub-Linux-, pub-Linux-` — main
// hit that key at 01:01:49, and the v1.0.620 release run hit it too, so a
// degraded-service stall, not eviction). Cold `pub get` + cold native-asset
// hook builds pushed the first test completion to ~5 min after job start
// (vs ~40 s warm); the shard needed ~14 min and died at the 12-min wall.
// A ~3-min headroom over warm walls means ANY slow cache service reds the
// whole release with zero product/test failures. Red tag runs are
// release-flow failures, triaged and fixed structurally — never
// quarantined as flakes (AGENTS.md, gh-1537 note).
//
// Deliberately YAML-level asserts (the ci_core_shard_upload_retry_guard_test.dart
// static pattern):
//  AC1  `test-core` declares `timeout-minutes` >= 20 — headroom over the
//       measured warm wall (~8.8 min) plus the observed degraded-cache
//       worst case (~14 min); in line with the sibling test legs
//       (flutter-tests 20, integration-mock 25, pty-integration-linux 40).
//       A real hang is still killed loudly, just not mid-green-run.
//  AC2  every `actions/cache` step in `test-core` carries
//       `continue-on-error: true` — a cache restore that fails is a
//       slower setup, never a product failure, and must not red the shard.
//  AC3  every `actions/cache` step in `test-core` carries a step-level
//       `timeout-minutes` <= 2 — a degraded cache service costs at most
//       ~2 min per step instead of an unbounded stall (~5 s is the warm
//       restore; 2 min is already generous), so the worst-case setup
//       stays inside AC1's budget.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const coreJobId = 'test-core';

/// Warm shard wall measured on the same commit with cache hits
/// (run 39703080550, 2026-10-22): 525/499/460/515 s.
const warmWallSeconds = 525;

/// The observed degraded-cache worst case (run 39704649488): two ~133 s
/// cache-service stalls + cold pub get/hook builds ≈ 14 min total.
const degradedWallMinutes = 14;

/// The new job budget — must clear the degraded worst case with margin
/// and sit inside the sibling test-leg band (20–40 min).
const minJobTimeoutMinutes = 20;

/// A cache step's stall cap — ~5 s warm restore; 2 min absorbs a slow
/// service without letting it eat the job budget.
const maxCacheStepTimeoutMinutes = 2;

bool isCacheStep(YamlMap step) =>
    (step['uses']?.toString() ?? '').startsWith('actions/cache@');

int? jobTimeout(YamlMap job) {
  final v = job['timeout-minutes'];
  return v is int ? v : (v is String ? int.tryParse(v) : null);
}

YamlMap job(String jobId) {
  final root = loadYaml(read(ci)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[jobId];
  if (job is! YamlMap) throw StateError('job $jobId missing from $ci');
  return job;
}

List<YamlMap> jobSteps(String jobId) =>
    (job(jobId)['steps'] as YamlList).whereType<YamlMap>().toList();

void main() {
  group('gh-1778 — test-core budget survives a degraded cache service', () {
    final coreJob = job(coreJobId);
    final steps = jobSteps(coreJobId);
    final caches = [
      for (final s in steps)
        if (isCacheStep(s)) s,
    ];

    test('the leg carries the pub and native-assets hook caches', () {
      expect(
        caches,
        hasLength(2),
        reason:
            'pub-cache + hooks-shared — the guards below key on '
            'exactly these; a new cache step must opt into the same '
            'best-effort contract',
      );
    });

    test('AC1: the job budget clears the degraded-cache worst case', () {
      final timeout = jobTimeout(coreJob);
      expect(
        timeout,
        isNotNull,
        reason:
            'test-core must keep a job-level timeout — it is the '
            'backstop that kills a genuinely hung shard loudly',
      );
      expect(
        timeout,
        greaterThanOrEqualTo(minJobTimeoutMinutes),
        reason:
            'test-core timeout-minutes is $timeout — a warm shard '
            'wall is $warmWallSeconds s and the observed degraded-cache '
            'run needed ~$degradedWallMinutes min before being cancelled '
            'mid-green-run (gh-1778); the budget must clear that worst '
            'case, matching the sibling test legs (20–40 min)',
      );
    });

    test('AC2: every cache step is best-effort (continue-on-error)', () {
      for (final step in caches) {
        expect(
          step['continue-on-error'],
          true,
          reason:
              'cache step "${step['name'] ?? step['uses']}" must carry '
              'continue-on-error: true — a failed restore means a slower '
              'setup, never a product failure; reding the shard on it '
              'is the gh-1778 release-kill shape',
        );
      }
    });

    test('AC3: every cache step caps its own stall (timeout-minutes)', () {
      for (final step in caches) {
        final timeout = step['timeout-minutes'];
        expect(
          timeout,
          isNotNull,
          reason:
              'cache step "${step['name'] ?? step['uses']}" must carry '
              'a step-level timeout-minutes — the gh-1778 run stalled '
              '~133 s per step on a degraded cache service with no bound',
        );
        final minutes = timeout is int ? timeout : int.tryParse('$timeout');
        expect(
          minutes,
          isNotNull,
          reason: 'cache step timeout-minutes must be a number',
        );
        expect(
          minutes,
          lessThanOrEqualTo(maxCacheStepTimeoutMinutes),
          reason:
              'cache step "${step['name']}" stalls are capped at '
              '$maxCacheStepTimeoutMinutes min — both capped steps plus '
              'the cold-cache builds must stay inside AC1',
        );
      }
    });
  });
}
