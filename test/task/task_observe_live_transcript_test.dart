@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/task/subagent_tools.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

/// gh-1948: `task_observe` on a live background subagent died with an
/// uncaught `SessionException: Failed to read session
/// `<parentSessionId>/<agentName>`: No such file or directory`. The handle's
/// `sessionId` is that synthetic placeholder until the first transcript
/// flush attaches the real JSONL path — a RUNNING child has not flushed
/// yet. The tool must resolve the real file from the sessions tree, and
/// degrade to a structured error when the transcript is genuinely
/// unavailable — never an uncaught exception.
void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;
  late SubagentManager mgr;
  late SessionMetadata parentMeta;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    mgr = SubagentManager(parentSessionId: 'parent-1');
    final parent = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    parentMeta = await parent.getMetadata();
  });

  Future<Session> createChildTranscript(
    String childId, {
    required List<String> messages,
  }) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': childId,
          'parent': parentMeta.id,
          'model': 'm',
        },
      ),
    );
    for (final text in messages) {
      await session.appendMessage(UserMessage.text(text));
    }
    return session;
  }

  Future<String> observeText({
    required Map<String, dynamic> args,
    ChildMessageReader? readMessages,
  }) async {
    final tools = subagentMonitoringTools(
      manager: mgr,
      readMessages: readMessages ?? jsonlChildMessageReader(env),
      resolveSessionPath: (childId) => resolveChildSessionPath(
        repo: repo,
        parent: parentMeta,
        childId: childId,
      ),
    );
    final tool = tools.firstWhere((t) => t.name == 'task_observe');
    final result = await tool.execute(args, null, null);
    return result.content
        .whereType<TextContent>()
        .map((b) => b.text)
        .join('\n');
  }

  test('resolves the real transcript for a RUNNING child (placeholder '
      'handle) and heals the handle path', () async {
    await mgr.register(id: 'a1', name: 'worker', agentType: 'task', task: 'x');
    await mgr.update('a1', status: SubagentStatus.running);
    final session = await createChildTranscript(
      'a1',
      messages: ['turn one', 'turn two'],
    );
    final realPath = (await session.getMetadata()).path;
    expect(mgr['a1']!.sessionId, 'parent-1/a1', reason: 'placeholder shape');

    final text = await observeText(args: {'id': 'a1', 'tail': 10});

    expect(text, contains('turn one'));
    expect(text, contains('turn two'));
    // The resolved path is healed onto the handle so later observes,
    // task_status and task_send skip the scan.
    expect(mgr['a1']!.sessionId, realPath);
  });

  test('no transcript yet → clean structured message, never a throw', () async {
    await mgr.register(id: 'a1', name: 'worker', agentType: 'task', task: 'x');
    await mgr.update('a1', status: SubagentStatus.running);

    final text = await observeText(args: {'id': 'a1'});

    expect(text, contains('no transcript'));
    expect(text, contains('a1'));
    expect(text, contains('running'));
  });

  test('unreadable transcript degrades to a structured error', () async {
    await mgr.register(id: 'a1', name: 'worker', agentType: 'task', task: 'x');
    await mgr.update('a1', status: SubagentStatus.running);
    await createChildTranscript('a1', messages: ['on disk']);
    final text = await observeText(
      args: {'id': 'a1'},
      readMessages: (_, {tail = 10}) =>
          throw const SessionException('file went away'),
    );

    expect(text, contains('transcript unavailable'));
    expect(text, contains('file went away'));
  });

  test('a handle with the REAL attached path observes directly — the '
      'resolver is not consulted', () async {
    await mgr.register(id: 'a1', name: 'worker', agentType: 'task', task: 'x');
    final session = await createChildTranscript('a1', messages: ['attached']);
    await mgr.attachSession('a1', (await session.getMetadata()).path);

    var resolverCalls = 0;
    final tools = subagentMonitoringTools(
      manager: mgr,
      readMessages: jsonlChildMessageReader(env),
      resolveSessionPath: (childId) async {
        resolverCalls++;
        return null;
      },
    );
    final tool = tools.firstWhere((t) => t.name == 'task_observe');
    final result = await tool.execute({'id': 'a1'}, null, null);
    final text = result.content
        .whereType<TextContent>()
        .map((b) => b.text)
        .join('\n');

    expect(text, contains('attached'));
    expect(resolverCalls, 0);
  });

  test('tail still bounds the returned window after resolution', () async {
    await mgr.register(id: 'a1', name: 'worker', agentType: 'task', task: 'x');
    await createChildTranscript('a1', messages: ['m1', 'm2', 'm3', 'm4']);

    final text = await observeText(args: {'id': 'a1', 'tail': 2});

    expect(text, contains('m4'));
    expect(text, contains('m3'));
    expect(text, isNot(contains('m1')));
  });
}
