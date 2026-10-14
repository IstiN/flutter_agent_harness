// gh-1596 REG-1/REG-2 — the installer sh-portability CI legs.
//
// The #1596 crash shipped because the wizard's POSIX artifacts had no
// dialect proof: the goldens diffed CONTENT but every leg ran under the
// author's bash. These pins keep the proof wired:
//   REG-1  a PR touching site/** or the generator runs
//          installer-portability (ubuntu: dash + busybox ash — the actual
//          `curl | sh` dialects; macOS: bash — REG-2, the shell whose
//          POSIX mode macOS sh IS) and a red leg blocks the merge via the
//          quality-gate platform class,
//   REG-2  the leg matrix carries both OSes so the dash-first template is
//          proven on the bash-3.2 host too,
// and the circuit stays CLOSED: the same two events gate it (pull_request
// + SM validation dispatch), a failed classification fails SAFE, and the
// path-triggered leg never leaks into the fast gate or the watchdog.
//
// Deliberately YAML-level asserts (the ci_1267 pattern): they pin the
// wiring — the legs are exercised by CI, not locally.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

const ci = '.github/workflows/ci.yml';
final installerGrep = r"'(^site/|^scripts/gen_installers\.dart$)'";

YamlMap stepById(YamlMap job, String id) => (job['steps'] as YamlList)
    .map((s) => s as YamlMap)
    .firstWhere((s) => s['id'] == id);

void main() {
  final body = read(ci);
  final jobs = jobsOf(ci);
  final changes = jobs['changes'] as YamlMap;

  group('gh-1596 REG-1 — path classification', () {
    test('the classifier exposes an installer output', () {
      final outputs = changes['outputs'] as YamlMap;
      expect(
        outputs['installer'],
        isNotNull,
        reason: 'without the output the gated leg can never consult it',
      );
      expect(outputs['installer'], contains('steps.paths.outputs.installer'));
    });

    test('installer arms key on site/** + the generator (single source)', () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(run, contains(installerGrep));
      expect(
        body.split(installerGrep).length - 1,
        1,
        reason:
            'a second copy of the path set would let the arms drift '
            '(the exzone single-source rule, #1267)',
      );
    });

    test('a failed classification fails SAFE — the installer arm runs', () {
      final run = stepById(changes, 'paths')['run'] as String;
      expect(
        run,
        contains('echo "installer=true"'),
        reason:
            'under-triggering hides a red the gate never sees '
            '(the #1309 class); over-triggering costs minutes',
      );
    });
  });

  group('gh-1596 REG-1/REG-2 — installer-portability leg', () {
    test('the leg exists and consults the classifier on the shared events', () {
      final job = jobs['installer-portability'] as YamlMap?;
      expect(job, isNotNull, reason: 'the sh-portability leg went missing');
      final cond = job!['if'].toString();
      expect(cond, contains("needs.changes.outputs.installer == 'true'"));
      expect(
        cond,
        contains("needs.release-pending.outputs.pending == 'true'"),
        reason:
            'same closed circuit as every other gated leg (gh-1551): '
            'a gated arm must never run when the release tick is empty',
      );
    });

    test('the matrix carries the curl|sh dialect host AND the bash host', () {
      final job = jobs['installer-portability'] as YamlMap;
      final os =
          ((job['strategy'] as YamlMap)['matrix'] as YamlMap)['os'] as YamlList;
      expect(
        os.map((e) => e as String).toSet(),
        {'ubuntu-latest', 'macos-latest'},
        reason:
            'ubuntu carries dash (Ubuntu /bin/sh) + busybox ash '
            '(Alpine); macOS proves the bash-direct path (REG-2) — a '
            'single-OS matrix re-creates the #1596 blind spot on the '
            'missing host',
      );
    });

    test('the ubuntu leg installs BOTH piped-dialect shells', () {
      final job = read(ci).split('  installer-portability:')[1];
      expect(
        job,
        contains('apt-get install -y --no-install-recommends dash busybox'),
        reason:
            'a dash-only ubuntu leg never runs busybox ash — the '
            'Alpine `curl | sh` dialect regresses invisibly',
      );
    });

    test('the leg runs the UT + IT entrypoints explicitly', () {
      final job = read(ci).split('  installer-portability:')[1];
      expect(
        job,
        contains(
          'dart test test/site/setup_sh_portability_test.dart '
          'test/site/installer_golden_test.dart',
        ),
      );
      expect(
        job,
        contains(
          'dart test test/integration/setup_wizard_portability_test.dart',
        ),
      );
    });
  });

  group('gh-1596 — a red leg blocks the merge (platform class)', () {
    test('quality-gate needs the leg, consumes its result, classifies it', () {
      expect(
        body,
        contains('installer-portability, installer-verify'),
        reason:
            'quality-gate must NEED the leg — a leg outside the '
            'aggregate never blocks the merge',
      );
      expect(
        body,
        contains('R_INSTALLER_REG: \${{ needs.installer-portability.result }}'),
      );
      expect(
        body,
        contains('"installer-portability:\$R_INSTALLER_REG"'),
        reason:
            'the verdict loop must consume the result — an unlisted '
            'need reports in the log and gates nothing',
      );
      expect(
        body,
        contains('flutter-app-lock-smoke|installer-portability)'),
        reason:
            'platform class (#1368): a red macOS leg blocks the MERGE '
            'via the aggregate but never holds the pure-Dart publish '
            'hostage',
      );
    });

    test('the leg stays OUT of the fast gate, watchdog and stage lists', () {
      final fastStages =
          stepById(jobs['changes'] as YamlMap, 'paths')['run'] as String;
      expect(
        fastStages,
        isNot(contains('installer-portability')),
        reason:
            'path-triggered platform legs ride the full gate only '
            '(the exzone/locksmoke model) — the fast gate stays cheap',
      );
      final watchdog = (jobs['watchdog'] as YamlMap)['needs'].toString();
      expect(
        watchdog,
        isNot(contains('installer-portability')),
        reason:
            'the watchdog waits on the always-on longest legs; '
            'path-triggered legs are not on that list (exzone/locksmoke '
            'precedent)',
      );
    });
  });
}
