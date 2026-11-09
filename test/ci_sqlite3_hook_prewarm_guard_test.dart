// gh-2074 — the daily-publish `play` leg (build-mobile.yml) went red on
// three Android jobs when a GitHub release-download brownout served 504
// pages to package:sqlite3's native-assets hook, which hashes the response
// body without honoring the HTTP status (released 3.7.0; 3.9.1 gained the
// check but has no retry). The hook then reports the 504 page's constant
// hash (bef140a1…) as a "Hash of downloaded file … mismatch" and exits 255
// mid-build. ci.yml solved this exact failure class for itself on
// 2026-09-21 by caching .dart_tool/hooks_runner/shared — the comment there
// names the same brownout signature — but build-mobile.yml never received
// that protection, and a mobile lane job has no cache to fall back on.
//
// The cure follows the repo's two established patterns for unretryable
// mid-build downloads (gh-1655/gh-1757 bounded-retry pre-install + the
// ci.yml hooks-shared cache):
//  AC1  scripts/sqlite3_hook_prewarm.dart exists and is the safe fetcher:
//       checks the HTTP status BEFORE hashing (the exact upstream root
//       cause), retries with backoff, verifies SHA-256 against the pin,
//       skips idempotently on a verified cache hit, writes tmp+rename, and
//       fails LOUDLY (::error::) after the last attempt,
//  AC2  every build-mobile.yml job that builds an Android APK/AAB restores
//       the hooks-shared cache (both roots) BEFORE its first hook-consuming
//       step and pre-warms the flutter_app android assets AFTER
//       flutter-pub-get and BEFORE its build step,
//  AC3  the assert-builtin-skills gate — the step that failed first in the
//       AAB job (a root `dart run` executes hooks for the whole package
//       graph) — pre-warms the root host assets between its pub get and
//       the verify run,
//  AC4  ci.yml keeps its own hooks-shared cache (the 2026-09-21 protection
//       must not rot while this guard exists),
//  AC5  the live hook-reuse layout (shared/sqlite3/build/download-<hash8>)
//       is pinned by the script unit test — this guard only asserts the
//       wiring, the byte-level behavior lives in
//       test/scripts/sqlite3_hook_prewarm_test.dart,
//  AC6  every ci.yml hosted lane whose first hook consumer is a plain dart
//       command carries the hooks-shared cache and the pre-warm step after
//       pub get and before that first consumer. The 2026-11-09 rework run
//       red'd FOUR such lanes on one brownout window: binaries-pr
//       (macos-x64 `dart build cli`, exit 255), hostile-env (`dart test`,
//       exit 65), pty-visual (the fa-boot prewarm, exit 255), and the
//       structural twins stayed exposed (test-core, integration-mock,
//       fa-aot-build, pty-integration-linux),
//  AC7  EVERY pre-warm invocation is hook-free (`dart --disable-dart-dev`):
//       a plain `dart run` inside a package executes the whole package
//       graph's build hooks BEFORE main() — proven live on 2026-11-09, a
//       brownout + cold cache killed the pre-warm step before it could
//       pre-warm (chicken-and-egg). --disable-dart-dev skips the pub run
//       machinery; the script stays self-contained (no package: imports,
//       pinned by the script unit test) so that mode can load it.
//
// Deliberately YAML-level asserts (the static-pattern style of
// ci_android_ndk_preinstall_guard_test.dart / ci_pub_get_retry_guard_
// test.dart — a future build job that drops the cache or the pre-warm is a
// test red here, not a silent return to the download roulette).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const scriptPath = 'scripts/sqlite3_hook_prewarm.dart';
const actionPath = '.github/actions/assert-builtin-skills/action.yml';
const mobilePath = '.github/workflows/build-mobile.yml';
const ciPath = '.github/workflows/ci.yml';

/// The build-mobile.yml jobs that build an Android APK/AAB (the play leg's
/// failing jobs in gh-2074: Build Android AAB + the god/store APK matrix).
const androidBuildJobs = ['build-android', 'build-android-apks'];

/// Every `steps:` entry of every job in [workflowPath] keyed by job id.
Map<String, List<YamlMap>> stepsPerJob(String workflowPath) {
  final root = loadYaml(read(workflowPath)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final out = <String, List<YamlMap>>{};
  for (final MapEntry(:key, :value) in jobs.entries) {
    final steps = (value as YamlMap)['steps'];
    if (steps is! YamlList) continue;
    out[key as String] = [
      for (final s in steps)
        if (s is YamlMap) s,
    ];
  }
  return out;
}

int stepIndexByPredicate(
  List<YamlMap> steps,
  bool Function(YamlMap) test,
  String what,
) {
  for (var i = 0; i < steps.length; i++) {
    if (test(steps[i])) return i;
  }
  return -1;
}

bool isCacheStep(YamlMap step) =>
    step['uses'] is String &&
    (step['uses'] as String).startsWith('actions/cache@') &&
    ((step['with'] as YamlMap?)?['key'] as String? ?? '').startsWith(
      'hooks-shared-mobile-',
    );

bool isPubGetStep(YamlMap step) =>
    step['uses'] == './.github/actions/flutter-pub-get';

bool isPrewarmStep(YamlMap step) {
  final run = step['run'];
  return run is String && run.contains('scripts/sqlite3_hook_prewarm.dart');
}

bool isCiHooksCacheStep(YamlMap step) =>
    step['uses'] is String &&
    (step['uses'] as String).startsWith('actions/cache@') &&
    ((step['with'] as YamlMap?)?['key'] as String? ?? '').startsWith(
      'hooks-shared-',
    );

bool isDartPubGetStep(YamlMap step) {
  final run = step['run'];
  return run is String && run.contains('dart pub get');
}

/// The first hook-consuming command of each ci.yml lane (the step that
/// must never be the first download site). `dart test` / `dart build cli`
/// compile the package graph's native assets; `dart bin/fah.dart` boots
/// the CLI through the same machinery.
const ciHookConsumerLanes = <String, String>{
  'test-core': 'dart test',
  'integration-mock': 'dart bin/fah.dart',
  'hostile-env': 'dart test',
  'fa-aot-build': 'dart build cli',
  'pty-integration-linux': 'dart test',
  'pty-visual': 'dart bin/fah.dart',
  'binaries-pr': 'dart build cli',
};

void main() {
  test('AC1: the pre-warm script exists and is the safe fetcher', () {
    final script = read(scriptPath);
    // The upstream root cause: hashing a body without checking the status.
    expect(
      script,
      contains('statusCode'),
      reason: 'the fetcher must gate on the HTTP status before hashing',
    );
    // Bounded retry with backoff (the gh-1655 pattern).
    expect(
      script,
      contains('attempts'),
      reason: 'downloads must be bounded-retried, never single-shot',
    );
    expect(
      script.contains('sleep(') || script.contains('.delayed('),
      isTrue,
      reason: 'retries must back off between attempts',
    );
    // SHA-256 verification against the pin before any cache write.
    expect(script, contains('sha256'));
    expect(
      script.contains('expectedSha256') || script.contains('expected'),
      isTrue,
      reason: 'downloads must be verified against the pinned hash',
    );
    // Idempotence: a verified cache hit performs no fetch.
    expect(script, contains('existsSync'));
    // Torn-write safety: download to a .tmp sibling, then rename.
    expect(script, contains('.tmp'));
    expect(script, contains('rename'));
    // Loud failure for humans scanning CI logs.
    expect(script, contains('::error::'));
  });

  for (final job in androidBuildJobs) {
    group('AC2: build-mobile.yml $job', () {
      final steps = stepsPerJob(mobilePath)[job]!;

      test('restores the hooks-shared cache for both roots', () {
        final cacheIdx = stepIndexByPredicate(steps, isCacheStep, 'cache');
        expect(
          cacheIdx,
          greaterThanOrEqualTo(0),
          reason:
              '$job must restore .dart_tool/hooks_runner/shared (both roots)',
        );
        final cache = steps[cacheIdx];
        final opts = cache['with'] as YamlMap;
        final path = opts['path'];
        final pathText = path is YamlList
            ? path.join('\n')
            : (path as String?) ?? '';
        expect(
          pathText,
          contains('.dart_tool/hooks_runner/shared'),
          reason: 'the root package assets (assert gate dart run)',
        );
        expect(
          pathText,
          contains('flutter_app/.dart_tool/hooks_runner/shared'),
          reason: 'the flutter_app android assets (APK/AAB builds)',
        );
        expect(
          (opts['restore-keys'] as String?) ?? '',
          startsWith('hooks-shared-mobile-'),
          reason:
              'prefix restore-keys keep the cache warm across lockfile bumps',
        );
      });

      test(
        'pre-warms flutter_app android assets after pub get, before build',
        () {
          final cacheIdx = stepIndexByPredicate(steps, isCacheStep, 'cache');
          final assertIdx = stepIndexByPredicate(
            steps,
            (s) => s['uses'] == './.github/actions/assert-builtin-skills',
            'assert-builtin-skills',
          );
          final pubGetIdx = stepIndexByPredicate(
            steps,
            isPubGetStep,
            'flutter-pub-get',
          );
          final prewarmIdx = stepIndexByPredicate(
            steps,
            isPrewarmStep,
            'pre-warm',
          );
          final buildIdx = stepIndexByPredicate(
            steps,
            (s) =>
                (s['name'] as String?) == 'Build Android AAB' ||
                (s['name'] as String?) == 'Build flavor APK',
            'build step',
          );
          expect(
            prewarmIdx,
            greaterThanOrEqualTo(0),
            reason: '$job must pre-warm the sqlite3 hook assets',
          );
          expect(
            prewarmIdx,
            greaterThan(pubGetIdx),
            reason:
                'the pre-warm reads flutter_app/.dart_tool/package_config.json '
                '— it can only run after the resolution step',
          );
          expect(
            prewarmIdx,
            lessThan(buildIdx),
            reason: 'the build must never be the first hook-download site',
          );
          expect(
            cacheIdx,
            lessThan(assertIdx),
            reason:
                'the assert gate runs a root dart run (hook consumer) — the '
                'cache restore must land before it',
          );
          final run = steps[prewarmIdx]['run'] as String;
          expect(run, contains('--package flutter_app'));
          expect(run, contains('--targets android'));
        },
      );
    });
  }

  test('AC3: assert-builtin-skills pre-warms the root host assets', () {
    final action = read(actionPath);
    final pubGetIdx = action.indexOf('dart pub get');
    final verifyIdx = action.indexOf(
      'dart run scripts/verify_builtin_skills.dart',
    );
    final prewarmIdx = action.indexOf('scripts/sqlite3_hook_prewarm.dart');
    expect(
      prewarmIdx,
      greaterThanOrEqualTo(0),
      reason:
          'the gate executes build hooks for the whole root package graph — '
          'it must pre-warm before the first dart run',
    );
    expect(
      prewarmIdx,
      greaterThan(pubGetIdx),
      reason: 'the pre-warm needs the root package_config.json',
    );
    expect(
      prewarmIdx,
      lessThan(verifyIdx),
      reason: 'the verify dart run must not be the first download site',
    );
    expect(action, contains('--targets host'));
  });

  test('AC4: ci.yml keeps its 2026-09-21 hooks-shared cache', () {
    final ci = read(ciPath);
    expect(
      ci,
      contains('hooks-shared-'),
      reason: 'the ci.yml brownout cache must not regress',
    );
    expect(ci, contains('.dart_tool/hooks_runner/shared'));
  });

  // The 2026-11-09 rework run: one brownout window red'd binaries-pr
  // (macos-x64), hostile-env and pty-visual — every one a lane whose FIRST
  // hook consumer ran bare against a cold cache. The structural twins
  // (test-core, integration-mock, fa-aot-build, pty-integration-linux)
  // share the identical wiring shape and stay pinned here so the next
  // brownout cannot pick them off one lane at a time.
  ciHookConsumerLanes.forEach((job, consumerMarker) {
    group('AC6: ci.yml $job', () {
      final steps = stepsPerJob(ciPath)[job]!;

      test('restores the hooks-shared cache and pre-warms the host asset '
          'after pub get, before $consumerMarker', () {
        final cacheIdx = stepIndexByPredicate(
          steps,
          isCiHooksCacheStep,
          'hooks cache',
        );
        final prewarmIdx = stepIndexByPredicate(
          steps,
          isPrewarmStep,
          'pre-warm',
        );
        // The LAST pub get (pty-visual runs a root `dart pub get` after the
        // flutter-pub-get action; fa-aot-build restores its cache BEFORE
        // pub get — the pre-warm must land after both either way).
        var lastPubGetIdx = -1;
        for (var i = 0; i < steps.length; i++) {
          if (isDartPubGetStep(steps[i])) lastPubGetIdx = i;
        }
        final consumerIdx = stepIndexByPredicate(steps, (s) {
          final run = s['run'];
          return run is String && run.contains(consumerMarker);
        }, 'first hook consumer ($consumerMarker)');

        expect(
          cacheIdx,
          greaterThanOrEqualTo(0),
          reason: '$job must restore .dart_tool/hooks_runner/shared',
        );
        expect(
          prewarmIdx,
          greaterThanOrEqualTo(0),
          reason: '$job must pre-warm the sqlite3 host asset',
        );
        expect(
          prewarmIdx,
          greaterThan(lastPubGetIdx),
          reason: 'the pre-warm reads .dart_tool/package_config.json',
        );
        expect(
          prewarmIdx,
          greaterThan(cacheIdx),
          reason: 'a warm cache hit must make the pre-warm a no-op',
        );
        expect(
          consumerIdx,
          greaterThan(prewarmIdx),
          reason:
              '$consumerMarker must never be the first download site — '
              'the pre-warm owns the bounded retries',
        );
        final run = steps[prewarmIdx]['run'] as String;
        expect(
          run,
          contains('--package .'),
          reason: '$job consumes the ROOT package graph',
        );
        expect(
          run,
          contains('--targets host'),
          reason: '$job builds for the machine it runs on',
        );
      });

      test('invokes the script hook-free (--disable-dart-dev)', () {
        final steps = stepsPerJob(ciPath)[job]!;
        final prewarmIdx = stepIndexByPredicate(
          steps,
          isPrewarmStep,
          'pre-warm',
        );
        final run = steps[prewarmIdx]['run'] as String;
        expect(
          run,
          contains('--disable-dart-dev'),
          reason:
              'a plain `dart run` executes the whole package graph build '
              'hooks BEFORE main() — on a brownout + cold cache the '
              'pre-warm dies before it can pre-warm (proven live '
              '2026-11-09). Only --disable-dart-dev skips that machinery.',
        );
      });
    });
  });

  test('AC7: every pre-warm invocation in .github is hook-free', () {
    const files = [ciPath, mobilePath, actionPath];
    for (final path in files) {
      final lines = read(path).split('\n');
      final invocations = <int, String>{
        for (var i = 0; i < lines.length; i++)
          if (lines[i].contains('scripts/sqlite3_hook_prewarm.dart') &&
              lines[i].contains('dart '))
            i: lines[i],
      };
      expect(
        invocations,
        isNotEmpty,
        reason: '$path must still wire the pre-warm',
      );
      for (final entry in invocations.entries) {
        expect(
          entry.value,
          contains('--disable-dart-dev'),
          reason:
              '$path:${entry.key + 1} runs the pre-warm with the pub '
              'machinery — the hook fires before main() and a brownout '
              'kills the pre-warm before it can pre-warm',
        );
      }
    }
  });
}
