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
//        Linux box also satisfies. gh-1692: the iOS legs (build-ios,
//        submit-ios) must resolve to fa-m5-1 BY NAME (the runner-name
//        label) — `macos-m5` also matches fa-m5-2, whose archive/signing
//        environment is unverified (the 10-17/10-18 silent ARCHIVE FAILED
//        runs), so the routing guard asserts the exact runner LABEL SET,
//        not merely "a macOS M5 machine".
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

/// The macOS publish legs, their jobs, and the exact runner-label set each
/// job must pin. gh-1692: the iOS legs resolve to fa-m5-1 BY NAME (the
/// runner-name label GitHub assigns to every self-hosted registration) —
/// `macos-m5` alone also matches fa-m5-2, whose archive/signing
/// environment is unverified (the 10-17/10-18 `** ARCHIVE FAILED **`
/// runs), so a label-set pin without the runner name is a coin flip.
/// gh-1865 EXTENDS the name pin to build-macos: its signing step mutates
/// the PER-USER GLOBAL keychain search list, and the fa-m5 pool is ONE
/// host under ONE user account — any signing job landing on another
/// runner of the pool stomps an in-flight build-macos codesign (run
/// 40165498619 autopsy: a build-mobile iOS job on fa-m5-3 replaced the
/// search list 84s after the macOS arm64 leg's import, its codesign died
/// 10 min later with "No certificate for team ... found"). Pinning ALL
/// signing legs (build-ios, submit-ios, build-macos) to the ONE runner
/// fa-m5-1 serializes them through that runner's one-job-at-a-time
/// queue — the only race-free arrangement on a shared user account.
const mobileMacosLegs = <String, Map<String, List<String>>>{
  '.github/workflows/build-mobile.yml': {
    'build-ios': ['self-hosted', 'macos-m5', 'fa-m5-1'],
    'submit-ios': ['self-hosted', 'macos-m5', 'fa-m5-1'],
  },
  '.github/workflows/build-macos.yml': {
    'build-macos': ['self-hosted', 'macos-m5', 'fa-m5-1'],
  },
};

void main() {
  group('AC1 — self-hosted macOS legs pin the runner LABEL SET (gh-1600 '
      'F-A, gh-1692)', () {
    for (final entry in mobileMacosLegs.entries) {
      final jobs = jobsOf(entry.key);
      for (final jobEntry in entry.value.entries) {
        final id = jobEntry.key;
        test('${entry.key}::$id runs on ${jobEntry.value.join(' + ')}', () {
          final runsOn = (jobs[id] as YamlMap)['runs-on'].toString();
          for (final label in jobEntry.value) {
            expect(
              runsOn,
              contains(label),
              reason:
                  '$entry.key job "$id" must pin the runner-label set '
                  '${jobEntry.value} — gh-1692: the iOS legs resolve to '
                  'fa-m5-1 BY NAME, the runner-name label GitHub assigns '
                  'to every self-hosted registration. `macos-m5` alone '
                  'also matches fa-m5-2, whose archive/signing '
                  'environment is unverified (the 10-17/10-18 '
                  '`** ARCHIVE FAILED **` runs) — a name-less pin is a '
                  'coin flip between a good and a broken runner.',
            );
          }
          expect(
            runsOn.contains('macOS') || runsOn.contains('ARM64'),
            isFalse,
            reason:
                '$entry.key job "$id" must not carry the generic '
                '`macOS`/`ARM64` labels — only the unambiguous '
                '`macos-m5` + runner-name pins route to the M5 runner '
                '(gh-1600 F-A, gh-1692)',
          );
        });
      }
    }

    test('audit: no workflow anywhere pins the generic macOS/ARM64 labels', () {
      // gh-1600 rework (review thread): the routing-bug class dies only if
      // the audit is repo-wide — a future `[self-hosted, macOS, ARM64]` pin
      // in ANY workflow (a new daily-publish/release leg) would re-route an
      // iOS-shaped job onto the Linux box. Precise today: the only
      // self-hosted legs are bench-mls.yml's bare `self-hosted` (the Linux
      // box, correctly label-free of macOS) and the `[self-hosted,
      // macos-m5]` pins; `macos-latest` (GitHub-hosted) does not match the
      // case-sensitive `macOS`/`ARM64` check.
      final workflows = Directory('.github/workflows')
          .listSync()
          .where((f) => f.path.endsWith('.yml'))
          .toList();
      expect(workflows, isNotEmpty);
      for (final f in workflows) {
        final jobs = jobsOf(f.path);
        for (final e in jobs.entries) {
          final runsOn = (e.value as YamlMap)['runs-on']?.toString() ?? '';
          expect(
            runsOn.contains('macOS') || runsOn.contains('ARM64'),
            isFalse,
            reason:
                '${f.path} job "${e.key}" carries the generic '
                '`macOS`/`ARM64` labels — the Linux self-hosted box also '
                'satisfies them, so a macOS-only job can be routed onto '
                'Linux (gh-1600 F-A class). Only the `macos-m5` pin '
                '(fa-m5-1) or GitHub-hosted `macos-*` runners are '
                'legitimate.',
          );
        }
      }
    });

    test('audit: matrix-defined runners never carry the generic macOS/ARM64 labels', () {
      // gh-1600 rework round 2 (review thread): the job-level runs-on
      // audit above reads only the parsed string — jobs routed through a
      // matrix escape it (`runs-on: \${{ matrix.runner }}` resolves at
      // runtime), so a future `strategy.matrix` value of
      // `[self-hosted, macOS, ARM64]` would sail past the audit and
      // re-route a macOS-shaped job onto the Linux box. Walk every
      // strategy.matrix subtree and assert no scalar value (string or
      // list item) carries the generic labels. A raw-text scan is NOT
      // usable here: comments and display names legitimately contain
      // `macOS` (e.g. build-macos.yml's `name: Build macOS Release (Fa)`
      // and the gh-1600 F-A comment) — only parsed YAML values are
      // semantically runner labels.
      List<String> matrixScalars(Object? node) {
        final out = <String>[];
        void walk(Object? n) {
          if (n is YamlMap) {
            n.forEach((_, v) => walk(v));
          } else if (n is YamlList) {
            for (final v in n) {
              walk(v);
            }
          } else if (n != null) {
            out.add(n.toString());
          }
        }

        walk(node);
        return out;
      }

      final workflows = Directory('.github/workflows')
          .listSync()
          .where((f) => f.path.endsWith('.yml'))
          .toList();
      for (final f in workflows) {
        final jobs = jobsOf(f.path);
        for (final e in jobs.entries) {
          final strategy = (e.value as YamlMap)['strategy'];
          if (strategy is! YamlMap) continue; // e.g. an expression string
          final matrix = strategy['matrix'];
          if (matrix is! YamlMap) continue;
          for (final scalar in matrixScalars(matrix)) {
            expect(
              scalar.contains('macOS') || scalar.contains('ARM64'),
              isFalse,
              reason:
                  '${f.path} job "${e.key}" strategy.matrix carries '
                  '`$scalar` with the generic `macOS`/`ARM64` labels — a '
                  'matrix-routed job escapes the job-level runs-on '
                  'audit, and the Linux self-hosted box also satisfies '
                  'those labels (gh-1600 F-A class).',
            );
          }
        }
      }
    });

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
        contains(r'-o "${RUNNER_TEMP:-/tmp}/bench/jobs"'),
        reason:
            'the harbor output dir must live OUTSIDE \$GITHUB_WORKSPACE — '
            '`-o jobs` parked jobs/fa-<family>-<env>-<kind>-<shard>/ in the '
            'persistent shared workspace and the next mobile build\'s clean '
            'choked on the docker-held leftovers (gh-1600). The '
            '`\${RUNNER_TEMP:-/tmp}` fallback form keeps the step alive '
            'under `set -u` when the var is absent (same hardening as the '
            'teardown step).',
      );
      expect(
        script.contains('-o jobs'),
        isFalse,
        reason: 'no bare workspace-relative `-o jobs` may remain (gh-1600)',
      );
      // gh-1600 × gh-1658 merge invariant: the zero-trial retry gate and
      // the attempt move-aside operate on the SAME out-of-workspace dir
      // as the harbor -o output — a workspace-relative retry path would
      // reintroduce the docker-held leftovers class.
      expect(
        script,
        contains(r'trials_started()'),
        reason:
            'the gh-1658 zero-trial inline retry must survive the merge '
            '(gh-1600 AC2 keeps its paths out-of-workspace)',
      );
      expect(
        script.contains(r'"jobs/$JOB_NAME"'),
        isFalse,
        reason:
            'no workspace-relative retry path (`jobs/\$JOB_NAME`) may '
            'remain — the gate and the move-aside must work on the '
            'out-of-workspace bench output (gh-1600 AC2)',
      );
      expect(
        script,
        contains(r'mv "${RUNNER_TEMP:-/tmp}/bench/jobs/$JOB_NAME"'),
        reason:
            'the zero-trial attempt move-aside must park the failed '
            'attempt under the same out-of-workspace dir (gh-1600 AC2 '
            '× gh-1658 C1)',
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
      // The cleanup step references \$FAMILY (job env) and \$ENV_TYPE — but
      // ENV_TYPE is only step-scoped to the harbor-run step. Without its own
      // copy `set -u` kills the step ("ENV_TYPE: unbound variable") and the
      // always() step fails the whole bench job.
      expect(
        (cleanup['env'] as YamlMap?)?.containsKey('ENV_TYPE') ?? false,
        isTrue,
        reason:
            'the cleanup step must declare ENV_TYPE: \${{ matrix.env }} — '
            'it is not in scope from the harbor-run step (gh-1600: a '
            'set -u unbound-variable crash in an always() step fails the '
            'job)',
      );
      // gh-1600 rework round 2 (BLOCKING review thread, re-opened): the
      // round-1 guard keyed on `com.docker.compose.project.working_dir`,
      // but harbor 0.23.0 runs compose with
      // `--project-directory <task_cache>/environment` and the task cache
      // lives in ~/.cache/harbor/tasks/packages/... (shared across ALL
      // shards and bench runs) — never under $RUNNER_TEMP/bench. What IS
      // under the bench output: the trial dirs (job.py trials_dir =
      // job_dir under the -o dir) bind-mounted into the containers as
      // /logs/* — so the container's .Mounts[].Source is the harbor-side
      // path that actually lives under the bench output. The guard must
      // inspect the mount Sources and prefix-match them against
      // "$RUNNER_TEMP/bench"/*; anything else (name filter, working_dir
      // label) selects zero containers and cancelled shards keep leaking.
      expect(
        script.contains('--filter "name='),
        isFalse,
        reason:
            'harbor 0.23.0 names trial containers '
            '`{task}__{random}__env-main-1` — a docker name filter can '
            'never match them, so the teardown is a silent no-op and '
            'cancelled shards leak live containers on the persistent box '
            '(gh-1600 rework)',
      );
      expect(
        script.contains('com.docker.compose.project.working_dir'),
        isFalse,
        reason:
            'harbor 0.23.0 puts the compose project directory in the '
            'shared task cache (~/.cache/harbor/tasks/packages/...), NOT '
            'under \$RUNNER_TEMP/bench — a working_dir guard still matches '
            'zero containers (gh-1600 rework round 2)',
      );
      expect(
        script,
        contains('label=com.docker.compose.project'),
        reason:
            'the teardown must select containers by the compose project '
            'label, not by name (gh-1600 rework)',
      );
      expect(
        script,
        contains(r'{{range .Mounts}}{{.Source}} {{end}}'),
        reason:
            'the bench-bound path on a harbor trial container is its '
            'bind-mount Source (the trial dirs under the -o output), not '
            'the compose project dir (gh-1600 rework round 2)',
      );
      expect(
        script,
        contains(r'"${RUNNER_TEMP:-/tmp}/bench"/*'),
        reason:
            'the mount-source match must be anchored to the shard\'s own '
            'out-of-workspace bench output — mount Sources embed the '
            'per-registration _temp path, so another workflow\'s or '
            'another registration\'s live containers are never touched; '
            'the pattern uses the \${RUNNER_TEMP:-/tmp} fallback like the '
            'final rm -rf (gh-1600 rework rounds 2+3)',
      );
      // gh-1600 rework round 3 (APPROVE review, suggestion): the step runs
      // under `set -u` and the final `rm -rf` guards with
      // "${RUNNER_TEMP:-/tmp}/bench" — but the mount-source `case` pattern,
      // the "tore down" summary echo, and the unremovable-dir warning echo
      // expanded bare $RUNNER_TEMP. If the var is ever absent (a
      // misconfigured/ephemeral runner, a local `act` run) the always()
      // cleanup hard-fails on an unbound variable — exactly the failure
      // mode this step's best-effort design exists to avoid. Every
      // $RUNNER_TEMP expansion in this step must carry the :-/tmp fallback.
      // Full-line comments are skipped — bash never expands them, so a
      // bare $RUNNER_TEMP in prose cannot trip set -u.
      final codeOnly = script
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .join('\n');
      var bareIdx = -1;
      var hasBareRunnerTemp = false;
      while ((bareIdx = codeOnly.indexOf(r'$RUNNER_TEMP', bareIdx + 1)) != -1) {
        final next = bareIdx + r'$RUNNER_TEMP'.length < codeOnly.length
            ? codeOnly[bareIdx + r'$RUNNER_TEMP'.length]
            : '';
        if (next != ':') hasBareRunnerTemp = true;
      }
      expect(
        hasBareRunnerTemp,
        isFalse,
        reason:
            'every \$RUNNER_TEMP expansion in the always() cleanup must use '
            'the \${RUNNER_TEMP:-/tmp} fallback — a bare expansion under '
            'set -u hard-fails the step when the var is absent (gh-1600 '
            'rework round 3)',
      );
      expect(
        script,
        contains(r'"${RUNNER_TEMP:-/tmp}/bench"/*'),
        reason:
            'the mount-source case pattern must use the \${RUNNER_TEMP:-'
            '/tmp} fallback like the final rm -rf (gh-1600 rework round 3)',
      );
      expect(
        script,
        contains(r'bound to ${RUNNER_TEMP:-/tmp}/bench'),
        reason:
            'the "tore down" summary echo must use the \${RUNNER_TEMP:-'
            '/tmp} fallback like the final rm -rf (gh-1600 rework round 3)',
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
        lessThan(script.indexOf(r'rm -rf "$GITHUB_WORKSPACE" || true')),
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

  group('Rework — checkout hardening (review threads)', () {
    /// All inline mirror-checkout scripts (build-ios + submit-ios +
    /// build-macos) — the clone-around-stub block is identical in each.
    List<String> allCheckoutScripts() {
      final scripts = <String>[];
      for (final wf in const [
        '.github/workflows/build-mobile.yml',
        '.github/workflows/build-macos.yml',
      ]) {
        final jobs = jobsOf(wf);
        for (final j in jobs.entries) {
          final steps = (j.value as YamlMap)['steps'] as YamlList?;
          if (steps == null) continue;
          for (final s in steps.whereType<YamlMap>()) {
            final name = s['name']?.toString() ?? '';
            if (name.startsWith('Checkout repository from local mirror') &&
                s['run'] != null) {
              scripts.add(s['run'].toString());
            }
          }
        }
      }
      return scripts;
    }

    test('stub collision parks the stale stub — the FRESH entry always wins', () {
      final scripts = allCheckoutScripts();
      expect(scripts.length, 3, reason: 'build-ios + submit-ios + build-macos');
      for (final script in scripts) {
        // The old path skipped the fresh entry (warning-only) and the
        // trailing `rm -rf "$CLONE_TARGET"` then DELETED it — the
        // workspace silently kept the stale leftover at that repo path.
        expect(
          script,
          contains(r'mv "$GITHUB_WORKSPACE/$name" "$STALE'),
          reason:
              'on a stub collision the stale leftover must move into the '
              '\$STALE sidecar — not stay in the workspace while the '
              'fresh checkout entry is dropped and deleted (gh-1600 '
              'rework: fresh content always wins)',
        );
        expect(
          script.indexOf(r'mv "$GITHUB_WORKSPACE/$name"'),
          lessThan(script.indexOf(r'mv "$entry" "$GITHUB_WORKSPACE/"')),
          reason:
              'the stale stub must be parked BEFORE the fresh entry moves '
              'in — same-name mv would otherwise overwrite the fresh '
              'content (gh-1600 rework)',
        );
        expect(
          script,
          contains('stub collision on'),
          reason:
              'the skip-with-warning path may remain only as the '
              'last-resort fallback when even parking the stub fails '
              '(gh-1600 rework)',
        );
      }
    });

    test('old stale-workspace-* sidecars are pruned before a new one is parked', () {
      final scripts = allCheckoutScripts();
      expect(scripts.length, 3, reason: 'build-ios + submit-ios + build-macos');
      for (final script in scripts) {
        expect(
          script,
          contains(r'rm -rf "${RUNNER_TEMP:-/tmp}"/stale-workspace-*'),
          reason:
              'on the persistent box the runner\'s own _temp cleanup '
              'cannot remove mount-held sidecars either — every degraded '
              'checkout must first best-effort-prune previous '
              '`stale-workspace-*` dirs (the containers that held them '
              'may have died since, so the retry often succeeds) '
              '(gh-1600 rework)',
        );
        expect(
          script.indexOf('stale-workspace-*'),
          lessThan(script.indexOf(r'stale-workspace-$(date')),
          reason:
              'the prune must run BEFORE the new timestamped sidecar is '
              'created — otherwise the glob would also match (and '
              're-delete) the fresh dir (gh-1600 rework)',
        );
      }
    });
  });
}
