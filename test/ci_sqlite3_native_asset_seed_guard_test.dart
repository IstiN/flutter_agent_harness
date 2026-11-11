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
// pure transport flake, one un-retried request. A red release run is
// triaged structurally, never quarantined as a flake (AGENTS.md / gh-1537).
//
// CONSOLIDATION (gh-2075 × gh-2074, round-2 review): main landed
// `scripts/sqlite3_hook_prewarm.dart` (PR #2077) for the SAME incident
// class and the SAME hook cache — broader OS coverage, already wired into
// build-mobile.yml + ci.yml. This train now rides that ONE tool; the
// parallel bash implementation (`scripts/seed_sqlite3_native_assets.sh`
// + its selftest) was removed, so there is exactly one prewarm contract
// to maintain when the hook layout moves.
//
// The sqlite3 hook has a digest-checked cache at a STABLE path —
// `<workspace>/.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/`
// (hooks_runner resolves `shared/<package>/build/`, NOT a per-input-hash
// dir) — and reuses a present file ONLY when its sha256 matches the
// package-pinned digest, else re-downloads (PrecompiledBinary
// .downloadIntoOutputDirectoryShared). Pre-warming that cache is therefore
// integrity-neutral: a wrong file is never trusted, the hook falls back
// to its own download. The tool reads version + release tag + pinned
// hashes from the INSTALLED package's lib/src/hook/asset_hashes.dart —
// no hashes pinned in the workflow, a lockfile bump self-updates.
// HARDENING (gh-2105): the v1.0.697 stranded draft exposed the release
// train legs still on the retired 3-attempt ≈3.5 min budget when a 5+
// minute egress storm hit — build-macos.yml now rides the same 8-attempt
// ≈10 min contracts as every other hosted leg (gh-2072/2074): the
// sqlite3-native-assets-prewarm composite for the CLI matrix and the
// hardened script copied to $RUNNER_TEMP for the desktop step. This
// guard pins the hardened wiring; scripts/sqlite3_hook_prewarm.dart and
// its suite remain as legacy pins (AC4) until the removal follow-up.
//
// Deliberately YAML-level asserts (the ci_core_shard_upload_retry_guard_test
// .dart / ci_pub_get_retry_guard_test.dart static pattern):
//  AC1  the app build step pre-warms <abi>-macos via the hardened
//       sqlite3_native_assets_prewarm.dart script copied to $RUNNER_TEMP
//       (--attempts 8, best-effort ::warning:: degradation) AFTER the
//       min-platform gate and BEFORE `flutter build macos --release`
//       (post-`flutter clean`, post-config — .dart_tool exists there —
//       and every arch of the matrix gets the pre-warm with the x86_64 →
//       x64 asset-arch mapping),
//  AC2  the CLI matrix legs pre-warm via the shared
//       sqlite3-native-assets-prewarm composite (targets
//       ${{ matrix.arch }}-macos, package-roots: .) AFTER `dart pub get`
//       and BEFORE `dart build cli` (both archs — the 504 killed the
//       bundle leg first, and it is the cheapest place to fail loud),
//  AC3  ONE hardened prewarm mechanism exists: the bash seed script and
//       its selftest are GONE from the tree, and NO retired
//       sqlite3_hook_prewarm.dart reference survives in the workflow —
//       both macOS lanes ride the composite / hardened script (a
//       re-introduction re-creates the two-implementations drift the
//       round-2 review flagged),
//  AC4  the shared tool's download contract stays statically pinned by
//       the canonical suite — bounded retries (brownout recovery,
//       exhausted-retry loud failure, corrupt-body never written), the
//       hook-free `--disable-dart-dev` invocation contract, and the
//       CI-wiring guard. (Round-1 F1 lesson: an assert must pin the
//       mechanism that actually retries — the vacuous `for\s+\w+\s+in\s+`
//       regex against a `while` loop pinned nothing and is gone with the
//       script it mis-pinned.)
//  AC5  no workflow step in build-macos.yml downloads sqlite3 assets by
//       literal URL — the only sqlite3 download path is the shared
//       prewarm tool (a future bare `curl .../libsqlite3` in a run step
//       is a test red).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const workflow = '.github/workflows/build-macos.yml';
const bashSeedScript = 'scripts/seed_sqlite3_native_assets.sh';
const bashSeedSelftest = 'scripts/seed_sqlite3_native_assets_selftest.sh';
const sharedPrewarmTool = 'scripts/sqlite3_hook_prewarm.dart';
const sharedPrewarmUnitSuite = 'test/scripts/sqlite3_hook_prewarm_test.dart';
const sharedPrewarmWiringGuard = 'test/ci_sqlite3_hook_prewarm_guard_test.dart';
const prewarmComposite = './.github/actions/sqlite3-native-assets-prewarm';

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
  group('gh-2075 AC1 — app build step pre-warms the sqlite3 hook cache', () {
    final steps = jobSteps(root, 'build-macos');

    test('the release build step pre-warms via the hardened script', () {
      final build = steps
          .where(
            (s) =>
                (s['name'] ?? '').toString().startsWith('Build macOS release'),
          )
          .toList();
      expect(build, hasLength(1), reason: 'the release build step must exist');
      final run = runOf(build.single);
      expect(
        run,
        contains('../scripts/sqlite3_native_assets_prewarm.dart'),
        reason:
            'the release build step must pre-warm the hook cache via the '
            'hardened gh-2072 script (status-gated fetch, exponential '
            'backoff, per-request timeouts) — the hook downloads inside '
            '`flutter build macos --release`; the step cwd is '
            'flutter_app, hence the ../scripts/ prefix',
      );
      expect(
        run,
        contains(
          r'cp ../scripts/sqlite3_native_assets_prewarm.dart "$RUNNER_TEMP/',
        ),
        reason:
            'the script must be copied OUT of the workspace before '
            'invocation — a plain dart <path> inside flutter_app builds '
            'the package graph\'s own hooks BEFORE main(), i.e. performs '
            'the exact single-attempt download this step exists to '
            'bypass (the hook-free contract; the composite does the '
            'same copy)',
      );
      expect(
        run,
        contains('--attempts 8'),
        reason:
            'the hardened contract is 8 attempts (≈ 10 min of coverage '
            'with the exponential backoff) — the retired 3-attempt '
            'budget (~3.5 min) did not cover the 5+ minute v1.0.697 '
            'storm that stranded the draft (gh-2105)',
      );
      expect(
        run,
        contains(r'--targets "$SQLITE_SEED_ARCH-macos"'),
        reason:
            'the pre-warm targets the macOS release assets in the '
            'script\'s <abi>-<os> grammar, through the mapped arch '
            'variable',
      );
      expect(
        run,
        contains('--package-root .'),
        reason:
            'the package root must be declared — explicit targets never '
            'ride a silent default (the AC7 doctrine of the canonical '
            'guard)',
      );
      expect(
        run,
        contains('|| echo "::warning::'),
        reason:
            'best-effort semantics (gh-2072 review thread 7): a failed '
            'pre-warm degrades to the hook\'s own single-attempt '
            'download, never reds the leg by itself',
      );
      expect(
        run,
        isNot(contains('sqlite3_hook_prewarm.dart')),
        reason:
            'the retired 3-attempt script must not come back on the '
            'release legs — its budget is below the measured storm '
            'duration',
      );
    });

    test('pre-warm runs after the min-platform gate, before the release', () {
      // Steps AND the lines inside a step, in order — the gate and the
      // pre-warm intentionally share the release build step (the pre-warm
      // must run inside it: `flutter clean` wipes .dart_tool mid-step).
      final combined = StringBuffer();
      for (final step in steps) {
        combined
          ..writeln(runOf(step))
          ..writeln((step['working-directory'] ?? '').toString());
      }
      final text = combined.toString();
      final gate = text.indexOf('assert_macos_min_platform');
      final prewarm = text.indexOf('sqlite3_native_assets_prewarm.dart');
      final release = text.indexOf('flutter build macos --release');
      expect(gate, greaterThanOrEqualTo(0), reason: 'gate step must exist');
      expect(
        release,
        greaterThanOrEqualTo(0),
        reason: 'release build must exist',
      );
      expect(
        prewarm,
        greaterThan(gate),
        reason:
            'pre-warm must run after `flutter clean` + the config-only '
            'pass wiped/recreated .dart_tool — seeding earlier is wiped '
            'away',
      );
      expect(
        prewarm,
        lessThan(release),
        reason:
            'pre-warm must run BEFORE the release build — the hook '
            'downloads mid-build (the gh-2075 failure landed ~20 min into '
            'the build)',
      );
    });

    test('both matrix archs are pre-warmed with the x86_64 → x64 mapping', () {
      final build = steps
          .where(
            (s) =>
                (s['name'] ?? '').toString().startsWith('Build macOS release'),
          )
          .single;
      final run = runOf(build);
      expect(
        run,
        contains('x86_64'),
        reason:
            'the matrix arch is x86_64; the release asset is named '
            'libsqlite3.x64.macos.dylib — the x86_64 → x64 mapping (the '
            'size-manifest step idiom) must be applied before pre-warming',
      );
      expect(
        run,
        contains('SQLITE_SEED_ARCH'),
        reason:
            'the mapped arch must go through a variable — pre-warming '
            'the raw matrix arch would request an asset that does not '
            'exist',
      );
    });
  });

  group('gh-2075 AC2 — CLI bundle legs pre-warm before dart build cli', () {
    final steps = jobSteps(root, 'build-macos-cli');

    test('a pre-warm step runs the shared composite for the matrix arch', () {
      final prewarms = steps
          .where((s) => s['uses'] == prewarmComposite)
          .toList();
      expect(
        prewarms,
        hasLength(1),
        reason: 'exactly one pre-warm step in the CLI job',
      );
      final with_ = prewarms.single['with'] as YamlMap;
      expect(
        with_['targets'].toString().trim(),
        r'${{ matrix.arch }}-macos',
        reason:
            'the CLI targets macOS — the target token must be the '
            'per-arch <abi>-<os> form the script validates, resolved '
            'per matrix row by the workflow',
      );
      expect(
        with_['package-roots'].toString().trim(),
        '.',
        reason:
            'build-macos-cli resolves the root package (dart pub get at '
            'the repo root) — declare package-roots: . explicitly next '
            'to the explicit targets',
      );
    });

    test('pre-warm runs after pub get, before dart build cli', () {
      final texts = steps.map(stepText).toList();
      final pubGet = texts.indexWhere((t) => t.contains('dart pub get'));
      final prewarm = steps.indexWhere((s) => s['uses'] == prewarmComposite);
      final build = texts.indexWhere((t) => t.contains('dart build cli'));
      expect(pubGet, greaterThanOrEqualTo(0));
      expect(
        prewarm,
        greaterThan(pubGet),
        reason:
            'the pre-warm resolves sqlite3 from .dart_tool/'
            'package_config.json — it needs the pub resolution first',
      );
      expect(
        prewarm,
        lessThan(build),
        reason:
            '`dart build cli` triggers the hook download — the 504 class '
            'must be caught in the pre-warm (seconds, retried), never '
            'mid-build',
      );
    });

    test('the pre-warm is paired with the hooks-shared cache restore', () {
      // The hosted CLI lane runs on fresh GitHub workspaces — without
      // the restore every release train re-downloads both dylibs live.
      // The pinned hosted-lane pattern (ci.yml AC6, build-mobile.yml
      // AC2) is cache restore + pre-warm: a warm cache makes the leg
      // network-independent, and the restore is hardened so a cache
      // service hiccup can never red the leg.
      final texts = steps.map(stepText).toList();
      final pubGet = texts.indexWhere((t) => t.contains('dart pub get'));
      final cache = texts.indexWhere((t) => t.contains('hooks-shared-'));
      final prewarm = steps.indexWhere((s) => s['uses'] == prewarmComposite);
      expect(
        cache,
        greaterThanOrEqualTo(0),
        reason:
            'the hosted lane must restore .dart_tool/hooks_runner/shared '
            'before the pre-warm (gh-2075 round-3 review, the ci.yml '
            'hosted-lane pattern)',
      );
      expect(
        cache,
        greaterThan(pubGet),
        reason:
            'the restore lands after pub get — the ci.yml idiom '
            '(the cache path exists to receive the restore)',
      );
      expect(
        prewarm,
        greaterThan(cache),
        reason:
            'pre-warm runs AFTER the restore: a warm cache reports '
            '"0 fetched, N already verified" with zero egress and a '
            'brownout window cannot touch the leg at all',
      );
      final cacheStep = steps[cache];
      expect(
        cacheStep['uses'].toString(),
        contains('55cc8345863c7cc4c66a329aec7e433d2d1c52a9'),
        reason: 'the repo-pinned actions/cache v6.1.0 SHA',
      );
      final with_ = cacheStep['with'] as YamlMap;
      expect(
        with_['path'].toString(),
        '.dart_tool/hooks_runner/shared',
        reason: 'exactly the hook cache the pre-warm fills',
      );
      expect(
        with_['key'].toString(),
        contains(
          r'hooks-shared-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles(',
        ),
        reason:
            'per-OS/arch key hashed on the lockfile — a sqlite3 bump '
            're-keys the cache instead of serving stale dylibs',
      );
      expect(
        with_['restore-keys'].toString(),
        contains(r'hooks-shared-${{ runner.os }}-${{ runner.arch }}-'),
        reason: 'prefix restore — a lockfile bump still restores the old cache',
      );
      expect(
        cacheStep['timeout-minutes'],
        2,
        reason: 'a hung cache service cannot stall the leg (ci.yml hardening)',
      );
      expect(
        cacheStep['continue-on-error'],
        true,
        reason:
            'a cache-service hiccup degrades to the pre-warm download '
            'path — never a red leg from the restore itself',
      );
    });
  });

  group('gh-2075 AC3 — ONE prewarm mechanism (the bash duplicate is gone)', () {
    test('the bash seed script and its selftest no longer exist', () {
      expect(
        File(bashSeedScript).existsSync(),
        isFalse,
        reason:
            'scripts/seed_sqlite3_native_assets.sh duplicated '
            'sqlite3_hook_prewarm.dart for the same cache (round-2 review '
            'F3) — the Dart tool is the single implementation; a '
            're-introduction re-creates the two-contract drift',
      );
      expect(
        File(bashSeedSelftest).existsSync(),
        isFalse,
        reason:
            'the selftest drove the removed bash script — kept around it '
            'would be a dead suite asserting a file that cannot run',
      );
    });

    test('build-macos.yml has no stale reference to the bash script', () {
      final text = read(workflow);
      expect(
        text.contains('seed_sqlite3_native_assets'),
        isFalse,
        reason: 'wiring must point at the shared tool only',
      );
    });

    test('both macOS lanes ride the ONE hardened mechanism', () {
      final text = read(workflow);
      expect(
        text.contains('sqlite3_hook_prewarm.dart'),
        isFalse,
        reason:
            'the retired 3-attempt script must not survive anywhere in '
            'build-macos.yml — its ≈3.5 min budget is below the measured '
            '5+ minute v1.0.697 egress storm (gh-2105)',
      );
      expect(
        text.contains('../scripts/sqlite3_native_assets_prewarm.dart'),
        isTrue,
        reason:
            'the app-build lane (cwd flutter_app) rides the hardened '
            'script',
      );
      expect(
        text.contains('uses: ./.github/actions/sqlite3-native-assets-prewarm'),
        isTrue,
        reason: 'the CLI lane (cwd repo root) rides the shared composite',
      );
    });
  });

  group('gh-2075 AC4 — the shared tool keeps its static contract pins', () {
    test('the canonical unit suite pins the bounded-retry contract', () {
      expect(File(sharedPrewarmUnitSuite).existsSync(), isTrue);
      final body = read(sharedPrewarmUnitSuite);
      expect(
        body,
        contains('retries a brownout (non-200) and succeeds on a later'),
        reason:
            'the 504-class retry recovery must stay statically pinned — '
            'this is the exact gh-2075 failure mode',
      );
      expect(
        body,
        contains('exhausted retries fail loudly'),
        reason:
            'bounded attempts that fail LOUD (never an un-bounded or '
            'silent download) — the round-1 F1 concern, pinned where the '
            'mechanism that actually retries lives',
      );
      expect(
        body,
        contains('a corrupt body is never written'),
        reason:
            'the bef140a1a wrong-body signature (HTTP 200 + error page) '
            'must never enter the cache',
      );
    });

    test('the canonical wiring guard stays in the tree', () {
      expect(
        File(sharedPrewarmWiringGuard).existsSync(),
        isTrue,
        reason:
            'test/ci_sqlite3_hook_prewarm_guard_test.dart pins the '
            'build-mobile.yml + ci.yml wiring — the macos lane (this '
            'guard) joins its lanes on the same contract',
      );
    });

    test('the tool keeps the hook-free invocation contract', () {
      final body = read(sharedPrewarmTool);
      expect(
        body.contains("import 'package:"),
        isFalse,
        reason:
            'the script must load under --disable-dart-dev (no package '
            'config resolution) — a package: import re-creates the '
            'gh-2074 rework failure where plain dart run executed the '
            'build hooks before main()',
      );
    });
  });

  group('gh-2075 AC5 — no literal sqlite3 download URLs in workflow steps', () {
    test('build-macos.yml never fetches libsqlite3 by literal URL', () {
      final rootText = read(workflow);
      expect(
        RegExp(r'libsqlite3\.[a-z0-9]+\.macos\.dylib').allMatches(rootText),
        isEmpty,
        reason:
            'the ONLY sqlite3 download path is the shared prewarm tool, '
            'which derives the asset name + pinned hash from the installed '
            'package — a literal URL in the workflow re-creates the '
            'un-pinned download gh-2075 exists to remove',
      );
    });
  });
}
