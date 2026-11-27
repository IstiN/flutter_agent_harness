// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1199 AC6 quarantine parity — the local `integration-mock` leg of
/// `scripts/ci_fast_gate.sh` (`stage_integration_mock`) selects its
/// targets through `scripts/apply_quarantine.py`, exactly like the two CI
/// legs that own the same selection (ci.yml jobs `integration-mock` and
/// `pty-integration-linux`).
///
/// Family: a file listed in `scripts/test_quarantine.json` is REMOVED from
/// every deterministic integration gate leg until its fix lands — nightly
/// still runs it. CI piped its target list through the filter, but the
/// local stage ran the bare `test/integration` directory, so the pre-commit
/// hook ran files CI never runs — and went red on them. On macOS both
/// quarantined legs are deterministic reds
/// (`pty_resume_equivalence_test.dart` AC1, issue #1422;
/// `header_badge_pty_test.dart`, issue #1469), so EVERY hook run that
/// triggers the stage (a commit touching `scripts/` or
/// `test/integration/**`) failed on pre-existing, already-quarantined
/// tests and forced a `--no-verify`.
///
/// Deliberately static asserts (ci_jsr_trio_load_drop_guard_test.dart
/// pattern) plus one behavioural check of the selection itself:
///  AC1  the two CI legs still pipe their selection through the filter
///       (the reference the local stage mirrors — a CI-side drop must
///       break this pin, not parity),
///  AC2  stage_integration_mock builds its target list through the
///       filter, and BOTH `dart test` invocations (the single-shot leg and
///       the flake-budget rerun loop) start from that filtered list,
///  AC3  the stage never runs the bare directory any more, and an
///       all-quarantined selection runs nothing (a bare `dart test` with
///       no path would silently run the whole default test tree),
///  AC4  behavioural: the selection the stage computes keeps every
///       un-quarantined file, drops every quarantined one, and prints a
///       `::warning::` line per drop (E3 — a quarantine never swallows a
///       regression silently).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const gate = 'scripts/ci_fast_gate.sh';
const filter = 'python3 scripts/apply_quarantine.py';
const quarantine = 'scripts/test_quarantine.json';
const findLine = "find test/integration -name '*_test.dart'";

String stageBody() {
  final text = read(gate);
  final start = text.indexOf('stage_integration_mock()');
  expect(start, greaterThan(0), reason: 'fixture: the stage exists');
  final next = text.indexOf('\nstage_', start + 1);
  return text.substring(start, next == -1 ? text.length : next);
}

/// Every `run:` block of [job] that mentions the quarantine filter.
List<String> filterRuns(String job) {
  final root = loadYaml(read(ci)) as YamlMap;
  final steps =
      ((root['jobs'] as YamlMap)[job] as YamlMap)['steps'] as YamlList;
  return [
    for (final step in steps.whereType<YamlMap>())
      if ((step['run']?.toString() ?? '').contains('apply_quarantine.py'))
        step['run'].toString(),
  ];
}

void main() {
  group(
    'gh-1199 AC6 — the local integration-mock leg rides the quarantine',
    () {
      test('AC1: the two CI legs pipe their selection through the filter', () {
        final mock = filterRuns('integration-mock');
        expect(mock, hasLength(1), reason: 'ci.yml integration-mock step');
        expect(mock.single, contains(findLine));
        expect(mock.single, contains(filter));

        final pty = filterRuns('pty-integration-linux');
        expect(pty, hasLength(1), reason: 'ci.yml pty-integration-linux step');
        expect(pty.single, contains('shard_files.py'));
        expect(pty.single, contains(filter));
      });

      test(
        'AC2: stage_integration_mock builds its targets through the filter',
        () {
          final body = stageBody();
          expect(body, contains(findLine));
          expect(
            body,
            contains('| sort \\'),
            reason: 'same sorted explicit file list as ci.yml',
          );
          expect(body, contains(filter));
          expect(
            body,
            contains('if [ -z "\$targets" ]'),
            reason: 'an all-quarantined selection runs nothing',
          );
          // The single-shot leg and the flake-budget rerun loop both start
          // from the filtered list — never from a hand-typed path.
          expect(
            '--concurrency=\$conc} \$targets'.allMatches(body).length,
            2,
            reason: 'both dart test invocations take \$targets',
          );
        },
      );

      test('AC3: the stage never runs the bare directory', () {
        final body = stageBody();
        expect(body, isNot(contains('targets="test/integration"')));
        expect(
          body,
          isNot(matches(RegExp(r'dart test [^\n]*\btest/integration\b'))),
          reason: 'a bare directory bypasses the quarantine filter',
        );
      });

      test(
        'AC4: the selection drops exactly the quarantined files, loudly',
        () async {
          final probe = Process.runSync('python3', ['--version']);
          if (probe.exitCode != 0) {
            markTestSkipped('python3 is required (the gate requires it too)');
          }
          final found = <String>[];
          await for (final entity in Directory(
            'test/integration',
          ).list(recursive: true)) {
            if (entity is File && entity.path.endsWith('_test.dart')) {
              found.add(entity.path.replaceAll(Platform.pathSeparator, '/'));
            }
          }
          expect(found, isNotEmpty, reason: 'fixture: the leg has targets');

          final entries =
              (jsonDecode(read(quarantine))
                      as Map<String, Object?>)['quarantined']
                  as List<Object?>;
          final quarantined = {
            for (final entry in entries.whereType<Map<String, Object?>>())
              entry['file']! as String,
          };
          final droppedHere = quarantined.where(found.contains).toSet();
          expect(
            droppedHere,
            isNotEmpty,
            reason: 'fixture: at least one quarantined file lives in the leg',
          );

          final proc = await Process.start('python3', [
            'scripts/apply_quarantine.py',
          ]);
          final out = proc.stdout.transform(utf8.decoder).join();
          final err = proc.stderr.transform(utf8.decoder).join();
          proc.stdin.write(found.join('\n'));
          await proc.stdin.flush();
          await proc.stdin.close();
          final code = await proc.exitCode;
          final warnings = (await err).split('\n');

          expect(code, 0, reason: warnings.join('\n'));
          final kept = (await out)
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toSet();
          expect(
            kept.intersection(quarantined),
            isEmpty,
            reason: 'no quarantined file reaches the leg',
          );
          expect(
            found.toSet().difference(quarantined),
            equals(kept),
            reason: 'the filter never drops an un-quarantined file',
          );
          for (final file in droppedHere) {
            expect(
              warnings.any(
                (line) => line.contains('::warning::') && line.contains(file),
              ),
              isTrue,
              reason: 'E3: the drop of $file must be visible in the gate log',
            );
          }
        },
      );
    },
  );
}
