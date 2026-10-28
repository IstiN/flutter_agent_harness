@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

/// gh-1948: a RUNNING background child had no session file at all — the
/// transcript flushed only at completion/compaction — so `task_observe`
/// had nothing to resolve and crashed on the placeholder path. The
/// executor now flushes the transcript incrementally at every child turn
/// boundary, so the JSONL exists and grows while the child runs.

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _toolTurn(String toolName) {
  final call = ToolCall(id: 'call-1', name: toolName, arguments: const {});
  final partial = _assistant(content: [call], stopReason: StopReason.toolUse);
  return [
    StartEvent(partial: _assistant()),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

List<AssistantMessageEvent> _textTurn(String text) {
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: _assistant()),
    TextStartEvent(contentIndex: 0, partial: partial),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// Turn 1 replays a `read` tool call; turn 2 parks on a per-child gate
/// so the test can observe the RUNNING child mid-flight. Routes by
/// task-fragment containment (the child prompt embeds the task text).
class _GatedMultiTurnStream {
  final _gates = <String, Completer<void>>{};
  final _calls = <String, int>{};

  /// Registers a task fragment BEFORE the spawn; [openGate] releases the
  /// parked turn 2.
  void registerFragment(String fragment) {
    _gates[fragment] = Completer<void>();
    _calls[fragment] = 0;
  }

  void openGate(String fragment) => _gates[fragment]!.complete();

  /// Whether the child for [fragment] parked on its second turn.
  bool turn2Entered(String fragment) => (_calls[fragment] ?? 0) >= 2;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    var taskText = '';
    for (final message in context.messages.reversed) {
      if (message is UserMessage) {
        final content = message.content;
        taskText = content is String
            ? content
            : (content as List<ContentBlock>)
                  .whereType<TextContent>()
                  .map((b) => b.text)
                  .join('\n');
        break;
      }
    }
    final fragment = _gates.keys.firstWhere(taskText.contains);
    final stream = AssistantMessageEventStream();
    _calls[fragment] = _calls[fragment]! + 1;
    if (_calls[fragment] == 1) {
      for (final event in _toolTurn('read')) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
    unawaited(
      _gates[fragment]!.future.then((_) {
        for (final event in _textTurn('child done: $fragment')) {
          stream.push(event);
        }
        stream.end();
      }),
    );
    return stream;
  }
}

const _model = Model(
  id: 'm',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

TaskToolConfig _buildConfig({
  required SubagentManager manager,
  required MemoryExecutionEnv env,
  required JsonlSessionRepo repo,
  required _GatedMultiTurnStream childStream,
}) {
  return TaskToolConfig(
    childTools: [
      AgentTool(
        name: 'read',
        description: 'read tool',
        tier: ApprovalTier.read,
        execute: (arguments, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('read result'),
      ),
    ],
    streamFunction: () => childStream.call,
    model: () => _model,
    subagentManager: manager,
    childSessionFactory: (parentId, childId) => repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': childId,
          'parent': parentId,
          'model': 'm',
        },
      ),
    ),
  );
}

/// Waits (bounded) until [predicate]; spins the event loop, never sleeps
/// longer than a few ms per pass.
Future<void> _waitFor(
  bool Function() predicate, {
  String timeoutMessage = 'condition never became true',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail(timeoutMessage);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test('a running child flushes its transcript at the turn boundary', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final manager = SubagentManager(parentSessionId: 'parent-1');
    final childStream = _GatedMultiTurnStream()..registerFragment('job one');
    final config = _buildConfig(
      manager: manager,
      env: env,
      repo: repo,
      childStream: childStream,
    );
    final tool = taskTool(config: config);

    final spawn = tool.execute(
      {
        'context': 'ctx',
        'background': true,
        'tasks': [
          {'name': 'Slow', 'task': 'job one'},
        ],
      },
      null,
      null,
    );
    await _waitFor(
      () => childStream.turn2Entered('job one'),
      timeoutMessage: 'child never reached its second turn',
    );
    await _waitFor(
      () => manager['Slow']!.sessionId != 'parent-1/Slow',
      timeoutMessage: 'turn-boundary flush never attached the child session',
    );

    // The transcript exists while the child is STILL RUNNING and carries
    // the first turn's messages.
    expect(manager['Slow']!.status, SubagentStatus.running);
    final handle = manager['Slow']!;
    final messages = await jsonlChildMessageReader(env)(
      handle.sessionId,
      tail: 10,
    );
    expect(messages, isNotEmpty, reason: 'turn-1 transcript is on disk');

    childStream.openGate('job one');
    await spawn;
    await _waitFor(
      () => manager['Slow']!.status == SubagentStatus.completed,
      timeoutMessage: 'child never settled completed',
    );
  });

  test(
    'two running children flush independently (per-child isolation)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final manager = SubagentManager(parentSessionId: 'parent-1');
      final childStream = _GatedMultiTurnStream()
        ..registerFragment('job one')
        ..registerFragment('job two');
      final config = _buildConfig(
        manager: manager,
        env: env,
        repo: repo,
        childStream: childStream,
      );
      final tool = taskTool(config: config);

      final spawn = tool.execute(
        {
          'context': 'ctx',
          'background': true,
          'tasks': [
            {'name': 'One', 'task': 'job one'},
            {'name': 'Two', 'task': 'job two'},
          ],
        },
        null,
        null,
      );
      await _waitFor(
        () =>
            childStream.turn2Entered('job one') &&
            childStream.turn2Entered('job two'),
        timeoutMessage: 'children never reached their second turns',
      );
      await _waitFor(
        () =>
            manager['One']!.sessionId != 'parent-1/One' &&
            manager['Two']!.sessionId != 'parent-1/Two',
        timeoutMessage: 'turn-boundary flush never attached both sessions',
      );

      expect(manager['One']!.sessionId, isNot(manager['Two']!.sessionId));
      for (final id in ['One', 'Two']) {
        final messages = await jsonlChildMessageReader(env)(
          manager[id]!.sessionId,
          tail: 10,
        );
        expect(messages, isNotEmpty);
      }

      childStream.openGate('job one');
      childStream.openGate('job two');
      await spawn;
      await _waitFor(
        () =>
            manager['One']!.status == SubagentStatus.completed &&
            manager['Two']!.status == SubagentStatus.completed,
        timeoutMessage: 'children never settled completed',
      );
    },
  );
}
