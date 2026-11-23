// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #2331 — the sharded dart test legs ride the bounded loopback-ws
/// load-drop retry (`scripts/load_drop_retry.sh`).
///
/// Family: under CI-leg load the dart test loader's loopback WebSocket to a
/// freshly spawned test VM dies mid-handshake (`Failed to load "x_test.dart": Connection closed before full header was received` or
/// `Connection reset by peer, uri=http://127.0.0.1:…/ws`). Ten occurrences (issue card), all in
/// the `test-core` (×4) and `pty-integration-linux` (×3) shards on
/// ubuntu-24.04-arm; the victim file is arbitrary, every test that ran was
/// green. The wrapper re-runs ONLY the failed inventory — bounded (≤2
/// reruns, drain backoff; the gh-1026 rerun-only-failed discipline); a
/// concurrency cap was rejected: the PTY
/// leg dropped twice AT its explicit `--concurrency=4`, and lowering it
/// collides with the gh-1300 shard-duration budgets (420 s/shard, down-only
/// ratchet).
///
/// Deliberately YAML-level asserts (the ci_core_shard_upload_retry_guard_test.dart
/// static pattern):
///  AC1  both dropping shard steps invoke the wrapper with their main
///       reporter log and a separate retry log,
///  AC2  the wrapped command keeps the flags the consumers pin —
///       `--coverage=coverage` + `--file-reporter` (release_hygiene_test
///       pins the PTY leg's reporting; the coverage gate merges the lcovs)
///       and the PTY leg's explicit `--concurrency=4`,
///  AC3  the junit steps still convert the MAIN log (attempt-1 evidence
///       intact; a healed rerun writes to …retry.json and is never clobbered),
///  AC4  the wrapper script exists on disk.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const wrapper = 'scripts/load_drop_retry.sh';

List<YamlMap> jobSteps(String jobId) {
  final root = loadYaml(read(ci)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[jobId];
  if (job is! YamlMap) throw StateError('job $jobId missing from $ci');
  return (job['steps'] as YamlList).whereType<YamlMap>().toList();
}

/// The run-text of the steps that invoke the retry wrapper.
List<String> wrappedRuns(String jobId) => [
  for (final step in jobSteps(jobId))
    if ((step['run']?.toString() ?? '').contains(wrapper))
      step['run'].toString(),
];

void expectWrapped(String run, String logPath) {
  expect(run, contains(wrapper));
  expect(run, contains('"$logPath"'), reason: 'main reporter log argument');
  expect(
    run,
    contains('"${logPath.replaceAll('.json', '.retry.json')}"'),
    reason:
        'the rerun must write to a separate retry log — the main log '
        'is attempt-1 evidence for junit/duration consumers',
  );
  expect(
    run,
    contains('--coverage=coverage'),
    reason:
        'a healed rerun inherits the coverage flag — the dropped file '
        'must land in the lcov the gate merges',
  );
  expect(run, contains('--file-reporter'), reason: 'junit/duration feed');
}

void main() {
  group('#2331 — sharded dart test legs ride the load-drop retry', () {
    test('AC4: the wrapper script exists', () {
      expect(File(wrapper).existsSync(), isTrue);
    });

    test('AC1/AC2: the core shard step is wrapped and keeps its flags', () {
      final runs = wrappedRuns('test-core');
      expect(runs, hasLength(1), reason: 'exactly the dart test shard step');
      expectWrapped(
        runs.single,
        'build/test-results/dart-shard-\${{ matrix.shard }}.json',
      );
      expect(runs.single, contains('--exclude-tags integration'));
      expect(
        runs.single,
        contains('junit_from_dart_json.py'),
        reason:
            'the junit conversion stays in the same step after the '
            'wrapped run',
      );
    });

    test('AC1/AC2: the PTY shard step is wrapped and keeps its flags', () {
      final runs = wrappedRuns('pty-integration-linux');
      expect(runs, hasLength(1), reason: 'exactly the dart test shard step');
      expectWrapped(
        runs.single,
        'build/test-results/integration-shard-\${{ matrix.shard }}.json',
      );
      expect(
        runs.single,
        contains('--concurrency=4'),
        reason:
            'the explicit in-suite cap stays — a concurrency-cap '
            'mitigation was rejected (gh-1300 420 s/shard down-only budget; '
            'occ1/occ5 dropped AT the cap)',
      );
    });

    test('AC3: junit steps convert the MAIN log only', () {
      final coreRun = wrappedRuns('test-core').single;
      expect(
        coreRun,
        contains('junit_from_dart_json.py'),
        reason:
            'the junit conversion stays in the same step after the '
            'wrapped run',
      );
      expect(
        '.retry.json'.allMatches(coreRun),
        hasLength(1),
        reason:
            'the retry log path appears ONLY in the wrapper arguments — '
            'the junit conversion keeps reading the attempt-1 main log',
      );
      final ptySteps = jobSteps('pty-integration-linux');
      final junitSteps = [
        for (final step in ptySteps)
          if ((step['run']?.toString() ?? '').contains('junit_from_dart_json'))
            step['run'].toString(),
      ];
      expect(
        junitSteps.join('\n'),
        contains(
          'build/test-results/integration-shard-\${{ matrix.shard }}.json',
        ),
        reason: 'the PTY junit step (always()) keeps reading the main log',
      );
      expect(
        junitSteps.join('\n'),
        isNot(contains('.retry.json')),
        reason: 'no consumer reads the retry log — it is rerun evidence only',
      );
    });
  });
}
