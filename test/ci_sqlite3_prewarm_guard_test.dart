// gh-2072 — the v1.0.697 tag run red'd four CI legs + the aggregate
// Quality gate on ONE shared flake: the `sqlite3` package's native-assets
// build hook downloads its prebuilt binaries from GitHub releases at
// build time in a single attempt with no HTTP status check, so one
// transient `504 Gateway Time-out` error page (saved as the library file,
// then rejected by the hook's own sha256 check) kills every leg that
// compiles the root package (`dart test`/`dart run`/`dart build`) or
// flutter_app (`flutter test`/`flutter build`). The identical tree was
// green on the SM validation run hours earlier — pure network roulette
// the release train rides on every tag.
//
// The cure follows the gh-1655/gh-1757 pre-install pattern (bounded-retry
// pre-fetch into the exact path the unretryable consumer reads, guard
// test pins the wiring). This guard is deliberately YAML-level (the
// static-pattern style of test/ci_android_ndk_preinstall_guard_test.dart
// — a future leg must red HERE, not silently re-enter the download
// roulette):
//   AC1  the shared composite action exists, is composite, and delegates
//        to the prewarm script (no second URL pin in the action),
//   AC2  the prewarm script carries the whole safety contract: bounded
//        retry, HTTP status check, sha256 verification, atomic tmp→rename,
//        idempotent hash-checked reuse, the hook's download-<hash8> cache
//        convention, and the pinned asset_hashes.dart parsing,
//   AC3  every workflow job that builds the root package or compiles the
//        app carries the prewarm BEFORE its first hook-building step —
//        the enumerated map below is the contract (a count below means a
//        job lost the prewarm in a refactor; above means a new
//        hook-building site appeared that the map must acknowledge),
//   AC4  the shared flutter-pub-get action ends with the central prewarm,
//        so every flutter leg is covered by one edit,
//   AC5  the target routing for cross-target legs is explicit: the
//        android legs request the APK ABI triple, the iOS legs request
//        arm64-ios, and nightly's release matrix routes per row (web
//        builds no code assets and is excluded),
//   AC6  every mapped prewarm runs AFTER the job's dependency resolution
//        and under the same scope condition: the first prewarm must
//        follow the job's first `dart pub get` step (the script reads
//        .dart_tool/package_config.json and hard-fails without it — the
//        fa-aot-build leg red'd exactly this way on the PR's own run), a
//        prewarm whose pub get is scope-gated carries the identical
//        `if:` (out-of-scope fastpass), and a job that resolves NO root
//        package (flutter_app-only legs) declares `package-roots:`
//        explicitly because the `.` default reads a package config that
//        never exists,
//   AC7  a prewarm with explicit non-auto `targets:` declares
//        `package-roots:` explicitly — every cross-target invocation
//        lives in a job whose ONLY resolution is the flutter-pub-get
//        action inside flutter_app (gh-2072 review threads 3/4).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const prewarmAction = './.github/actions/sqlite3-native-assets-prewarm';
const actionPath = '.github/actions/sqlite3-native-assets-prewarm/action.yml';
const scriptPath = 'scripts/sqlite3_native_assets_prewarm.dart';
const pubGetActionPath = '.github/actions/flutter-pub-get/action.yml';

/// Every (workflow, jobs) pair whose jobs build the root package's
/// native-assets hook (`dart test`/`dart run`/`dart compile`/`dart build`
/// on a package graph carrying sqlite3 via flutter_agent_memory) or
/// compile flutter_app (flutter test / apk / appbundle / ios / macos /
/// linux / windows builds, fastlane release lanes). The same class
/// enumeration the gh-1655 guard pins: the network-roulette fix must
/// cover the whole release-blocking class, not just the four legs that
/// happened to lose the dice at v1.0.697.
///
/// ci.yml build-macos and build-web are intentionally absent: build-macos
/// needs only the host-macos target, which the central flutter-pub-get
/// prewarm (AC4) provides, and build-web compiles no code assets.
/// browser-ext.yml is intentionally absent (gh-2072 review thread 10):
/// its only Dart build runs in browser_ext/dart — a package graph that
/// carries NO sqlite3 at all — and hooks_runner caches are per package
/// root, so a repo-root prewarm there downloads a file nothing consumes.
const sqlite3PrewarmJobs = <String, List<String>>{
  '.github/workflows/ci.yml': [
    'test-core',
    'static',
    'cube-kernel-live',
    'integration-mock',
    'installer-portability',
    'hostile-env',
    'fa-aot-build',
    'pty-integration-linux',
    'pty-visual',
    'guards',
    'model-switch-reg',
    'cli-visual-settings',
    'dep-audit',
    'perf-gate',
    'usage-fold',
    'integration',
    'js-ext-integration',
    'build-android',
    'build-ios',
    'binaries',
    'binaries-pr',
  ],
  '.github/workflows/build-mobile.yml': [
    'build-android',
    'build-android-apks',
    'test-android-emulator',
    'build-ios',
  ],
  '.github/workflows/nightly.yml': ['build-release', 'pty-integration'],
  '.github/workflows/coverage-gardener.yml': ['measure-and-file'],
};

/// Run-step signatures that mean "this step builds the root package's
/// native-assets hook or compiles the app" — the prewarm must run before
/// any of them in the same job. `matrix.cmd` covers nightly's build-release
/// matrix, where the per-row command is interpolated at job level.
/// Deliberately NOT a signature: `dart pub get` (pub get never builds
/// hooks) and the firebase_options.dart template sanity-compiles (their
/// import graph reaches no code asset).
final hookBuildingSignatures = [
  RegExp(r'\bdart (?:test|run|compile|build)\b'),
  RegExp(r'\bdart bin/\S+\.dart\b'),
  RegExp(r'\bflutter test\b'),
  RegExp(r'\bflutter build (?:apk|appbundle|ios|ipa|macos|linux|windows)\b'),
  RegExp(r'fastlane android build_release\b'),
  RegExp(r'matrix\.cmd'),
];

/// Jobs that compile the app for a NON-host target: the central host-auto
/// prewarm cannot cover them, so the map entries must pass explicit
/// targets. The APK ABI triple is what `flutter build apk` produces by
/// default (armeabi-v7a, arm64-v8a, x86_64 — no x86/ia32 row since
/// Flutter 3.22); iOS device builds are arm64.
const explicitTargetJobs = <String, String>{
  'ci.yml/build-android': 'android',
  'build-mobile.yml/build-android': 'android',
  'build-mobile.yml/build-android-apks': 'android',
  'build-mobile.yml/test-android-emulator': 'android',
  'ci.yml/build-ios': 'arm64-ios',
  'build-mobile.yml/build-ios': 'arm64-ios',
};

YamlMap workflowRoot(String workflowPath) =>
    loadYaml(read(workflowPath)) as YamlMap;

YamlList jobSteps(String workflowPath, String jobKey) {
  final jobs = workflowRoot(workflowPath)['jobs'] as YamlMap;
  final job = jobs[jobKey] as YamlMap;
  return job['steps'] as YamlList;
}

List<int> prewarmIndexes(YamlList steps) => [
  for (var i = 0; i < steps.length; i++)
    if ((steps[i] as YamlMap)['uses'] == prewarmAction) i,
];

/// The `with.package-roots` value of a prewarm step, or null when the
/// step leaves it at the action default (`.` — the repo root).
String? declaredPackageRoots(YamlMap step) {
  final withMap = step['with'];
  if (withMap is! YamlMap) return null;
  final value = '${withMap['package-roots'] ?? ''}'.trim();
  return value.isEmpty ? null : value;
}

List<int> signatureIndexes(YamlList steps) => [
  for (var i = 0; i < steps.length; i++)
    if (hookBuildingSignatures.any(
      (re) => re.hasMatch('${(steps[i] as YamlMap)['run'] ?? ''}'),
    ))
      i,
];

void main() {
  group('gh-2072 — sqlite3 native-assets prewarm wiring', () {
    test('AC1: the composite action exists and delegates to the script', () {
      final action = loadYaml(read(actionPath)) as YamlMap;
      expect(action['name'], isNotNull);
      final runs = action['runs'] as YamlMap;
      expect(runs['using'], 'composite');
      final steps = runs['steps'] as YamlList;
      expect(steps, isNotEmpty);
      final body = read(actionPath);
      expect(
        body,
        contains('sqlite3_native_assets_prewarm.dart'),
        reason:
            'the action must invoke the shared prewarm script — a second '
            'implementation in YAML would drift from the tested contract',
      );
      expect(
        body,
        isNot(contains('releases/download')),
        reason:
            'the release URL pattern must live ONLY in the script (and the '
            'sqlite3 package itself) — a second URL pin in the action '
            'drifts from the hook the cached files must satisfy',
      );
    });

    test('AC2: the script carries the full safety contract', () {
      final body = read(scriptPath);
      expect(
        body,
        contains('asset_hashes.dart'),
        reason:
            'the pinned hashes must be parsed from the installed sqlite3 '
            'package itself — a second pin drifts the moment the '
            'lockfile/float moves the version',
      );
      expect(
        body,
        contains('releaseTag'),
        reason:
            'the download URL needs the release tag from the same '
            'pinned source',
      );
      expect(
        body,
        contains('download-'),
        reason:
            "the cache path must reuse the hook's "
            'download-<hash8> convention so the hook finds and reuses the '
            'prewarmed file instead of fetching',
      );
      expect(
        body,
        contains('statusCode'),
        reason:
            'gh-2072: the hook died because it piped a 504 error page into '
            'the output file with no status check — the prewarm must '
            'reject non-200 responses explicitly',
      );
      expect(
        body,
        contains('sha256'),
        reason:
            'the prewarm must verify the downloaded bytes against the '
            'pinned hash before caching — the same check that caught the '
            'v1.0.697 corruption, but before the hook ever sees the file',
      );
      expect(
        body,
        contains('.tmp'),
        reason:
            'downloads must land atomically (tmp then rename) — a torn '
            'download must never be visible at the cache path the hook '
            'reads',
      );
      expect(
        body,
        contains('for (var attempt'),
        reason:
            'the fetch must be bounded-retried — the whole point of the '
            'prewarm is that one transient 504 is not fatal (gh-2072)',
      );
      expect(
        body,
        contains('findProxyFromEnvironment'),
        reason:
            'the hook itself respects proxy environment variables; the '
            'prewarm must too or it breaks proxied runners',
      );
      expect(
        body,
        contains('connectionTimeout'),
        reason:
            'a stalled TCP connect must fail fast and engage the retry '
            'budget instead of riding the leg wall-clock timeout '
            '(gh-2072 review thread 9)',
      );
      expect(
        body,
        contains('requestTimeout'),
        reason:
            'every attempt must carry a per-request timeout — a hung '
            'connection (no 504, just a socket that never answers) must '
            'engage the bounded-retry budget, not park the step until '
            'the leg timeout kills it (gh-2072 review thread 9)',
      );
      expect(
        body,
        contains('client.close('),
        reason:
            'the HttpClient must be closed on EVERY path (success and '
            'failure) — android × N packages stacks one client per file '
            'per attempt, and a failure-path leak accumulates per leg '
            '(gh-2072 review thread 9)',
      );
    });

    for (final entry in sqlite3PrewarmJobs.entries) {
      final workflow = entry.key;
      for (final jobKey in entry.value) {
        test('AC3: $workflow $jobKey prewarms before its first '
            'hook-building step', () {
          final steps = jobSteps(workflow, jobKey);
          final signatures = signatureIndexes(steps);
          expect(
            signatures,
            isNotEmpty,
            reason:
                'precondition: $workflow $jobKey must contain a '
                'hook-building step (dart test/run/compile/build, flutter '
                'test/build, fastlane release, or matrix.cmd) — otherwise '
                'this map entry pins nothing and should be removed',
          );
          final prewarm = prewarmIndexes(steps);
          expect(
            prewarm,
            isNotEmpty,
            reason:
                '$workflow $jobKey builds the root package\'s native-assets '
                'hook (or compiles the app) without prewarming the sqlite3 '
                'prebuilt binaries — the hook then downloads them from '
                'GitHub releases in a single attempt with no status check, '
                'and one transient 504 error page reds the leg and the '
                'aggregate Quality gate (gh-2072). Add `uses: '
                '$prewarmAction` before the first hook-building step.',
          );
          for (final prewarmIndex in prewarm) {
            for (final signatureIndex in signatures) {
              expect(
                prewarmIndex,
                lessThan(signatureIndex),
                reason:
                    '$workflow $jobKey runs the sqlite3 prewarm AFTER a '
                    'hook-building step — the hook builds during that '
                    'step, so a later prewarm never applies',
              );
            }
          }
        });

        test('AC6: $workflow $jobKey prewarms after its pub get and '
            'under the same scope condition', () {
          final steps = jobSteps(workflow, jobKey);
          final pubGets = [
            for (var i = 0; i < steps.length; i++)
              if (RegExp(
                r'^\s*dart pub get\b',
              ).hasMatch('${(steps[i] as YamlMap)['run'] ?? ''}'))
                i,
          ];
          final prewarm = prewarmIndexes(steps);
          expect(
            prewarm,
            isNotEmpty,
            reason: 'AC3 already covers presence — this job lost it',
          );
          if (pubGets.isEmpty) {
            // The job resolves a NON-root package (flutter_app through
            // the flutter-pub-get action): the prewarm must name that
            // root explicitly — the `.` default reads a root
            // package_config.json that never exists here and hard-fails
            // (gh-2072 review threads 3/4: build-android/build-ios red'd
            // on the PR's own run exactly this way).
            for (final index in prewarm) {
              expect(
                declaredPackageRoots(steps[index] as YamlMap),
                isNotNull,
                reason:
                    '$workflow $jobKey runs no root `dart pub get` — its '
                    'prewarm must declare `package-roots:` with the '
                    'package root the job actually resolves '
                    '(flutter_app); the `.` default would hard-fail on '
                    'the missing root package config',
              );
            }
            return;
          }
          final firstPubGet = pubGets.first;
          final pubGetIf = '${(steps[firstPubGet] as YamlMap)['if'] ?? ''}';
          for (final index in prewarm) {
            expect(
              index,
              greaterThan(firstPubGet),
              reason:
                  '$workflow $jobKey runs the sqlite3 prewarm BEFORE its '
                  '`dart pub get` — the script reads '
                  '.dart_tool/package_config.json and hard-fails when '
                  'pub get has not produced it yet (gh-2072 review '
                  'thread 2: the fa-aot-build leg red exactly this way '
                  'on the PR\'s own run)',
            );
            if (pubGetIf.isNotEmpty) {
              expect(
                '${(steps[index] as YamlMap)['if'] ?? ''}',
                pubGetIf,
                reason:
                    '$workflow $jobKey scope-gates its pub get but runs '
                    'the prewarm unconditionally — on an out-of-scope PR '
                    'checkout/setup-dart/pub get are all skipped and the '
                    'prewarm must skip with them or it reds the '
                    'documented fastpass (gh-2072 review thread 5)',
              );
            }
          }
        });

        test('AC7: every $workflow $jobKey prewarm with explicit targets '
            'declares package-roots', () {
          final steps = jobSteps(workflow, jobKey);
          for (final index in prewarmIndexes(steps)) {
            final step = steps[index] as YamlMap;
            final withMap = step['with'];
            final targets = withMap is YamlMap
                ? '${withMap['targets'] ?? ''}'.trim()
                : '';
            if (targets.isEmpty || targets == 'auto') continue;
            expect(
              declaredPackageRoots(step),
              isNotNull,
              reason:
                  '$workflow $jobKey prewarm requests explicit targets '
                  '($targets) but leaves `package-roots:` at the `.` '
                  'default — every cross-target invocation in this repo '
                  'lives in a job that resolves ONLY flutter_app, so the '
                  'step hard-fails on the missing root package config '
                  '(gh-2072 review threads 3/4)',
            );
          }
        });

        final explicitKey = '${workflow.split('/').last}/$jobKey';
        final expectedTargets = explicitTargetJobs[explicitKey];
        if (expectedTargets != null) {
          test('AC5: $workflow $jobKey requests explicit targets '
              '($expectedTargets)', () {
            final steps = jobSteps(workflow, jobKey);
            final targets = [
              for (final step in steps.whereType<YamlMap>())
                if (step['uses'] == prewarmAction && step['with'] is YamlMap)
                  '${(step['with'] as YamlMap)['targets'] ?? ''}',
            ];
            expect(
              targets,
              isNotEmpty,
              reason:
                  '$explicitKey compiles for a non-host target — the '
                  'host-auto prewarm cannot provision those binaries. Pass '
                  "targets: $expectedTargets to the prewarm action",
            );
            expect(
              targets.any((t) => t.contains(expectedTargets)),
              isTrue,
              reason:
                  '$explicitKey must request targets: $expectedTargets — '
                  'the host-auto default provisions only the runner\'s own '
                  'platform, not the APK ABIs / iOS device binaries the '
                  'hook will ask for',
            );
          });
        }
      }

      test('AC3: $workflow references the prewarm action exactly '
          '(${entry.value.length} job(s))', () {
        final jobs = workflowRoot(workflow)['jobs'] as YamlMap;
        final usesCount = jobs.values
            .whereType<YamlMap>()
            .map((job) => job['steps'])
            .whereType<YamlList>()
            .expand((steps) => steps)
            .whereType<YamlMap>()
            .where((step) => step['uses'] == prewarmAction)
            .length;
        expect(
          usesCount,
          entry.value.length,
          reason:
              '$workflow must prewarm through `$prewarmAction` exactly '
              '${entry.value.length} time(s) — a count BELOW means a build '
              'job lost the prewarm in a refactor; ABOVE means a new site '
              'appeared that the sqlite3PrewarmJobs map must acknowledge '
              '(either way the guard, not the roulette, decides)',
        );
      });
    }

    test('AC4: the shared flutter-pub-get action ends with the central '
        'prewarm (nested composite call — one implementation)', () {
      final steps =
          (loadYaml(read(pubGetActionPath)) as YamlMap)['runs'] as YamlMap;
      final list = steps['steps'] as YamlList;
      final last = list.last as YamlMap;
      expect(
        last['uses'],
        prewarmAction,
        reason:
            'every flutter leg resolves flutter_app through '
            'flutter-pub-get (test/ci_pub_get_retry_guard_test.dart '
            'enforces that) — the central prewarm at the end of the action '
            'is what covers the flutter legs (flutter-tests, pty legs, '
            'build-macos, exzone, …) without per-job edits. The nested '
            'composite `uses` keeps ONE prewarm implementation for both '
            'callers (gh-2072 review thread 12: the duplicated inline '
            'copies had already drifted); best-effort semantics '
            '(continue-on-error + fallback to the hook\'s own download) '
            'live inside the composite itself (gh-2072 review thread 7)',
      );
    });
  });
}
