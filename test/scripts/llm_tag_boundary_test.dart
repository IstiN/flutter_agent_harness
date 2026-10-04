// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1199 AC2/AC3: pin the live-provider tag boundary as a repo test.
///
/// `scripts/check_llm_tag_boundary.py` is the enforcing lint (a static-gate
/// step runs it on every PR); this test runs it against the working tree so
/// the boundary is ALSO red in the regular `dart test` legs — a test file
/// that performs live provider I/O without the `llm` tag fails here before
/// it can even reach CI. The lint's own heuristics are covered by
/// test/scripts/shard_files_llm_boundary_test.dart (the selection side).
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('llm tag boundary lint is clean (gh-1199 AC2/AC3 audit)', () async {
    final proc = await Process.run('python3', [
      'scripts/check_llm_tag_boundary.py',
    ]);
    expect(
      proc.exitCode,
      0,
      reason:
          'live-provider I/O without the llm tag detected:\n'
          '${proc.stdout}\n${proc.stderr}',
    );
    expect(proc.stdout as String, contains('0 violation(s)'));
  });
}
