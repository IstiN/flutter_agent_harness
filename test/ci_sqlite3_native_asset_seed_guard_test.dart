// gh-2075 — the macOS release builds must never depend on the package:sqlite3
// build hook's single un-retried build-time download.
//
// CI run 42566734746 (daily-publish cli leg, 2026-11-09) red'd ALL THREE
// macOS jobs on the same request class:
//
//   sqlite3 ≥3.7 ships a native-assets build hook (hook/build.dart →
//   PrecompiledFromGithubAssets) that fetches the prebuilt libsqlite3
//   dylib from the package's GitHub release at BUILD time — one HTTP GET,
//   no retry, no cache seeding, mid-build:
//   - Build macOS CLI arm64 (`dart build cli`): "Unexpected response
//     code: 504 Gateway Time-out" → `Running build hooks failed`, exit
//     255 (the bundle never got built),
//   - Build macOS arm64 / x86_64 (flutter build macos --release, the
//     Flutter Assemble phase, ~20 min into the build): the download
//     returned HTTP 200 with the SAME wrong body for BOTH distinct arch
//     assets (sha256 bef140a1a… for arm64 AND x64 — a middlebox error
//     page), caught by the hook's own digest pin: "Bad state: Hash of
//     downloaded file … is bef140a1a…, expected 649fdf22…/5b956194…" →
//     `** BUILD FAILED **`.
//
// Upstream assets verified intact post-incident (the sqlite3-3.7.0 and
// sqlite3-3.9.1 release dylibs hash-match the package-pinned digests) —
// pure transport flake one un-retried request, the same egress class
// gh-1759 solved for the WasmRun.xcframework download (bounded curl
// retries + pinned sha256 + purge on mismatch) and gh-1644 for the git
// mirrors. A red release run is triaged structurally, never quarantined
// as a flake (AGENTS.md / gh-1537).
//
// The sqlite3 hook has a digest-checked cache at a STABLE path —
// `<workspace>/.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/`
// (hooks_runner resolves `shared/<package>/build/`, NOT a per-input-hash
// dir) — and reuses a present file ONLY when its sha256 matches the
// package-pinned digest, else re-downloads (PrecompiledBinary
// .downloadIntoOutputDirectoryShared). Seding that cache is therefore
// integrity-neutral: a wrong file is never trusted, the hook falls back
// to its own download. The seed reads version + release tag + pinned
// hashes from the INSTALLED package's lib/src/hook/asset_hashes.dart —
// no hashes pinned in the workflow, a lockfile bump self-updates.
//
// Deliberately YAML-level asserts (the ci_core_shard_upload_retry_guard_test
// .dart / ci_pub_get_retry_guard_test.dart static pattern):
//  AC1  the app build step seeds the sqlite3 hook cache AFTER the
//       min-platform gate and BEFORE `flutter build macos --release`
//       (the seed must run post-`flutter clean`, post-config —
//       .dart_tool exists there — and every arch of the matrix gets the
//       seed with the x86_64 → x64 asset-arch mapping),
//  AC2  the CLI matrix legs seed AFTER `dart pub get` and BEFORE
//       `dart build cli` (both archs — the 504 killed the bundle leg
//       first, and it is the cheapest place to fail loud),
//  AC3  the seed script carries the gh-1759 WasmRun recipe: `curl --fail`,
//       bounded attempts (loop), per-attempt `--max-time`, sha256 verify
//       against the package-pinned digest before install, purge on
//       mismatch, warm-cache skip (a hash-valid cached file skips the
//       download), and reads the pinned hashes from the installed
//       package's asset_hashes.dart — never literals in the script,
//  AC4  the selftest drives the REAL script (not a copy) through the
//       incident scenarios with a fault-injected curl: retry recovery
//       after transient failures, wrong-content purge (the bef140a1a
//       signature), warm-cache skip, missing-sqlite3 fail-loud, and
//       attempt-exhaustion failing loudly — and the guard runs it,
//  AC5  no workflow step in build-macos.yml downloads sqlite3 assets by
//       literal URL — the only sqlite3 download path is the seed script
//       (a future bare `curl .../libsqlite3` in a run step is a test red).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const workflow = '.github/workflows/build-macos.yml';
const script = 'scripts/seed_sqlite3_native_assets.sh';
const selftest = 'scripts/seed_sqlite3_native_assets_selftest.sh';

List<YamlMap> jobSteps(YamlMap root, String jobId) {
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[jobId];
  if (job is! YamlMap) throw StateError('job $jobId missing from $workflow');
  return (job['steps'] as YamlList).whereType<YamlMap>().toList();
}

String runOf(YamlMap step) => (step['run'] ?? '').toString();

/// Flattened multiline text of a step — run body, or `with:`/`uses:` for
/// composite steps (the static pattern's "does this step reference X").
String stepText(YamlMap step) {
  final buf = StringBuffer()
    ..writeln(runOf(step))
    ..writeln((step['working-directory'] ?? '').toString());
  final with_ = step['with'];
  if (with_ is YamlMap) with_.forEach((k, v) => buf.writeln('$k: $v'));
  return buf.toString();
}

final YamlMap root = loadYaml(read(workflow)) as YamlMap;

void main() {
  group('gh-2075 AC1 — app build step seeds the sqlite3 hook cache', () {
    final steps = jobSteps(root, 'build-macos');

    test('the build step invokes the seed script', () {
      final build = steps
          .where((s) => (s['name'] ?? '').toString().startsWith('Build macOS release'))
          .toList();
      expect(build, hasLength(1), reason: 'the release build step must exist');
      expect(
        runOf(build.single),
        contains('seed_sqlite3_native_assets.sh'),
        reason: 'the release build step must seed the hook cache '
            '(the hook runs inside `flutter build macos --release`)',
      );
    });

    test('seed runs after the min-platform gate, before the release build', () {
      // Steps AND the lines inside a step, in order — the gate and the
      // seed intentionally share the release build step (the seed must
      // run inside it: `flutter clean` wipes .dart_tool mid-step).
      final combined = StringBuffer();
      for (final step in steps) {
        combined
          ..writeln(runOf(step))
          ..writeln((step['working-directory'] ?? '').toString());
      }
      final text = combined.toString();
      final gate = text.indexOf('assert_macos_min_platform');
      final seed = text.indexOf('seed_sqlite3_native_assets.sh');
      final release = text.indexOf('flutter build macos --release');
      expect(gate, greaterThanOrEqualTo(0), reason: 'gate step must exist');
      expect(release, greaterThanOrEqualTo(0), reason: 'release build must exist');
      expect(
        seed, greaterThan(gate),
        reason: 'seed must run after `flutter clean` + the config-only pass '
            'wiped/recreated .dart_tool — seeding earlier is wiped away',
      );
      expect(
        seed, lessThan(release),
        reason: 'seed must run BEFORE the release build — the hook downloads '
            'mid-build (the gh-2075 failure landed ~20 min into the build)',
      );
    });

    test('both matrix archs are seeded with the x86_64 → x64 asset mapping', () {
      final build = steps
          .where((s) => (s['name'] ?? '').toString().startsWith('Build macOS release'))
          .single;
      final run = runOf(build);
      expect(
        run, contains('x86_64'),
        reason: 'the matrix arch is x86_64; the release asset is named '
            'libsqlite3.x64.macos.dylib — the x86_64 → x64 mapping (the '
            'size-manifest step idiom) must be applied before seeding',
      );
      expect(
        run, contains('SQLITE_SEED_ARCH'),
        reason: 'the mapped arch must go through a variable — seeding the '
            'raw matrix arch would request an asset that does not exist',
      );
    });
  });

  group('gh-2075 AC2 — CLI bundle legs seed before dart build cli', () {
    final steps = jobSteps(root, 'build-macos-cli');

    test('a seed step runs the script for the matrix arch', () {
      final seeds = steps
          .map(stepText)
          .where((t) => t.contains('seed_sqlite3_native_assets.sh'))
          .toList();
      expect(seeds, hasLength(1), reason: 'exactly one seed step in the CLI job');
      expect(seeds.single, contains('macos'), reason: 'the CLI targets macOS');
    });

    test('seed runs after pub get, before dart build cli', () {
      final texts = steps.map(stepText).toList();
      final pubGet = texts.indexWhere((t) => t.contains('dart pub get'));
      final seed = texts.indexWhere((t) => t.contains('seed_sqlite3_native_assets.sh'));
      final build = texts.indexWhere((t) => t.contains('dart build cli'));
      expect(pubGet, greaterThanOrEqualTo(0));
      expect(
        seed, greaterThan(pubGet),
        reason: 'the seed resolves sqlite3 from .dart_tool/package_config.json '
            '— it needs the pub resolution first',
      );
      expect(
        seed, lessThan(build),
        reason: '`dart build cli` triggers the hook download — the 504 class '
            'must be caught in the seed (seconds, retried), never mid-build',
      );
    });
  });

  group('gh-2075 AC3 — the seed script carries the WasmRun download recipe', () {
    final body = read(script);

    test('the script exists and is executable', () {
      expect(File(script).existsSync(), isTrue);
      // 0o111 == 73: owner/group/other execute bits (the sandbox Dart SDK
      // rejects 0o octal literals, so the mask is spelled in decimal).
      final mode = File(script).statSync().mode;
      expect(mode & 73, isNot(0), reason: 'bash scripts in scripts/ are +x');
    });

    test('curl runs with --fail (a 5xx must engage the retry loop)', () {
      expect(body, contains('--fail'), reason: 'gh-1759: without --fail, curl '
          'exits 0 on HTTP errors and writes the error page into the output');
    });

    test('the download is bounded (attempt loop + per-attempt wall cap)', () {
      expect(body, contains('--max-time'), reason: 'per-attempt wall cap');
      expect(body, matches(RegExp(r'for\s+\w+\s+in\s+')), reason: 'attempt loop');
    });

    test('the downloaded bytes are sha256-pinned before install', () {
      expect(body, contains('sha256'), reason: 'verify against the pinned digest');
      expect(
        body, contains('asset_hashes.dart'),
        reason: 'version + release tag + hashes come from the INSTALLED '
            'package — no literals pinned in the script, a lockfile bump '
            'self-updates',
      );
    });

    test('wrong content is purged, never installed', () {
      expect(
        body, contains('::error::'),
        reason: 'digest mismatch / exhausted attempts fail LOUD with a named '
            'annotation — the gh-2075 failure must surface here in seconds, '
            'not ~20 min into the build',
      );
      expect(
        body, matches(RegExp(r'rm -f')),
        reason: 'a hash-mismatched download is purged before install '
            '(the WasmRun digest-purge precedent)',
      );
    });

    test('a hash-valid cached file skips the download (warm path)', () {
      expect(
        body, contains('already cached'),
        reason: 'the hook cache persists across builds in the same job '
            '(release + no-sandbox build share the workspace); re-downloading '
            'a warm cache would re-expose every build to the egress flake',
      );
    });

    test('seeds the stable hooks_runner shared cache path', () {
      expect(
        body, contains('hooks_runner/shared/sqlite3/build'),
        reason: 'the hook cache is shared/<package>/<hook>/ under '
            '.dart_tool/hooks_runner — a per-input-hash path can not be '
            'seeded (its name is a config checksum)',
      );
    });

    test('requires package resolution first (package_config.json gate)', () {
      expect(
        body, contains('package_config.json'),
        reason: 'the seed resolves the installed sqlite3 from the workspace '
            'package config; a missing one must fail loud, not silently skip',
      );
    });
  });

  group('gh-2075 AC4 — the selftest drives the real script', () {
    test('the selftest exists and exercises the real script', () {
      expect(File(selftest).existsSync(), isTrue);
      final body = read(selftest);
      expect(
        body, contains('seed_sqlite3_native_assets.sh'),
        reason: 'the selftest runs the REAL script (update_git_mirror_selftest '
            'pattern) — never a copy that can drift',
      );
    });

    test('the selftest pins the incident scenarios', () {
      final body = read(selftest);
      expect(body, contains('fault'), reason: 'fault-injected curl shim — '
          'the selftest must be hermetic, no real egress');
      // T-matrix: transient failure recovery, wrong-content purge,
      // warm-cache skip, missing-dependency fail-loud, exhaustion.
      expect(body, contains('RETRY'), reason: 'transient 504-class recovery');
      expect(body, contains('GARBAGE'), reason: 'the bef140a1a wrong-body signature');
      expect(body, contains('WARM'), reason: 'warm-cache skip');
      expect(body, contains('MISSING'), reason: 'missing sqlite3 fail-loud');
      expect(body, contains('EXHAUST'), reason: 'attempts exhausted → loud red');
    });

    test('the guard runs the selftest', () {
      final result = Process.runSync('bash', [selftest]);
      final out = '${result.stdout}${result.stderr}';
      expect(
        result.exitCode, 0,
        reason: 'selftest must pass: ${result.exitCode}\n$out',
      );
      expect(out, contains('PASS'), reason: 'scenario verdicts are visible');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('gh-2075 AC5 — no literal sqlite3 download URLs in workflow steps', () {
    test('build-macos.yml never fetches libsqlite3 by literal URL', () {
      final rootText = read(workflow);
      expect(
        RegExp(r'libsqlite3\.[a-z0-9]+\.macos\.dylib').allMatches(rootText),
        isEmpty,
        reason: 'the ONLY sqlite3 download path is the seed script, which '
            'derives the asset name + pinned hash from the installed package '
            '— a literal URL in the workflow re-creates the un-pinned '
            'download gh-2075 exists to remove',
      );
    });
  });
}
