// gh-2432 — v1.0.778 release run red: the ci.yml `binaries` job's
// "Draft lifecycle guard" step ran its `bash scripts/release_draft_guard.sh
// "${GITHUB_REF_NAME}"` line under the WINDOWS-DEFAULT shell (pwsh), where
// `"${GITHUB_REF_NAME}"` interpolates an UNDEFINED POWERSHELL VARIABLE —
// empty — so the guard died on `${1:?usage: release_draft_guard.sh <tag>}`
// (`scripts/release_draft_guard.sh: line 36: 1: usage: …`, run
// 45643151796, windows-x64 leg). The issue-#282 failure-path cleanup —
// delete THIS leg's orphaned draft — therefore never runs on a windows
// matrix row; only the linux/macOS rows' default bash masked it.
//
// On the same run the staged draft was stranded for the daily sweeper to
// reclaim (the sweep issue re-filed, gh-2432). The release-lifecycle
// scripts are POSIX bash — every `run:` step that invokes them from a
// job whose runners can be windows-latest MUST pin `shell: bash`
// (step-level, or job/workflow `defaults.run.shell`).
//
// Static workflow-shape asserts (the ci_2408 / ci_1596 pattern), repo-wide:
//
//   AC1  every `run:` step that invokes `bash scripts/…` in a
//        windows-capable job carries an effective `shell: bash`
//        (step-level `shell:` > job `defaults.run.shell` > workflow
//        `defaults.run.shell`);
//   AC2  the guard stays meaningful: the repo still runs
//        release-lifecycle bash steps from windows-capable jobs — if the
//        inventory empties, the guard is dead weight and should be
//        revisited.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

String? defaultsRunShell(YamlMap? defaults) =>
    defaults is YamlMap && defaults['run'] is YamlMap
    ? (defaults['run'] as YamlMap)['shell']?.toString()
    : null;

/// True when [runsOn] (raw expression) or the job's matrix values can put
/// the job on a windows runner. `matrix` expressions are resolved against
/// `strategy.matrix.runner/os/include` values — the ci.yml `binaries`
/// shape (`runner: [ubuntu-latest, windows-latest, …]`).
bool windowsCapable(String runsOn, YamlMap job) {
  if (runsOn.contains('windows')) return true;
  if (!runsOn.contains('matrix')) return false;
  final strategy = job['strategy'];
  if (strategy is! YamlMap || strategy['matrix'] is! YamlMap) return false;
  final matrix = strategy['matrix'] as YamlMap;
  bool valueLooksWindows(Object? v) =>
      v != null && v.toString().contains('windows');
  final runner = matrix['runner'];
  if (runner is YamlList && runner.any(valueLooksWindows)) return true;
  final os = matrix['os'];
  if (os is YamlList && os.any(valueLooksWindows)) return true;
  final include = matrix['include'];
  if (include is YamlList) {
    for (final inc in include.whereType<YamlMap>()) {
      if (valueLooksWindows(inc['runner']) || valueLooksWindows(inc['os'])) {
        return true;
      }
    }
  }
  return false;
}

/// (job, step, effectiveShell) for every run-step of [workflowPath] that
/// invokes `bash scripts/…` from a windows-capable job. Comment lines are
/// NOT exempt here: a commented-out `bash scripts/…` mention inside a
/// step whose shell is unset is indistinguishable from a live one at this
/// level, and a stray false positive is cheap (ci_2408 precedent) — a
/// missed violation reintroduces the gh-2432 guard gap.
List<(String, String, String)> windowsBashScriptSteps(String workflowPath) {
  final hits = <(String, String, String)>[];
  final docShell = defaultsRunShell(
    loadYaml(read(workflowPath))['defaults'],
  );
  final jobs = jobsOf(workflowPath);
  for (final jobEntry in jobs.entries) {
    final job = jobEntry.value;
    if (job is! YamlMap) continue;
    final runsOn = job['runs-on']?.toString() ?? '';
    if (!windowsCapable(runsOn, job)) continue;
    final effDefault =
        docShell ?? defaultsRunShell(job['defaults']) ?? '<unset>';
    final steps = job['steps'] as YamlList?;
    if (steps == null) continue;
    for (final step in steps.whereType<YamlMap>()) {
      final run = step['run']?.toString();
      if (run == null) continue;
      if (!run.contains('bash scripts/')) continue;
      final shell = step['shell']?.toString() ?? effDefault;
      hits.add((jobEntry.key.toString(), step['name']?.toString() ?? '<unnamed>', shell));
    }
  }
  return hits;
}

void main() {
  final workflowPaths =
      Directory('.github/workflows')
          .listSync()
          .where((f) => f.path.endsWith('.yml'))
          .map((f) => f.path)
          .toList()
        ..sort();

  group('AC1 — bash-script run-steps in windows-capable jobs pin shell: bash', () {
    test(
      'the gh-2432 regression pin: ci.yml binaries "Draft lifecycle guard" is shell-bash',
      () {
        // The exact step that died on the v1.0.778 windows leg (run
        // 45643151796): `line 36: 1: usage: release_draft_guard.sh <tag>`
        // — `"${GITHUB_REF_NAME}"` interpolated to EMPTY under pwsh. Pin
        // the fix directly so removing the shell pin fails THIS suite
        // even if the step is later renamed or the only remaining
        // windows-exposed step in the repo.
        final jobs = jobsOf('.github/workflows/ci.yml');
        final binaries = jobs['binaries'] as YamlMap?;
        expect(binaries, isNotNull, reason: 'ci.yml must keep the binaries job');
        final steps = binaries!['steps'] as YamlList;
        final guard = steps.whereType<YamlMap>().where(
          (s) =>
              (s['name']?.toString() ?? '').contains('Draft lifecycle guard'),
        );
        expect(guard, isNotEmpty, reason: 'the failure-path guard must exist');
        for (final step in guard) {
          expect(
            step['shell']?.toString(),
            'bash',
            reason:
                'ci.yml job "binaries" step "${step['name']}" invokes '
                '`bash scripts/release_draft_guard.sh` from a '
                'windows-capable matrix row — without `shell: bash` the '
                'windows-latest pwsh default interpolates '
                '`\$GITHUB_REF_NAME` as an UNDEFINED PowerShell variable '
                '(empty) and the guard dies on its usage guard '
                '(gh-2432, run 45643151796).',
          );
        }
      },
    );

    test('negative probe — an unshelled bash-scripts step IS flagged', () {
      // Synthetic violation (ci_2408 pattern): a windows-matrix job with
      // a bash-script run-step and no shell pin must be reported as
      // unprotected. Without this probe a refactor of the helper (e.g.
      // matching nothing) could silently zero the inventory above.
      final dir = Directory.systemTemp.createTempSync('gh-2432-probe-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final probe = File('${dir.path}/probe.yml')..writeAsStringSync('''
jobs:
  binaries:
    runs-on: \${{ matrix.runner }}
    strategy:
      matrix:
        runner: [ubuntu-latest, windows-latest]
    steps:
      - name: Upload archive to GitHub Release
        shell: bash
        run: bash scripts/release_lazy_draft.sh "\${GITHUB_REF_NAME}"
      - name: Draft lifecycle guard (delete orphaned draft on failure)
        if: always() && job.status != 'success'
        run: bash scripts/release_draft_guard.sh "\${GITHUB_REF_NAME}"
''');
      final hits = windowsBashScriptSteps(probe.path);
      expect(hits, hasLength(2));
      expect(hits[0].$3, 'bash', reason: 'the pinned step is protected');
      expect(
        hits[1].$3,
        '<unset>',
        reason:
            'the unshelled guard step must be reported as unprotected — '
            'this is the exact gh-2432 shape',
      );
    });

    test('negative probe — job-level defaults.run.shell counts as bash', () {
      final dir = Directory.systemTemp.createTempSync('gh-2432-probe-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final probe = File('${dir.path}/probe.yml')..writeAsStringSync('''
defaults:
  run:
    shell: bash
jobs:
  binaries:
    runs-on: \${{ matrix.runner }}
    strategy:
      matrix:
        runner: [windows-latest]
    steps:
      - name: Draft lifecycle guard (delete orphaned draft on failure)
        run: bash scripts/release_draft_guard.sh "\${GITHUB_REF_NAME}"
''');
      final hits = windowsBashScriptSteps(probe.path);
      expect(hits, hasLength(1));
      expect(
        hits.single.$3,
        'bash',
        reason: 'workflow-level defaults.run.shell: bash protects the step',
      );
    });

    for (final path in workflowPaths) {
      final steps = windowsBashScriptSteps(path);
      if (steps.isEmpty) continue;
      test('${path.split('/').last}: every bash scripts/ step is shell-bash', () {
        for (final (job, step, shell) in steps) {
          expect(
            shell,
            'bash',
            reason:
                '$path job "$job" step "$step" invokes `bash scripts/…` with '
                'effective shell "$shell" — on a windows-latest runner the '
                'default shell is pwsh, where `\$GITHUB_REF_NAME`-style '
                'expansions inside the command line interpolate an UNDEFINED '
                'PowerShell variable (empty), so the bash script is invoked '
                'without its arguments. That is exactly how the gh-2432 '
                'release-draft lifecycle guard died on the v1.0.778 windows '
                'leg (run 45643151796: `line 36: 1: usage: '
                'release_draft_guard.sh <tag>`). Pin `shell: bash` on the '
                'step (or `defaults.run.shell: bash` on the job/workflow).',
          );
        }
      });
    }
  });

  group('AC2 — the guard stays meaningful', () {
    test('the repo still runs bash-script steps from windows-capable jobs', () {
      final all = [
        for (final path in workflowPaths) ...windowsBashScriptSteps(path),
      ];
      expect(
        all,
        isNotEmpty,
        reason:
            'the ci.yml binaries matrix keeps building release assets on '
            'windows-latest through bash release scripts — if every such '
            'step disappeared this guard is dead weight and should be '
            'revisited',
      );
    });
  });
}
