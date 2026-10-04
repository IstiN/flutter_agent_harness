// UT-2/UT-3 (gh-1241): the pure fold math — segment accumulation, total
// recompute, byModel split — and the source-marker matrix
// (reported/estimated/mixed).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

FoldRequest reported({
  String model = 'model-a',
  int input = 100,
  int output = 50,
  int cacheRead = 0,
  int cacheWrite = 0,
  int? reasoning,
}) => FoldRequest(
  model: model,
  input: input,
  output: output,
  cacheRead: cacheRead,
  cacheWrite: cacheWrite,
  reasoning: reasoning,
  source: UsageSource.reported,
);

FoldRequest estimated({String model = 'model-a', int input = 0, int output = 0}) =>
    FoldRequest(
      model: model,
      input: input,
      output: output,
      source: UsageSource.estimated,
    );

void main() {
  const folder = UsageFolder();

  group('UsageFolder.foldSegment (UT-2)', () {
    test('sums a single request', () {
      final segment = folder.foldSegment(0, [reported(input: 100, output: 50)]);
      expect(segment.totals.requests, 1);
      expect(segment.totals.input, 100);
      expect(segment.totals.output, 50);
    });

    test('sums MULTIPLE requests (a single-item case can pass with broken accumulation)', () {
      final segment = folder.foldSegment(0, [
        reported(input: 100, output: 50),
        reported(input: 200, output: 70, cacheRead: 30, cacheWrite: 10),
        reported(input: 0, output: 5, reasoning: 5),
      ]);
      expect(segment.totals.requests, 3);
      expect(segment.totals.input, 300);
      expect(segment.totals.output, 125);
      expect(segment.totals.cacheRead, 30);
      expect(segment.totals.cacheWrite, 10);
      expect(segment.totals.reasoning, 5);
    });

    test('splits usage per model inside the segment (I5)', () {
      final segment = folder.foldSegment(0, [
        reported(model: 'model-a', input: 100, output: 50),
        reported(model: 'model-b', input: 200, output: 100),
        reported(model: 'model-a', input: 50, output: 25),
      ]);
      // Grand total is model-agnostic…
      expect(segment.totals.input, 350);
      expect(segment.totals.output, 175);
      expect(segment.totals.requests, 3);
      // …with the per-model breakdown attached.
      expect(segment.byModel['model-a']!.requests, 2);
      expect(segment.byModel['model-a']!.input, 150);
      expect(segment.byModel['model-b']!.requests, 1);
      expect(segment.byModel['model-b']!.input, 200);
    });

    test('empty segment folds to zero with a reported (vacuous) marker', () {
      final segment = folder.foldSegment(0, const []);
      expect(segment.totals, UsageModelTotals.zero);
      expect(segment.source, UsageSource.reported);
    });
  });

  group('UsageFolder.totalOf (UT-2, I2)', () {
    test('total always equals the sum of the segments', () {
      final segments = [
        folder.foldSegment(0, [reported(input: 100, output: 50)]),
        folder.foldSegment(
          1,
          [reported(input: 300, output: 150, cacheRead: 40)],
        ),
        folder.foldSegment(2, [reported(model: 'other', input: 10, output: 5)]),
      ];
      final total = folder.totalOf(segments);
      expect(total.totals.requests, 3);
      expect(total.totals.input, 410);
      expect(total.totals.output, 205);
      expect(total.totals.cacheRead, 40);
      // Per-model merge across segments.
      expect(total.byModel['model-a']!.requests, 2);
      expect(total.byModel['other']!.input, 10);
    });
  });

  group('source marker matrix (UT-3)', () {
    test('all-reported scope reads reported', () {
      final segment = folder.foldSegment(0, [
        reported(),
        reported(input: 5, output: 5),
      ]);
      expect(segment.source, UsageSource.reported);
      expect(folder.totalOf([segment]).source, UsageSource.reported);
    });

    test('all-estimated scope reads estimated', () {
      final segment = folder.foldSegment(0, [
        estimated(input: 25, output: 12),
        estimated(input: 10, output: 5),
      ]);
      expect(segment.source, UsageSource.estimated);
      expect(folder.totalOf([segment]).source, UsageSource.estimated);
    });

    test('mixed scope reads mixed — estimated never silently substitutes', () {
      final segment = folder.foldSegment(0, [reported(), estimated()]);
      expect(segment.source, UsageSource.mixed);
    });

    test('total is mixed when some segments reported and others estimated', () {
      final reportedSegment = folder.foldSegment(0, [reported()]);
      final estimatedSegment = folder.foldSegment(1, [estimated()]);
      final total = folder.totalOf([reportedSegment, estimatedSegment]);
      expect(total.source, UsageSource.mixed);
    });
  });
}
