// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #2227 — the jsr delegate trio (the unit-lcov producer for the
/// `lib/src/cli` jsr hits) rides the one-shot loopback-ws load-drop retry
/// (`scripts/load_drop_retry.sh`, issue #2331) in BOTH legs that run it,
/// and the #2228 quarantine entry is retired.
///
/// Family: under CI-leg load the dart test loader's loopback WebSocket to
/// a freshly spawned test VM dies mid-handshake (`Failed to load "x.dart":
/// Connection closed before full header was received`, uri =
/// http://127.0.0.1:…/ws). All four jsr_cli_test.dart reds (issue #2227:
/// runs 43861013338, 43994366865, 44149246706, 44167780049 — 4 distinct
/// SHAs) were loader drops: 89 tests green, only the `loading …`
/// pseudo-test red. The trio rides NO quarantine filter (gh-1033: the CLI
/// coverage ratchet needs these hits), so the two legs pinned here were
/// the last unhealed surface for the family; the PTY shards have been
/// wrapped since #2331, and the integration-mock leg never selects
/// test/cli files at all (it finds test/integration only).
///
/// Deliberately static asserts (ci_load_drop_retry_guard_test.dart
/// pattern):
///  AC1  the ci.yml test-core trio step is wrapped and keeps its flags
///       (--tags integration, --coverage=coverage, all three files),
///  AC2  ci_fast_gate.sh stage_test_core is wrapped identically (the two
///       target lists must stay in sync — gh-1538: the pre-merge gate is
///       the single unit-lcov producer),
///  AC3  no junit consumer reads the trio logs (lcov-only evidence),
///  AC4  jsr_cli_test.dart is NOT in scripts/test_quarantine.json — the
///       load-drop class heals at runtime on every leg that runs the
///       file; a re-quarantine would silently drop it from the PTY shard
///       selection and dilute the CLI coverage ratchet. Re-add ONLY for a
///       non-load-drop flake and update this pin in the same PR.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const gate = 'scripts/ci_fast_gate.sh';
const wrapper = 'scripts/load_drop_retry.sh';
const trioFiles = [
  'test/cli/jsr_cli_test.dart',
  'test/cli/cli_args_jsr_test.dart',
  'test/cli/agent_cli_jsr_test.dart',
];
const trioLog = 'build/test-results/cli-trio-lcov.json';

String trioStepRun() {
  final root = loadYaml(read(ci)) as YamlMap;
  final steps =
      ((root['jobs'] as YamlMap)['test-core'] as YamlMap)['steps'] as YamlList;
  for (final step in steps.whereType<YamlMap>()) {
    if ((step['name']?.toString() ?? '').contains('jsr delegate trio')) {
      return step['run'].toString();
    }
  }
  throw StateError('jsr delegate trio step missing from $ci');
}

void main() {
  group('#2227 — the jsr trio rides the load-drop retry in both legs', () {
    test('AC1: ci.yml test-core trio step is wrapped and keeps its flags', () {
      final run = trioStepRun();
      expect(run, contains(wrapper));
      expect(run, contains('"$trioLog"'), reason: 'main reporter log argument');
      expect(
        run,
        contains('build/test-results/cli-trio-lcov.retry.json'),
        reason:
            'the rerun writes to a separate retry log — attempt-1 '
            'evidence is never clobbered',
      );
      expect(run, contains('--tags integration'), reason: 'ratchet source tag');
      expect(
        run,
        contains('--coverage=coverage'),
        reason:
            'a healed rerun inherits coverage — the dropped file must '
            'land in the lcov the gate merges',
      );
      expect(
        run,
        contains('--file-reporter'),
        reason: 'wrapper inventory feed',
      );
      for (final file in trioFiles) {
        expect(run, contains(file));
      }
    });

    test('AC2: ci_fast_gate.sh stage_test_core is wrapped identically', () {
      final gateText = read(gate);
      final stage = gateText.indexOf('stage_test_core()');
      expect(stage, greaterThan(0), reason: 'fixture: stage exists');
      final next = gateText.indexOf('\nstage_', stage + 1);
      final body = gateText.substring(
        stage,
        next == -1 ? gateText.length : next,
      );
      expect(body, contains(wrapper));
      expect(body, contains('"$trioLog"'));
      expect(body, contains('cli-trio-lcov.retry.json'));
      expect(body, contains('--coverage=coverage'));
      expect(body, contains('--file-reporter'));
      for (final file in trioFiles) {
        expect(body, contains(file));
      }
    });

    test('AC3: no junit consumer reads the trio logs', () {
      final jobs = (loadYaml(read(ci)) as YamlMap)['jobs'] as YamlMap;
      final consumers = <String>[];
      for (final job in jobs.values.whereType<YamlMap>()) {
        final steps = job['steps'];
        if (steps is! YamlList) continue;
        for (final step in steps.whereType<YamlMap>()) {
          final run = step['run']?.toString() ?? '';
          if (run.contains('junit_from_dart_json') &&
              run.contains('cli-trio-lcov')) {
            consumers.add(run);
          }
        }
      }
      expect(
        consumers,
        isEmpty,
        reason:
            'the trio evidence is lcov-only — no junit conversion reads '
            'cli-trio-lcov.json',
      );
    });

    test(
      'AC4: jsr_cli_test.dart is un-quarantined (wrapper heals the class)',
      () {
        final quarantine =
            jsonDecode(read('scripts/test_quarantine.json'))
                as Map<String, dynamic>;
        final files = [
          for (final entry
              in (quarantine['quarantined'] as List)
                  .cast<Map<String, dynamic>>())
            entry['file'] as String,
        ];
        expect(
          files,
          isNot(contains('test/cli/jsr_cli_test.dart')),
          reason:
              'the #2227 load-drop class heals at runtime via the wrapper on '
              'every leg that runs the file — a quarantine entry would '
              'silently drop it from the PTY shard selection and dilute the '
              'CLI coverage ratchet (gh-1033). Re-add ONLY for a '
              'non-load-drop flake and update this pin in the same PR.',
        );
      },
    );
  });
}
