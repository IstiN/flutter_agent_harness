// gh-995 — artifact action pins + PTY shard pipeline coherence.
//
// Split out of test/release_hygiene_test.dart (gh-2008 rework): the
// gh-2008 sweeper coverage pushed that file past the gh-1232 god-file
// ceiling (crap4dart `loc` gate, max_lines: 2800 over test/ — a ratchet,
// max_lines only DOWN), and this concern is CI-workflow coherence, not
// release-hygiene behavior: every third-party action pinned at exactly
// ONE full SHA repo-wide, upload-artifact on the current
// digest-validating line (pty-coverage-gate's download-artifact v8
// digest-validates every download), and the PTY shard
// upload/download/count pipeline agreeing. The helpers move with their
// only consumer; same style as release_hygiene_test.dart.

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// Every `uses:` ref in the YAML AST at any depth (workflow job steps,
/// composite action `runs.steps`), grouped by action name → set of pins.
/// Unlike a raw grep over the file text this never matches `@v4` fixture
/// strings embedded in `run:` bodies (the supply-chain selftest writes
/// those on purpose).
void collectUses(dynamic node, Map<String, Set<String>> byAction) {
  if (node is YamlMap) {
    final uses = node['uses'];
    if (uses is String) {
      final ref = uses.trim();
      final at = ref.lastIndexOf('@');
      if (!ref.startsWith('./') && !ref.startsWith('docker://') && at > 0) {
        byAction
            .putIfAbsent(ref.substring(0, at), () => {})
            .add(ref.substring(at + 1));
      }
    }
    for (final key in node.keys) {
      collectUses(node[key], byAction);
    }
  } else if (node is YamlList) {
    for (final item in node) {
      collectUses(item, byAction);
    }
  }
}

/// All third-party `uses:` pins across the workflows and composite actions.
Map<String, Set<String>> usesByAction() {
  final byAction = <String, Set<String>>{};
  final files = <String>[
    ...Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
        .map((f) => f.path),
    ...Directory('.github/actions')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('action.yml') || f.path.endsWith('action.yaml'),
        )
        .map((f) => f.path),
  ];
  for (final f in files) {
    collectUses(loadYaml(read(f)), byAction);
  }
  return byAction;
}

/// Shell glob (`*` wildcards) → anchored regexp.
RegExp globToRegExp(String glob) =>
    RegExp('^${glob.split('*').map(RegExp.escape).join('.*')}\$');

void main() {
  // ── gh-995 — artifact action pins + PTY shard pipeline coherence ────────
  // 2026-09-27 outage: the PTY legs were the only jobs still uploading
  // artifacts with the stale upload-artifact@ea165f8d (v4 line) pin while
  // the rest of the repo had moved to cf430e03 (v7.0.2). The gate downloads
  // with download-artifact@9000827c (v8.0.2), which digest-validates every
  // download — the stale uploads stopped verifying (digest-mismatch), the
  // shard merge saw < 3 reports and pty-coverage-gate wedged every run.
  // check_action_pins.sh cannot see this class (both forms are valid
  // full-SHA pins), so pin drift is guarded here instead.
  group('gh-995 — artifact action pins + PTY shard pipeline coherence', () {
    test(
      'every third-party action is pinned at exactly ONE full SHA repo-wide',
      () {
        final byAction = usesByAction();
        expect(byAction, isNotEmpty);
        final drifted = <String>[];
        byAction.forEach((action, pins) {
          if (pins.length > 1) drifted.add('$action: ${pins.join(', ')}');
        });
        expect(
          drifted,
          isEmpty,
          reason:
              'a second pin for the same action means one workflow was '
              'left behind on an old version — exactly how the pty legs '
              'wedge happened (their v4-era upload-artifact uploads failed '
              'the gate\'s v8 download digest validation)',
        );
      },
    );

    test(
      'upload-artifact is pinned to the current digest-validating line everywhere',
      () {
        expect(
          usesByAction()['actions/upload-artifact'],
          {'cf430e030ddbb5b0abf93d22962f4752f3646cd9'},
          reason:
              'pty-coverage-gate downloads with download-artifact v8 '
              '(strict SHA256 digest validation); every upload must come '
              'from the same current action line or the download '
              'digest-mismatches and the shard merge loses a report',
        );
      },
    );

    test(
      'pty shard coverage artifacts: upload name, download pattern and count check agree',
      () {
        // gh-1005: the consolidated leg is pty-integration-linux (the former
        // mac `pty-integration` shards merged in; there is no mac leg anymore).
        final jobs = jobsOf('.github/workflows/ci.yml');
        final integration = jobs['pty-integration-linux'] as YamlMap;
        final gate = jobs['pty-coverage-gate'] as YamlMap;

        // The matrix width is the source of truth for the expected report count.
        final shardCount =
            ((integration['strategy'] as YamlMap)['matrix'] as YamlMap)['shard']
                as YamlList;
        expect(
          shardCount.length,
          3,
          reason: 'the leg is documented as 3 shards',
        );

        // Exactly one coverage upload per shard leg, named pty-coverage-shard-N.
        // gh-1412: the gh-1412 retry steps (same artifact name, `if` keyed on
        // the primary upload's failed outcome) re-upload the SAME single
        // artifact — they must not count as a second coverage upload here.
        final uploadNames = <String>[];
        for (final step in integration['steps'] as YamlList) {
          if (step is YamlMap &&
              step['uses'].toString().startsWith('actions/upload-artifact') &&
              !(step['if']?.toString().contains("outcome == 'failure'") ??
                  false)) {
            uploadNames.add(((step['with'] as YamlMap)['name']).toString());
          }
        }
        final coverageUploads = uploadNames
            .where((n) => n.startsWith('pty-coverage-shard-'))
            .toList();
        expect(
          coverageUploads,
          hasLength(1),
          reason: 'exactly one pty-coverage-shard artifact per shard leg',
        );

        // The gate downloads the pattern; every uploaded shard name matches it.
        String? pattern;
        for (final step in gate['steps'] as YamlList) {
          if (step is YamlMap &&
              step['uses'].toString().startsWith('actions/download-artifact') &&
              step['with'] is YamlMap &&
              ((step['with'] as YamlMap)['pattern'] ?? '')
                  .toString()
                  .startsWith('pty-coverage-shard-')) {
            pattern = ((step['with'] as YamlMap)['pattern']).toString();
          }
        }
        expect(
          pattern,
          isNotNull,
          reason: 'the gate must download pty-coverage-shard-*',
        );
        final concreteName = coverageUploads.single.replaceAll(
          r'${{ matrix.shard }}',
          '0',
        );
        expect(
          globToRegExp(pattern!).hasMatch(concreteName),
          isTrue,
          reason:
              'upload name "${coverageUploads.single}" must match '
              'download pattern "$pattern"',
        );

        // The merge step's hard count check must expect the matrix width.
        final mergeRuns = <String>[];
        for (final step in gate['steps'] as YamlList) {
          if (step is YamlMap &&
              step['run'].toString().contains('pty shard coverage reports')) {
            mergeRuns.add(step['run'].toString());
          }
        }
        expect(mergeRuns, hasLength(1));
        final expected = RegExp(
          r'expected (\d+) pty shard coverage reports',
        ).firstMatch(mergeRuns.single);
        expect(expected, isNotNull);
        expect(
          int.parse(expected!.group(1)!),
          shardCount.length,
          reason:
              'the count check must expect exactly the configured shard count',
        );

        // A shard report that downloads but carries no SF: records (empty or
        // truncated upload) must fail the merge LOUDLY — the 2026-09-27
        // outage also showed a partial merge reading 7.95% against the
        // 11.00% baseline because a hollow report still satisfied the count.
        expect(
          mergeRuns.single,
          contains("'^SF:'"),
          reason:
              'merge must reject hollow per-shard lcov reports before merging',
        );
      },
    );
  });
}
