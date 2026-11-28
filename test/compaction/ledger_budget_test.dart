@TestOn('vm')
library;

/// gh-2492 C4 — the dedicated `ledger_budget.dart` component.
///
/// The hidden-record MARKERS a request carries are the compaction
/// ledger's render cost: one marker per hidden record (~19 tokens with
/// the preview) adds up — after five hide passes the ledger alone can
/// cost multiples of the checkpoint it replaced. The budget component:
/// - pins `hiddenLedgerBudgetTokens` (1000 over ALL hidden markers of a
///   request);
/// - detects the contiguous marker runs of a request;
/// - collapses OLDEST-FIRST: each merge turns the two oldest adjacent
///   markers into one collapsed pointer
///   (`N records hidden · <label> [expand a-b]`), repeat until under
///   budget — the newest run keeps its per-record detail;
/// - builds the deterministic C5 range labels (tool-name histogram +
///   time span) from the covered records — engine-generated, never
///   model text, so the hide-only path is not content-blind.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/ledger_budget.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart';
import 'package:test/test.dart';

AssistantMessage _assistantWithTools({
  required String id,
  required List<String> tools,
  DateTime? at,
}) => AssistantMessage(
  content: [
    for (final tool in tools) ToolCall(id: id, name: tool, arguments: const {}),
  ],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: at ?? DateTime.utc(2026, 11, 28, 12, 0, 0),
);

MessageRecord _msgRecord(String id, Message message, {DateTime? at}) =>
    MessageRecord(
      id: id,
      parentId: 'p1',
      timestamp: at ?? DateTime.utc(2026, 11, 28, 12, 0, 0),
      message: message,
    );

void main() {
  group('hiddenLedgerBudgetTokens', () {
    test('the cap is the pinned 1000-token constant', () {
      expect(hiddenLedgerBudgetTokens, 1000);
    });
  });

  group('toolHistogramLabel (C5 per-range label)', () {
    test('renders the tool-name histogram and the time span', () {
      final records = <SessionRecord>[
        _msgRecord(
          'r1',
          _assistantWithTools(id: 'c1', tools: ['bash']),
          at: DateTime.utc(2026, 11, 28, 12, 41),
        ),
        _msgRecord(
          'r2',
          _assistantWithTools(id: 'c2', tools: ['bash', 'read']),
          at: DateTime.utc(2026, 11, 28, 13, 44),
        ),
      ];
      final label = toolHistogramLabel(records);
      expect(label, contains('bash ×2'));
      expect(label, contains('read ×1'));
      expect(label, contains('12:41'));
      expect(label, contains('13:44'));
      // One line, bracket-free — the engine-marker shape.
      expect(label.contains('\n'), isFalse);
      expect(label.contains('['), isFalse);
    });

    test('caps the histogram at the top tool names', () {
      final records = <SessionRecord>[
        for (var i = 0; i < 6; i++)
          _msgRecord('r$i', _assistantWithTools(id: 'c$i', tools: ['t$i'])),
      ];
      final label = toolHistogramLabel(records);
      expect(
        RegExp(r't\d+ ×1').allMatches(label).length,
        lessThanOrEqualTo(toolHistogramMaxEntries),
        reason: 'only the top entries render',
      );
    });

    test('records without tools render the span only', () {
      final records = <SessionRecord>[
        _msgRecord(
          'r1',
          UserMessage.text('plain'),
          at: DateTime.utc(2026, 11, 28, 9, 15),
        ),
        _msgRecord(
          'r2',
          _msgRecord('r3', UserMessage.text('plain')).message,
          at: DateTime.utc(2026, 11, 28, 9, 30),
        ),
      ];
      final label = toolHistogramLabel(records);
      expect(label, contains('09:15'));
      expect(label, contains('09:30'));
      expect(label.contains('×'), isFalse);
    });

    test('no records → empty label (the bare pointer stays)', () {
      expect(toolHistogramLabel(const []), isEmpty);
    });
  });

  group('collapsedLedgerMarkerText (C4 collapsed pointer)', () {
    test('names the hidden count and the expand door', () {
      final text = collapsedLedgerMarkerText(
        hiddenCount: 142,
        fromSeq: 142,
        toSeq: 425,
      );
      expect(text, contains('142 records hidden'));
      expect(text, contains('[expand 142-425]'));
    });

    test('the histogram label rides the collapsed pointer', () {
      final text = collapsedLedgerMarkerText(
        hiddenCount: 142,
        fromSeq: 142,
        toSeq: 425,
        label: 'bash ×3 · read ×1 · 12:41–13:44',
      );
      expect(text, startsWith('142 records hidden · bash ×3'));
      expect(text, endsWith('[expand 142-425]'));
    });

    test('every collapsed text matches the engine-marker predicate', () {
      for (final text in [
        collapsedLedgerMarkerText(hiddenCount: 5, fromSeq: 3, toSeq: 90),
        collapsedLedgerMarkerText(
          hiddenCount: 142,
          fromSeq: 142,
          toSeq: 425,
          label: 'bash ×61 · read ×40 · edit ×12 · 12:41–13:44',
        ),
        collapsedLedgerMarkerText(hiddenCount: 1, fromSeq: 7),
      ]) {
        expect(
          isCompactionMarkerText(text),
          isTrue,
          reason: 'the collapsed pointer must resolve as an engine marker',
        );
      }
    });
  });

  group('marker run collapse (oldest-first)', () {
    test('collapses oldest-first until under budget; the head becomes one '
        'working pointer', () {
      // 150 per-record markers ≈ 15 tokens each ≈ 2.2k tokens: the
      // collapse shaves the OLDEST end until under the cap — the head
      // ends as one collapsed pointer, the newest markers keep detail.
      final markers = [
        for (var i = 0; i < 150; i++)
          UserMessage.text(
            hiddenMarker(
              seq: i + 2,
              kind: 'assistant',
              tokens: 100,
              preview: 'consumed output ${'x' * 30}',
            ),
          ),
      ];
      final result = collapseLedgerMarkers(
        markers,
        budget: hiddenLedgerBudgetTokens,
        labelFor: (from, to) => '',
      );
      expect(result.replacementCount, greaterThanOrEqualTo(1));
      final under = result.messages.fold<int>(
        0,
        (sum, message) => sum + estimateTokens(message),
      );
      expect(under, lessThanOrEqualTo(hiddenLedgerBudgetTokens));
      final firstText =
          (result.messages.first as UserMessage).content as String;
      expect(firstText, contains('records hidden'));
      expect(firstText, contains('[expand 2-'));
      // The newest marker keeps its per-record detail.
      final lastText = (result.messages.last as UserMessage).content as String;
      expect(lastText, contains('[151:hidden'));
    });

    test('collapses oldest-first across 2+ runs, newest detail survives', () {
      // Three runs of 30 markers each ≈ 570 tokens per run; budget 1000
      // forces merges until under — the newest run's tail markers stay.
      final markers = [
        for (var i = 0; i < 90; i++)
          UserMessage.text(
            hiddenMarker(seq: i + 2, kind: 'assistant', tokens: 100),
          ),
      ];
      final result = collapseLedgerMarkers(
        markers,
        budget: hiddenLedgerBudgetTokens,
        labelFor: (from, to) => '',
      );
      final under = result.messages.fold<int>(
        0,
        (sum, message) => sum + estimateTokens(message),
      );
      expect(under, lessThanOrEqualTo(hiddenLedgerBudgetTokens));
      // The newest marker (seq 91) survives with its detail.
      final last = result.messages.last;
      expect((last as UserMessage).content as String, contains('[91:hidden'));
    });

    test('under budget → no collapses (byte-identical markers)', () {
      final markers = [
        UserMessage.text(hiddenMarker(seq: 2, kind: 'assistant', tokens: 100)),
        UserMessage.text(hiddenMarker(seq: 3, kind: 'assistant', tokens: 100)),
      ];
      final result = collapseLedgerMarkers(
        markers,
        budget: hiddenLedgerBudgetTokens,
        labelFor: (from, to) => '',
      );
      expect(result.replacementCount, 0);
      expect(result.messages.length, 2);
    });

    test('a single marker over budget stays (nothing left to merge)', () {
      final marker = UserMessage.text(
        '${'x' * 5000} [2:hidden·assistant·1.3k]',
      );
      final result = collapseLedgerMarkers(
        [marker],
        budget: hiddenLedgerBudgetTokens,
        labelFor: (from, to) => '',
      );
      expect(result.replacementCount, 0);
      expect(result.messages.length, 1);
    });
  });
}
