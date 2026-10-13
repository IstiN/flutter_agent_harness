// gh-1468 rework — the ci.yml `build-android` leg went red on a transient
// HTTP 500 from the github.com release-asset CDN: the
// flutter_gemma_litertlm native-assets build hook downloads
// `litertlm-android_arm64.tar.gz` during `flutter build apk`, one CDN
// 500 killed the hook ("Bad state: flutter_gemma: could not download
// litertlm native libs for android_arm64 — HTTP 500"), and the aggregate
// Quality gate reddened on the platform leg. The hook has a real
// filesystem cache — on Linux `$HOME/.cache/flutter_gemma/native/
// android_arm64/` plus the `.flutter_gemma_native_version` marker: once
// `libLiteRtLm.so` and a matching marker are in place, `_resolveLibDir`
// short-circuits and NO download happens. The macOS legs already pre-seed
// their companion dylibs ("Ensure flutter_gemma macOS companion dylibs",
// ci.yml/build-macos.yml/nightly.yml); every Android build job had no
// equivalent and rode the release-asset roulette bare.
//
// Deliberately YAML-level asserts (the ci_pub_get_retry_guard_test.dart
// static pattern — a future bare Android build job must red here, not
// silently re-enter the roulette):
//  AC1  the shared composite action exists, is composite, downloads the
//       pinned archive with bounded retry, sha256-verifies it, and writes
//       the {version, owner} marker the hook's _guardAndCheckPresent
//       reads (owner must equal the hook's _packageName so the pre-seeded
//       cache keeps a single registrant),
//  AC2  every CI job that builds an Android APK/AAB seeds through the
//       action BEFORE its flutter/fastlane build step, and
//  AC3  the action's pinned version + checksum match the
//       flutter_gemma_litertlm hook's registered values when flutter_app's
//       package config resolves the package (a flutter_gemma bump must
//       update both sides together, like the CRAP badge/config sync
//       guard); a named skip line is printed when the hook source is not
//       resolvable in this environment.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const seedAction = './.github/actions/flutter-gemma-android-seed';
const actionPath = '.github/actions/flutter-gemma-android-seed/action.yml';

/// The pinned LiteRT-LM native bundle — must equal the hook's
/// _litertlmBundle registration in the pinned flutter_gemma_litertlm
/// (hook/build.dart). AC3 cross-checks both sides when the package source
/// is resolvable; a bump of the flutter_gemma pin must move these
/// constants and the action TOGETHER.
const expectedVersion = '0.17.1-a';
const expectedChecksum =
    '745b89b606eb712a78f06aed41daca1370eae79b00e0a36054c8e775c0251768';

/// Every (workflow, job) that builds an Android APK/AAB for the app. The
/// gh-1310 lesson: the network-roulette fix must cover the whole class —
// the release path (build-mobile.yml) and nightly (build-release matrix)
/// hit the same hook download the PR leg did.
const androidBuildJobs = {
  '.github/workflows/ci.yml': ['build-android'],
  '.github/workflows/build-mobile.yml': ['build-android', 'build-android-apks'],
  '.github/workflows/nightly.yml': ['build-release'],
};

/// Run-step signatures that mean "this step compiles the Android app" —
/// the seed must run before any of them in the same job. `matrix.cmd`
/// covers nightly's build-release matrix, where the per-row command
/// (`cmd: flutter build apk --flavor store --release` on the android row)
/// is interpolated at job level.
final androidBuildSignatures = [
  RegExp(r'flutter build (apk|appbundle)\b'),
  RegExp(r'fastlane android build_release\b'),
  RegExp(r'matrix\.cmd'),
];

YamlList jobSteps(String workflowPath, String jobKey) {
  final root = loadYaml(read(workflowPath)) as YamlMap;
  final job = (root['jobs'] as YamlMap)[jobKey] as YamlMap;
  return job['steps'] as YamlList;
}

void main() {
  group('gh-1468 — Android builds pre-seed the flutter_gemma native cache', () {
    test('AC1: the seed action exists and is composite', () {
      final action = loadYaml(read(actionPath)) as YamlMap;
      expect(action['name'], isNotNull);
      final runs = action['runs'] as YamlMap;
      expect(runs['using'], 'composite');
      expect(runs['steps'], isA<YamlList>());
    });

    test('AC1: the seed pins version, checksum, and bounded retry', () {
      final body = read(actionPath);
      expect(
        body,
        contains('native-v$expectedVersion/litertlm-android_arm64.tar.gz'),
        reason:
            'the seed must fetch the exact archive the pinned '
            'flutter_gemma_litertlm hook registers (native-v'
            '$expectedVersion) — a different tag is a skewed cache '
            'the hook will wipe and re-download (or worse, conflict '
            'on via the marker owner guard)',
      );
      expect(body, contains(expectedChecksum));
      expect(
        body,
        contains('sha256sum -c'),
        reason:
            'a retry that never verifies the bytes just re-races the '
            'same corrupt-CDN scenario the checksum exists to catch '
            '(gh-1468: HTTP 500 from the release-asset CDN)',
      );
      expect(body, contains('--retry 3'));
      expect(
        body,
        contains('--retry-all-errors'),
        reason:
            'curl retries only transient errors by default; HTTP 500 '
            'from a release-asset CDN edge is exactly the class that '
            'needs --retry-all-errors (same hardening as the macOS '
            'companion-dylibs step)',
      );
    });

    test('AC1: the seed writes the hook marker with the hook owner', () {
      final body = read(actionPath);
      expect(body, contains(r'$HOME/.cache/flutter_gemma/native'));
      expect(body, contains('.flutter_gemma_native_version'));
      expect(body, contains(expectedVersion));
      // The marker owner must equal the hook's _packageName: with the
      // owner recorded as flutter_gemma_litertlm the hook remains the
      // registrant of the shared CodeAssets (a foreign owner would make
      // it a non-owner dedup and the dylib would never be bundled —
      // the orphaned-owner edge case documented in hook/build.dart).
      expect(body, contains('flutter_gemma_litertlm'));
    });

    for (final entry in androidBuildJobs.entries) {
      final workflow = entry.key;
      for (final jobKey in entry.value) {
        test('AC2: $workflow $jobKey seeds before its Android build step', () {
          final steps = jobSteps(workflow, jobKey);
          final buildIndexes = <int>[];
          final seedIndexes = <int>[];
          for (var i = 0; i < steps.length; i++) {
            final step = steps[i] as YamlMap;
            if (step['uses'] == seedAction) seedIndexes.add(i);
            final run = step['run'];
            if (run is String &&
                androidBuildSignatures.any((re) => re.hasMatch(run))) {
              buildIndexes.add(i);
            }
          }
          expect(
            buildIndexes,
            isNotEmpty,
            reason:
                'precondition: $workflow $jobKey must contain an '
                'Android build step, otherwise this guard pins nothing',
          );
          expect(
            seedIndexes,
            isNotEmpty,
            reason:
                '$workflow $jobKey builds an Android APK/AAB without '
                'seeding the flutter_gemma native cache — the hook '
                'then downloads litertlm-android_arm64.tar.gz mid-build, '
                'and one release-asset CDN 500 reds the leg and the '
                'aggregate Quality gate (gh-1468). Add `uses: '
                '$seedAction` before the build step.',
          );
          for (final buildIndex in buildIndexes) {
            for (final seedIndex in seedIndexes) {
              expect(
                seedIndex,
                lessThan(buildIndex),
                reason:
                    '$workflow $jobKey runs the seed action AFTER its '
                    'Android build step — the hook resolves the cache '
                    'at build time, so a post-build seed never applies',
              );
            }
          }
        });
      }

      test('AC3: $workflow references the seed action exactly '
          '(${androidBuildJobs[workflow]!.length} job(s))', () {
        final root = loadYaml(read(workflow)) as YamlMap;
        final jobs = root['jobs'] as YamlMap;
        final usesCount = jobs.values
            .whereType<YamlMap>()
            .map((job) => job['steps'])
            .whereType<YamlList>()
            .expand((steps) => steps)
            .whereType<YamlMap>()
            .where((step) => step['uses'] == seedAction)
            .length;
        expect(
          usesCount,
          androidBuildJobs[workflow]!.length,
          reason:
              '$workflow must seed through `$seedAction` exactly '
              '${androidBuildJobs[workflow]!.length} time(s) — a count '
              'BELOW means a build job lost the seed in a refactor; '
              'ABOVE means a new site appeared that the '
              'androidBuildJobs map must acknowledge (either way the '
              'guard, not the roulette, decides)',
        );
      });
    }

    test('AC3: the pinned version+checksum match the '
        'flutter_gemma_litertlm hook registration', () {
      final packageConfigFile = File(
        'flutter_app/.dart_tool/package_config.json',
      );
      if (!packageConfigFile.existsSync()) {
        print(
          'SKIP (named): flutter_app/.dart_tool/package_config.json not '
          'present — the hook source is unresolvable here; falling back '
          'to the pinned constants only',
        );
        return;
      }
      final packageConfig =
          jsonDecode(packageConfigFile.readAsStringSync())
              as Map<String, dynamic>;
      final packages = packageConfig['packages'] as List<dynamic>;
      final litertlm = packages
          .whereType<Map<String, dynamic>>()
          .where((p) => p['name'] == 'flutter_gemma_litertlm')
          .firstOrNull;
      if (litertlm == null) {
        print(
          'SKIP (named): flutter_gemma_litertlm not in flutter_app\'s '
          'package config — the pin moved; the pinned constants above '
          'are the only source',
        );
        return;
      }
      var rootUri = Uri.parse(litertlm['rootUri'] as String);
      // package_config rootUri may omit the trailing slash (treated as a
      // file path — resolving against it would drop the package segment).
      if (!rootUri.path.endsWith('/')) {
        rootUri = rootUri.replace(path: '${rootUri.path}/');
      }
      final packageRoot = packageConfigFile.parent.uri.resolveUri(rootUri);
      final hookFile = File.fromUri(packageRoot.resolve('hook/build.dart'));
      if (!hookFile.existsSync()) {
        print(
          'SKIP (named): ${hookFile.path} missing — the package layout '
          'changed; the pinned constants above are the only source',
        );
        return;
      }
      final hook = hookFile.readAsStringSync();

      // The bundle registration block carries `version: '...'` first.
      final bundleBlock = hook.split('const _litertlmBundle').last;
      final version = RegExp(
        r"version: '([^']+)'",
      ).firstMatch(bundleBlock)?.group(1);
      expect(
        version,
        expectedVersion,
        reason:
            'the workflow seed pins native-v$expectedVersion but the '
            'resolved flutter_gemma_litertlm hook registers version '
            '"$version" — a flutter_gemma bump must update the action '
            'AND this guard TOGETHER, or the seeded cache is wiped as '
            'stale on every build (and re-downloaded mid-build: the '
            'roulette is back)',
      );
      final checksum = RegExp(
        r"'litertlm-android_arm64\.tar\.gz':\s*'([0-9a-f]{64})'",
      ).firstMatch(hook)?.group(1);
      expect(
        checksum,
        expectedChecksum,
        reason:
            'the workflow seed sha256 must equal the hook\'s registered '
            'checksum for litertlm-android_arm64.tar.gz — the hook '
            'verifies downloads against it, so a drifted seed either '
            'fails verification or seeds bytes the hook would reject',
      );
    });
  });
}
