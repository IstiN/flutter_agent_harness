// Regression guard for the 2026-09-29 live incident (PR #1092): the
// `machine-sm.yml` workflow_dispatch input `dryRun` DEFAULTS TO `true`, so
// any `gh workflow run machine-sm.yml` that forgets an explicit
// `-f dryRun=` flag silently no-ops — the rescue tick logs its plan and
// performs no action while the SM stays idle.
//
// Text-level grep-guard over every workflow file (repo convention:
// test/store_automation_guard_test.dart, factory_stub_ref_test.dart): every
// dispatch site must carry the explicit flag, and the sm-kicker rescue
// dispatch is pinned verbatim.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final workflowDir = Directory('.github/workflows');
  final workflowFiles =
      workflowDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  group('sm-kicker live-tick guard (#1092)', () {
    test('machine-sm.yml keeps the dryRun=true dispatch trap documented', () {
      final doc =
          loadYaml(File('.github/workflows/machine-sm.yml').readAsStringSync())
              as YamlMap;
      // yaml 1.1 parses the bare key `on:` as boolean true — accept both.
      final trig = (doc['on'] ?? doc[true]) as YamlMap? ?? YamlMap();
      final dispatch = trig['workflow_dispatch'] as YamlMap? ?? YamlMap();
      final inputs = dispatch['inputs'] as YamlMap? ?? YamlMap();
      final dryRun = inputs['dryRun'] as YamlMap? ?? YamlMap();
      expect(
        dryRun['default'],
        true,
        reason:
            'machine-sm.yml workflow_dispatch dryRun default must stay true '
            '(cron ticks pass no input and must run live; manual dispatches '
            'MUST pass -f dryRun=false). If you are flipping this default, '
            'update sm_kicker_test.dart deliberately.',
      );
    });

    test('every machine-sm.yml dispatch site passes -f dryRun= explicitly', () {
      var dispatchSites = 0;
      for (final file in workflowFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('gh workflow run machine-sm.yml')) continue;
          dispatchSites++;
          // Command window: the dispatch line plus up to 4 continuation
          // lines, so flag-splitting (`... \` / `-f dryRun=false`) counts.
          final window = lines.skip(i).take(5).join('\n');
          expect(
            window,
            contains('dryRun='),
            reason:
                '${file.path}:${i + 1} dispatches machine-sm.yml without an '
                'explicit `-f dryRun=` flag — the input defaults to true and '
                'the tick will silently no-op (live incident 2026-09-29 '
                '21:14-21:24Z). Pass -f dryRun=false.',
          );
        }
      }
      expect(
        dispatchSites,
        greaterThanOrEqualTo(1),
        reason:
            'expected the sm-kicker rescue dispatch (and any future tooling '
            'dispatch sites) for machine-sm.yml to exist in .github/workflows',
      );
    });

    test('sm-kicker rescue dispatch carries -f dryRun=false verbatim', () {
      final kicker = File('.github/workflows/sm-kicker.yml').readAsStringSync();
      expect(
        'gh workflow run machine-sm.yml -R "\$GITHUB_REPOSITORY" '
        '-f dryRun=false',
        isIn(kicker),
        reason:
            'the sm-kicker rescue tick must dispatch a LIVE tick — this exact '
            'line is what un-sticks the SM after a missed cron window',
      );
    });
  });
}
