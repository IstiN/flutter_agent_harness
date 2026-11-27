// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1/C3 — the two new HEP frames, byte-pinned: `working_set`
/// (a write: size + time + cleared — NEVER the text) and `context_notice`
/// (the harness told the model about its context: kind + tokens + window,
/// `hidden` only for post-hide). Numbers only (AC12 / I8).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/hep.dart';
import 'package:test/test.dart';

void main() {
  late List<String> lines;
  late HepWriter writer;

  setUp(() {
    lines = <String>[];
    writer = HepWriter(emit: lines.add, fahVersion: '1.0.0');
    writer.writeHeader(sessionId: 's1');
  });

  test('working_set frame: chars + updated + cleared, no text', () {
    writer.workingSet(chars: 18, updated: '12:30', cleared: false);
    expect(
      lines.last,
      '{"type":"working_set","turn_id":0,"chars":18,"updated":"12:30",'
      '"cleared":false}',
    );
    final frame = jsonDecode(lines.last) as Map<String, dynamic>;
    expect(frame.keys.toSet(), {
      'type',
      'turn_id',
      'chars',
      'updated',
      'cleared',
    });
    writer.workingSet(chars: 0, updated: '12:31', cleared: true);
    expect(jsonDecode(lines.last), {
      'type': 'working_set',
      'turn_id': 0,
      'chars': 0,
      'updated': '12:31',
      'cleared': true,
    });
  });

  test('context_notice frame: kind + tokens + window; hidden on post-hide', () {
    writer.contextNotice(kind: 'near-limit', tokens: 170000, window: 200000);
    expect(
      lines.last,
      '{"type":"context_notice","turn_id":0,"kind":"near-limit",'
      '"tokens":170000,"window":200000,"estimate":true}',
    );
    writer.contextNotice(
      kind: 'post-hide',
      tokens: 53924,
      window: 200000,
      hidden: 303,
    );
    expect(
      lines.last,
      '{"type":"context_notice","turn_id":0,"kind":"post-hide",'
      '"tokens":53924,"window":200000,"hidden":303,"estimate":true}',
    );
  });

  test('both frames ride the OPEN turn of a compaction bracket', () {
    writer.compactionStart();
    writer.contextNotice(kind: 'post-hide', tokens: 10, window: 100, hidden: 3);
    writer.workingSet(chars: 5, updated: '09:00', cleared: false);
    writer.compactionEnd(90);
    expect(
      lines.skip(1).map((l) => (jsonDecode(l) as Map)['turn_id']),
      everyElement(1),
      reason: 'the bracket allocated turn 1; both frames belong to it',
    );
  });

  test('the pure builders are the single source of the byte shape', () {
    expect(
      hepWorkingSetFrame(turnId: 2, chars: 7, updated: '01:02', cleared: false),
      '{"type":"working_set","turn_id":2,"chars":7,"updated":"01:02",'
      '"cleared":false}',
    );
    expect(
      hepContextNoticeFrame(
        turnId: 2,
        kind: 'near-limit',
        tokens: 1,
        window: 2,
      ),
      '{"type":"context_notice","turn_id":2,"kind":"near-limit","tokens":1,'
      '"window":2,"estimate":true}',
    );
  });

  test(
    'the provenance field: estimate by default, false only when reported',
    () {
      // Owner rule: a heuristic figure is marked as one everywhere it is
      // shown; `estimate: false` is reserved for a provider-reported number.
      Map frame({bool? estimated}) =>
          jsonDecode(
                hepContextNoticeFrame(
                  turnId: 3,
                  kind: 'near-limit',
                  tokens: 170000,
                  window: 200000,
                  estimated: estimated ?? true,
                ),
              )
              as Map;
      expect(frame()['estimate'], isTrue);
      expect(frame(estimated: false)['estimate'], isFalse);
    },
  );
}
