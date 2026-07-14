import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

StreamFunction _errorStream(String errorMessage) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.error,
      errorMessage: errorMessage,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.error, message: message));
    stream.end();
    return stream;
  };
}

Agent _createAgent(StreamFunction streamFunction) {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are fah.',
    streamFunction: streamFunction,
    toolRegistry: ToolRegistry([]),
  );
}

void main() {
  group('AgentService', () {
    test('sendText appends user and assistant messages', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('hello back')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('hello');
      await service.waitForIdle();

      expect(service.messages.length, 2);
      expect(service.messages[0].role, 'user');
      expect(service.messages[0].content, 'hello');
      expect(service.messages[1].role, 'assistant');
      expect(service.messages[1].content, 'hello back');
    });

    test('sendImage appends a user message with image bytes', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('nice image')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      final bytes = Uint8List.fromList([1, 2, 3]);
      await service.sendImage(
        bytes: bytes,
        mimeType: 'image/png',
        text: 'describe this',
      );
      await service.waitForIdle();

      expect(service.messages.length, 2);
      expect(service.messages[0].role, 'user');
      expect(service.messages[0].content, 'describe this');
      expect(service.messages[0].imageBytes, bytes);
      expect(service.messages[1].role, 'assistant');
    });

    test('error event surfaces error text', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_errorStream('something broke')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('boom');
      await service.waitForIdle();

      expect(service.error, contains('something broke'));
    });

    test('reset clears messages and starts a new session', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      await service.sendText('hi');
      await service.waitForIdle();
      expect(service.messages, isNotEmpty);

      await service.reset();

      expect(service.messages, isEmpty);
      expect(service.error, isNull);
    });
  });
}
