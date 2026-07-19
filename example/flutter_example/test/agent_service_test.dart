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

    test('reconfigure swaps the backend and keeps the transcript', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      await service.sendText('hi');
      await service.waitForIdle();
      expect(service.messages, hasLength(2));

      await service.reconfigure(
        AgentConfig(
          providerKind: 'anthropic',
          modelId: 'claude-test',
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'sk-test',
        ),
      );

      expect(service.providerKind, 'anthropic');
      expect(service.modelId, 'claude-test');
      // The visible transcript survives the switch.
      expect(service.messages, hasLength(2));
      expect(service.messages[0].content, 'hi');
    });

    test('loadSession restores a persisted session into the chat', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('hello back')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      await service.sendText('first');
      await service.waitForIdle();
      final stored = (await service.listSessions()).single;

      await service.reset();
      expect(service.messages, isEmpty);
      expect((await service.listSessions()), hasLength(2));

      await service.loadSession(stored);

      expect(service.currentSessionId, stored.id);
      expect(service.messages, hasLength(2));
      expect(service.messages[0].role, 'user');
      expect(service.messages[0].content, 'first');
      expect(service.messages[1].role, 'assistant');
      expect(service.messages[1].content, 'hello back');
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

    test('stageAttachment writes into uploads/ and returns the env-relative '
        'path', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );

      final path = await service.stageAttachment(
        name: 'report.pdf',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      expect(path, 'uploads/report.pdf');
      expect((await env.readBinaryFile('uploads/report.pdf')).getOrThrow(), [
        1,
        2,
        3,
      ]);
    });

    test('stageAttachment de-duplicates the file name on collision', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );

      final first = await service.stageAttachment(
        name: 'report.pdf',
        bytes: Uint8List.fromList([1]),
      );
      final second = await service.stageAttachment(
        name: 'report.pdf',
        bytes: Uint8List.fromList([2]),
      );
      final third = await service.stageAttachment(
        name: 'report.pdf',
        bytes: Uint8List.fromList([3]),
      );

      expect(first, 'uploads/report.pdf');
      expect(second, 'uploads/report-1.pdf');
      expect(third, 'uploads/report-2.pdf');
      // Nothing was overwritten: each copy kept its own content.
      expect((await env.readBinaryFile('uploads/report.pdf')).getOrThrow(), [
        1,
      ]);
      expect((await env.readBinaryFile('uploads/report-1.pdf')).getOrThrow(), [
        2,
      ]);
    });

    test('stageAttachment flattens browser-supplied subdirectories', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );

      final path = await service.stageAttachment(
        name: 'photos/2026/cat.jpg',
        bytes: Uint8List.fromList([1]),
      );

      expect(path, 'uploads/cat.jpg');
    });

    test('stageAttachment rejects names with nothing usable left', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );

      await expectLater(
        service.stageAttachment(name: '../../..', bytes: Uint8List(0)),
        throwsStateError,
      );
    });

    test(
      'sendAttachments references the staged paths before the typed text',
      () async {
        final env = MemoryExecutionEnv();
        final service = AgentService(
          agent: _createAgent(_singleTextResponse('ok')),
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        await service.sendAttachments(
          attachments: [
            (
              path: 'uploads/notes.txt',
              bytes: Uint8List.fromList('hi'.codeUnits),
              mimeType: 'application/octet-stream',
            ),
          ],
          text: 'summarize it',
        );
        await service.waitForIdle();

        expect(service.messages[0].role, 'user');
        expect(
          service.messages[0].content,
          '[attached file: uploads/notes.txt — read it with your tools]\n'
          'summarize it',
        );
        expect(service.messages[0].imageBytes, isNull);
      },
    );

    test('sendAttachments inlines images for hosted providers', () async {
      Context? captured;
      AssistantMessageEventStream capturing(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        captured = context;
        return _singleTextResponse('ok')(
          model,
          context,
          cancelToken: cancelToken,
        );
      }

      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(capturing),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      expect(service.inlinesImageAttachments, isTrue);

      await service.sendAttachments(
        attachments: [
          (
            path: 'uploads/pic.png',
            bytes: Uint8List.fromList([1, 2, 3]),
            mimeType: 'image/png',
          ),
        ],
      );
      await service.waitForIdle();

      expect(service.messages[0].imageBytes, isNotNull);
      final userMessage = captured!.messages.whereType<UserMessage>().last;
      final blocks = userMessage.content as List<ContentBlock>;
      final images = blocks.whereType<ImageContent>().toList();
      expect(images, hasLength(1));
      expect(images.single.mimeType, 'image/png');
      expect(
        blocks.whereType<TextContent>().single.text,
        contains('[attached file: uploads/pic.png'),
      );
    });

    test('sendAttachments sends paths only to on-device providers', () async {
      Context? captured;
      AssistantMessageEventStream capturing(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        captured = context;
        return _singleTextResponse('ok')(
          model,
          context,
          cancelToken: cancelToken,
        );
      }

      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: Agent(
          model: Model(
            id: 'on-device-model',
            api: 'webllm',
            provider: 'webllm',
            baseUrl: '',
            contextWindow: 4096,
            maxTokens: 1024,
          ),
          systemPrompt: 'You are fah.',
          streamFunction: capturing,
          toolRegistry: ToolRegistry(const []),
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      expect(service.inlinesImageAttachments, isFalse);

      await service.sendAttachments(
        attachments: [
          (
            path: 'uploads/pic.png',
            bytes: Uint8List.fromList([1, 2, 3]),
            mimeType: 'image/png',
          ),
        ],
      );
      await service.waitForIdle();

      // Text-only on-device backends get the path, never ImageContent.
      expect(service.messages[0].imageBytes, isNull);
      expect(
        service.messages[0].content,
        contains('[attached file: uploads/pic.png'),
      );
      final userMessage = captured!.messages.whereType<UserMessage>().last;
      // Text-only backends go through prompt(): the user message is plain
      // text, so no ImageContent block can ride along.
      expect(userMessage.content, isA<String>());
    });

    test('deleteSession removes a persisted non-active session', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      await service.sendText('first');
      await service.waitForIdle();
      final stored = (await service.listSessions()).single;

      await service.reset();
      expect((await service.listSessions()), hasLength(2));

      await service.deleteSession(stored);

      final remaining = await service.listSessions();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, isNot(stored.id));
      expect(service.currentSessionId, isNot(stored.id));
    });

    test('deleteSession on the active session starts a fresh one', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();
      await service.sendText('hi');
      await service.waitForIdle();
      final active = (await service.listSessions()).single;
      expect(service.currentSessionId, active.id);
      expect(service.messages, hasLength(2));

      await service.deleteSession(active);

      expect(service.messages, isEmpty);
      expect(service.currentSessionId, isNot(active.id));
      // The fresh session replaces the deleted one on disk.
      final remaining = await service.listSessions();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, service.currentSessionId);
    });
  });

  group('system prompt assembly', () {
    AgentConfig config({String? systemPrompt}) => AgentConfig(
      providerKind: 'openai-completions',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: 'sk-test',
      systemPrompt: systemPrompt,
    );

    test('substitutes the registry command section for the host platform', () {
      // Host tests run through the io env factory (not web, not mobile), so
      // the advertised platform is desktop.
      final prompt = AgentService.effectiveSystemPromptForTest(config(), null);
      expect(prompt, isNot(contains('{{commands}}')));
      expect(prompt, contains('host machine'));
      // The rest of the sandbox prompt survives intact.
      expect(prompt, contains('File tools'));
      expect(prompt, contains('You are fah'));
    });

    test('secret names suffix still appends after the command section', () {
      // Values below the redactor's 8-char minimum are ignored.
      final redactor = SecretRedactor.fromSecrets(const {
        'MY_TOKEN': 'supersecretvalue',
      });
      final prompt = AgentService.effectiveSystemPromptForTest(
        config(),
        redactor,
      );
      expect(prompt, contains('Available secret env vars: MY_TOKEN'));
      expect(
        prompt.indexOf('host machine'),
        lessThan(prompt.indexOf('Available secret env vars')),
      );
    });

    test('a custom system prompt gets the placeholder substituted too', () {
      final prompt = AgentService.effectiveSystemPromptForTest(
        config(systemPrompt: 'Custom base.\n{{commands}}'),
        null,
      );
      expect(prompt, isNot(contains('{{commands}}')));
      expect(prompt, contains('Custom base.'));
      expect(prompt, contains('host machine'));
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
