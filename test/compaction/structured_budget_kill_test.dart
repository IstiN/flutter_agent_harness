// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #2258 — a total-budget kill must stop EVERY engine path. The
/// hide/checkpoint pass ladders (no budget guard — only the escalation
/// had one) used to keep appending session records and REPLACING
/// `state.messages` after the factory already returned `timedOut` and
/// the local trim bounded the live context: two writers, the funnel's
/// "[context trimmed locally]" success silently undone. A ladder that
/// lost the race to the factory's verdict must stop writing and surface
/// abandoned — no late records, no refresh, no receipts (#1085
/// vocabulary: the verdict is authoritative).
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart'
    show localTrimMarkerPrefix;
import 'package:test/test.dart';

import '../session/flaky_session_fs.dart';

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

/// A judge that never answers on its own — the marathon-session wedge,
/// minus the wall clock (real event loop, no real provider).
Future<String?> _deadJudge(String ledger, [CancelToken? cancelToken]) =>
    Completer<String?>().future;

final class _Hooks implements StructuredCompactorHooks {
  final passes = <StructuredCompactionPass>[];

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) => passes.add(pass);
}

final class _CapturingAutoHooks extends AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];
  int doneCount = 0;

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens, {String? reason}) => doneCount++;

  @override
  void onBothRolesFailed(Object lastError) {}
}

/// Lets every trailing microtask/timer the abandoned engine future still
/// has scheduled land — exactly the late-settle window `running.ignore()`
/// drops the VALUE of (its EXECUTION keeps running until the guards stop
/// it).
Future<void> _pump([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

Set<String> hiddenRecordIds(List<SessionRecord> records) => {
  for (final record in records.whereType<HiddenRangeRecord>())
    ...record.recordIds,
};

/// Whether [message] is the in-memory local-trim marker the valve
/// prefixes (an in-memory-only construct: never in the session file).
bool _isLocalTrimMarker(Message message) {
  if (message is! UserMessage) return false;
  final content = message.content;
  final text = content is String
      ? content
      : (content as List<Object>).whereType<TextContent>().map((b) {
          return b.text;
        }).join();
  return text.startsWith(localTrimMarkerPrefix);
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
  /// (12k chars ≈ 3k tok each) — hideable entries past the recency floor,
  /// closed by a small live tail (the trim valve's newest-message budget
  /// rule, gh-1077, needs a last message that fits keepRecentTokens).
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
      await session.appendMessage(_result('c$i', 'read', 'x' * 12000));
    }
    await session.appendMessage(_assistant('done — the build is green'));
    final messages = await session.buildContextMessages();
    return (session, stateFor(messages));
  }

  group('AC1 — the factory kill stops the hide ladder (two-writer hole)', () {
    test(
      'a judge hung past the 2s totalBudget: after factory.run() + the '
      'local trim, NO HiddenRangeRecord lands and the trimmed tail stays',
      () async {
        final (session, state) = await pairSession(6);
        final hooks = _CapturingAutoHooks();
        AssistantMessage streamMessage(StopReason reason) => AssistantMessage(
          content: [TextContent(text: '')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: reason,
          timestamp: DateTime.utc(2026),
        );

        // The production wedge: the judge stream starts, then hangs until
        // its per-call token aborts — the totalBudget kill (2s) lands while
        // it is in flight (attemptBudget 30s never fires first).
        AssistantMessageEventStream routed(
          Model m,
          Context c, {
          CancelToken? cancelToken,
        }) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: streamMessage(StopReason.stop)));
          unawaited(
            cancelToken?.onCancel.then((_) {
              stream.push(
                DoneEvent(
                  reason: StopReason.aborted,
                  message: streamMessage(StopReason.aborted),
                ),
              );
              stream.end();
            }),
          );
          return stream;
        }

        final ok = await AutoCompactorFactory(
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
          attemptBudget: const Duration(seconds: 30),
          totalBudget: const Duration(seconds: 2),
        ).run();

        // The factory verdict is authoritative: the local trim bounded the
        // live context and the run succeeded.
        expect(ok, isTrue);
        final trimmedTail = List<Message>.of(state.messages);
        expect(
          trimmedTail.map((m) => m.role),
          contains('user'),
          reason: 'the [context trimmed locally] marker leads the tail',
        );
        final recordsAfterVerdict = await session.getEntries();
        final hiddenAfterVerdict = hiddenRecordIds(recordsAfterVerdict);

        // The abandoned engine future's execution keeps running — pump the
        // event loop so any post-verdict write would land.
        await _pump();

        expect(
          hiddenRecordIds(await session.getEntries()),
          equals(hiddenAfterVerdict),
          reason:
              'no HiddenRangeRecord may land after the factory verdict '
              '(the deterministic-hide ladder lost the race and must stop)',
        );
        // state.messages must stay the trimmed list. The getter wraps its
        // backing store fresh on every read (identity proves nothing) — the
        // decisive observable is the CONTENT: the trim marker is in-memory
        // ONLY, so any post-verdict _refreshState() rebuilds the FULL
        // session projection (14 records, markers for hidden ranges) and
        // drops it.
        expect(
          state.messages.length,
          trimmedTail.length,
          reason:
              'state.messages must stay the trimmed tail, not the '
              'rebuilt session projection',
        );
        expect(
          [for (final m in state.messages) m.role],
          equals([for (final m in trimmedTail) m.role]),
          reason: 'the trimmed tail must keep its exact shape',
        );
        expect(
          _isLocalTrimMarker(state.messages.first),
          isTrue,
          reason:
              'the [context trimmed locally] marker must survive — a '
              'post-verdict refresh silently undoes the funnel success',
        );
        // And nothing surfaced while the judge was hung or after the kill:
        // no structured pass receipt (ok:false judge failures, ok:true
        // hide-fallback — silence either way).
        expect(
          hooks.passes.where(
            (p) => p.fallback?.startsWith('structured') ?? false,
          ),
          isEmpty,
          reason: 'a ladder that lost the race must not report',
        );
        expect(hooks.doneCount, 1, reason: 'the host bracket closes once');
      },
    );
  });

  group('AC2 — the checkpoint ladder stops before the append', () {
    test('a kill between summarize success and appendCompactCheckpoint '
        'skips the append', () async {
      final (session, state) = await pairSession(3);
      final hooks = _Hooks();
      final summarizeStarted = Completer<void>();
      final source = CancelTokenSource();

      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: _deadJudge,
        summarize: (request) async {
          summarizeStarted.complete();
          // Holds the fold in flight until the test lands the kill — the
          // summarize then returns SUCCESS after the verdict.
          await request.cancelToken?.onCancel;
          return SummarizationResult.success('kept checkpoint summary');
        },
        checkpointPrompt: 'P',
        hooks: hooks,
        // No hideable entries: the hide ladder breaks at once and the
        // checkpoint ladder is the writer under test.
        protectLastN: 99,
        budgetSource: source,
        attemptBudget: const Duration(seconds: 30),
      );

      final run = compactor.run();
      await summarizeStarted.future;
      // The factory's kill: cancelBudget is the ONE caller (issue #515).
      compactor.cancelBudget(
        TimeoutException(
          'structured compaction exceeded the 2s total budget',
          const Duration(seconds: 2),
        ),
      );

      expect(
        run,
        completion(isFalse),
        reason: 'a killed run surfaces abandoned, never success',
      );
      final records = await session.getEntries();
      expect(
        records.whereType<CompactCheckpointRecord>(),
        isEmpty,
        reason: 'the append after the verdict must be skipped',
      );
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint'),
        isEmpty,
        reason: 'no checkpoint receipt may follow the verdict',
      );
    });
  });

  group('AC3 — escalation stops after a mid-append verdict', () {
    test(
      'a kill inside the escalation append skips refresh and receipt',
      () async {
        final gate = FlakySessionFs(fs);
        repo = JsonlSessionRepo(fs: gate, sessionsRoot: '/sessions');
        final (session, state) = await pairSession(6);
        final hooks = _Hooks();
        final source = CancelTokenSource();
        var summaries = 0;
        var checkpointAppends = 0;
        late StructuredCompactor compactor;

        // Let the dead-judge deterministic fallback settle under the trigger.
        // On the escalation's append, emulate the factory verdict + local trim
        // while the write is in flight; the write itself still completes.
        gate.beforeAppend = (path, content) async {
          if (!content.contains('compact_checkpoint')) return;
          checkpointAppends++;
          state.messages = [
            UserMessage.text('$localTrimMarkerPrefix\nolder turns omitted'),
            _assistant('authoritative trimmed tail'),
          ];
          compactor.cancelBudget(
            TimeoutException(
              'structured compaction exceeded the 2s total budget',
              const Duration(seconds: 2),
            ),
          );
        };
        compactor = StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          judge: (ledger, [cancelToken]) async => 'not json',
          summarize: (request) async {
            summaries++;
            return SummarizationResult.success('checkpoint summary $summaries');
          },
          checkpointPrompt: 'P',
          hooks: hooks,
          budgetSource: source,
          attemptBudget: const Duration(seconds: 30),
        );

        await compactor.run();
        await _pump();

        expect(summaries, 1, reason: 'only the escalation summarizes');
        expect(checkpointAppends, 1, reason: 'the in-flight append completed');
        expect(
          (await session.getEntries()).whereType<CompactCheckpointRecord>(),
          hasLength(1),
          reason: 'written-but-unprojected is the race under test',
        );
        expect(state.messages, hasLength(2));
        expect(
          _isLocalTrimMarker(state.messages.first),
          isTrue,
          reason: 'no post-verdict refresh may discard the local trim marker',
        );
        expect(
          hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
          isEmpty,
          reason: 'no success/failure escalation receipt after the verdict',
        );
      },
    );
  });

  group('AC4 — grep-guard: every pass ladder checks the terminal gate', () {
    // The ladders' guards are the fix's load-bearing lines; a refactor
    // that drops one silently reopens the two-writer hole. Source-coupled
    // by design (same convention as the cli source-guard tests).
    test('each ladder body checks the terminal write gate', () {
      final src = io.File(
        'lib/src/compaction/structured/engine.dart',
      ).readAsStringSync();

      String body(String declaration) {
        final start = src.indexOf(declaration);
        expect(
          start,
          greaterThanOrEqualTo(0),
          reason: 'ladder `$declaration` vanished from the engine',
        );
        final nextMember = RegExp(
          r'\n  (///|Future<|void |bool |int |String |List<|Set<|Map<|final )',
        ).firstMatch(src.substring(start + declaration.length));
        final end = start + declaration.length + (nextMember?.start ?? 0);
        return src.substring(start, end);
      }

      const ladders = <String, String>{
        'Future<void> _runLruRehidePasses(int trigger) async {':
            '_runLruRehidePasses',
        'Future<bool> _runHidePasses(int trigger) async {': '_runHidePasses',
        'Future<bool> _runCheckpointPasses(int trigger) async {':
            '_runCheckpointPasses',
        'Future<bool> _deterministicHide(int trigger) async {':
            '_deterministicHide',
      };
      ladders.forEach((declaration, name) {
        expect(
          body(declaration),
          contains('_ladderTerminated'),
          reason:
              '$name lost its terminal write gate (#2258) — a ladder '
              'without the guard keeps writing after the factory verdict',
        );
      });
      // The deterministic hide's legacy guard was token-only; the gate
      // must have REPLACED it, not joined it.
      expect(
        body('Future<bool> _deterministicHide(int trigger) async {'),
        isNot(contains('cancelToken?.isCancelled')),
        reason:
            'the budget kill is not a user abort — the old token-only '
            'guard cannot see it',
      );
      // The escalation keeps its gate (the one guard, unified).
      expect(
        body(
          'Future<bool> _runCheckpointEscalationPass('
          'int trigger, int margin) async {',
        ),
        contains('_ladderTerminated'),
      );
    });
  });
}
