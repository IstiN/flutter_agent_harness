@TestOn('vm')
library;

/// gh-2492 C4 — the ledger budget wired into the projection.
///
/// After several hide passes the request's hidden markers stay under the
/// pinned budget: the oldest adjacent markers collapse into ONE working
/// pointer each (`N records hidden · <label> [expand a-b]`), derived at
/// RENDER time from the session records (no file rewrite, deterministic
/// across rebuilds). The expandable set never changes — every id the
/// collapsed pointer names is still hidden in the session file (REG-2/3).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/ledger_budget.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart'
    show RecordSeqIndex;
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {String? tool, String? callId}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        if (tool != null)
          ToolCall(id: callId!, name: tool, arguments: const {}),
      ],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026, 11, 28, 12, 0, 0),
    );

/// A session whose first [count] records (after the two head records the
/// fixture writes first) are hidden across [passes] separate hide events
/// — the five-compaction shape.
Future<(Session, List<String>)> _hiddenSession(
  JsonlSessionRepo repo,
  int count,
  int passes,
) async {
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  final ids = <String>[];
  for (var i = 0; i < count; i++) {
    ids.add(
      await session.appendMessage(
        _assistant(
          'turn $i with some body text to make the record non-trivial',
          tool: i.isEven ? 'bash' : 'read',
          callId: 'c$i',
        ),
      ),
    );
  }
  // Hide in [passes] contiguous chunks — adjacent ranges the render-time
  // view must consolidate.
  final chunk = count ~/ passes;
  for (var p = 0; p < passes; p++) {
    final start = p * chunk;
    final end = p == passes - 1 ? count - 1 : start + chunk - 1;
    await session.appendHiddenRange(
      recordIds: [for (var i = start; i <= end; i++) ids[i]],
    );
  }
  return (session, ids);
}

void main() {
  group('renderStructuredMessages ledger budget (gh-2492 C4)', () {
    test('markers of a request stay under the pinned budget after five '
        'hide passes', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final (session, ids) = await _hiddenSession(repo, 160, 5);
      final messages = await session.buildContextMessages();
      // The markers the request carries (user-role ledger markers only —
      // tool_result pair markers are content, out of the budget).
      final markerTokens = messages.fold<int>(0, (sum, message) {
        final ref = ledgerMarkerRef(0, message);
        return ref == null ? sum : sum + ref.tokens;
      });
      expect(
        markerTokens,
        lessThanOrEqualTo(hiddenLedgerBudgetTokens),
        reason: 'the oldest markers collapse until the ledger fits',
      );
      // The head carries the collapsed pointer with its histogram label
      // and a working door.
      final firstMarker = messages
          .map((message) => ledgerMarkerRef(0, message))
          .firstWhere((ref) => ref != null, orElse: () => null)!;
      final text = firstMarker.message is UserMessage
          ? (firstMarker.message as UserMessage).content as String
          : '';
      expect(text, contains('records hidden'));
      expect(text, contains('[expand'));
      expect(text, contains('· bash ×'), reason: 'the C5 histogram label');
      // The expand door stays honest: every seq the collapsed pointer
      // names is still hidden in the session file (REG-2/3).
      final hidden = <String>{};
      final records = await (await JsonlSessionStorage.open(
        env,
        (await session.getMetadata()).path,
      )).getEntries();
      for (final record in records) {
        if (record is HiddenRangeRecord) hidden.addAll(record.recordIds);
      }
      final collapsedStart = firstMarker.firstSeq;
      final collapsedEnd = firstMarker.lastSeq;
      expect(collapsedEnd, greaterThan(collapsedStart));
      final seqs = RecordSeqIndex(records);
      for (var seq = collapsedStart; seq <= collapsedEnd; seq++) {
        final record = seqs.recordAt(seq);
        if (record == null) continue;
        expect(
          hidden.contains(record.id),
          isTrue,
          reason: 'seq $seq must stay hidden — the door still resolves it',
        );
      }
      // Every hidden id remains expandable somewhere (the set never
      // shrinks: N records over all collapsed pointers = all hidden).
      final namedSeqs = <int>{};
      for (final message in messages) {
        final ref = ledgerMarkerRef(0, message);
        if (ref == null) continue;
        for (var seq = ref.firstSeq; seq <= ref.lastSeq; seq++) {
          namedSeqs.add(seq);
        }
      }
      final hiddenSeqs = {
        for (final id in hidden)
          if (seqs.seqOf(id) != null) seqs.seqOf(id)!,
      };
      expect(namedSeqs, containsAll(hiddenSeqs));
    });

    test('the collapsed view is deterministic across rebuilds', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final (session, _) = await _hiddenSession(repo, 160, 5);
      final first = await session.buildContextMessages();
      // A SECOND, independent session over the SAME file rebuilds the
      // identical view — the labels derive from the records, not from
      // live state.
      final reopened = await repo.open(await session.getMetadata());
      final second = await reopened.buildContextMessages();
      expect(
        second.map((m) => m.toJson()).toList(),
        first.map((m) => m.toJson()).toList(),
        reason: 'labels derive from the records — stable across rebuilds',
      );
    });

    test('under budget the markers render byte-identical to before', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      // Three hidden records — far under the cap.
      final (session, ids) = await _hiddenSession(repo, 3, 1);
      final messages = await session.buildContextMessages();
      final texts = [
        for (final message in messages)
          if (message is UserMessage) message.content as String,
      ];
      expect(texts.any((text) => text.contains('records hidden')), isFalse);
      expect(texts.any((text) => text.contains('[2:hidden')), isTrue);
      expect(texts.any((text) => text.contains('[4:hidden')), isTrue);
    });
  });
}
