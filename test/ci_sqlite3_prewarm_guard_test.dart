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
//        action inside flutter_app (gh-2072 review threads 3/4),
//   AC8  every mapped prewarm's target VALUES resolve through the
//        script's own grammar (expandTargets → sourceFilenameForTarget)
//        — presence alone let the nightly android release row ride
//        97/97 green with the reversed <os>-<abi> grammar
//        `android-arm,android-arm64,android-x64` (gh-2072 review thread
//        14, round 2): AC5/AC8 resolve the matrix placeholder and pin
//        `arm-android,arm64-android,x64-android` + `arm64-ios`.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';
import '../scripts/sqlite3_native_assets_prewarm.dart'
    show expandTargets, hostTarget, sourceFilenameForTarget;

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
/// Flutter 3.22); iOS device builds are arm64. `nightly.yml/build-release`
/// reads `targets: ${{ matrix.sqlite3_targets }}` — AC5/AC8 resolve the
/// placeholder through `strategy.matrix.include` and pin the per-row
/// values (gh-2072 review thread 13, round 2: the android release row
/// rode 97/97 green with the reversed `<os>-<abi>` grammar until this pin).
const explicitTargetJobs = <String, List<String>>{
  'ci.yml/build-android': ['android'],
  'build-mobile.yml/build-android': ['android'],
  'build-mobile.yml/build-android-apks': ['android'],
  'build-mobile.yml/test-android-emulator': ['android'],
  'ci.yml/build-ios': ['arm64-ios'],
  'build-mobile.yml/build-ios': ['arm64-ios'],
  'nightly.yml/build-release': [
    'arm-android,arm64-android,x64-android',
    'arm64-ios',
  ],
};

YamlMap workflowRoot(String workflowPath) =>
    loadYaml(read(workflowPath)) as YamlMap;

YamlList jobSteps(String workflowPath, String jobKey) {
  final jobs = workflowRoot(workflowPath)['jobs'] as YamlMap;
  final job = jobs[jobKey] as YamlMap;
  return job['steps'] as YamlList;
}

/// The `sqlite3_targets` values of a job's `strategy.matrix.include` rows
/// (nightly build-release), or null when the job has no matrix — AC5/AC8
/// resolve the `${{ matrix.sqlite3_targets }}` placeholder through this.
List<String>? matrixSqlite3Targets(String workflowPath, String jobKey) {
  final job = (workflowRoot(workflowPath)['jobs'] as YamlMap)[jobKey];
  if (job is! YamlMap) return null;
  final strategy = job['strategy'];
  if (strategy is! YamlMap) return null;
  final matrix = strategy['matrix'];
  if (matrix is! YamlMap) return null;
  final include = matrix['include'];
  if (include is! YamlList) return null;
  return [
    for (final row in include.whereType<YamlMap>())
      if (row['sqlite3_targets'] != null) '${row['sqlite3_targets']}',
  ];
}

/// The `targets:` strings a mapped job's prewarms request — literal
/// `with.targets` values pass through; the `${{ matrix.sqlite3_targets }}`
/// placeholder (nightly build-release) resolves to every matrix row's
/// `sqlite3_targets`. `auto`/empty steps contribute nothing (AC8 is about
/// explicit-target values; AC6 already pins the host-auto wiring).
List<String> requestedTargetSpecs(String workflowPath, String jobKey) {
  final steps = jobSteps(workflowPath, jobKey);
  final matrixValues = matrixSqlite3Targets(workflowPath, jobKey);
  final out = <String>[];
  for (final step in steps.whereType<YamlMap>()) {
    if (step['uses'] != prewarmAction || step['with'] is! YamlMap) continue;
    final raw = '${(step['with'] as YamlMap)['targets'] ?? ''}'.trim();
    if (raw.isEmpty || raw == 'auto') continue;
    if (raw.contains(r'${{ matrix.')) {
      out.addAll(matrixValues ?? const <String>[]);
    } else {
      out.add(raw);
    }
  }
  return out;
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
                'flutter_app',
                reason:
                    '$workflow $jobKey runs no root `dart pub get` — its '
                    'prewarm must declare `package-roots:` with exactly '
                    'the root the job actually resolves (flutter_app, '
                    'via flutter-pub-get). Declaring the value is not '
                    'enough: a typo\'d root (or `.`) fails per-root and '
                    'the composite degrades the prewarm to a silent '
                    '::warning fallback (gh-2072 review round 3, thread '
                    '17; round 2 threads 3/4 wired the value in)',
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
              'flutter_app',
              reason:
                  '$workflow $jobKey prewarm requests explicit targets '
                  '($targets) but does not point `package-roots:` at '
                  'exactly the root the job resolves — every '
                  'cross-target invocation in this repo lives in a '
                  'flutter_app-only job (via flutter-pub-get), and a '
                  'wrong value fails per-root while the composite '
                  'degrades the prewarm to a silent ::warning fallback '
                  '(gh-2072 review round 3, thread 17; round 2 threads '
                  '3/4 wired the value in)',
            );
          }
        });

        final explicitKey = '${workflow.split('/').last}/$jobKey';
        final expectedTargets = explicitTargetJobs[explicitKey];

        // AC8 (gh-2072 review thread 14 — round 2): the guard must
        // validate target VALUES, not just their presence — the nightly
        // android release row rode AC3/AC5/AC6/AC7 97/97 green with
        // `android-arm,android-arm64,android-x64`, the reversed
        // `<os>-<abi>` grammar the script rejects: every target failed
        // per-target, the composite's continue-on-error downgraded it to
        // a ::warning, and the store-APK release build silently stayed on
        // the unprotected hook download. Importing the script's own
        // resolver keeps this test and the script in one grammar.
        test('AC8: every $workflow $jobKey prewarm target value expands '
            'to a release asset the script can download', () {
          for (final spec in requestedTargetSpecs(workflow, jobKey)) {
            for (final target in expandTargets(
              spec,
              hostTarget: hostTarget(),
            )) {
              expect(
                () => sourceFilenameForTarget(target),
                returnsNormally,
                reason:
                    '$workflow $jobKey requests target "$target" '
                    '(from "$spec") which the prewarm script cannot '
                    'resolve to a release asset — every such target '
                    'fails per-target and the composite\'s '
                    'continue-on-error silently falls back to the '
                    'hook\'s single-attempt download (gh-2072 review '
                    'thread 13: the nightly android row used the '
                    'reversed <os>-<abi> grammar)',
              );
            }
          }
        });

        if (expectedTargets != null) {
          test('AC5: $workflow $jobKey requests explicit targets '
              '(${expectedTargets.join(', ')})', () {
            final targets = requestedTargetSpecs(workflow, jobKey);
            expect(
              targets,
              isNotEmpty,
              reason:
                  '$explicitKey compiles for a non-host target — the '
                  'host-auto prewarm cannot provision those binaries. '
                  'Pass targets: ${expectedTargets.join(', ')} to the '
                  'prewarm action',
            );
            expect(
              // Every expected value must be covered by some requested
              // spec — `any` over the specs would let a single valid ios
              // row mask an invalid android row (exactly the round-2
              // nightly defect shape).
              expectedTargets.every(
                (expected) => targets.any((t) => t.contains(expected)),
              ),
              isTrue,
              reason:
                  '$explicitKey must request targets: '
                  '${expectedTargets.join(', ')} — the host-auto default '
                  'provisions only the runner\'s own platform, not the '
                  'APK ABIs / iOS device binaries the hook will ask for '
                  '(gh-2072 review thread 13: the nightly android row '
                  'read the reversed grammar and provisioned nothing)',
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

    // gh-2105 — the release-train legs in build-macos.yml still rode the
    // OLD prewarm (scripts/sqlite3_hook_prewarm.dart: 3 attempts × 60s +
    // 15s sleeps ≈ 3.5 min of coverage) when the v1.0.697 egress storm
    // (5+ minutes of 504/error pages — every failed job carries the same
    // constant bogus digest bef140a1…) red'd Build CLI bundle arm64 on
    // the raw 504 and both desktop matrix legs ~20 min in on the hook's
    // digest mismatch. The green extension leg minted the tag + staging
    // draft, the failed train never published it, and the daily sweeper
    // deleted it a day later (gh-2105). Every hosted leg was hardened
    // post-incident (gh-2072/2074/2075: 8-attempt ≈ 10 min composite
    // contract); these pins keep the RELEASE legs on the same contract,
    // so the same storm cannot re-strand a draft through them.
    group('gh-2105 — build-macos.yml release legs ride the hardened prewarm', () {
      const wf = '.github/workflows/build-macos.yml';

      test(
        'build-macos-cli prewarms through the shared composite between pub '
        'get and its first dart build, with per-arch targets the script '
        'can resolve',
        () {
          final steps = jobSteps(wf, 'build-macos-cli');
          final prewarm = [
            for (var i = 0; i < steps.length; i++)
              if ((steps[i] as YamlMap)['uses'] == prewarmAction) i,
          ];
          expect(
            prewarm,
            isNotEmpty,
            reason:
                'build-macos-cli runs `dart build cli` on a root package '
                'graph carrying sqlite3 (via flutter_agent_memory) — the '
                'hook downloads its prebuilt dylib in a single attempt '
                'with no status check; one 504 error page reds the leg '
                '(gh-2075, run 42566734746) and the stranded-draft shape '
                'of gh-2105 re-arms. Add `uses: $prewarmAction`.',
          );
          final pubGet = [
            for (var i = 0; i < steps.length; i++)
              if (RegExp(
                r'^\s*dart pub get\b',
              ).hasMatch('${(steps[i] as YamlMap)['run'] ?? ''}'))
                i,
          ].first;
          final firstBuild = [
            for (var i = 0; i < steps.length; i++)
              if (hookBuildingSignatures.any(
                (re) => re.hasMatch('${(steps[i] as YamlMap)['run'] ?? ''}'),
              ))
                i,
          ].first;
          expect(
            prewarm.first,
            greaterThan(pubGet),
            reason:
                'the prewarm reads .dart_tool/package_config.json and '
                'hard-fails before `dart pub get` has produced it',
          );
          expect(
            prewarm.first,
            lessThan(firstBuild),
            reason:
                'the prewarm must land in the hook cache BEFORE the first '
                'hook-building step — a later prewarm never applies',
          );
          final step = steps[prewarm.first] as YamlMap;
          final withMap = step['with'];
          expect(
            withMap,
            isA<YamlMap>(),
            reason: 'the composite invocation must pass `with:` inputs',
          );
          // The CLI legs build the ROOT package graph (dart build cli at
          // the repo root) — the root is the correct package-roots value
          // here, but it must be DECLARED: explicit targets never ride a
          // silent default (the AC7 doctrine).
          expect(
            '${(withMap as YamlMap)['package-roots'] ?? ''}'.trim(),
            '.',
            reason:
                'build-macos-cli resolves the root package (dart pub get '
                'at the repo root) — declare package-roots: . explicitly '
                'next to the explicit targets',
          );
          final targets = '${withMap['targets'] ?? ''}'.trim();
          expect(
            targets,
            contains('matrix.arch'),
            reason:
                'the two matrix legs (arm64/x64) build different macOS '
                'dylibs — a fixed target provisions one arch and leaves '
                'the other on the bare hook download',
          );
          // Resolve the matrix placeholder for BOTH rows and validate the
          // values through the script's own grammar (AC8 doctrine): the
          // <abi>-<os> order, not the reversed <os>-<abi> the nightly
          // android row rode green with (gh-2072 review thread 14).
          for (final arch in ['arm64', 'x64']) {
            final resolved = targets.replaceAll(
              RegExp(r'\$\{\{\s*matrix\.arch\s*\}\}'),
              arch,
            );
            for (final target in expandTargets(
              resolved,
              hostTarget: hostTarget(),
            )) {
              expect(
                () => sourceFilenameForTarget(target),
                returnsNormally,
                reason:
                    'targets value "$target" (from "$targets", arch '
                    '$arch) is not a target the prewarm script can '
                    'download — it would fail per-target and the '
                    'composite degrades to the bare hook download',
              );
            }
          }
        },
      );

      test(
        'desktop build step prewarms post-clean with the hardened script '
        'and the composite retry budget',
        () {
          final steps = jobSteps(wf, 'build-macos');
          final runText = [
            for (final step in steps.whereType<YamlMap>())
              if ('${step['name'] ?? ''}'.startsWith('Build macOS release'))
                '${step['run'] ?? ''}',
          ].first;
          expect(
            runText,
            contains('sqlite3_native_assets_prewarm.dart'),
            reason:
                'the desktop release build must prewarm through the '
                'hardened script (status-gated, exponential backoff, '
                'per-request timeouts) — the old '
                'sqlite3_hook_prewarm.dart budget (3 attempts ≈ 3.5 min) '
                'did not cover the 5+ minute v1.0.697 storm and the leg '
                'red ~20 min into the build on the hook digest mismatch '
                '(gh-2105 RCA, run 42566734746)',
          );
          expect(
            runText,
            isNot(contains('sqlite3_hook_prewarm.dart')),
            reason:
                'the retired 3-attempt script must not come back on the '
                'release legs — its budget is below the measured storm '
                'duration',
          );
          expect(
            runText,
            contains('--attempts 8'),
            reason:
                'the composite contract passes attempts: 8 (≈ 10 min of '
                'coverage with the exponential backoff) — the v1.0.697 '
                'storm was 5+ minutes; the script default (4) does not '
                'cover it',
          );
          expect(
            runText,
            contains('RUNNER_TEMP'),
            reason:
                'the script must be copied OUT of the workspace before '
                'invocation — a plain dart <path> inside flutter_app '
                'builds the package graph\'s own hooks BEFORE main(), '
                'i.e. performs the exact single-attempt download this '
                'step exists to bypass (the composite does the same '
                'copy)',
          );
          expect(
            runText,
            contains('::warning::'),
            reason:
                'best-effort semantics (gh-2072 review thread 7): a '
                'failed prewarm degrades to the hook\'s own '
                'single-attempt download, never reds the leg by itself',
          );
          // Post-clean position is load-bearing: this step's
          // `flutter clean` wipes .dart_tool — including the
          // flutter-pub-get prewarm's warmed cache — so THIS invocation
          // must re-warm AFTER the clean or the hook re-downloads bare.
          expect(
            runText.indexOf('flutter clean'),
            lessThan(
              runText.indexOf('sqlite3_native_assets_prewarm.dart'),
            ),
            reason:
                'the prewarm must run AFTER `flutter clean` — the clean '
                'wipes the hooks_runner cache and a pre-warmed-but-then-'
                'wiped cache is the bare download again',
          );
          expect(
            runText.indexOf('cd flutter_app'),
            lessThan(
              runText.indexOf('sqlite3_native_assets_prewarm.dart'),
            ),
            reason:
                'the prewarm must resolve flutter_app (the desktop build '
                'compiles its graph, whose lockfile pins sqlite3) — run '
                'it from the flutter_app working directory',
          );
          expect(
            runText,
            contains('-macos'),
            reason:
                'the desktop build targets macOS — the prewarm must '
                'request the macOS dylib in the script\'s <abi>-<os> '
                'grammar (arm64-macos / x64-macos), not a host-auto '
                'guess that can drift from the build arch',
          );
        },
      );

      test('build-macos.yml no longer references the retired prewarm '
          'script', () {
        expect(
          read(wf),
          isNot(contains('sqlite3_hook_prewarm.dart')),
          reason:
              'both call sites must ride the hardened contract '
              '(composite for build-macos-cli, the hardened script '
              'in-run for the post-clean desktop prewarm) — one leg '
              'staying on the 3-attempt budget is a leg the same storm '
              'can still red',
        );
      });
    });
  });
}
