// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1199 AC1: the merge-blocking Quality-gate integration shards are
/// deterministic-only — the shard selection must NEVER emit a file tagged
/// `llm`, however it got there (manifest unit or runtime bin-pack of a
/// new file). This is the red/green proof the AC asks for: it shells out
/// to the exact `shard_files.py` invocation the CI leg uses (with
/// `--exclude-tag llm`) and asserts the live suite is absent, while the
/// raw manifest still contains it (so the exclusion is the selector's
/// doing, not a stale manifest silently hiding a leak).
library;

import 'dart:io';

import 'package:test/test.dart';

const _shardFiles = 'scripts/shard_files.py';
const _manifest = 'scripts/test_integration_shards.json';

/// Every live-provider file: the audited `live` class of the integration
/// suite (gh-1199 AC3). Keep in sync with the files tagged
/// `integration` + `llm` — scripts/check_llm_tag_boundary.py fails the
/// gate when a new live file lacks the tag, and this list then catches
/// any selection leak.
const _liveFiles = [
  'test/integration/provider_ollama_test.dart',
  'test/integration/provider_anthropic_test.dart',
  'test/integration/provider_openrouter_test.dart',
  'test/integration/provider_google_test.dart',
  'test/integration/provider_glm_live_test.dart',
  'test/integration/chatgpt_codex_live_test.dart',
  'test/integration/copilot_live_test.dart',
  'test/integration/subagent_real_model_test.dart',
  'test/integration/provider_codex_boot_live_test.dart',
];

Future<Set<String>> selection(int shard) async {
  final proc = await Process.run('python3', [
    _shardFiles, _manifest, '$shard',
    '--tags', 'integration',
    '--exclude', 'browser_ext',
    '--exclude-tag', 'llm',
  ]);
  expect(proc.exitCode, 0, reason: proc.stderr as String);
  return (proc.stdout as String)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toSet();
}

void main() {
  test('no live-provider file appears in any gate shard selection', () async {
    final union = <String>{};
    for (var shard = 0; shard < 3; shard++) {
      union.addAll(await selection(shard));
    }
    for (final live in _liveFiles) {
      expect(
        File(live).existsSync(),
        isTrue,
        reason: 'stale _liveFiles entry — $live no longer exists',
      );
      expect(
        union,
        isNot(contains(live)),
        reason: '$live is tagged llm but reached the deterministic-gate '
            'selection — the live boundary is leaking (gh-1199 AC1)',
      );
    }
    // The gate must still RUN integration tests — an empty union would
    // mean the selector filtered everything, not just the live files.
    expect(union.length, greaterThan(20), reason: 'selection: $union');
  });

  test('without --exclude-tag the same invocation WOULD select a live '
      'file (red/green contrast)', () async {
    final proc = await Process.run('python3', [
      _shardFiles, _manifest, '0',
      '--tags', 'integration',
      '--exclude', 'browser_ext',
    ]);
    expect(proc.exitCode, 0, reason: proc.stderr as String);
    final raw = (proc.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet();
    final wouldRun = raw.where(_liveFiles.contains).toList();
    expect(
      wouldRun,
      isNotEmpty,
      reason: 'no live file would be selected even WITHOUT --exclude-tag — '
          'the manifest lost the live suite; re-balance or drop this '
          'contrast check',
    );
  });
}
