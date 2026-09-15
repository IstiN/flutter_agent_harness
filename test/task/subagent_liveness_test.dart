@TestOn('vm')
library;

/// Issue #383 — executor liveness: while a child runs, every completed
/// provider response stamps the handle's in-flight usage (`touch`), so the
/// parent's heartbeat digest sees live request/token counts and fresh
/// last-activity; a resumed child excludes its seeded prior transcript and
/// resets the stale snapshot to zero before its first response.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'parent-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  Usage usage = Usage.zero,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

Usage _usageOf(int input, int output) => Usage(
  input: input,
  output: output,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: input + output,
  cost: const UsageCost(),
);

/// A text turn whose final message carries the given usage.
List<AssistantMessageEvent> _textTurn(String text, Usage usage) {
  final partial = _assistant(
    content: [TextContent(text: text)],
    usage: usage,
  );
  return [
    StartEvent(partial: _assistant()),
    TextStartEvent(contentIndex: 0, partial: _assistant()),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A tool-call turn whose final message carries the given usage.
List<AssistantMessageEvent> _toolTurn(Usage usage) {
  final call = ToolCall(id: 'call-1', name: 'read', arguments: const {});
  final partial = _assistant(
    content: [call],
    usage: usage,
    stopReason: StopReason.toolUse,
  );
  return [
    StartEvent(partial: _assistant()),
    ToolCallStartEvent(contentIndex: 0, partial: _assistant()),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

AssistantMessageEventStream _streamOf(List<AssistantMessageEvent> events) {
  final stream = AssistantMessageEventStream();
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
  return stream;
}

/// Every run (fresh spawn, resume) starts with an ungated tool turn; its
/// follow-up call parks on the gate so the test can observe the child
/// mid-run. [rearm] arms a fresh gate between runs.
final class _GatedStream {
  int calls = 0;

  Completer<void> _gate = Completer<void>();

  /// The gate the CURRENT pending stream call is parked behind.
  Completer<void> get gate => _gate;

  /// Arms a fresh gate for the next run's follow-up call.
  void rearm() {
    _gate = Completer<void>();
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
    // Every run (fresh spawn, resume) starts with an ungated tool turn;
    // its follow-up call parks on the gate so the test can observe the
    // child mid-run.
    if (calls.isOdd) {
      return _streamOf(_toolTurn(_usageOf(10, 20)));
    }
    final stream = AssistantMessageEventStream();
    unawaited(() async {
      await gate.future;
      for (final event in _textTurn('final report', _usageOf(10, 20))) {
        stream.push(event);
      }
      stream.end();
    }());
    return stream;
  }
}

Future<void> _until(bool Function() test, [String message = 'never held']) =>
    Future.doWhile(() async {
      if (test()) return false;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return true;
    }).timeout(const Duration(seconds: 10), onTimeout: () => fail(message));

final _env = MemoryExecutionEnv(cwd: '/work');
final _repo = JsonlSessionRepo(fs: _env, sessionsRoot: '/sessions');
TaskExecutor _executor(SubagentManager manager, _GatedStream stream) =>
    TaskExecutor(
      childTools: [
        AgentTool(
          name: 'read',
          description: 'read tool',
          tier: ApprovalTier.read,
          execute: (arguments, cancelToken, onUpdate) async =>
              ToolExecutionResult.text('read result'),
        ),
      ],
      streamFunction: () => stream.call,
      model: () => _model,
      registry: TaskAgentRegistry(const []),
      semaphore: Semaphore(2),
      store: AgentOutputStore(),
      subagentManager: manager,
      childSessionFactory: (parentId, childId) => _repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {
            'agent': 'subagent',
            'id': childId,
            'parent': parentId,
            'model': _model.id,
          },
        ),
      ),
      childSessionOpener: jsonlChildSessionOpener(_env),
    );

void main() {
  group('executor liveness touch (issue #383)', () {
    test(
      'a running child stamps live usage on every completed response',
      () async {
        final stream = _GatedStream();
        final manager = SubagentManager(parentSessionId: 'p');
        final executor = _executor(manager, stream);

        final done = executor.runSpawn(
          item: const TaskItem(name: 'w', task: 'work'),
          index: 0,
          context: '',
        );

        await _until(() => manager['w'] != null, 'child never registered');
        final handle = manager['w']!;
        await _until(
          () => handle.status == SubagentStatus.running,
          'child never started running',
        );
        await _until(
          () => handle.liveRequests >= 1,
          'first response never touched the handle',
        );
        // Mid-run state: the tool turn's usage is already visible as the
        // in-flight snapshot; the child is still RUNNING (gated stream).
        expect(handle.liveRequests, 1);
        expect(handle.liveTokens, 30);
        expect(handle.status, SubagentStatus.running);

        stream.gate.complete();
        final result = await done;
        expect(result.status, TaskSpawnStatus.completed);
        // The final update wins: lifetime totals cover both responses.
        expect(handle.requests, 2);
        expect(handle.tokens, 60);
      },
    );

    test('a resumed child resets the stale snapshot and excludes the '
        'seeded prior transcript', () async {
      final stream = _GatedStream();
      final manager = SubagentManager(parentSessionId: 'p');
      final executor = _executor(manager, stream);

      // The first run must complete fully: release its gated second turn
      // up front (observation happens during the resume, not here).
      stream.gate.complete();
      final first = await executor.runSpawn(
        item: const TaskItem(name: 'w', task: 'work'),
        index: 0,
        context: '',
      );
      expect(first.status, TaskSpawnStatus.completed);
      final handle = manager['w']!;
      expect(handle.requests, 2);
      expect(handle.tokens, 60);

      stream.rearm();
      // Resume: the child reopens its transcript (seeded with the prior
      // messages). Mid-run, the live snapshot must be the RESUME run's
      // usage only — zeroed before the first response, then counting from
      // the seeded transcript's end. The run-1 touches are stale by now;
      // the resume's zero-touch + first response refresh them.
      final callsBeforeResume = stream.calls;
      final resumed = executor.resumeChild('w', 'continue now');
      await _until(
        () => stream.calls >= callsBeforeResume + 2,
        'resume never re-streamed',
      );
      expect(handle.liveRequests, 1);
      expect(handle.liveTokens, 30);
      expect(handle.status, SubagentStatus.running);

      stream.gate.complete();
      await resumed;
      // Lifetime totals: original run (2 requests, 60 tokens) + the
      // resume run's own usage (tool turn + text turn = 2 requests,
      // 60 tokens) — the seeded messages are not double-billed.
      expect(handle.requests, 4);
      expect(handle.tokens, 120);
    });
  });
}
