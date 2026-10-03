@TestOn('vm')
library;

/// Issue #862 IT-2 / AC5 (IT half): the luna death wiring replayed.
///
/// A parent tool pool that leaks the child-only `reply` tool into the
/// inherited surface (the luna session's wiring bug) used to kill every
/// child at spawn in 0.0s with `ConfigException: Duplicate tool name:
/// reply` (the hallucinated-fix death). With replace-and-note registration
/// the same wiring produces a LIVE child that runs and completes; the
/// duplicate registration is recorded as a warning, and the child-specific
/// injected `reply` wins.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

import '../support/scripted_stream_harness.dart';


AssistantMessageEventStream _immediate(List<AssistantMessageEvent> events) {
  final stream = AssistantMessageEventStream();
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
  return stream;
}

/// The exact luna wiring: the parent pool carries `reply` (it must not) in
/// addition to the monitoring tools every child inherits.
AgentTool _replyLeakTool() {
  return AgentTool(
    name: 'reply',
    description: 'reply (leaked from the parent surface)',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('leaked reply'),
  );
}

AgentTool _fakeTool(String name) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name result'),
  );
}

final class _FakeFabric implements MessagingRepository {
  @override
  Future<void> send(AgentMessage message) async {}

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<AgentMessage>> peek(String agentId) async => const [];

  @override
  Future<List<AgentMessage>> drain(String agentId) async => const [];

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

void main() {
  test('IT-2: a duplicate-reply registry spawn produces a LIVE child that '
      'completes (issue #862 AC5)', () async {
    final manager = SubagentManager(
      parentSessionId: 'sess',
      messaging: _FakeFabric(),
    )..mailboxPrefix = 'sess';
    final executor = TaskExecutor(
      childTools: [_replyLeakTool(), _fakeTool('read')],
      streamFunction: () => (model, context, {cancelToken}) {
        return _immediate(textTurn('child finished the work'));
      },
      model: () => testModel,
      registry: TaskAgentRegistry(const []),
      semaphore: Semaphore(2),
      store: AgentOutputStore(),
      subagentManager: manager,
    );

    final result = await executor.runSpawn(
      item: const TaskItem(name: 'scout', task: 'luna mini-app job'),
      index: 0,
      context: 'ctx',
    );

    // The child RAN (pre-fix: status failed, error 'Duplicate tool name:
    // reply', duration ~0.0s).
    expect(result.status, TaskSpawnStatus.completed);
    expect(result.error, isNull);
    expect(result.output, contains('child finished the work'));
    expect(result.requests, 1);

    // The duplicate registration degrades LOUDLY: the spawn result carries
    // the wiring warning (issue #862 review), and the child-specific
    // injected `reply` won. The registry-level note itself is unit covered
    // in tool_registry_test.dart.
    expect(result.output, contains('warning: duplicate tool registration'));
    expect(result.output, contains('reply'));
  });

  test('resume re-wires the leak loudly and keeps the stored output', () async {
    // Round-3 review: the resume-path warning must READ-MODIFY-WRITE the
    // output artifact — `put` replaces, and a clobbering resume would
    // erase the child's spawn-time output from `agent://<id>`.
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final manager = SubagentManager(
      parentSessionId: 'sess',
      messaging: _FakeFabric(),
    )..mailboxPrefix = 'sess';
    final store = AgentOutputStore();
    TaskExecutor buildExecutor() => TaskExecutor(
      childTools: [_replyLeakTool(), _fakeTool('read')],
      streamFunction: () => (model, context, {cancelToken}) {
        return _immediate(textTurn('child finished the work'));
      },
      model: () => testModel,
      registry: TaskAgentRegistry(const []),
      semaphore: Semaphore(2),
      store: store,
      subagentManager: manager,
      childSessionFactory: (parentId, childId) => repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {
            'agent': 'subagent',
            'id': childId,
            'parent': parentId,
            'model': testModel.id,
          },
        ),
      ),
      childSessionOpener: jsonlChildSessionOpener(env),
    );

    final executor = buildExecutor();
    final result = await executor.runSpawn(
      item: const TaskItem(name: 'scout', task: 'luna mini-app job'),
      index: 0,
      context: 'ctx',
    );
    expect(result.status, TaskSpawnStatus.completed);

    // The spawn stored the child's output with its warning.
    final afterSpawn = store.get(result.id);
    expect(afterSpawn, isNotNull);
    expect(afterSpawn, contains('child finished the work'));
    expect(afterSpawn, contains('warning: duplicate tool registration'));

    // A FRESH executor over the same manager — the process-restart shape
    // the round-1 thread called out. The resume re-fires the duplicate
    // registration; the stored output must survive it.
    await buildExecutor().resumeChild(result.id, 'continue now');

    final afterResume = store.get(result.id)!;
    expect(afterResume, contains('child finished the work'));
    // Append-not-replace: the spawn's warning AND the resume's warning are
    // both present (a clobbering write leaves exactly one).
    expect(
      'warning: duplicate tool registration'.allMatches(afterResume).length,
      2,
    );
  });
}
