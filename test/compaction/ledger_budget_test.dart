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

  group('ledgerMarkerRef: per-record prefix vs a preview-quoted pointer '
      '(gh-2492 review round 1)', () {
    test('a per-record marker whose preview quotes an expand pointer '
        'parses as its OWN seq', () {
      // The preview quotes a genuine pointer literal (markers.dart: docs
      // and skill texts quote `[expand 3-140]`) — the per-record prefix
      // must win over the expand branch, or the marker plans as
      // covering 3–140 while it actually stands for seq 142.
      final text = hiddenMarker(
        seq: 142,
        kind: 'user',
        tokens: 1200,
        preview: 'see the fold quoted as [expand 3-140] above',
      );
      expect(text, startsWith('[142:hidden·user·'));
      expect(text, contains('[expand 3-140]'));
      final ref = ledgerMarkerRef(0, UserMessage.text(text));
      expect(ref, isNotNull);
      expect(ref!.firstSeq, 142, reason: 'the marker names seq 142');
      expect(ref.lastSeq, 142);
      expect(ref.hiddenCount, 1);
    });

    test('a merged pair that includes the preview-quoted marker emits a '
        'door for the TRUE span', () {
      final quoted = UserMessage.text(
        hiddenMarker(
          seq: 142,
          kind: 'user',
          tokens: 1200,
          preview: 'see the fold quoted as [expand 3-140] above',
        ),
      );
      final plain = UserMessage.text(
        hiddenMarker(seq: 143, kind: 'user', tokens: 100),
      );
      final plan = planLedgerBudget([
        ledgerMarkerRef(0, quoted)!,
        ledgerMarkerRef(1, plain)!,
      ], budget: 1);
      expect(plan.isEmpty, isFalse);
      final merged = plan.replace[0] as UserMessage;
      expect(
        merged.content as String,
        contains('[expand 142-143]'),
        reason: 'the door must name the records the markers stand for',
      );
      expect(merged.content as String, isNot(contains('[expand 3-')));
    });

    test('a consolidated pointer still parses through the expand branch', () {
      final ref = ledgerMarkerRef(
        0,
        UserMessage.text('fold note [expand 9-12]'),
      );
      expect(ref, isNotNull);
      expect(ref!.firstSeq, 9);
      expect(ref.lastSeq, 12);
      expect(ref.hiddenCount, 4);
    });
  });

  group('collapse merges only true emission-adjacent markers '
      '(gh-2492 review round 1)', () {
    test('a visible record between two markers blocks the merge across '
        'the gap', () {
      final markers = [
        UserMessage.text(hiddenMarker(seq: 5, kind: 'user', tokens: 100)),
        UserMessage.text('a visible user record sits here (never hidden)'),
        UserMessage.text(hiddenMarker(seq: 7, kind: 'user', tokens: 100)),
        UserMessage.text(
          checkpointMarkerHeader(
            startSeq: 9,
            endSeq: 10,
            coveredTokens: 100,
            textTokens: 40,
            coversRanges: '9,10',
          ),
        ),
        UserMessage.text(hiddenMarker(seq: 12, kind: 'user', tokens: 100)),
      ];
      final result = collapseLedgerMarkers(
        markers,
        budget: 10,
        labelFor: (from, to) => '',
      );
      expect(
        result.replacementCount,
        0,
        reason: 'every marker sits in a run of one — runs of one never merge',
      );
      expect(result.messages.length, markers.length);
      expect(
        result.messages.map((m) => m.toJson()),
        markers.map((m) => m.toJson()),
        reason: 'byte-identical markers — nothing collapsed across the gap',
      );
    });

    test('markers inside ONE contiguous run still merge oldest-first', () {
      final markers = [
        UserMessage.text(hiddenMarker(seq: 5, kind: 'user', tokens: 100)),
        UserMessage.text(hiddenMarker(seq: 7, kind: 'user', tokens: 100)),
        UserMessage.text(hiddenMarker(seq: 9, kind: 'user', tokens: 100)),
      ];
      final result = collapseLedgerMarkers(
        markers,
        budget: 10,
        labelFor: (from, to) => '',
      );
      // The whole run folds (the loop merges until under budget): ONE
      // working pointer naming only the run's own span.
      expect(result.replacementCount, greaterThanOrEqualTo(1));
      expect(result.messages, hasLength(1));
      final head = result.messages.first as UserMessage;
      expect((head.content as String), contains('[expand 5-9]'));
    });
  });

  group('the engine label stays inside the marker-predicate budget '
      '(gh-2492 review round 1)', () {
    // This repo's own MCP-style names: three histogram entries blow
    // past the 96-char predicate budget, and the engine's own markers
    // stop resolving as markers (the ledger budget under-counts; the
    // pin/image renumbering boundaries are missed).
    const longNames = [
      'mcp__flutter_agent_harness__codegraph_callers',
      'mcp__flutter_agent_harness__codegraph_impact_analysis',
      'mcp__flutter_agent_harness__session_search_tool',
    ];

    List<SessionRecord> recordsWithLongNames() => [
      for (var i = 0; i < longNames.length; i++)
        _msgRecord(
          'r$i',
          _assistantWithTools(id: 'c$i', tools: [longNames[i]]),
          at: DateTime.utc(2026, 11, 28, 12, 41 + i),
        ),
    ];

    test('toolHistogramLabel caps at the marker-predicate budget', () {
      final label = toolHistogramLabel(recordsWithLongNames());
      expect(label.length, lessThanOrEqualTo(markerLabelMaxChars));
      expect(
        label.split(RegExp(r'\s+')).length,
        lessThanOrEqualTo(markerLabelMaxWords),
      );
    });

    test('the label cap leaves room for the collapsed count line — BOTH '
        'persisted shapes resolve as markers', () {
      final label = toolHistogramLabel(recordsWithLongNames());
      // The persisted consolidated marker (head = the label alone).
      expect(
        isCompactionMarkerText(
          consolidatedHideMarker(from: 3, to: 5, label: label),
        ),
        isTrue,
        reason: 'the engine-consolidated marker itself must resolve',
      );
      // The collapsed ledger pointer (worst-case `999 records hidden · `
      // head rides the same budget).
      expect(
        isCompactionMarkerText(
          collapsedLedgerMarkerText(
            hiddenCount: 999,
            fromSeq: 3,
            toSeq: 5,
            label: label,
          ),
        ),
        isTrue,
        reason: 'the engine-collapsed pointer itself must resolve',
      );
    });

    test('the capped marker parses — the ledger budget counts it', () {
      final label = toolHistogramLabel(recordsWithLongNames());
      final ref = ledgerMarkerRef(
        0,
        UserMessage.text(consolidatedHideMarker(from: 3, to: 5, label: label)),
      );
      expect(ref, isNotNull, reason: 'an unparsable marker escapes the cap');
      expect(ref!.firstSeq, 3);
      expect(ref.lastSeq, 5);
    });

    test('hideBatchLabels rides the same cap', () {
      final labels = hideBatchLabels([
        'a',
        'b',
      ], recordAt: (id) => recordsWithLongNames()[id == 'a' ? 0 : 1]);
      expect(labels, isNotEmpty);
      for (final label in labels.values) {
        expect(label.length, lessThanOrEqualTo(markerLabelMaxChars));
      }
    });

    test('a tight label renders unchanged (the cap is a no-op under it)', () {
      final label = toolHistogramLabel([
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
      ]);
      expect(label, contains('bash ×2'));
      expect(label, contains('read ×1'));
      expect(label, contains('12:41–13:44'));
    });
  });
}
