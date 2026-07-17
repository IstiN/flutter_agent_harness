import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/memory_shell.dart';
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

StreamFunction _streamingTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final now = DateTime.now();
    AssistantMessage partial(int length) => AssistantMessage(
      content: [TextContent(text: text.substring(0, length))],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: now,
    );
    for (var i = 1; i <= text.length; i++) {
      stream.push(
        TextDeltaEvent(
          contentIndex: 0,
          delta: text[i - 1],
          partial: partial(i),
        ),
      );
    }
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: [TextContent(text: text)],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: now,
        ),
      ),
    );
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

StreamFunction _toolThenText(String toolOutput, String finalText) {
  var callCount = 0;
  return (model, context, {cancelToken}) {
    callCount++;
    final stream = AssistantMessageEventStream();
    if (callCount == 1) {
      final message = AssistantMessage(
        content: [
          ToolCall(id: 'tc-1', name: 'echo', arguments: const {'x': 'hi'}),
        ],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      );
      stream.push(DoneEvent(reason: StopReason.stop, message: message));
    } else {
      final message = AssistantMessage(
        content: [TextContent(text: finalText)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      );
      stream.push(DoneEvent(reason: StopReason.stop, message: message));
    }
    stream.end();
    return stream;
  };
}

Agent _createAgent(
  StreamFunction streamFunction, {
  List<AgentTool> tools = const [],
}) {
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
    toolRegistry: ToolRegistry(tools),
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

    test('tool calls and results are surfaced as distinct messages', () async {
      final env = MemoryExecutionEnv();
      final echoTool = AgentTool(
        name: 'echo',
        description: 'Echoes the input back.',
        parameters: const {
          'type': 'object',
          'properties': {
            'x': {'type': 'string'},
          },
          'required': ['x'],
        },
        execute: (arguments, cancelToken, onUpdate) async {
          return ToolExecutionResult.text('echo: ${arguments['x']}');
        },
      );
      final service = AgentService(
        agent: _createAgent(
          _toolThenText('echo: hi', 'done'),
          tools: [echoTool],
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('call echo');
      await service.waitForIdle();

      final roles = service.messages.map((m) => m.role).toList();
      expect(roles, contains('system'));
      expect(roles, contains('tool'));
      expect(roles, contains('assistant'));

      final toolMsg = service.messages.firstWhere((m) => m.role == 'tool');
      expect(toolMsg.toolName, 'echo');
      expect(toolMsg.content, contains('echo: hi'));
    });

    test('secrets expand inside the shell and are redacted from transcript '
        'and session files', () async {
      const secretValue = 'tok-test-9f8e7d6c5b';
      final shell = MemoryShell();
      final env = MemoryExecutionEnv(cwd: '/', shell: shell);
      shell.attach(env);
      final secrets = {'FAH_TOKEN': secretValue};
      final secureEnv = SecretsExecutionEnv(env, secrets);

      Context? secondTurnContext;
      var calls = 0;
      AssistantMessageEventStream bashThenText(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        final stream = AssistantMessageEventStream();
        if (calls == 1) {
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: AssistantMessage(
                content: [
                  ToolCall(
                    id: 'tc-1',
                    name: 'bash',
                    arguments: const {'command': r'echo $FAH_TOKEN'},
                  ),
                ],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage.zero,
                stopReason: StopReason.stop,
                timestamp: DateTime.now(),
              ),
            ),
          );
        } else {
          secondTurnContext = context;
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: AssistantMessage(
                content: [TextContent(text: 'done')],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage.zero,
                stopReason: StopReason.stop,
                timestamp: DateTime.now(),
              ),
            ),
          );
        }
        stream.end();
        return stream;
      }

      final service = AgentService(
        agent: _createAgent(bashThenText, tools: builtinTools(secureEnv)),
        env: secureEnv,
        sessionsRoot: '/sessions',
        redactor: SecretRedactor.fromSecrets(secrets),
      );
      await service.initialize();
      await service.sendText('echo the token');
      await service.waitForIdle();

      // (a) The tool output seen in the transcript is masked.
      final toolMessage = service.messages.firstWhere((m) => m.role == 'tool');
      expect(toolMessage.content, contains('***'));
      expect(toolMessage.content, isNot(contains(secretValue)));

      // (c) The mask proves the value materialized inside the shell
      // (i.e. $FAH_TOKEN expansion worked); the context handed to the
      // model on the next turn is masked as well.
      final contextText = secondTurnContext!.messages
          .whereType<ToolResultMessage>()
          .expand((m) => m.content)
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');
      expect(contextText, contains('***'));
      expect(contextText, isNot(contains(secretValue)));

      // (b) The raw value never lands in the serialized session JSONL.
      final sessionText = await _readAllFiles(env, '/sessions');
      expect(sessionText, isNot(contains(secretValue)));
      expect(sessionText, contains('***'));
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

    test('second user message produces a new assistant message '
        'instead of overwriting the previous one', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_streamingTextResponse('response')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('first');
      await service.waitForIdle();

      await service.sendText('second');
      await service.waitForIdle();

      expect(service.messages.length, 4);
      expect(service.messages[0].role, 'user');
      expect(service.messages[0].content, 'first');
      expect(service.messages[1].role, 'assistant');
      expect(service.messages[1].content, 'response');
      expect(service.messages[2].role, 'user');
      expect(service.messages[2].content, 'second');
      expect(service.messages[3].role, 'assistant');
      expect(service.messages[3].content, 'response');

      final assistantContents = service.messages
          .where((m) => m.role == 'assistant')
          .map((m) => m.content)
          .toList();
      expect(assistantContents, ['response', 'response']);
    });
  });
}

/// Concatenates the text of every file under [path] (recursive), used to
/// scan serialized sessions for leaked secret values.
Future<String> _readAllFiles(ExecutionEnv env, String path) async {
  final buffer = StringBuffer();
  final entries = await env.listDir(path);
  for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
    if (entry.kind == FileKind.directory) {
      buffer.write(await _readAllFiles(env, entry.path));
    } else {
      buffer.write((await env.readTextFile(entry.path)).valueOrNull ?? '');
    }
  }
  return buffer.toString();
}
