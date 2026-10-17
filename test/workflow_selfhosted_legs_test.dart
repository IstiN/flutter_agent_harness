// gh-1600 — the daily-publish testflight leg failed twice over:
//
//   L1-routing      `Build iOS IPA` / `Submit iOS to TestFlight` pinned the
//                   GENERIC `[self-hosted, macOS, ARM64]` label list, which
//                   also matches the Linux self-hosted box's advertised
//                   labels — the iOS job ran on Linux and died with
//                   `bundle: command not found` (exit 127) at Install
//                   fastlane (run 38516656653; the 2026-10-15 night run
//                   additionally hit `security: command not found`).
//   L1-isolation    bench-harbor wrote its job output INTO the shared
//                   self-hosted workspace (`-o jobs` → jobs/
//                   fa-2.1-docker-cpu-14/, trial dirs bind-mounted into
//                   task containers), so the mobile legs' bare
//                   `rm -rf "$GITHUB_WORKSPACE"` hit unremovable leftovers
//                   and failed the checkout before any build step.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of workflow_fetch_shape_guard_test.dart / release_hygiene_test.dart):
//
//   AC1  every self-hosted job in the macOS publish legs (build-mobile.yml,
//        build-macos.yml) pins the UNIQUE macOS label `macos-m5` — the
//        fa-m5-1 registration (gh-1005: the repo's ONE self-hosted macOS M5
//        runner) — and never the generic `macOS`/`ARM64` labels that the
//        Linux box also satisfies.
//   AC2  a bench run immediately followed by a mobile build on the same box
//        cannot break the checkout: bench-harbor writes its job output
//        OUTSIDE $GITHUB_WORKSPACE ($RUNNER_TEMP/bench/jobs) and tears its
//        docker containers down BEFORE removing the output dir, and the
//        three mirror-checkout jobs clean the shared workspace
//        log-and-prune (a stale unremovable path moves aside / the clone
//        works around it instead of failing).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// The `run` script of the named step in the named job of the workflow.
String checkoutScriptOf(String workflowPath, String job, String stepName) {
  final steps = (jobsOf(workflowPath)[job] as YamlMap)['steps'] as YamlList;
  return steps
      .whereType<YamlMap>()
      .firstWhere((s) => (s['name']?.toString() ?? '') == stepName)['run']
      .toString();
}

/// The macOS publish legs and the jobs that must run on fa-m5-1.
const mobileMacosLegs = <String, List<String>>{
  '.github/workflows/build-mobile.yml': ['build-ios', 'submit-ios'],
  '.github/workflows/build-macos.yml': ['build-macos'],
};

void main() {
  group('AC1 — self-hosted macOS legs pin the macos-m5 label (gh-1600 F-A)', () {
    for (final entry in mobileMacosLegs.entries) {
      final jobs = jobsOf(entry.key);
      for (final id in entry.value) {
        test('${entry.key}::$id runs on fa-m5-1, never on Linux', () {
          final runsOn = (jobs[id] as YamlMap)['runs-on'].toString();
          expect(
            runsOn,
            contains('macos-m5'),
            reason:
                '$entry.key job "$id" must pin the unique macOS label '
                '`macos-m5` (the fa-m5-1 registration) — the generic '
                '`[self-hosted, macOS, ARM64]` list also matches the Linux '
                'self-hosted box, and the job ran there with no '
                'ruby/fastlane/Xcode (gh-1600: exit 127 at Install fastlane)',
          );
          expect(
            runsOn.contains('macOS') || runsOn.contains('ARM64'),
            isFalse,
            reason:
                '$entry.key job "$id" must not carry the generic '
                '`macOS`/`ARM64` labels — only the unambiguous `macos-m5` '
                'pin routes to the M5 runner (gh-1600 F-A)',
          );
        });
      }
    }

    test('audit: no self-hosted job in either leg skips the macos-m5 pin', () {
      for (final entry in mobileMacosLegs.entries) {
        final jobs = jobsOf(entry.key);
        for (final e in jobs.entries) {
          final runsOn = (e.value as YamlMap)['runs-on']?.toString() ?? '';
          if (!runsOn.contains('self-hosted')) continue;
          expect(
            runsOn,
            contains('macos-m5'),
            reason:
                '${entry.key} job "${e.key}" runs self-hosted without the '
                '`macos-m5` pin — a macOS-only leg must never be routable '
                'onto the Linux box (gh-1600 F-A audit)',
          );
        }
      }
    });
  });

  group('AC2 — bench leftovers never land in the shared workspace (F-B)', () {
    final harbor = read('.github/workflows/bench-harbor.yml');
    final harborJobs = jobsOf('.github/workflows/bench-harbor.yml');

    test('harbor run writes its job output under \$RUNNER_TEMP, not the workspace', () {
      final run = (harborJobs['bench'] as YamlMap)['steps'] as YamlList;
      final harborRun = run
          .whereType<YamlMap>()
          .firstWhere((s) => (s['run']?.toString() ?? '').contains('harbor run'));
      final script = harborRun['run'].toString();
      expect(
        script,
        contains(r'-o "$RUNNER_TEMP/bench/jobs"'),
        reason:
            'the harbor output dir must live OUTSIDE \$GITHUB_WORKSPACE — '
            '`-o jobs` parked jobs/fa-<family>-<env>-<kind>-<shard>/ in the '
            'persistent shared workspace and the next mobile build\'s clean '
            'choked on the docker-held leftovers (gh-1600)',
      );
      expect(
        script.contains('-o jobs'),
        isFalse,
        reason: 'no bare workspace-relative `-o jobs` may remain (gh-1600)',
      );
    });

    test('artifact + Harbor Hub uploads follow the out-of-workspace output', () {
      expect(
        harbor,
        contains('path: \${{ runner.temp }}/bench/jobs/'),
        reason:
            'the harbor-job artifact upload must point at '
            '\$RUNNER_TEMP/bench/jobs — the workspace `jobs/` dir no longer '
            'exists (gh-1600)',
      );
      expect(
        harbor,
        contains(r'for job_dir in "$RUNNER_TEMP/bench/jobs"/fa-'),
        reason:
            'the Harbor Hub upload loop must iterate the '
            '\$RUNNER_TEMP/bench/jobs output, not a workspace `jobs/` dir '
            '(gh-1600)',
      );
    });

    test('bench job tears its docker containers down before removing the output', () {
      final steps = (harborJobs['bench'] as YamlMap)['steps'] as YamlList;
      final cleanup = steps.whereType<YamlMap>().firstWhere(
            (s) =>
                (s['run']?.toString() ?? '').contains('docker rm -f') &&
                (s['if']?.toString() ?? '') == 'always()',
            orElse: () => throw TestFailure(
              'bench-harbor bench job has no always-run cleanup step that '
              'tears the shard docker containers down (gh-1600 AC2: a '
              'cancelled shard must not leave bind-mounted leftovers behind)',
            ),
          );
      final script = cleanup['run'].toString();
      final dockerDown = script.indexOf('docker rm -f');
      final dirRm = script.indexOf('rm -rf');
      expect(dockerDown, greaterThan(-1));
      expect(
        dirRm,
        greaterThan(dockerDown),
        reason:
            'the output-dir rm must come AFTER the docker teardown — the '
            'containers hold the trial dirs and any earlier rm fails on the '
            'live mounts (gh-1600)',
      );
    });

    test('every mirror-checkout script is inline with a log-and-prune clean', () {
      // The hardened clean lives INLINE in each checkout step, NOT in a
      // composite action: local `uses: ./...` actions resolve against
      // $GITHUB_WORKSPACE at step time, and on the persistent self-hosted box
      // that workspace is the PREVIOUS run's tree (or nothing) — the action
      // file would be missing on the first run and stale afterwards, because
      // the checkout step IS the thing that materializes the tree.
      final checkoutSteps = <String, String>{
        '.github/workflows/build-mobile.yml': 'Checkout repository from local mirror',
        '.github/workflows/build-macos.yml': 'Checkout repository from local mirrors',
      };
      for (final entry in checkoutSteps.entries) {
        final jobs = jobsOf(entry.key);
        final hits = <String>[];
        for (final j in jobs.entries) {
          final steps = (j.value as YamlMap)['steps'] as YamlList?;
          if (steps == null) continue;
          for (final s in steps.whereType<YamlMap>()) {
            if ((s['name']?.toString() ?? '') == entry.value) {
              hits.add((s['run'] ?? '').toString());
            }
          }
        }
        expect(
          hits.length,
          entry.key.contains('mobile') ? 2 : 1,
          reason:
              '${entry.key} must carry ${entry.value == 'Checkout repository from local mirror' ? 'two (build-ios + submit-ios)' : 'one (build-macos)'} '
              'inline checkout step(s) named "${entry.value}" (gh-1600)',
        );
        for (final script in hits) {
          expect(
            script,
            contains(r'rm -rf "$GITHUB_WORKSPACE" || true'),
            reason:
                'the clean must TOLERATE unremovable paths (bench leftovers '
                'held by docker) — a bare rm -rf failing the checkout was the '
                'gh-1600 trigger ($entry.key)',
          );
          expect(
            script,
            contains('stale-workspace'),
            reason:
                'a still-blocked remainder must move aside into \$RUNNER_TEMP '
                '(gh-1600 log-and-prune, $entry.key)',
          );
          expect(
            script,
            contains('git clone --reference'),
            reason: 'the local-mirror clone shape is kept (gh-1600, $entry.key)',
          );
          expect(
            RegExp(r'^\s*rm -rf "\$GITHUB_WORKSPACE"\s*$', multiLine: true)
                .hasMatch(script),
            isFalse,
            reason:
                'no UNGUARDED workspace rm may remain — the bare failing form '
                'was the gh-1600 checkout killer ($entry.key)',
          );
        }
      }
    });

    test('no local-action checkout remained in either publish leg', () {
      final mobile = read('.github/workflows/build-mobile.yml');
      final macos = read('.github/workflows/build-macos.yml');
      expect(
        mobile.contains('uses: ./.github/actions/mirror-checkout'),
        isFalse,
        reason:
            'a local composite action cannot be the checkout on the '
            'persistent box — it resolves from the stale shared workspace '
            '(gh-1600: inline scripts only)',
      );
      expect(
        macos.contains('uses: ./.github/actions/mirror-checkout'),
        isFalse,
        reason: 'same as build-mobile (gh-1600: inline scripts only)',
      );
    });

    test('build-macos parks its per-arch build cache outside the clean, expanded \$HOME', () {
      final script = checkoutScriptOf(
        '.github/workflows/build-macos.yml',
        'build-macos',
        'Checkout repository from local mirrors',
      );
      // bash double quotes expand $HOME natively here — the cache dir must
      // be built at run time in the runner home (the gh-1600 round-1
      // composite action assigned it single-quoted and would have parked a
      // literal-\$HOME junk dir under the cwd).
      expect(
        script,
        contains(r'BUILD_CACHE_DIR="$HOME/actions-runner-yoloit/build-cache/macos-$ARCH"'),
        reason:
            'the per-arch cache dir must expand \$HOME at run time '
            '(gh-1600: a single-quoted assignment parks the cache in a junk '
            'literal-\$HOME dir)',
      );
      expect(
        script.indexOf('Preserving existing macOS build cache'),
        lessThan(script.indexOf('rm -rf "$GITHUB_WORKSPACE" || true')),
        reason:
            'the cache must be parked BEFORE the workspace clean — the clean '
            'removes everything else in the workspace (gh-1600)',
      );
      expect(
        script,
        contains('Restoring macOS build cache'),
        reason: 'the parked cache must be restored after the clone (gh-1600 kept shape)',
      );
    });
  });
}
