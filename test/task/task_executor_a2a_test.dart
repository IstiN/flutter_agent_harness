@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_config.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_manager.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/task/agent_registry.dart';
import 'package:flutter_agent_harness/src/task/output_manager.dart';
import 'package:flutter_agent_harness/src/task/parallel.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/task/task_executor.dart';
import 'package:flutter_agent_harness/src/task/task_types.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'openai',
  provider: 'openai-completions',
  baseUrl: 'http://localhost:1',
  contextWindow: 128000,
  maxTokens: 4096,
);

AssistantMessageEventStream _noopStream(Model model, context, {cancelToken}) {
  final message = AssistantMessage(
    content: const [TextContent(text: 'ok')],
    api: 'openai',
    provider: 'openai-completions',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: message));
  stream.push(DoneEvent(reason: StopReason.stop, message: message));
  stream.end();
  return stream;
}

/// An A2aManager over a mock backend: card + send → working + get → completed
/// (with a text artifact).
A2aManager _mockA2aManager() {
  final backend = http_testing.MockClient((request) async {
    if (request.url.path.endsWith('/.well-known/agent.json')) {
      return http.Response(
        '{"name":"remote","url":"https://x.example.com"}',
        200,
      );
    }
    if (request.body.contains('"message/send"')) {
      return http.Response(
        '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
        '"status":{"state":"working"}}}',
        200,
      );
    }
    if (request.body.contains('"tasks/get"')) {
      return http.Response(
        '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
        '"status":{"state":"completed"},'
        '"artifacts":[{"parts":[{"type":"text","text":"remote answer"}]}]}}',
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return A2aManager(
    A2aConfig(
      servers: {
        'remote': const A2aServerConfig(
          name: 'remote',
          url: 'https://x.example.com',
        ),
      },
    ),
    clientFactory: (config) =>
        A2aClient(baseUrl: config.url, token: config.token, client: backend),
  );
}

TaskExecutor _executor({
  A2aManager? a2aManager,
  SubagentManager? subagentManager,
}) {
  return TaskExecutor(
    childTools: const [],
    streamFunction: _noopStream,
    model: _model,
    registry: TaskAgentRegistry(const []),
    semaphore: Semaphore(1),
    store: AgentOutputStore(),
    subagentManager: subagentManager,
    a2aManager: a2aManager,
  );
}

void main() {
  group('TaskExecutor a2a:<name> items', () {
    test('runs a remote item and returns the artifacts as output', () async {
      final executor = _executor(a2aManager: _mockA2aManager());
      final result = await executor.runSpawn(
        item: const TaskItem(task: 'do the remote thing', agent: 'a2a:remote'),
        index: 0,
        context: 'shared background',
      );
      expect(result.status, TaskSpawnStatus.completed);
      expect(result.output, contains('remote answer'));
      expect(result.agent, 'a2a:remote');
    });

    test('unknown a2a server is a per-item error, not a throw', () async {
      final executor = _executor(a2aManager: _mockA2aManager());
      final result = await executor.runSpawn(
        item: const TaskItem(task: 'x', agent: 'a2a:ghost'),
        index: 0,
        context: 'shared background',
      );
      expect(result.status, TaskSpawnStatus.failed);
      expect(result.error, contains('unknown a2a server'));
    });

    test('a2a item registers in the subagent manager as completed', () async {
      final subagents = SubagentManager(parentSessionId: 'p');
      final executor = _executor(
        a2aManager: _mockA2aManager(),
        subagentManager: subagents,
      );
      final result = await executor.runSpawn(
        item: const TaskItem(task: 'x', agent: 'a2a:remote', name: 'w1'),
        index: 0,
        context: 'shared background',
      );
      expect(result.status, TaskSpawnStatus.completed);
      final handle = subagents[result.id];
      expect(handle, isNotNull);
      expect(handle!.status, SubagentStatus.completed);
      expect(handle.agentType, 'a2a:remote');
    });

    test('null a2aManager still errors cleanly on a2a items', () async {
      final executor = _executor();
      final result = await executor.runSpawn(
        item: const TaskItem(task: 'x', agent: 'a2a:remote'),
        index: 0,
        context: 'shared background',
      );
      expect(result.status, TaskSpawnStatus.failed);
      expect(result.error, contains('a2a not configured'));
    });
  });
}
