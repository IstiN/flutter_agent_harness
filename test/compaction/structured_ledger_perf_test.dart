// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #1499 — the ledger build's growth shape and rebuild cost.
///
/// Regression guard with GENEROUS bounds (CI runners jitter): the absolute
/// ceilings are 10-30x the measured local costs, tight enough that the
/// historical shape — every compaction pass re-tokenizing the whole visible
/// history from scratch, plus linear `entryAtSeq` scans — fails them on a
/// synthetic 10k-record session.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

/// One tool-use turn: user ask, assistant tool-call carrier, giant result.
/// ~1.5 KB of text per turn — realistic file-read sizes, heavy enough that
/// re-tokenizing history dominates any bookkeeping loop.
List<SessionRecord> _turns(int count, {int startIndex = 0}) => [
  for (var i = 0; i < count; i++) ..._turn(startIndex + i),
];

List<SessionRecord> _turn(int i) {
  final resultText = 'x.dart:${'line $i content. ' * 44}';
  return [
    MessageRecord(
      id: 'r$i-u',
      parentId: i == 0 ? null : 'r${i - 1}-t',
      timestamp: DateTime.utc(2026),
      message: UserMessage.text('turn $i: inspect the failing module'),
    ),
    MessageRecord(
      id: 'r$i-a',
      parentId: 'r$i-u',
      timestamp: DateTime.utc(2026),
      message: AssistantMessage(
        content: [
          TextContent(text: 'reading the module for turn $i'),
          ToolCall(
            id: 'c$i',
            name: 'read',
            arguments: {'path': 'lib/mod$i.dart', 'why': 'turn $i'},
          ),
        ],
        api: 'anthropic-messages',
        provider: 'p',
        model: 'm1',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      ),
    ),
    MessageRecord(
      id: 'r$i-t',
      parentId: 'r$i-a',
      timestamp: DateTime.utc(2026),
      message: ToolResultMessage(
        toolCallId: 'c$i',
        toolName: 'read',
        content: [TextContent(text: resultText)],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    ),
  ];
}

ContextLedger _build(List<SessionRecord> history, {LedgerEntryCache? cache}) =>
    buildContextLedger(
      visiblePath: history,
      seqs: RecordSeqIndex(history),
      cache: cache,
    );

void main() {
  // JIT warmup so the timed builds measure the steady state, not the VM.
  _build(_turns(100));

  test('cold ledger build stays bounded and near-linear at 10k records', () {
    final small = _turns(1000); // ~334 turns
    final large = _turns(10000); // ~3334 turns

    final sw1 = Stopwatch()..start();
    _build(small);
    final smallMs = sw1.elapsedMilliseconds;

    final sw10 = Stopwatch()..start();
    _build(large);
    final largeMs = sw10.elapsedMilliseconds;

    // Sanity ceiling (~7x the measured cost): only a blown-up build — the
    // quadratic shape this guard exists for — trips it.
    expect(largeMs, lessThan(3000), reason: '10k-record cold build');
    // Linear growth is ~10x from 1k to 10k; quadratic is >=100x. The 30x
    // ratio plus additive slack only trips when growth went superlinear.
    expect(
      largeMs,
      lessThan(smallMs * 30 + 250),
      reason:
          'growth 1k->10k must stay near-linear '
          '(${smallMs}ms -> ${largeMs}ms)',
    );
  });

  test('per-pass rebuilds with a shared cache stay incremental', () {
    final history = _turns(10000);
    final cache = LedgerEntryCache();
    _build(history, cache: cache); // cold pass populates the cache

    // Engine shape: every compaction pass rebuilds the ledger over the
    // whole visible path, with a few new records appended since. 24 passes
    // over a 10k-record session must cost O(records) bookkeeping per pass,
    // NOT 24 full re-tokenizations of history.
    final sw = Stopwatch()..start();
    for (var pass = 0; pass < 24; pass++) {
      history.addAll(_turn(100000 + pass)); // ids unique per pass
      _build(history, cache: cache);
    }
    final totalMs = sw.elapsedMilliseconds;

    // Bound is ~12x the measured cost; the pre-fix shape (full rebuild:
    // 24 x 10k re-tokenizations of ~1.5KB records) runs multiple seconds.
    expect(
      totalMs,
      lessThan(2500),
      reason: '24 cached rebuilds over a 10k-record session',
    );

    // Byte-equivalence: the cached ledger renders identically to a fresh
    // cold build over the same history, entry by entry.
    final cold = _build(history);
    final warm = _build(history, cache: cache);
    expect(warm.render(), cold.render());
    expect(warm.entries.length, cold.entries.length);
    for (var i = 0; i < cold.entries.length; i++) {
      final a = warm.entries[i];
      final b = cold.entries[i];
      expect(a.seq, b.seq);
      expect(a.recordId, b.recordId);
      expect(a.kind, b.kind);
      expect(a.tokens, b.tokens);
      expect(a.preview, b.preview);
      expect(a.toolNames, b.toolNames);
    }
  });

  test('entryAtSeq resolves every visible seq through the index', () {
    final history = _turns(300);
    final ledger = _build(history);
    for (final entry in ledger.entries) {
      expect(identical(ledger.entryAtSeq(entry.seq), entry), isTrue);
    }
    expect(ledger.entryAtSeq(-1), isNull);
    expect(ledger.entryAtSeq(999999), isNull);
  });

  test('a cache hit whose seq moved in file order recomputes honestly', () {
    final history = _turns(30);
    final cache = LedgerEntryCache();
    _build(history, cache: cache);

    // The same ids, shifted by one position (a prepended record): every
    // cached seq is now stale — the seq guard must recompute, and the
    // rendered aliases must match a fresh cold build exactly.
    final shifted = [..._turn(9999), ...history];
    final warm = _build(shifted, cache: cache);
    final cold = _build(shifted);
    expect(warm.render(), cold.render());
  });

  test('clear() forgets every memo and rebuilds byte-identically', () {
    final history = _turns(50);
    final cache = LedgerEntryCache();
    expect(_build(history, cache: cache).render(), _build(history).render());
    cache.clear();
    expect(_build(history, cache: cache).render(), _build(history).render());
  });
}
