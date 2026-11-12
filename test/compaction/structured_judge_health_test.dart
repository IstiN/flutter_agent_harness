// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2096 — judge robustness for slow/unusable judge classes.
///
/// - **Per-call budget token**: a budget timeout aborts only the in-flight
///   judge call — the retry and the later LM stages of the run keep a live
///   token (the incident's retry was born cancelled: the run-wide budget
///   token died with the first timeout and every later call failed in
///   ~75 ms).
/// - **Cross-run health latch**: consecutive judge failures persist per
///   session as additive records; while latched, runs skip the judge
///   (deterministic hide immediately) until the probe window elapses or
///   the configured class changes; a successful probe unlatches.
/// - **Timeout diagnosis**: the judge failure receipt names the attempt
///   shape — input entries, estimated tokens, elapsed.
/// - **Session survival (owner directive)**: every write is
///   append-only/additive — an old session loads unchanged, byte-identical
///   apart from the new records.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/judge.dart';
import 'package:flutter_agent_harness/src/compaction/structured/judge_health.dart';
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
/// wall clock (150ms budgets, real event loop, no real provider). The
/// per-call token is observed, never honoured (the engine's `.timeout`
/// owns the abort).
Future<String?> _deadJudge(String ledger, [CancelToken? cancelToken]) =>
    Completer<String?>().future;

/// A healthy judge: "hide every tool-call pair named in the ledger" —
/// the picks derive from the ledger text itself, so they stay valid
/// across runs whose additive records shift the numeric aliases.
Future<String?> _pairJudge(String ledger, [CancelToken? cancelToken]) {
  final seqs = RegExp(
    r'\[(\d+)\] assistant-TOOLCALL',
  ).allMatches(ledger).map((m) => m.group(1)!).toList();
  return Future<String?>.value(jsonEncode(seqs));
}

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
  /// (12k chars ≈ 3k tok each), sized so the deterministic fallback
  /// clears the trigger and these tests stay in the no-escalation
  /// regime. The LAST appended pair (seqs 15/16 with [pairs] == 6) stays
  /// inside the protected tail; seq 13 names the sixth pair's carrier.
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
      await session.appendMessage(_result('c$i', 'read', 'x' * 4000));
    }
    final messages = await session.buildContextMessages();
    return (session, stateFor(messages));
  }

  /// One more read pair, appended after the compaction runs.
  Future<void> appendPair(Session session, int i) async {
    await session.appendMessage(
      _assistant(
        'probe $i',
        calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
      ),
    );
    await session.appendMessage(_result('c$i', 'read', 'x' * 4000));
  }

  /// Runs one structured compaction over [session]/[state] with the given
  /// judge and latch knobs.
  Future<(_Hooks, bool)> runCompact(
    Session session,
    AgentState state, {
    required HideJudgeFn judge,
    Duration attemptBudget = const Duration(milliseconds: 150),
    Duration judgeProbeAfter = const Duration(minutes: 10),
    String judgeTarget = 'role=smol, model=flash-1 @ gate.example.ai',
    CancelTokenSource? budgetSource,
  }) async {
    final hooks = _Hooks();
    final ok = await StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: judge,
      summarize: (request) async => SummarizationResult.failure('no ckpt'),
      checkpointPrompt: 'P',
      hooks: hooks,
      protectLastN: 2,
      attemptBudget: attemptBudget,
      judgeProbeAfter: judgeProbeAfter,
      judgeTarget: judgeTarget,
      budgetSource: budgetSource,
    ).run();
    return (hooks, ok);
  }

  group('per-call budget token', () {
    test('gh-2096 AC: a budget timeout cancels ONLY the in-flight judge '
        'call — the retry and the run-wide token stay live', () async {
      final (session, state) = await pairSession(6);
      final budgetSource = CancelTokenSource();
      final received = <CancelToken>[];
      final liveAtReceive = <bool>[];
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) {
          received.add(token!);
          liveAtReceive.add(!token.isCancelled);
          return _deadJudge(ledger, token);
        },
        summarize: (request) async => SummarizationResult.failure('no ckpt'),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 2,
        attemptBudget: const Duration(milliseconds: 150),
        budgetSource: budgetSource,
      );

      final watch = Stopwatch()..start();
      final hid = await compactor.run();
      watch.stop();

      expect(hid, isTrue);
      // Initial + retry: the retry must actually run — and PAY the
      // budget (the incident's retry died in ~75 ms, born cancelled).
      expect(received, hasLength(2));
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 280)),
        reason:
            'every judge call pays the budget — none dies instantly '
            'on a stale cancelled token',
      );
      // Each call rode its OWN fresh token, live when received.
      expect(identical(received[0], received[1]), isFalse);
      expect(
        liveAtReceive.every((live) => live),
        isTrue,
        reason: 'a token must be live when its call starts',
      );
      // The timeouts still killed the in-flight calls (#515 kept).
      expect(received.every((token) => token.isCancelled), isTrue);
      // The run-wide budget token survived BOTH judge timeouts — the
      // retry and the later LM stages keep a live token (gh-2096).
      expect(
        budgetSource.token.isCancelled,
        isFalse,
        reason: 'a judge timeout must not cancel the run-wide budget token',
      );
    });
  });

  group('cross-run judge-health latch', () {
    test('gh-2096 AC: the first run pays the budget, the next run goes '
        'straight to the deterministic hide', () async {
      final (session, state) = await pairSession(6);
      var run1Calls = 0;
      final (hooks1, ok1) = await runCompact(
        session,
        state,
        judge: (ledger, [token]) {
          run1Calls++;
          return _deadJudge(ledger, token);
        },
      );
      expect(ok1, isTrue);
      expect(run1Calls, 2, reason: 'one retry, then the fallback');

      // The latch persisted as an additive session record.
      final health = judgeHealthFromPath(await session.getBranch());
      expect(health, isNotNull);
      expect(health!.consecutiveFailures, 2);
      expect(health.latched, isTrue);
      expect(health.target, 'role=smol, model=flash-1 @ gate.example.ai');

      // Fresh pressure + a fresh compactor: no judge call at all — the
      // run goes straight to the deterministic hide.
      await appendPair(session, 9);
      await appendPair(session, 10);
      final state2 = stateFor(await session.buildContextMessages());
      var run2Calls = 0;
      final (hooks2, ok2) = await runCompact(
        session,
        state2,
        judge: (ledger, [token]) {
          run2Calls++;
          return _deadJudge(ledger, token);
        },
        judgeProbeAfter: const Duration(hours: 1),
      );
      expect(ok2, isTrue);
      expect(run2Calls, 0, reason: 'the latch skips the judge entirely');
      // The skip receipt names the consequence explicitly.
      final notes = hooks2.passes.map((p) => p.error?.toString() ?? '').join();
      expect(
        notes,
        contains('judge latched: budget unwinnable for the configured class'),
      );
      expect(hooks2.passes.any((p) => p.judgeLatched), isTrue);
      // The deterministic hide still ran and freed the window.
      expect(
        hooks2.passes.where((p) => p.kind == 'hide-fallback' && p.ok),
        isNotEmpty,
      );
    });

    test('gh-2096 AC: a due probe unlatches on success — its answer '
        'drives the hide, the unlatch persists', () async {
      final (session, state) = await pairSession(6);
      await runCompact(session, state, judge: _deadJudge);

      // Fresh pressure, probe immediately due (zero window).
      await appendPair(session, 9);
      await appendPair(session, 10);
      final state2 = stateFor(await session.buildContextMessages());
      var probeCalls = 0;
      final (hooks2, ok2) = await runCompact(
        session,
        state2,
        judge: (ledger, [token]) {
          probeCalls++;
          return _pairJudge(ledger, token);
        },
        judgeProbeAfter: Duration.zero,
      );
      expect(ok2, isTrue);
      expect(probeCalls, 1, reason: 'the probe ran once and its answer hid');
      // The probe's answer drove a judged hide (whole pair groups).
      final judged = hooks2.passes.where((p) => p.kind == 'hide' && p.ok);
      expect(judged, isNotEmpty);
      expect(judged.single.hiddenCount, greaterThanOrEqualTo(2));
      // The unlatch persisted.
      final health = judgeHealthFromPath(await session.getBranch());
      expect(health!.consecutiveFailures, 0);
      expect(health.latched, isFalse);

      // A third run sees a HEALTHY latch state: the judge participates
      // normally again (no skip receipts, no latch writes).
      await appendPair(session, 11);
      await appendPair(session, 12);
      await appendPair(session, 13);
      await appendPair(session, 14);
      await appendPair(session, 15);
      final state3 = stateFor(await session.buildContextMessages());
      var run3Calls = 0;
      final (hooks3, ok3) = await runCompact(
        session,
        state3,
        judge: (ledger, [token]) {
          run3Calls++;
          return _pairJudge(ledger, token);
        },
        judgeProbeAfter: const Duration(hours: 1),
      );
      expect(ok3, isTrue);
      expect(
        run3Calls,
        greaterThanOrEqualTo(1),
        reason: 'unlatched — the judge is back',
      );
      expect(hooks3.passes.any((p) => p.judgeLatched), isFalse);
    });

    test('gh-2096: a failing probe stays latched — one call, no retry, '
        'the failure count grows', () async {
      final (session, state) = await pairSession(6);
      await runCompact(session, state, judge: _deadJudge);

      await appendPair(session, 9);
      await appendPair(session, 10);
      final state2 = stateFor(await session.buildContextMessages());
      var probeCalls = 0;
      final (hooks2, ok2) = await runCompact(
        session,
        state2,
        judge: (ledger, [token]) {
          probeCalls++;
          return _deadJudge(ledger, token);
        },
        judgeProbeAfter: Duration.zero,
      );
      expect(ok2, isTrue);
      // ONE probe call — no retry ladder while latched.
      expect(probeCalls, 1);
      // The failure grew and persisted.
      final health = judgeHealthFromPath(await session.getBranch());
      expect(health!.consecutiveFailures, 3);
      expect(health.latched, isTrue);
      // The probe failure surfaced as a latched receipt, then the
      // deterministic hide.
      final failed = hooks2.passes.where((p) => !p.ok).toList();
      expect(failed.first.judgeLatched, isTrue);
      expect(
        hooks2.passes.where((p) => p.kind == 'hide-fallback' && p.ok),
        isNotEmpty,
      );
    });

    test('gh-2096: a garbage probe failure rides the same one-probe '
        'latch path — persist + deterministic hide, no retry', () async {
      final (session, state) = await pairSession(6);
      await runCompact(session, state, judge: _deadJudge);

      await appendPair(session, 9);
      await appendPair(session, 10);
      final state2 = stateFor(await session.buildContextMessages());
      var probeCalls = 0;
      final (hooks2, ok2) = await runCompact(
        session,
        state2,
        judge: (ledger, [token]) {
          probeCalls++;
          return Future.value('not a pick list at all');
        },
        judgeProbeAfter: Duration.zero,
      );
      expect(ok2, isTrue);
      expect(probeCalls, 1, reason: 'one garbage probe, no retry');
      final health = judgeHealthFromPath(await session.getBranch());
      expect(health!.consecutiveFailures, 3);
      expect(health.latched, isTrue);
      final failed = hooks2.passes.where((p) => !p.ok).toList();
      expect(failed.first.judgeLatched, isTrue);
      expect(
        hooks2.passes.where((p) => p.kind == 'hide-fallback' && p.ok),
        isNotEmpty,
      );
    });

    test('gh-2096: a healthy judge answering garbage counts toward the '
        'same latch — two unparseable answers engage it', () async {
      final (session, state) = await pairSession(6);
      var judgeCalls = 0;
      final (hooks, ok) = await runCompact(
        session,
        state,
        judge: (ledger, [token]) {
          judgeCalls++;
          return Future.value('garbage');
        },
      );
      expect(ok, isTrue);
      // Failure → retry → the threshold crosses on the garbage itself.
      expect(judgeCalls, 2);
      final health = judgeHealthFromPath(await session.getBranch());
      expect(health!.consecutiveFailures, 2);
      expect(health.latched, isTrue);
      expect(hooks.passes.first.judgeLatched, isFalse);
      expect(
        hooks.passes.where((p) => p.kind == 'hide-fallback' && p.ok),
        isNotEmpty,
      );
    });

    test('gh-2096: a changed judge class probes immediately — the latch '
        'is about the class, not the session', () async {
      final (session, state) = await pairSession(6);
      await runCompact(session, state, judge: _deadJudge);

      await appendPair(session, 9);
      await appendPair(session, 10);
      final state2 = stateFor(await session.buildContextMessages());
      var probeCalls = 0;
      // The probe window is far away, but the CLASS changed.
      final (_, ok2) = await runCompact(
        session,
        state2,
        judge: (ledger, [token]) {
          probeCalls++;
          return _pairJudge(ledger, token);
        },
        judgeProbeAfter: const Duration(hours: 1),
        judgeTarget: 'role=smol, model=flash-2 @ gate.example.ai',
      );
      expect(ok2, isTrue);
      expect(probeCalls, 1, reason: 'a changed class probes at once');
      final health = judgeHealthFromPath(await session.getBranch());
      expect(health!.consecutiveFailures, 0, reason: 'unlatched on success');
      expect(health.target, 'role=smol, model=flash-2 @ gate.example.ai');
    });
  });

  group('timeout diagnosis', () {
    test('gh-2096 AC: the judge failure receipt carries entries, tokens '
        'and elapsed', () async {
      final (session, state) = await pairSession(6);
      final (hooks, ok) = await runCompact(session, state, judge: _deadJudge);
      expect(ok, isTrue);

      // The judge failure receipts (the escalation's own failed receipt
      // is gh-2044 machinery, not judge diagnosis).
      final failures = hooks.passes
          .where((p) => !p.ok && p.judgeInputEntries != null)
          .toList();
      expect(failures, hasLength(2));
      for (final pass in failures) {
        expect(pass.error, isA<TimeoutException>());
        final message = (pass.error as TimeoutException).message;
        // The #541 named line (role/model/endpoint/budget) is preserved…
        expect(
          message,
          startsWith(
            'structured compaction judge timeout (role=smol, model=flash-1 '
            '@ gate.example.ai, 0s budget,',
          ),
        );
        // …and the gh-2096 attempt shape rides it.
        expect(message, contains('entries=13'));
        expect(message, contains(' tok, elapsed='));
        expect(message, contains('ms)'));
        // The receipt carries the shape as structured fields too.
        expect(pass.judgeInputEntries, 13, reason: 'user + 6 read pairs');
        expect(pass.judgeInputTokens, greaterThan(0));
        expect(pass.judgeElapsedMs, greaterThanOrEqualTo(140));
      }
    });
  });

  group('session survival (owner directive)', () {
    test('gh-2096: an old large session loads unchanged — byte-identical '
        'apart from the additive records', () async {
      final (session, state) = await pairSession(6);
      // Age the session: a big append-only history the new code must not
      // rewrite (240 filler records on top of the pairs).
      for (var i = 0; i < 240; i++) {
        await session.appendMessage(_assistant('history filler $i'));
      }
      final meta = await session.getMetadata();
      final before = (await fs.readTextFile(meta.path)).valueOrNull ?? '';
      expect(before.split('\n').length, greaterThan(240));

      // The OLD binary never wrote judge-health records: loading the
      // session derives a fresh state — the judge participates normally.
      final reopened = Session(await JsonlSessionStorage.open(fs, meta.path));
      expect(
        judgeHealthFromPath(await reopened.getBranch()),
        isNull,
        reason: 'no judge-health records in an old session',
      );

      // A latching compaction appends records — never rewrites.
      final stateOld = stateFor(await reopened.buildContextMessages());
      await runCompact(reopened, stateOld, judge: _deadJudge);

      final after = (await fs.readTextFile(meta.path)).valueOrNull ?? '';
      expect(
        after.startsWith(before),
        isTrue,
        reason: 'the original bytes are untouched — append-only',
      );
      // The appended records are ONLY additive kinds: the hide event and
      // the judge-health custom record.
      final appendedLines = after
          .substring(before.length)
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      expect(appendedLines, hasLength(2));
      final maps = appendedLines
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(maps.map((map) => map['type']).toSet(), {
        'hidden_range',
        'custom',
      });
      final customLine = maps.singleWhere((map) => map['type'] == 'custom');
      expect(customLine['customType'], judgeHealthRecordType);
      expect(
        (customLine['data'] as Map)['consecutiveFailures'],
        2,
        reason: 'the latch record itself is honest',
      );
    });
  });

  group('judgeHealthFromPath', () {
    CustomRecord health(int failures, {String? target}) => CustomRecord(
      id: 'h$failures${target ?? ''}',
      parentId: 'prev',
      timestamp: DateTime.utc(2026),
      customType: judgeHealthRecordType,
      data: judgeHealthPayload(consecutiveFailures: failures, target: target),
    );

    test('no records → null (the legacy path writes nothing)', () {
      expect(judgeHealthFromPath(const []), isNull);
      expect(
        judgeHealthFromPath([
          MessageRecord(
            id: 'r1',
            parentId: '',
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('hi'),
          ),
        ]),
        isNull,
      );
    });

    test('newest record wins; latched only at the threshold', () {
      final state = judgeHealthFromPath([
        health(2, target: 'role=smol, model=a @ g'),
        health(0, target: 'role=smol, model=a @ g'),
      ])!;
      expect(state.consecutiveFailures, 0);
      expect(state.latched, isFalse);

      final latched = judgeHealthFromPath([health(2), health(3)])!;
      expect(latched.consecutiveFailures, 3);
      expect(latched.latched, isTrue);
      expect(latched.target, isNull);
    });

    test('malformed payload degrades to a fresh state, never throws', () {
      final corrupt = CustomRecord(
        id: 'bad',
        parentId: 'prev',
        timestamp: DateTime.utc(2026),
        customType: judgeHealthRecordType,
        data: {'consecutiveFailures': 'not-an-int', 'target': 42},
      );
      final state = judgeHealthFromPath([corrupt])!;
      expect(state.consecutiveFailures, 0);
      expect(state.latched, isFalse);
      expect(state.target, isNull);
    });

    test('judgeLatchAfter mirrors the in-run fallback threshold', () {
      expect(judgeLatchAfter, 2);
    });
  });

  group('factory surface (AutoCompactorPass fields)', () {
    test('gh-2096: the host-visible pass receipts carry the judge '
        'diagnosis and the latch flag', () async {
      final (session, state) = await pairSession(6);
      final hooks = _CapturingAutoHooks();
      final receivedTokens = <CancelToken>[];
      final liveAtReceive = <bool>[];

      // The smol stream serves the judge AND the structured summarizer:
      // a judge prompt (the ledger) hangs until its token aborts — the
      // slow-class wedge; a checkpoint prompt ('<conversation>') answers
      // so the checkpoint ladder succeeds and the run settles cleanly.
      AssistantMessage message(StopReason reason, {String? text}) =>
          AssistantMessage(
            content: [
              if (text != null) TextContent(text: text) else ...const [],
            ],
            api: 'anthropic-messages',
            provider: 'p',
            model: 'flash-1',
            usage: Usage.zero,
            stopReason: reason,
            timestamp: DateTime.utc(2026),
          );
      bool isSummarizerPrompt(Context c) {
        final last = c.messages.lastOrNull;
        if (last is! UserMessage) return false;
        final content = last.content;
        final text = content is String
            ? content
            : (content as List<Object>)
                  .whereType<TextContent>()
                  .map((block) => block.text)
                  .join();
        return text.contains('<conversation>');
      }

      AssistantMessageEventStream routed(
        Model m,
        Context c, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        if (isSummarizerPrompt(c)) {
          stream.push(StartEvent(partial: message(StopReason.stop)));
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: message(StopReason.stop, text: 'checkpoint summary'),
            ),
          );
          stream.end();
          return stream;
        }
        // The judge: record the per-call token, then hang until aborted.
        receivedTokens.add(cancelToken!);
        liveAtReceive.add(!cancelToken.isCancelled);
        stream.push(StartEvent(partial: message(StopReason.stop)));
        unawaited(
          cancelToken.onCancel.then((_) {
            stream.push(
              DoneEvent(
                reason: StopReason.aborted,
                message: message(StopReason.aborted),
              ),
            );
            stream.end();
          }),
        );
        return stream;
      }

      Future<bool> runOnce() => AutoCompactorFactory(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        sources: AutoCompactorSources(
          smolStream: routed,
          smolModel: Model(
            id: 'flash-1',
            name: 'flash-1',
            api: 'anthropic-messages',
            provider: 'p',
            baseUrl: 'http://localhost:1',
            contextWindow: 8000,
            maxTokens: 4096,
          ),
          mainStream: routed,
          mainModel: state.model,
        ),
        hooks: hooks,
        attemptBudget: const Duration(milliseconds: 150),
        totalBudget: const Duration(seconds: 5),
      ).run();

      expect(await runOnce(), isTrue);
      // The judge timeouts surfaced with the attempt shape on the
      // host-visible pass.
      final failed = hooks.passes.where((p) => !p.ok).toList();
      expect(failed, isNotEmpty);
      expect(failed.first.judgeInputEntries, greaterThan(0));
      expect(failed.first.judgeInputTokens, greaterThan(0));
      expect(failed.first.judgeElapsedMs, greaterThanOrEqualTo(140));
      // The provider stream received the per-call tokens — each LIVE
      // when received (the incident's retry was born cancelled) — and
      // each killed by its own budget expiry (#515 kept).
      expect(receivedTokens, hasLength(2));
      expect(liveAtReceive.every((live) => live), isTrue);
      expect(receivedTokens.every((t) => t.isCancelled), isTrue);

      // Fresh pressure; run again with the probe window far away — the
      // latch skip surfaces on the host pass as `judgeLatched`, and no
      // judge call happens at all.
      await appendPair(session, 9);
      await appendPair(session, 10);
      await appendPair(session, 11);
      await appendPair(session, 12);
      state.messages = await session.buildContextMessages();
      receivedTokens.clear();
      liveAtReceive.clear();
      expect(await runOnce(), isTrue);
      expect(
        hooks.passes.any((p) => p.judgeLatched),
        isTrue,
        reason: 'the latched skip is visible to the host',
      );
      expect(receivedTokens, isEmpty, reason: 'no judge call while latched');
    });
  });
}

final class _CapturingAutoHooks extends AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onBothRolesFailed(Object lastError) {}
}
