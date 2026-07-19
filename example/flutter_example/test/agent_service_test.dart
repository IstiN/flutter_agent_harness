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

/// First call fails the way a provider 400/403 does — ONE terminal
/// [ErrorEvent], never a throw (the adapters' errors-as-events contract) —
/// and every later call answers with [thenText].
StreamFunction _providerErrorThen(String errorMessage, String thenText) {
  var callCount = 0;
  return (model, context, {cancelToken}) {
    callCount++;
    final stream = AssistantMessageEventStream();
    if (callCount == 1) {
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
      stream.push(ErrorEvent(reason: StopReason.error, error: message));
    } else {
      final message = AssistantMessage(
        content: [TextContent(text: thenText)],
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

/// A completed turn with no content at all — small on-device models do
/// this occasionally.
StreamFunction _emptyResponse() {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: const [],
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

    test('a provider error settles the run once: banner shown, send '
        're-enabled, the next message works', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(
          _providerErrorThen('400: bad request', 'recovered'),
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('boom');
      await service.waitForIdle();

      // Exactly one failed assistant turn (no duplicated failure events),
      // the banner carries the provider's message, and the run state has
      // settled so the composer is unblocked.
      expect(
        service.messages.where((m) => m.role == 'assistant'),
        hasLength(1),
      );
      expect(service.error, contains('400: bad request'));
      expect(service.isStreaming, isFalse);

      await service.sendText('again');
      await service.waitForIdle();
      expect(service.messages.last.role, 'assistant');
      expect(service.messages.last.content, 'recovered');
    });

    test('a prompt refused because a run is active lands in the banner, '
        'not the console', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      final first = service.sendText('one');
      // The second send hits Agent.prompt's synchronous "already
      // processing" refusal. The composer calls send unawaited, so a
      // synchronous escape would surface as an unhandled async error (the
      // "Uncaught Error" storm); it must become the error banner instead.
      await service.sendText('two');
      expect(service.error, contains('already processing'));

      await first;
      await service.waitForIdle();
      // The first run completed undisturbed.
      expect(service.isStreaming, isFalse);
      expect(
        service.messages.where((m) => m.role == 'assistant'),
        hasLength(1),
      );
    });

    test('a failing session append neither duplicates failure events nor '
        'blocks the UI', () async {
      final env = _FailingSessionAppendEnv(MemoryExecutionEnv());
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('hello back')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('hello');
      await service.waitForIdle();

      // The run itself succeeded; persistence is best effort. A throwing
      // session append must not re-enter the agent's failure path (that
      // duplicated the failure events and escaped the run as an unhandled
      // error).
      expect(
        service.messages.where((m) => m.role == 'assistant'),
        hasLength(1),
      );
      expect(service.messages.last.content, 'hello back');
      expect(service.error, isNull);
      expect(service.isStreaming, isFalse);
    });

    test('a completed turn with no text shows the empty-response '
        'placeholder', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_emptyResponse()),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('hi');
      await service.waitForIdle();

      // A blank bubble looks like a UI bug; the placeholder marks the turn.
      expect(service.messages.last.role, 'assistant');
      expect(service.messages.last.content, emptyResponsePlaceholder);
      expect(service.error, isNull);
    });

    test('a failed turn shows the error, never the empty-response '
        'placeholder', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_errorStream('provider exploded')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('boom');
      await service.waitForIdle();

      expect(service.messages.last.content, isNot(emptyResponsePlaceholder));
      expect(service.error, contains('provider exploded'));
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
      // This test exercises message surfacing, not approval: run unattended.
      service.approval.mode = ApprovalMode.yolo;
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
      // This test exercises secret redaction, not approval: run unattended.
      service.approval.mode = ApprovalMode.yolo;
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

    test(
      'sendAttachments never inlines SVG, even for hosted providers',
      () async {
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
              path: 'uploads/icon.svg',
              bytes: Uint8List.fromList('<svg/>'.codeUnits),
              mimeType: 'image/svg+xml',
            ),
            (
              path: 'uploads/pic.png',
              bytes: Uint8List.fromList([1, 2, 3]),
              mimeType: 'image/png',
            ),
          ],
        );
        await service.waitForIdle();

        final userMessage = captured!.messages.whereType<UserMessage>().last;
        final blocks = userMessage.content as List<ContentBlock>;
        final images = blocks.whereType<ImageContent>().toList();
        // Only the decodable raster image rides inline; the SVG is a path
        // reference in the text.
        expect(images, hasLength(1));
        expect(images.single.mimeType, 'image/png');
        final text = blocks.whereType<TextContent>().single.text;
        expect(text, contains('[attached file: uploads/icon.svg'));
        expect(text, contains('[attached file: uploads/pic.png'));
        // The UI thumbnail comes from the PNG, never from the SVG bytes.
        expect(service.messages[0].imageBytes, [1, 2, 3]);
      },
    );

    test(
      'discardStagedAttachment removes files inside uploads/ only',
      () async {
        final env = MemoryExecutionEnv();
        final service = AgentService(
          agent: _createAgent(_singleTextResponse('ok')),
          env: env,
          sessionsRoot: '/sessions',
        );

        final staged = await service.stageAttachment(
          name: 'scratch.txt',
          bytes: Uint8List.fromList([1]),
        );
        await env.writeFile('keep.txt', 'stay');

        await service.discardStagedAttachment(staged);
        await service.discardStagedAttachment('keep.txt');

        expect((await env.exists(staged)).getOrThrow(), isFalse);
        // Paths outside uploads/ are never touched.
        expect((await env.exists('keep.txt')).getOrThrow(), isTrue);
      },
    );

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
      expect(prompt, contains('You are Fa'));
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

/// An [ExecutionEnv] delegating everything to an inner instance except
/// [appendFile] under the sessions root, which fails — simulating a broken
/// session store (disk full, quota exceeded) so the run-state tests can
/// prove a persistence failure never cascades into the agent's failure
/// path.
final class _FailingSessionAppendEnv implements ExecutionEnv {
  _FailingSessionAppendEnv(this._inner);

  final ExecutionEnv _inner;

  @override
  String get cwd => _inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _inner.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    if (path.contains('sessions')) {
      return Future.value(
        Err(
          FileError(
            FileErrorCode.unknown,
            'simulated session-store failure',
            path: path,
          ),
        ),
      );
    }
    return _inner.appendFile(path, content);
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _inner.exec(command, options: options);
}
