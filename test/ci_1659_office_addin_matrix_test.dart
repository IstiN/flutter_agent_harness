// gh-1659 — the Office add-in acceptance suite folds into the shared
// ci.yml matrix. The suite lived in office-addin.yml under push/
// pull_request triggers, so every lib/**- or flutter_app/**-touching PR
// paid for a SECOND standalone workflow whose check had to be tracked
// separately in branch protection. Now:
//  AC1  a lib/**-only PR runs the office-addin suite INSIDE ci.yml (one
//       workflow entry per push), path-gated on a new `office_addin`
//       changes output carrying the exact path list the standalone
//       triggers used,
//  AC2  office-addin.yml keeps ONLY workflow_dispatch (the daily-publish
//       addin leg still dispatches it — its #423 dispatch group stays
//       intact); the push/pull_request blocks are gone so a PR never
//       spawns the separate workflow again,
//  AC3  the check name stays coherent for the ruleset: the moved job
//       keeps the bare check-run name "Office add-in suite" (only the
//       workflow display prefix changes to "CI / …"),
//  AC4  no path-skip regression: out-of-scope PRs skip the leg exactly as
//       today, and a red suite reddens the required Quality gate
//       (platform class, #1368) while skipped reporting stays correct.
//
// Deliberately YAML-level asserts (the ci_binaries_arch_gate_test.dart /
// ci_1267_path_triggered_legs_test.dart static pattern): they pin the
// wiring — the suite itself is exercised by CI, not locally (no local
// tests run GitHub runners). The job body exists in TWO files on purpose
// (ci.yml = the PR gate, office-addin.yml = the dispatch-only daily leg);
// the step-parity test below is the drift guard that keeps both copies
// running the same suite.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

const ci = '.github/workflows/ci.yml';
const addin = '.github/workflows/office-addin.yml';
const legId = 'office-addin-suite';

/// The exact path list the retired standalone office-addin.yml push/PR
/// triggers carried (C1: "same path list as today").
final officeAddinGrep =
    r"grep -qE '(^office_addin/|^flutter_app/|^packages/|^lib/"
    r"|^pubspec\.lock$|^scripts/build_office_addin\.sh$"
    r"|^\.github/workflows/office-addin\.yml$)'";

/// Recursively convert the yaml package's unmodifiable views into plain
/// Dart structures so two job step-lists can be deep-compared.
Object? plain(Object? node) {
  if (node is YamlMap) {
    return {
      for (final e in node.entries) plain(e.key): plain(e.value),
    };
  }
  if (node is YamlList) {
    return [for (final e in node) plain(e)];
  }
  return node;
}

void main() {
  final ciBody = read(ci);
  final ciJobs = jobsOf(ci);
  final addinBody = read(addin);
  final addinJobs = jobsOf(addin);

  group('AC2 — office-addin.yml is dispatch-only', () {
    final on = loadYaml(addinBody)['on'] as YamlMap;

    test('workflow_dispatch stays; push and pull_request are gone', () {
      expect(
        on.containsKey('workflow_dispatch'),
        isTrue,
        reason:
            'daily-publish.yml dispatches this workflow for the addin leg '
            '(issues #343/#344 watcher) — the entry must survive',
      );
      expect(
        on.containsKey('push'),
        isFalse,
        reason:
            'gh-1659 AC2: a push must never spawn the standalone Office '
            'add-in workflow again — the gate lives in ci.yml now',
      );
      expect(
        on.containsKey('pull_request'),
        isFalse,
        reason:
            'gh-1659 AC2: a PR must never spawn the standalone Office '
            'add-in workflow again (two CI entries per push today)',
      );
    });

    test('the #423 dispatch-group concurrency block stays intact', () {
      final concurrency = loadYaml(addinBody)['concurrency'] as YamlMap;
      final group = concurrency['group'].toString();
      expect(
        group,
        contains("github.event_name == 'workflow_dispatch'"),
        reason:
            'issue #423: a workflow_dispatch run (the daily-publish addin '
            'leg) gets its OWN concurrency group so a push landing '
            'mid-daily cannot cancel it — the special-case must survive '
            'the trigger retirement',
      );
      expect(group, contains('dispatch-{0}'));
      expect(concurrency['cancel-in-progress'], isTrue);
    });

    test('the daily leg still has a real job to dispatch and watch', () {
      final job = addinJobs[legId] as YamlMap?;
      expect(
        job,
        isNotNull,
        reason:
            'daily-publish.yml dispatch_and_watch.sh office-addin.yml '
            'waits on this job — an empty workflow would break the daily '
            'train (test matrix: "the daily dispatch leg still works")',
      );
      expect(job!['timeout-minutes'], 45,
          reason: '#351 watcher budget arithmetic pins the 45m ceiling');
      expect((job['permissions'] as YamlMap)['contents'], 'read');
    });
  });

  group('AC1 — the suite runs inside the ci.yml matrix', () {
    test('the office-addin-suite leg exists in ci.yml', () {
      expect(ciJobs[legId], isNotNull,
          reason: 'the leg must move INTO the shared matrix');
    });

    test('the leg is path-gated on the new office_addin output', () {
      final cond = (ciJobs[legId] as YamlMap)['if'].toString();
      expect(
        cond,
        contains("needs.changes.outputs.office_addin == 'true'"),
        reason:
            'AC4: a PR touching none of the office-addin paths must skip '
            'the leg exactly as the standalone path filter did',
      );
      // Same two-event guard as exzone/locksmoke: pull_request events AND
      // SM validation dispatches (the pre-merge gate under dispatch-only
      // CI). Tags/schedule/release never ran the suite and still don't.
      expect(cond, contains("github.event_name == 'pull_request'"));
      expect(cond, contains("github.event_name == 'workflow_dispatch'"));
      expect(
        cond,
        contains("needs.release-pending.outputs.pending == 'true'"),
        reason: 'gh-1551: the empty-schedule-tick pre-check gates every leg',
      );
      expect(
        cond,
        contains("needs.release-dedupe.outputs.dedupe != 'true'"),
        reason: 'gh-1625: the release-twin pre-check gates every leg',
      );
    });

    test('the classifier emits office_addin for both events', () {
      final outputs = (ciJobs['changes'] as YamlMap)['outputs'] as YamlMap;
      expect(
        outputs['office_addin'].toString(),
        contains('steps.paths.outputs.office_addin'),
        reason:
            'the output rides the paths step (pull_request + validation '
            'dispatches), NOT the non-PR full-gate filter — tags/schedule '
            'never ran the suite and still skip it',
      );
    });

    test('the classifier keys on the exact retired trigger path list', () {
      final run = read(ci)
          .split('\n  changes:')[1]
          .split('\n  # ─')[0]; // the changes job body only
      expect(run, contains(officeAddinGrep));
      expect(
        ciBody.split(officeAddinGrep).length - 1,
        1,
        reason: 'single source — a second copy would let the arms drift',
      );
    });

    test('the classifier failure arm runs the leg (fail-safe)', () {
      final run = read(ci)
          .split('\n  changes:')[1]
          .split('\n  # ─')[0];
      expect(
        run,
        contains('echo "office_addin=true"'),
        reason:
            'a failed classification must over-trigger, never silently '
            'skip — the #1309 class (same arm as exzone/locksmoke/installer)',
      );
      expect(run, contains('failing safe: exzone + locksmoke arms run'));
    });

    test('the office_addin arm classifies validation dispatches too', () {
      final run = read(ci)
          .split('\n  changes:')[1]
          .split('\n  # ─')[0];
      final armAt = run.indexOf(officeAddinGrep);
      final dispatchExitAt = run.indexOf('!= "pull_request"');
      expect(armAt, greaterThan(-1));
      expect(dispatchExitAt, greaterThan(-1));
      expect(
        armAt < dispatchExitAt,
        isTrue,
        reason:
            'the arm must sit before the dispatch early-exit — the SM '
            'validation dispatch IS the pre-merge gate (dispatch-only '
            'CI); a classification after the exit is path-blind there',
      );
    });

    test('the two job copies run the SAME suite (drift guard)', () {
      final ciSteps = ((ciJobs[legId] as YamlMap)['steps'] as YamlList)
          .map(plain)
          .toList();
      final addinSteps =
          ((addinJobs[legId] as YamlMap)['steps'] as YamlList)
              .map(plain)
              .toList();
      expect(
        ciSteps,
        equals(addinSteps),
        reason:
            'the PR gate (ci.yml) and the daily leg (office-addin.yml) '
            'must run the identical step pipeline — "no behavior change to '
            'what the job runs"; update BOTH copies together',
      );
    });

    test('runner/timeout/permissions parity with the retired job', () {
      final ciJob = ciJobs[legId] as YamlMap;
      final addinJob = addinJobs[legId] as YamlMap;
      expect(ciJob['runs-on'], addinJob['runs-on'],
          reason: 'same runner pool as today (ubuntu-latest, x64)');
      expect(ciJob['timeout-minutes'], addinJob['timeout-minutes'],
          reason: '#351 watcher budget arithmetic pins the 45m ceiling');
      expect((ciJob['permissions'] as YamlMap)['contents'],
          (addinJob['permissions'] as YamlMap)['contents'],
          reason: 'SEC-08: the leg keeps its minimal contents: read');
    });
  });

  group('AC3 — the check name stays ruleset-coherent', () {
    test('the moved job keeps the bare check-run name', () {
      expect(
        (ciJobs[legId] as YamlMap)['name'],
        (addinJobs[legId] as YamlMap)['name'],
        reason:
            'branch protection / rulesets match the CHECK-RUN name, which '
            'is the job name — keeping "Office add-in suite" means the '
            'required context survives the move; only the workflow display '
            'prefix changes (Office add-in / … → CI / Office add-in suite)',
      );
      expect((ciJobs[legId] as YamlMap)['name'], 'Office add-in suite');
    });
  });

  group('AC4 — a red suite blocks the merge via the Quality gate', () {
    test('quality-gate NEEDS the leg', () {
      final gate = ciJobs['quality-gate'] as YamlMap;
      final needs = gate['needs'];
      final needsList =
          needs is YamlList ? needs.map((n) => n.toString()) : [needs!];
      expect(
        needsList,
        contains(legId),
        reason:
            'a leg outside the aggregate never blocks the merge — the '
            'quality gate is the single required check',
      );
    });

    test('the verdict loop consumes the leg result', () {
      expect(
        ciBody,
        contains('R_OFFICE_ADDIN: \${{ needs.office-addin-suite.result }}'),
      );
      expect(
        ciBody,
        contains('"office-addin-suite:\$R_OFFICE_ADDIN"'),
        reason:
            'the verdict loop must consume the result — an unlisted need '
            'reports in the log and gates nothing',
      );
    });

    test('the leg is platform class (never holds the dart publish)', () {
      final gateRun = ciBody
          .split('\n  quality-gate:')[1]
          .split('\n  # ─')[0];
      final caseBody =
          gateRun.split('case "\$name" in')[1].split('esac')[0];
      expect(
        caseBody,
        contains('office-addin-suite'),
        reason:
            '#1368 platform class: a red office-addin e2e reddens the '
            'required aggregate (blocks the MERGE) but never gates '
            'dart_ok — a browser-suite red must not hold the pure-Dart '
            'pub.dev publish hostage',
      );
    });
  });
}
