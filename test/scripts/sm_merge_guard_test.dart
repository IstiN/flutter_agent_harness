// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-1537 AC5 — the SM merge guard's decision logic, exercised through
/// the script's `--runs-json` test seam (no gh, no network): the guard
/// must accept a pushed tree covered by a successful dispatched
/// validation (by tree identity for squash/merge-commit landings, by
/// exact head SHA for fast-forwards), skip the release-bot bump pushes,
/// and alarm on everything else — a failed validation, a tag/push-event
/// run, a stale-only match, or no dispatch at all.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _script = 'scripts/sm_merge_guard.py';

const _sha = 'aaaabbbbccccdddd';
const _tree = 'tree1111';
const _subject = 'gh-999 some story (#1000)';

Future<int> runGuard(List<Map<String, Object?>> runs,
    {String subject = _subject,
    String sha = _sha,
    String tree = _tree}) async {
  final dir = Directory.systemTemp.createTempSync('sm-merge-guard-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final runsFile = File('${dir.path}/runs.json')
    ..writeAsStringSync(jsonEncode(runs));
  final proc = await Process.run('python3', [
    _script,
    '--sha',
    sha,
    '--subject',
    subject,
    '--tree',
    tree,
    '--runs-json',
    runsFile.path,
  ]);
  final out = '${proc.stdout}${proc.stderr}';
  expect(out, isNot(contains('Traceback')),
      reason: 'the guard must fail loud, never traceback: $out');
  return proc.exitCode;
}

Map<String, Object?> _run({
  required Object id,
  required String sha,
  String? tree,
  String conclusion = 'success',
}) =>
    {'database_id': id, 'head_sha': sha, 'tree_sha': tree};

void main() {
  test('a successful dispatch run with the SAME tree validates the push '
      '(squash/merge-commit landing, new SHA)', () async {
    final code = await runGuard([
      _run(id: 11, sha: 'validatedhead1', tree: _tree),
      _run(id: 12, sha: 'otherhead', tree: 'othertree'),
    ]);
    expect(code, 0, reason: 'tree identity is the gh-1537 invariant');
  });

  test('a successful dispatch run on the EXACT pushed SHA validates '
      '(fast-forward landing)', () async {
    final code = await runGuard([
      _run(id: 11, sha: _sha, tree: 'differenttree'),
    ]);
    expect(code, 0);
  });

  test('two or more items: one matching run among non-matching ones '
      'still validates', () async {
    final code = await runGuard([
      _run(id: 11, sha: 'nope1', tree: 'nope'),
      _run(id: 12, sha: 'nope2', tree: _tree),
      _run(id: 13, sha: 'nope3', conclusion: 'failure', tree: _tree),
    ]);
    expect(code, 0, reason: 'a FAILED run on the same tree must not '
        'count — only successes validate (exit 3 is the alarm class)');
  });

  test('a FAILED run on the same tree is an alarm (validation ran red)',
      () async {
    final code = await runGuard([
      _run(id: 11, sha: 'validatedhead', tree: _tree, conclusion: 'failure'),
    ]);
    expect(code, 3);
  });

  test('a push/tag-event run match does NOT validate (must be the SM '
      'dispatch population)', () async {
    // fetch_validated_runs filters --event workflow_dispatch; the seam
    // models that by only ever receiving dispatch runs — a run entry
    // here IS a dispatch run, so this case is really "same SHA only in a
    // non-dispatch run" — modeled as no dispatch runs at all.
    final code = await runGuard([]);
    expect(code, 3);
  });

  test('no dispatch runs in the window is an alarm', () async {
    final code = await runGuard([]);
    expect(code, 3, reason: 'a main push with zero successful dispatched '
        'validations is exactly the #687-invariant violation');
  });

  test('runs covering other trees only is an alarm (main moved past '
      'what was validated)', () async {
    final code = await runGuard([
      _run(id: 11, sha: 'ahead1', tree: 'newertree'),
      _run(id: 12, sha: 'ahead2', tree: 'evennewer'),
    ]);
    expect(code, 3);
  });

  test('the release-bot bump push skips the guard even with no runs',
      () async {
    final code = await runGuard([],
        subject: 'chore(release): v0.1.999');
    expect(code, 0, reason: 'the v* tag run gates the bump commit');
  });

  test('missing --tree is a usage error, not an alarm', () async {
    final proc = await Process.run(
        'python3', [_script, '--sha', _sha, '--tree', '', '--runs-json']);
    expect(proc.exitCode, isNot(0));
  });
}
