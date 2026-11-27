// The pre-commit hook drops the coverage stage — CI-only coverage (the
// owner's hook-speed directive on PR #2435).
//
// Facts pinned here (verified before the change landed): CI computes its
// own coverage (the ci.yml test-core shards instrument `dart test
// --coverage=coverage` ×4, the coverage-gate job merges the per-shard
// artifacts and owns the diff-coverage / main ratchet) and NEVER consumes
// the hook's coverage/ dir; the hook is a thin wrapper over
// scripts/ci_fast_gate.sh. The instrumentation tax is the hook's slowest
// leg and bought nothing the CI does not re-pay.
//
//   AC1  hook mode selects the core/integ/all stage lists WITHOUT
//        coverage (behavioral: the gate's own --dry-run derives them);
//   AC2  non-hook runs keep coverage in every stage list — the ci.yml
//        fallback parity (the workflow invokes this same script without
//        --hook on fallback paths);
//   AC3  an explicit `--stages coverage` still selects the stage
//        standalone, even in hook mode (the fail-path guard);
//   AC4  stage_test_core instruments ONLY when the coverage stage is
//        selected (the `--coverage=coverage` flag is assigned under
//        `stage_selected coverage` and applied via the conditional — the
//        actual speed win is the uninstrumented dart test), and the jsr
//        trio leg keeps its in-body literal (AC2 of
//        ci_jsr_trio_load_drop_guard_test.dart stays satisfied);
//   AC5  CI parity holds: ci.yml still has the coverage-gate job and its
//        shards still pass --coverage explicitly.
//
// Behavioral where cheap (dry-run runs nothing), textual where the wiring
// itself is the contract (the ci_integration_mock_quarantine_guard_test
// pattern).
import 'dart:io';

import 'dart:convert' show utf8;

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const gate = 'scripts/ci_fast_gate.sh';
const ci = '.github/workflows/ci.yml';

Future<String> dryRun(List<String> args) async {
  final result = await Process.run(
    'bash',
    [gate, '--dry-run', ...args],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: 'dry-run must succeed: ${result.stderr}');
  return result.stdout as String;
}

String gateBody() => File(gate).readAsStringSync();

void main() {
  group('hook drops the coverage stage — CI-only coverage', () {
    test('AC1: hook mode derives the stage lists WITHOUT coverage', () async {
      for (final scope in ['core', 'integ', 'all']) {
        final out = await dryRun(['--hook', '--scope', scope]);
        expect(
          out,
          isNot(contains('coverage')),
          reason:
              '--hook --scope $scope must not select the coverage '
              'stage:\n$out',
        );
        expect(out, contains('test-core'), reason: out);
      }
      // The integ hook list keeps the no-key legs; the all hook list keeps
      // flutter (the hook's slow legs are the tests, not the ratchets).
      final integ = await dryRun(['--hook', '--scope', 'integ']);
      expect(integ, contains('integration-mock'), reason: integ);
      final all = await dryRun(['--hook', '--scope', 'all']);
      expect(all, contains('flutter'), reason: all);
    });

    test('AC2: non-hook runs keep coverage (ci.yml fallback parity)', () async {
      final core = await dryRun(['--scope', 'core']);
      expect(core, contains('coverage'), reason: core);
      final all = await dryRun(['--scope', 'all']);
      expect(all, contains('coverage'), reason: all);
    });

    test(
      'AC3: explicit --stages coverage still runs standalone in hook mode',
      () async {
        final out = await dryRun(['--hook', '--stages', 'coverage']);
        expect(out, contains('coverage'), reason: out);
      },
    );

    test(
      'AC4: test-core instruments only when the coverage stage is selected',
      () {
        final body = gateBody();
        final stage = body.indexOf('stage_test_core()');
        expect(stage, greaterThan(0), reason: 'fixture: stage exists');
        final next = body.indexOf('\nstage_', stage + 1);
        final text = body.substring(stage, next == -1 ? body.length : next);
        // The flag is assigned under the selection guard and applied via the
        // conditional — never unconditionally on the dart test lines.
        expect(
          text,
          contains('if stage_selected coverage; then'),
          reason:
              'the instrumentation must be conditional on the '
              'coverage stage',
        );
        expect(text, contains('cov_flags="--coverage=coverage"'));
        expect(text, contains('\$cov_flags --exclude-tags integration'));
        expect(text, contains('\$cov_flags \\'));
        expect(
          text,
          isNot(contains('--coverage=coverage --exclude-tags')),
          reason:
              'the unconditioned literal must not survive: the hook '
              'dart test must run without instrumentation',
        );
      },
    );

    test(
      'AC5: CI parity — the coverage-gate job and its --coverage shards',
      () {
        final jobs =
            (loadYaml(File(ci).readAsStringSync())['jobs'] ?? {}) as YamlMap;
        expect(
          jobs.keys,
          contains('coverage-gate'),
          reason:
              'the ratchet moved OUT of the hook, not out of existence: '
              'CI keeps the coverage-gate job',
        );
        final workflow = File(ci).readAsStringSync();
        expect(
          'dart test --coverage=coverage --exclude-tags integration'.allMatches(
            workflow,
          ),
          isNotEmpty,
          reason: 'the test-core shards keep their explicit instrumentation',
        );
      },
    );
  });
}
