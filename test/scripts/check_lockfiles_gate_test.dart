// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1296 AC2 / PR #1298 rework: run the lockfile gate's fixture selftest
/// in the regular dart test legs too.
///
/// `scripts/check_lockfiles_selftest.sh` is wired into ci.yml Static gates;
/// this wrapper (the `check_llm_tag_boundary_test.dart` pattern of running
/// the enforcing script from a test) makes the gate's red exits ALSO red in
/// every `dart test` run — the selftest cannot rot between static-gate
/// runs, and its new PR-#1298-rework cases (stale pod VERSION, dashed pod
/// names, NG1 inventory files, clean corrupt-JSON failure) are exercised by
/// the full suite this PR must keep green.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('check_lockfiles selftest: every red exit stays red (gh-1296 AC2)',
      () {
    final result = Process.runSync(
      'bash',
      ['scripts/check_lockfiles_selftest.sh'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'the lockfile gate selftest must pass — a rotting guard is '
          'worse than no guard (#1100 pattern). stderr:\n'
          '${result.stderr}',
    );
    expect(
      result.stdout,
      contains('all red exits stay red, green path stays green'),
    );
  });
}
