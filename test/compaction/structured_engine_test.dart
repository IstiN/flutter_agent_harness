// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #148 — the structured engine loop: judge-driven hides, no-op on
/// judge failure, checkpoint append with covers, failure-safe summarize,
/// under-window termination, and depth-cap flattening.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      if (calls != null) ...calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _result(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

/// Window 8000, reserve 2000 -> trigger 6000; keep-recent 2000.
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  AgentState stateFor(List<Message> messages) => AgentState(
    model: Model(
      id: 'm1',
      name: 'm1',
      api: 'anthropic-messages',
      provider: 'p',
      baseUrl: 'http://localhost:1',
      contextWindow: 8000,
      maxTokens: 4096,
    ),
    messages: messages,
  );

  /// A bug-fix shaped history (~7.1k estimated tokens, over the 6000
  /// trigger): user ask, read pair (16k chars), analysis, bash pair
  /// (12k chars), 6 filler assistants.
  Future<(Session, AgentState)> overWindowSession() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(
      _assistant(
        'looking',
        calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
      ),
    );
    await session.appendMessage(_result('c1', 'read', 'x' * 16000));
    await session.appendMessage(_assistant('found token-expiry bug'));
    await session.appendMessage(
      _assistant(
        'running tests',
        calls: [ToolCall(id: 'c2', name: 'bash', arguments: {})],
      ),
    );
    await session.appendMessage(_result('c2', 'bash', 'y' * 12000));
    for (var i = 0; i < 6; i++) {
      await session.appendMessage(_assistant('filler analysis $i'));
    }
    final messages = await session.buildContextMessages();
    assert(
      estimateContextTokens(messages).tokens > 6000,
      'fixture must be over the trigger',
    );
    return (session, stateFor(messages));
  }

  test('pass 1 hides judge-picked pairs and refreshes state', () async {
    final (session, state) = await overWindowSession();
    var judgeCalls = 0;
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger) async {
        judgeCalls++;
        // Hide the read pair: the assistant carrier (line 3) snaps the
        // whole group with its result.
        return '["3"]';
      },
      summarize: (request) async =>
          SummarizationResult.failure('must not summarize in this test'),
      checkpointPrompt: 'SUMMARY INSTRUCTIONS',
    );
    final hid = await compactor.run();

    final messages = state.messages;
    // The whole read pair is hidden: the carrier became a user-role
    // marker and its result — orphaned by the hidden carrier — became
    // one too (wire safety), both addressable by their line ids.
    final markers = messages
        .whereType<UserMessage>()
        .map((m) => m.content as String)
        .where((text) => text.contains(':hidden'))
        .toList();
    expect(markers, hasLength(2));
    expect(markers.first, startsWith('[3:hidden'));
    expect(markers.last, startsWith('[4:hidden·tool_result'));
    // The pair did not split on the wire.
    expect(validateToolPairing(messages), isEmpty);
    // Nothing was checkpointed: hides alone relieved the pressure.
    final records = await session.getEntries();
    expect(records.whereType<CompactCheckpointRecord>(), isEmpty);
    expect(hid, isTrue, reason: 'hides alone relieved the pressure');
    expect(judgeCalls, 1);
  });

  test('judge failure is a no-op for hides — pass 2 still engages', () async {
    final (session, state) = await overWindowSession();
    var judgeCalls = 0;
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger) async {
        judgeCalls++;
        return null; // Failed call (F1): never an empty hide list.
      },
      summarize: (request) async => SummarizationResult.success('S'),
      checkpointPrompt: 'P',
    );
    await compactor.run();

    // F1: no hide records from a failed judge; exactly one bounded call.
    expect(judgeCalls, 1);
    final records = await session.getEntries();
    expect(records.whereType<HiddenRangeRecord>(), isEmpty);
    // Pressure remained, so pass 2 checkpointed legitimately.
    expect(records.whereType<CompactCheckpointRecord>(), isNotEmpty);
    expect(
      state.messages.whereType<UserMessage>().map((m) => m.content as String),
      anyElement(contains(':ckpt')),
    );
  });

  test(
    'pass 2 checkpoints the oldest range with covers and open asks',
    () async {
      final (session, state) = await overWindowSession();
      final prompts = <String>[];
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger) async => null, // Judge refuses: straight to pass 2.
        summarize: (request) async {
          prompts.add(request.prompt);
          return SummarizationResult.success(
            'investigated login crash; token-expiry bug found; tests green',
          );
        },
        checkpointPrompt: 'CHECKPOINT INSTRUCTIONS',
      );
      final ok = await compactor.run();

      final ckpts = (await session.getEntries())
          .whereType<CompactCheckpointRecord>()
          .toList();
      expect(ckpts, hasLength(1), reason: 'relief after one checkpoint: $ok');
      final ckpt = ckpts.single;
      expect(ckpt.text, contains('token-expiry'));
      // The range is the whole unprotected prefix, pair-snapped.
      expect(
        ckpt.coversRecordIds,
        containsAll([ckpt.firstRecordId, ckpt.lastRecordId]),
      );
      // Prompt carried the conversation, the covers line, open asks, and
      // the instruction tail.
      final prompt = prompts.single;
      expect(prompt, contains('<conversation>'));
      expect(prompt, contains('<covers>'));
      expect(prompt, contains('fix the login crash'));
      expect(prompt, contains('CHECKPOINT INSTRUCTIONS'));
      // State renders the checkpoint marker in place of the range and
      // stays wire-valid.
      final marker = state.messages
          .whereType<UserMessage>()
          .map((m) => m.content as String)
          .firstWhere((text) => text.contains(':ckpt'));
      expect(marker, contains('covers:'));
      expect(validateToolPairing(state.messages), isEmpty);
      // Transcript replay stays consistent.
      expect(
        await session.buildContextMessages(),
        hasLength(state.messages.length),
      );
    },
  );

  test('summarizer failure appends nothing and surfaces failure', () async {
    final (session, state) = await overWindowSession();
    final messagesBefore = [...state.messages];
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger) async => null,
      summarize: (request) async => SummarizationResult.failure('boom'),
      checkpointPrompt: 'P',
    );
    final ok = await compactor.run();

    expect(ok, isFalse, reason: 'failure surfaces for classic fallback');
    final records = await session.getEntries();
    expect(records.whereType<CompactCheckpointRecord>(), isEmpty);
    expect(records.whereType<HiddenRangeRecord>(), isEmpty);
    expect(state.messages.length, messagesBefore.length);
  });

  test('nested checkpoints flatten at the depth cap', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('start'));
    final state = stateFor(await session.buildContextMessages());
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 800,
      settings: const CompactionSettings(
        enabled: true,
        reserveTokens: 100,
        keepRecentTokens: 100,
      ),
      judge: (ledger) async => null,
      summarize: (request) async =>
          SummarizationResult.success('round summary'),
      checkpointPrompt: 'P',
      maxCheckpointPasses: 2,
    );

    // Nesting happens across runs: each burst of new turns re-pressures
    // the window and the next checkpoint swallows the previous one.
    for (var round = 0; round < 6; round++) {
      for (var i = 0; i < 8; i++) {
        await session.appendMessage(
          _assistant('round $round step $i ${'detail ' * 40}'),
        );
      }
      // Hosts mirror the session into state; do the same before each
      // run so the trigger sees the fresh pressure.
      state.messages = await session.buildContextMessages();
      await compactor.run();
    }

    final ckpts = (await session.getEntries())
        .whereType<CompactCheckpointRecord>()
        .toList();
    expect(ckpts.length, greaterThan(3));
    // Once depth would exceed 4, the new checkpoint flattens the deepest
    // chain head — recorded in flattenedRecordIds (D5).
    expect(
      ckpts.any((c) => c.flattenedRecordIds.isNotEmpty),
      isTrue,
      reason: 'depth cap must fold at least one inner checkpoint',
    );
    // Everything still renders and stays wire-safe.
    expect(validateToolPairing(state.messages), isEmpty);
  });

  group('classicTransform', () {
    MessageRecord rec(String id, String? parentId) => MessageRecord(
      id: id,
      parentId: parentId,
      timestamp: DateTime.utc(2026),
      message: UserMessage.text('msg $id'),
    );

    CompactionRecord compaction(String id, String firstKept) =>
        CompactionRecord(
          id: id,
          parentId: 'p',
          timestamp: DateTime.utc(2026),
          summary: 'legacy summary',
          firstKeptEntryId: firstKept,
          tokensBefore: 1234,
        );

    test('no compaction → the path passes through unchanged (copied)', () {
      final path = [rec('a', null), rec('b', 'a')];
      final out = classicTransform(path);
      expect(out, equals(path));
      expect(identical(out, path), isFalse, reason: 'defensive copy');
    });

    test('cuts at the LAST compaction; kept suffix + post records survive', () {
      final path = [
        rec('a', null),
        rec('b', 'a'),
        compaction('c1', 'b'),
        rec('d', 'c1'),
        rec('e', null), // pre-second-compaction: dropped
        compaction('c2', 'e'),
        rec('f', 'c2'),
      ];
      final out = classicTransform(path);
      // Heads with the LAST compaction's summary; everything before its
      // first-kept entry is gone; records after it stay in order.
      expect([for (final r in out) r.id], ['c2', 'e', 'f']);
      expect(out.first, isA<CompactionRecord>());
    });

    test('firstKeptEntryId not on the path → everything before drops', () {
      final path = [rec('a', null), compaction('c', 'gone'), rec('d', 'c')];
      final out = classicTransform(path);
      expect([for (final r in out) r.id], ['c', 'd']);
    });
  });
}
