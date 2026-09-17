// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #541 — the structured-compaction judge is not a single point of
/// failure. Consecutive judge failures (timeout / error) engage a
/// deterministic judge-less hide, the judge input is bounded so the 90s
/// budget stays winnable on giant sessions, and a judge timeout names its
/// role/model/endpoint/budget instead of dying anonymously.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      ...?calls,
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

/// A judge that never answers — the marathon-session wedge, minus the
/// wall clock (150ms budgets, real event loop, no real provider).
Future<String?> _deadJudge(String ledger) => Completer<String?>().future;

final class _Hooks implements StructuredCompactorHooks {
  final passes = <StructuredCompactionPass>[];

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) => passes.add(pass);
}

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

  /// A session over the 6000 trigger: user ask + [pairs] read pairs
  /// (16k chars ≈ 4k tok each).
  Future<(Session, AgentState)> pairSession(int pairs) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    for (var i = 0; i < pairs; i++) {
      await session.appendMessage(
        _assistant(
          'probe $i',
          calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
        ),
      );
      await session.appendMessage(_result('c$i', 'read', 'x' * 16000));
    }
    final messages = await session.buildContextMessages();
    return (session, stateFor(messages));
  }

  Set<String> hiddenRecordIds(List<SessionRecord> records) => {
    for (final record in records.whereType<HiddenRangeRecord>())
      ...record.recordIds,
  };

  test('AC1: a judge that always times out no longer bricks the run — '
      'the deterministic fallback hides and the run continues', () async {
    final (session, state) = await pairSession(6);
    var judgeCalls = 0;
    final hooks = _Hooks();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger) {
        judgeCalls++;
        return _deadJudge(ledger);
      },
      summarize: (request) async => SummarizationResult.failure('no ckpt'),
      checkpointPrompt: 'P',
      hooks: hooks,
      protectLastN: 2,
      attemptBudget: const Duration(milliseconds: 150),
    );

    final hid = await compactor.run();

    expect(hid, isTrue, reason: 'the fallback freed enough on its own');
    expect(
      judgeCalls,
      2,
      reason: 'one retry, then the judge-less fallback — no more LLM burns',
    );
    final records = await session.getEntries();
    expect(hiddenRecordIds(records), hasLength(10), reason: 'five whole pairs');
    // The fallback receipt surfaced as its own loud pass.
    final fallbackPasses = hooks.passes
        .where((p) => p.kind == 'hide-fallback')
        .toList();
    expect(fallbackPasses, hasLength(1));
    expect(fallbackPasses.single.ok, isTrue);
    expect(fallbackPasses.single.hiddenCount, 10);
    // The judge failures surfaced by name, not as an anonymous wedge.
    final failurePasses = hooks.passes.where((p) => !p.ok).toList();
    expect(failurePasses, hasLength(2));
    expect(failurePasses.every((p) => p.error is TimeoutException), isTrue);
    // Wire stays pair-safe; the real user turn survived.
    expect(validateToolPairing(state.messages), isEmpty);
    expect(
      hiddenRecordIds(records),
      isNot(contains(records.first.id)),
      reason: 'the exempt user record is never hidden',
    );
  });

  test('AC2: the judge input is bounded — a 30k-record ledger renders '
      'within 2x of a 3k-record one', () {
    String judgeInput(int records) {
      final entries = <SessionRecord>[
        for (var i = 0; i < records; i++)
          MessageRecord(
            id: 'r$i',
            parentId: '',
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('message $i'),
          ),
      ];
      final ledger = buildContextLedger(
        visiblePath: entries,
        seqs: RecordSeqIndex(entries),
      );
      return ledger.render();
    }

    final small = judgeInput(3000);
    final giant = judgeInput(30000);

    expect(
      giant.length <= small.length * 2,
      isTrue,
      reason: 'bounded cap, not linear: ${giant.length} vs ${small.length}',
    );
    // The omitted prefix is summarized, not dropped silently.
    expect(giant, contains('older records'));
    expect(giant, contains('[30001]'));
  });

  test(
    'AC3: the judge timeout names role, model, endpoint and budget',
    () async {
      final (session, state) = await pairSession(2);
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: _deadJudge,
        summarize: (request) async => SummarizationResult.failure('no ckpt'),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 2,
        judgeTarget: 'role=smol, model=kimi-k2 @ gate.example.ai',
        attemptBudget: const Duration(seconds: 1),
      );

      await compactor.run();

      final errors = [
        for (final pass in hooks.passes.where((p) => !p.ok)) pass.error,
      ];
      expect(errors, isNotEmpty);
      expect(
        (errors.first as TimeoutException).message,
        'structured compaction judge timeout (role=smol, model=kimi-k2 @ '
        'gate.example.ai, 1s budget) (issue #515)',
      );
    },
  );

  test('AC4: the budget knob bounds the judge — a patient judge succeeds '
      'where a tight one falls back', () async {
    Future<(bool, _Hooks)> runWith(Duration attemptBudget) async {
      final (session, state) = await pairSession(2);
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger) async {
          // An 80ms judge: patient budgets win, tight ones fall back.
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return '["3"]';
        },
        summarize: (request) async => SummarizationResult.failure('no ckpt'),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 2,
        attemptBudget: attemptBudget,
      );
      return (await compactor.run(), hooks);
    }

    final (okPatient, patientHooks) = await runWith(
      const Duration(milliseconds: 300),
    );
    expect(okPatient, isTrue);
    expect(
      patientHooks.passes.where((p) => p.kind == 'hide-fallback'),
      isEmpty,
      reason: 'a judge inside the budget never needs the fallback',
    );

    final (okTight, tightHooks) = await runWith(
      const Duration(milliseconds: 50),
    );
    expect(okTight, isTrue);
    expect(
      tightHooks.passes.where((p) => p.kind == 'hide-fallback'),
      isNotEmpty,
      reason: 'a judge past the budget falls back instead of brickkilling',
    );
  });

  test('AC5: the fallback never splits a pair reaching into the protected '
      'tail', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(_assistant('a'));
    await session.appendMessage(_assistant('b'));
    await session.appendMessage(
      _assistant(
        'probe',
        calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
      ),
    );
    await session.appendMessage(_result('c1', 'read', 'x' * 16000));
    for (var i = 0; i < 7; i++) {
      await session.appendMessage(_assistant('filler $i'));
    }
    final state = stateFor(await session.buildContextMessages());
    final recordsAt = await session.getEntries();
    // 12 records; protectLastN 8 -> the read pair (records 4 and 5)
    // straddles the recency floor: its result is protected, so the whole
    // group must be vetoed.
    final hooks = _Hooks();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: _deadJudge,
      summarize: (request) async => SummarizationResult.failure('no ckpt'),
      checkpointPrompt: 'P',
      hooks: hooks,
      attemptBudget: const Duration(milliseconds: 150),
    );

    await compactor.run();

    final records = await session.getEntries();
    final hidden = hiddenRecordIds(records);
    expect(hidden.contains(recordsAt[3].id), isFalse, reason: 'carrier');
    expect(
      hidden.contains(recordsAt[4].id),
      isFalse,
      reason: 'the pair is whole or nothing (D6)',
    );
    expect(validateToolPairing(state.messages), isEmpty);
  });

  test('AC6 REG: a healthy judge keeps the exact legacy flow — no '
      'fallback receipt, no failure passes', () async {
    final (session, state) = await pairSession(2);
    final hooks = _Hooks();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger) async => '["3"]',
      summarize: (request) async => SummarizationResult.failure('no ckpt'),
      checkpointPrompt: 'P',
      hooks: hooks,
      protectLastN: 2,
    );

    final hid = await compactor.run();

    expect(hid, isTrue);
    expect(hooks.passes.where((p) => p.kind == 'hide-fallback'), isEmpty);
    expect(hooks.passes.where((p) => !p.ok), isEmpty);
    expect(hooks.passes.where((p) => p.kind == 'hide' && p.ok), hasLength(1));
    expect(hiddenRecordIds(await session.getEntries()), hasLength(2));
  });

  test('E2: one judge failure with a recovery on the retry never engages '
      'the fallback', () async {
    final (session, state) = await pairSession(2);
    var calls = 0;
    final hooks = _Hooks();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger) {
        calls++;
        return calls == 1 ? Future<String?>.value(null) : Future.value('["3"]');
      },
      summarize: (request) async => SummarizationResult.failure('no ckpt'),
      checkpointPrompt: 'P',
      hooks: hooks,
      protectLastN: 2,
    );

    final hid = await compactor.run();

    expect(hid, isTrue);
    expect(calls, 2, reason: 'the failed call is retried, not fatal');
    expect(hooks.passes.where((p) => p.kind == 'hide-fallback'), isEmpty);
    expect(
      hooks.passes.where((p) => p.kind == 'hide' && p.ok).single.hiddenCount,
      2,
      reason: 'the hide came from the judge retry, not the fallback',
    );
  });

  test('E1: when even the fallback finds nothing hideable, the stuck pass '
      'names the offender instead of looping silently', () async {
    final (session, state) = await pairSession(1);
    final hooks = _Hooks();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 5000, // Trigger 3000 < ~4020 estimated: real pressure.
      settings: _settings,
      judge: _deadJudge,
      summarize: (request) async => SummarizationResult.failure('no ckpt'),
      checkpointPrompt: 'P',
      hooks: hooks,
      protectLastN: 1, // tailStart 2: the pair straddles it — all vetoed.
      attemptBudget: const Duration(milliseconds: 150),
    );

    // Three records, protectLastN 1: the only hideable group reaches
    // into the protected tail — the fallback has nothing it may hide.
    final hid = await compactor.run();

    expect(hid, isFalse, reason: 'honest failure for the classic fallback');
    final stuck = hooks.passes
        .where((p) => !p.ok && p.error.toString().contains('deterministic'))
        .toList();
    expect(stuck, hasLength(1));
    expect(stuck.single.error.toString(), contains('toolResult'));
  });
}
