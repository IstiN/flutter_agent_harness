// gh-1511 rework review — the publish-fa-llm.yml pre-flight probe must
// use the repo's bounded-retry curl convention (ci.yml, nightly.yml,
// build-macos.yml). A bare curl has NO timeout (a hung pub.dev
// connection stalls the step until the job-level timeout) and NO retry
// (a transient blip yields code 000, which slips the publish past the
// 404-guard through the warn-and-continue branch). --retry-all-errors is
// required for --retry to cover probe-style transient failures (curl 56
// et al. — documented at ci.yml). Deliberately YAML-level asserts,
// matching the ci_pub_get_retry_guard_test.dart static pattern: a future
// bare curl is a test red, not a silent network roulette.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _workflowPath = '.github/workflows/publish-fa-llm.yml';
const _preflightStep = 'Pre-flight — package must already exist on pub.dev';

/// The `run:` block of the pre-flight step (the probe + the 404 exit-10
/// guard), single-spaced for flag assertions.
String _preflightRun() {
  final doc = loadYaml(File(_workflowPath).readAsStringSync()) as YamlMap;
  final jobs = doc['jobs'] as YamlMap;
  final steps = (jobs['publish'] as YamlMap)['steps'] as YamlList;
  for (final step in steps) {
    if (step is YamlMap && step['name'] == _preflightStep) {
      return (step['run'] as String).replaceAll('\n', ' ');
    }
  }
  fail(
    'pre-flight step "$_preflightStep" not found in $_workflowPath — '
    'update this test',
  );
}

void main() {
  test('workflow YAML parses and carries the OIDC pre-flight probe', () {
    final run = _preflightRun();
    expect(run, contains('curl'));
    expect(run, contains('https://pub.dev/api/packages/fa_llm'));
    // The #1511 guard itself: 404 ⇒ actionable message + exit 10.
    expect(run, contains('exit 10'));
  });

  test('pre-flight probe curl uses the repo retry/timeout convention', () {
    // Review threads 1+2 (gh-1511 rework): bare curl — add retry/timeout
    // flags per repo convention. Flags are asserted individually so a
    // partial fix (retry without timeout, or --retry without
    // --retry-all-errors) still reds.
    final run = _preflightRun();
    expect(run, contains('--retry 3'), reason: 'bounded retry count');
    expect(
      run,
      contains('--retry-all-errors'),
      reason:
          '--retry alone skips probe-style transient failures (curl 56) '
          '— the ci.yml convention requires --retry-all-errors',
    );
    expect(
      run,
      contains('--connect-timeout'),
      reason: 'a hung connection must fail fast, not stall to the job timeout',
    );
    expect(
      run,
      contains('--max-time'),
      reason: 'overall probe bound — the step must not outlive the guard',
    );
  });
}
