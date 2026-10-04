// UT-1 (gh-1241): the usage.json schema round-trips losslessly and
// tolerates unknown fields from newer writers.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  UsageSegment sampleSegment({int index = 0}) => UsageSegment(
    index: index,
    totals: const UsageModelTotals(
      requests: 3,
      input: 1000,
      output: 200,
      cacheRead: 400,
      cacheWrite: 50,
      reasoning: 80,
    ),
    byModel: const {
      'model-a': UsageModelTotals(requests: 2, input: 700, output: 100),
      'model-b': UsageModelTotals(
        requests: 1,
        input: 300,
        output: 100,
        cacheRead: 400,
      ),
    },
    source: UsageSource.mixed,
    openedAt: DateTime.utc(2024, 1, 1, 12),
    closedAt: DateTime.utc(2024, 1, 1, 12, 30),
  );

  UsageLedger sampleLedger() => UsageLedger(
    sessionId: 'sess-1',
    segments: [sampleSegment(), sampleSegment(index: 1)],
    total: const UsageLedgerTotal(
      totals: UsageModelTotals(requests: 6, input: 2000, output: 400),
      byModel: {
        'model-a': UsageModelTotals(requests: 4, input: 1400, output: 200),
        'model-b': UsageModelTotals(requests: 2, input: 600, output: 200),
      },
      source: UsageSource.reported,
    ),
    chainRecords: 42,
    chainHash: 'sha256:abc',
  );

  group('UsageLedger schema', () {
    test('round-trips through JSON losslessly', () {
      final ledger = sampleLedger();
      final decoded = UsageLedger.fromJson(
        jsonDecode(jsonEncode(ledger.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.sessionId, ledger.sessionId);
      expect(decoded.resumedCount, 1);
      expect(decoded.chainRecords, 42);
      expect(decoded.chainHash, 'sha256:abc');
      expect(decoded.segments.length, 2);
      final segment = decoded.segments[0];
      expect(segment.index, 0);
      expect(segment.totals.requests, 3);
      expect(segment.totals.input, 1000);
      expect(segment.totals.output, 200);
      expect(segment.totals.cacheRead, 400);
      expect(segment.totals.cacheWrite, 50);
      expect(segment.totals.reasoning, 80);
      expect(segment.source, UsageSource.mixed);
      expect(segment.openedAt, DateTime.utc(2024, 1, 1, 12));
      expect(segment.closedAt, DateTime.utc(2024, 1, 1, 12, 30));
      expect(segment.byModel['model-a']!.requests, 2);
      expect(segment.byModel['model-b']!.cacheRead, 400);
      expect(decoded.total.totals.requests, 6);
      expect(decoded.total.source, UsageSource.reported);
      expect(decoded.total.byModel['model-a']!.input, 1400);
    });

    test('double round-trip is byte-identical (I6 serialization side)', () {
      final ledger = sampleLedger();
      final once = jsonEncode(UsageLedger.fromJson(ledger.toJson()).toJson());
      final twice = jsonEncode(
        UsageLedger.fromJson(
          jsonDecode(once) as Map<String, dynamic>,
        ).toJson(),
      );
      expect(twice, once);
    });

    test('tolerates unknown fields from future writers (forward-compat)', () {
      final json = sampleLedger().toJson()
        ..['futureField'] = {'anything': true}
        ..['segments'] = [
          for (final segment in sampleLedger().segments)
            segment.toJson()
              ..['futureSegmentField'] = 1
              ..['byModel'] = {
                for (final entry in segment.byModel.entries)
                  entry.key: entry.value.totalsJson()..['futureModelField'] = 2,
              },
        ];
      final decoded = UsageLedger.fromJson(json);
      expect(decoded.segments.length, 2);
      expect(decoded.segments[0].byModel.length, 2);
      expect(decoded.total.totals.requests, 6);
    });

    test('tolerates garbage shapes without throwing', () {
      final decoded = UsageLedger.fromJson(const {
        'sessionId': 'x',
        'segments': 'not-a-list',
        'total': 42,
        'chain': 'nope',
      });
      expect(decoded.segments, isEmpty);
      expect(decoded.chainRecords, 0);
      expect(decoded.chainHash, '');
    });

    test('resumedCount derives from the segment count (I1)', () {
      expect(sampleLedger().resumedCount, 1);
      final fresh = UsageLedger(
        sessionId: 's',
        segments: [sampleSegment()],
        total: const UsageLedgerTotal(
          totals: UsageModelTotals.zero,
          byModel: {},
          source: UsageSource.reported,
        ),
        chainRecords: 0,
        chainHash: '',
      );
      expect(fresh.resumedCount, 0);
    });
  });
}
