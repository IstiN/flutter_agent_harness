// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — `selectCompactionMode` (AC1, UT-13, I9): the exhaustive
/// mode table; no outcome of a run switches mode.

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('UT-13 the table is exhaustive', () {
    CompactionMode mode(CompactionEngine engine, bool s0, bool smol) =>
        selectCompactionMode(
          engine: engine,
          snapshotValid: s0,
          separateDigestRole: smol,
        );
    // classic ⇔ the setting, whatever S0 or roles say.
    for (final s0 in [true, false]) {
      for (final smol in [true, false]) {
        expect(
          mode(CompactionEngine.classic, s0, smol),
          CompactionMode.classic,
        );
      }
    }
    expect(
      mode(CompactionEngine.structured, true, false),
      CompactionMode.merged,
    );
    expect(
      mode(CompactionEngine.structured, false, false),
      CompactionMode.standalone,
    );
    expect(
      mode(CompactionEngine.structured, true, true),
      CompactionMode.standalone,
    );
    expect(
      mode(CompactionEngine.structured, false, true),
      CompactionMode.standalone,
    );
  });

  test('every engine × snapshot × role combination names a mode (I9)', () {
    final seen = <CompactionMode>{};
    for (final engine in CompactionEngine.values) {
      for (final s0 in [true, false]) {
        for (final smol in [true, false]) {
          seen.add(
            selectCompactionMode(
              engine: engine,
              snapshotValid: s0,
              separateDigestRole: smol,
            ),
          );
        }
      }
    }
    expect(seen, CompactionMode.values.toSet());
  });
}
