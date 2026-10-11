// Issue #1267 N1/N2 (slice 2) — the path-triggered legs:
//
// Slice 1 (gh-1350) landed flutter-app-exzone path-BLIND under the SM's
// dispatch-only CI: it ran on EVERY validation dispatch, because the paths
// classifier had no pull_request event to diff. Slice 2 makes the
// classifier derive the validated diff itself — merge-base(origin/main,
// HEAD) on workflow_dispatch events (the PR fork point; the changes
// checkout is fetch-depth: 0) — so
//   AC1  a PR touching the exclusion-zone paths runs the macOS JS-engine
//        leg, and a PR touching only lib/src core does NOT pay for it,
//   AC2  a PR whose diff modifies flutter_app/pubspec.lock (#1265: the
//        transitive float that broke linux/windows release builds for 5
//        nights) additionally runs the new flutter-app-lock-smoke legs —
//        linux+windows flutter_app RELEASE builds — while PRs not
//        touching the lockfile pay nothing,
// and a failed classification fails SAFE (the rare-path arms run, never
// silently skip — over-triggering costs minutes, under-triggering hides a
// nightly-only red, the #1309 class).
//
// Deliberately YAML-level asserts (the ci_binaries_arch_gate_test.dart /
// ci_pub_get_retry_guard_test.dart static pattern): they pin the wiring —
// the legs themselves are exercised by CI, not locally (no local tests run
// GitHub runners).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

const ci = '.github/workflows/ci.yml';
const pubGetAction = './.github/actions/flutter-pub-get';
final exzoneGrep =
    r"grep -qE '(^flutter_app/lib/apps/|^lib/src/js_ext/|^flutter_app/test/apps/|^flutter_app/test/native_test_guard\.dart$|^flutter_app/pubspec\.yaml$)'";
final lockGrep = r"grep -qE '^flutter_app/pubspec\.lock$'";

YamlMap stepById(YamlMap job, String id) => (job['steps'] as YamlList)
    .map((s) => s as YamlMap)
    .firstWhere((s) => s['id'] == id);

void main() {
  final body = read(ci);
  final jobs = jobsOf(ci);
  final changes = jobs['changes'] as YamlMap;

  group('#1267 N1/N2 — dispatch-time path classification', () {
    test('the paths classifier runs on SM validation dispatches', () {
      final cond = stepById(changes, 'paths')['if'].toString();
      expect(cond, contains("github.event_name == 'pull_request'"));
      expect(
        cond,
        contains("github.event_name == 'workflow_dispatch'"),
        reason: 'PR validation IS a workflow_dispatch (dispatch-only CI) — '
            'a pull_request-only classifier leaves every narrowed arm '
            'path-blind on real validation runs (the slice-1 model)',
      );
    });

    test('the dispatch arm derives the validated diff from the fork point',
        () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(run, contains('git rev-parse HEAD'));
      expect(
        run,
        contains('git merge-base origin/main'),
        reason: 'no pull_request context exists on dispatches — the '
            'validated diff is the fork point with origin/main '
            '(fetch-depth: 0 carries it)',
      );
    });

    test('a failed classification fails SAFE — both rare-path arms run', () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(run, contains('failing safe: exzone + locksmoke arms run'));
      expect(run, contains('echo "exzone=true"'));
      expect(run, contains('echo "locksmoke=true"'));
    });

    test('the dispatch arm exits before the PR-only stages logic', () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(
        run.indexOf('exit 0'),
        lessThan(run.indexOf('ci_fast_gate')),
        reason: 'on dispatches the four group outputs must stay with the '
            'non-PR filter step (full gate) — the stages classifier reads '
            'a pull_request event base/head only',
      );
    });

    test('exzone keys on the exclusion-zone path set (single source)', () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(run, contains(exzoneGrep));
      expect(
        body.split(exzoneGrep).length - 1,
        1,
        reason: 'the exzone grep moved into the shared block — a second '
            'copy would let the two arms drift',
      );
    });

    test('locksmoke keys on the flutter_app/pubspec.lock diff (AC2)', () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(run, contains(lockGrep));
      final outputs = changes['outputs'] as YamlMap;
      expect(outputs['exzone'], contains('steps.paths.outputs.exzone'));
      expect(outputs['locksmoke'], contains('steps.paths.outputs.locksmoke'));
    });
  });

  group('#1267 AC1 — flutter-app-exzone is path-triggered', () {
    test('the leg consults the classifier output on BOTH events', () {
      final cond = (jobs['flutter-app-exzone'] as YamlMap)['if'].toString();
      expect(
        cond,
        contains("needs.changes.outputs.exzone == 'true'"),
        reason: 'the gh-1280-era unconditional dispatch arm is gone — a '
            'lib/src-only PR must never pay for the macOS leg again',
      );
      expect(cond, contains("github.event_name == 'workflow_dispatch'"));
      expect(cond, contains("github.event_name == 'pull_request'"));
    });
  });

  group('#1267 AC2 — flutter-app-lock-smoke', () {
    test('the leg exists and gates on the locksmoke output', () {
      final job = jobs['flutter-app-lock-smoke'] as YamlMap?;
      expect(job, isNotNull, reason: 'the lockfile smoke leg went missing');
      final cond = job!['if'].toString();
      expect(cond, contains("needs.changes.outputs.locksmoke == 'true'"));
      expect(cond, contains("github.event_name == 'workflow_dispatch'"));
      expect(cond, contains("github.event_name == 'pull_request'"));
    });

    test('the matrix builds BOTH nightly-only native targets', () {
      final job = jobs['flutter-app-lock-smoke'] as YamlMap;
      final include =
          ((job['strategy'] as YamlMap)['matrix'] as YamlMap)['include']
              as YamlList;
      final targets =
          include.map((e) => (e as YamlMap)['os'] as String).toSet();
      expect(targets, {'linux', 'windows'},
          reason: '#1265 broke exactly these two — the smoke must cover '
              'both, on the same hosted runners the nightly uses');
    });

    test('the resolve rides the shared --enforce-lockfile action', () {
      final steps = (jobs['flutter-app-lock-smoke'] as YamlMap)['steps']
          as YamlList;
      expect(
        steps
            .map((s) => (s as YamlMap)['uses'] as String?)
            .where((u) => u == pubGetAction)
            .length,
        1,
        reason: 'a bare flutter_app pub get would float the very transitive '
            'the smoke exists to catch (test/ci_pub_get_retry_guard_test '
            'AC2) — and the #726 retry must guard the cold git-dep clones',
      );
    });

    test('the legs are RELEASE builds with the pinned SDK', () {
      final job = read(ci).split('  flutter-app-lock-smoke:')[1];
      expect(
        job,
        contains(r'flutter build ${{ matrix.os }} --release'),
        reason: 'debug builds pass where release breaks (#1265 was '
            'release-only: R8/minify/tree-shake class) — the smoke must '
            'build what the nightly builds',
      );
      expect(job, contains("flutter-version: '3.47.x'"),
          reason: 'same pinned SDK as the nightly build-release legs (#281) '
              '— a floating SDK would smoke a different tree than ships');
    });

    test('a red smoke reddens the required Quality gate (platform class)',
        () {
      expect(
        body,
        contains('install-pin-gate, flutter-app-exzone, flutter-app-lock-smoke]'),
        reason: 'quality-gate must NEED the leg — a leg outside the '
            'aggregate never blocks the merge',
      );
      expect(body,
          contains('R_LOCK_SMOKE: \${{ needs.flutter-app-lock-smoke.result }}'));
      expect(
        body,
        contains(
            '"flutter-app-exzone:\$R_EXZONE" "flutter-app-lock-smoke:\$R_LOCK_SMOKE"; do'),
        reason: 'the verdict loop must consume the result — an unlisted '
            'need reports in the log and gates nothing',
      );
      expect(
        body,
        contains('pty-coverage-gate|pty-visual|flutter-app-lock-smoke)'),
        reason: 'platform class (#1368): a red windows release build blocks '
            'the MERGE via the aggregate but never holds the pure-Dart '
            'publish hostage',
      );
    });
  });
}
