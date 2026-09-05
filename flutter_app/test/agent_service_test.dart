import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:fa/services/agent_service.dart';
import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/webllm/webllm_types.dart';
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

StreamFunction _hungResponse() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: partial.copyWith(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream; // stays open until aborted
  }

  return fn;
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
  String provider = 'test',
  int contextWindow = 100000,
  String systemPrompt = 'You are Fa.',
}) {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: provider,
      baseUrl: 'https://example.com',
      contextWindow: contextWindow,
      maxTokens: 4096,
    ),
    systemPrompt: systemPrompt,
    streamFunction: streamFunction,
    toolRegistry: ToolRegistry(tools),
  );
}

void main() {
  group('AgentService', () {
    test(
      'a pre-constructed agent keeps its custom system prompt on send',
      () async {
        final env = MemoryExecutionEnv();
        final agent = _createAgent(_singleTextResponse('ok'));
        agent.state.systemPrompt = 'custom prompt without a date';
        final service = AgentService(
          agent: agent,
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        await service.sendText('hello');
        await service.waitForIdle();

        // Runs re-compose the prompt only for config-built services; manual
        // agents (tests, embedders) are left untouched.
        expect(agent.state.systemPrompt, 'custom prompt without a date');
      },
    );

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

    test(
      'the model request summary persists before its assistant message',
      () async {
        final env = MemoryExecutionEnv();
        final service = AgentService(
          agent: _createAgent(_singleTextResponse('hello back')),
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        await service.sendText('hello');
        await service.waitForIdle();

        // The loop emits ModelRequestEvent before the provider call; the
        // service persists it as a context-omitted CustomRecord whose data
        // round-trips the request summary.
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        final metadata = (await repo.list()).single;
        final session = await repo.open(metadata);
        final entries = await session.getEntries();
        final summaries = entries.whereType<CustomRecord>().toList();
        expect(summaries, hasLength(1));
        expect(summaries.single.customType, 'model_request_summary');

        // Ordering: the summary sits on the chain before the assistant
        // message record it produced (the replay walk expects that).
        final summaryIndex = entries.indexOf(summaries.single);
        final assistantIndex = entries.indexWhere(
          (e) => e is MessageRecord && e.message is AssistantMessage,
        );
        expect(summaryIndex, lessThan(assistantIndex));

        // Replaying the persisted branch rebuilds the Request tab data.
        final builder = TrajectorySnapshotBuilder();
        for (final record in entries) {
          builder.append(record);
        }
        final assistant = builder
            .build()
            .records
            .whereType<TrajectoryAssistantRecord>()
            .single;
        expect(assistant.requestDetail, isNotNull);
        expect(assistant.requestDetail!.systemPromptChars, greaterThan(0));
      },
    );

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

    test('a second send while a run is active is queued as a steer and '
        'processed automatically at the next turn boundary', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      final first = service.sendText('one');
      // The second send arrives while the first run is still active. It must
      // be queued via Agent.steer() instead of throwing, shown as pending in
      // the UI, and auto-continued once the first run finishes.
      await service.sendText('two');
      expect(service.error, isNull);
      expect(service.pendingSteerTexts, contains('two'));

      await first;
      await service.waitForIdle();

      // Both runs completed; the queued message is no longer pending.
      expect(service.isStreaming, isFalse);
      expect(service.pendingSteerTexts, isEmpty);
      final userContents = service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList();
      expect(userContents, ['one', 'two']);
      // The harness may fold the queued steering into the in-flight turn, so
      // there is one assistant response that answers both user messages.
      expect(service.messages.where((m) => m.role == 'assistant'), isNotEmpty);
    });

    test('abort drains the steer queue into the transcript instead of '
        'dropping it', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      final first = service.sendText('one');
      await service.sendText('two');
      expect(service.pendingSteerTexts, contains('two'));

      service.abort();
      await first;
      await service.waitForIdle();

      // The queued message is no longer pending but is NOT lost: it lands
      // in the transcript as a user message (pi's abort behavior).
      expect(service.pendingSteerTexts, isEmpty);
      expect(
        service.messages.where((m) => m.role == 'user').map((m) => m.content),
        contains('two'),
      );

      // And the next prompt runs cleanly with it in context.
      await service.sendText('three');
      await service.waitForIdle();
      expect(service.messages.last.role, 'assistant');
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

    test('a run brackets itself in an extended background task', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fah/background'), (
            call,
          ) async {
            calls.add(call.method);
            return call.method == 'begin' ? 7 : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('fah/background'),
              null,
            ),
      );
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('done')),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('go');
      await service.waitForIdle();
      // Let the unawaited begin/end channel calls land.
      await Future<void>.delayed(Duration.zero);

      expect(calls, contains('begin'));
      expect(calls, contains('end'));
      expect(calls.indexOf('end'), greaterThan(calls.indexOf('begin')));
    });

    test(
      'a queued steer RUNS after abort (never dies in the transcript)',
      () async {
        final env = MemoryExecutionEnv();
        var call = 0;
        streams(Model model, dynamic context, {cancelToken}) {
          call++;
          if (call == 1) {
            return _hungResponse()(model, context, cancelToken: cancelToken);
          }
          return _singleTextResponse('follow-up answer')(
            model,
            context,
            cancelToken: cancelToken,
          );
        }

        final service = AgentService(
          agent: _createAgent(streams),
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        unawaited(service.sendText('first'));
        // Wait for the run to actually reach the model, then queue the steer
        // (waiting on isStreaming alone races the abort against the first
        // model call).
        for (var i = 0; i < 50 && call == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(call, 1);
        expect(service.isStreaming, isTrue);
        await service.sendText('follow-up');

        service.abort();
        // AgentEnd schedules the queued follow-up as its own run; pump until
        // it reached the model and settled.
        for (var i = 0; i < 100 && (call < 2 || service.isStreaming); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await service.waitForIdle();

        // The queued message got its OWN run — it never just died in the
        // transcript after the manual stop.
        expect(call, 2);
        expect(
          service.messages.any(
            (m) => m.role == 'user' && m.content == 'follow-up',
          ),
          isTrue,
        );
        expect(service.messages.last.content, 'follow-up answer');
        expect(service.messages.where((m) => m.isError), isEmpty);
      },
    );

    test('messages persist incrementally — a mid-run "crash" loses nothing '
        'that landed (no AgentEnd needed)', () async {
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(_hungResponse()),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      unawaited(service.sendText('crash me'));
      for (var i = 0; i < 100 && service.messages.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.messages.single.content, 'crash me');

      // The run is STILL in flight (hung provider stream, no AgentEnd),
      // yet the session file must already hold the user message — this is
      // what survives an actual app crash mid-run.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      final onDisk = await _readAllFiles(env, '/sessions');
      expect(onDisk, contains('crash me'));

      service.abort();
      await service.waitForIdle();
    });

    test(
      'a failed turn ALSO lands as an error tile in the transcript',
      () async {
        final env = MemoryExecutionEnv();
        final service = AgentService(
          agent: _createAgent(_errorStream('provider exploded')),
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        await service.sendText('boom');
        await service.waitForIdle();

        // Not just the banner field: an isError tool message the shared
        // renderer styles as an error tile (in the sheet too, which has no
        // banner — a dead key must never look like "no answer").
        final errors = service.messages.where((m) => m.isError).toList();
        expect(errors, hasLength(1));
        expect(errors.single.role, 'tool');
        expect(errors.single.toolName, 'error');
        expect(errors.single.content, contains('provider exploded'));
      },
    );

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

    test('one tool call surfaces exactly ONE tool message (no duplicate '
        'from the tool-result message event)', () async {
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
      service.approval.mode = ApprovalMode.yolo;
      await service.initialize();

      await service.sendText('call echo');
      await service.waitForIdle();

      // Regression: ToolExecutionEndEvent and the ToolResultMessage's
      // MessageEndEvent both fired per call and each appended a 'tool'
      // message — every tool tile rendered twice, and the duplicate lost
      // the isError flag.
      final toolMessages = service.messages
          .where((m) => m.role == 'tool')
          .toList();
      expect(toolMessages, hasLength(1));
      expect(toolMessages.single.toolName, 'echo');
      service.dispose();
    });

    test('a tool-only turn leaves no empty assistant bubble', () async {
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
        agent: _createAgent(_toolThenText('echo: hi', ''), tools: [echoTool]),
        env: env,
        sessionsRoot: '/sessions',
      );
      service.approval.mode = ApprovalMode.yolo;
      await service.initialize();

      await service.sendText('call echo');
      await service.waitForIdle();

      // Tool-only turns leave only the placeholder bubble (hidden by the chat
      // screen) plus the tool messages — no blank assistant bubble with real
      // content. A blank answer after the tool turn is retried ONCE by the
      // loop (degenerate-empty retry), so the transcript carries the tool
      // call plus BOTH blank attempts, each rendered as the placeholder.
      final assistantMessages = service.messages
          .where((m) => m.role == 'assistant')
          .toList();
      expect(assistantMessages, hasLength(3));
      expect(
        assistantMessages.where((m) => m.content == emptyResponsePlaceholder),
        hasLength(2),
      );
      expect(service.messages.where((m) => m.role == 'tool'), isNotEmpty);
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

    test(
      'bash tool executions carry FAH_ session env vars (no secrets)',
      () async {
        final shell = _RecordingShell();
        final service = await AgentService.create(
          config: AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'test-model',
            baseUrl: 'https://example.test',
            apiKey: 'test-key',
          ),
          env: MemoryExecutionEnv(cwd: '/', shell: shell),
          streamFunction: _singleTextResponse('ok'),
        );
        addTearDown(service.dispose);
        await service.initialize();
        // Materialise the session file so the env var carries a real JSONL path.
        await service.sendText('hello');
        await service.waitForIdle();

        final bash = service.toolsForTest.whereType<AgentTool>().singleWhere(
          (tool) => tool.name == 'bash',
        );
        await bash.execute(const {'command': 'echo hi'}, null, null);

        final envVars = shell.lastOptions!.env!;
        expect(envVars[sessionIdEnvVar], isNotEmpty);
        expect(envVars[sessionFileEnvVar], endsWith('.jsonl'));
        expect(envVars[providerEnvVar], 'openai-completions');
        expect(envVars[modelEnvVar], 'test-model');
        // Correlation data only — never the API key.
        for (final value in envVars.values) {
          expect(value, isNot(contains('test-key')));
        }
      },
    );

    test(
      'inbox messages to main are injected at the next turn (messaging fabric)',
      () async {
        final env = MemoryExecutionEnv(cwd: '/');
        final contexts = <Context>[];
        AssistantMessageEventStream recording(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          contexts.add(
            Context(
              systemPrompt: context.systemPrompt,
              messages: List.of(context.messages),
              tools: context.tools,
            ),
          );
          final stream = AssistantMessageEventStream();
          final message = AssistantMessage(
            content: [TextContent(text: 'ok')],
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
        }

        final service = await AgentService.create(
          config: AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'test-model',
            baseUrl: 'https://example.test',
            apiKey: 'test-key',
          ),
          env: env,
          streamFunction: recording,
        );
        addTearDown(service.dispose);
        await service.initialize();

        final manager = service.subagentManager!;
        // The session id namespaces this instance's mailboxes.
        expect(manager.mailboxPrefix, isNotEmpty);
        // A child (or another Fa instance) messages the main agent through
        // the file inbox colocated with the sessions.
        await manager.enqueueMessage(
          'main',
          SubagentMessage(
            fromId: 'a1',
            text: 'ping from child',
            sentAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
        expect(await manager.pendingInboxCount('main'), 1);

        await service.sendText('hello');
        await service.waitForIdle();

        final seen = contexts.last.messages
            .whereType<UserMessage>()
            .map((m) => m.content)
            .join('\n');
        expect(
          seen,
          contains('from ${manager.mailboxPrefix}/a1: ping from child'),
        );
        // The inbox was consumed.
        expect(await manager.pendingInboxCount('main'), 0);
      },
    );

    test(
      'mail arriving while idle wakes the agent into a turn (app)',
      () async {
        AgentService.enableInboxWatcher = true;
        addTearDown(() => AgentService.enableInboxWatcher = false);
        final env = MemoryExecutionEnv(cwd: '/');
        final contexts = <Context>[];
        AssistantMessageEventStream recording(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          contexts.add(
            Context(
              systemPrompt: context.systemPrompt,
              messages: List.of(context.messages),
              tools: context.tools,
            ),
          );
          final stream = AssistantMessageEventStream();
          final message = AssistantMessage(
            content: [TextContent(text: 'ok')],
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
        }

        final service = await AgentService.create(
          config: AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'test-model',
            baseUrl: 'https://example.test',
            apiKey: 'test-key',
          ),
          env: env,
          streamFunction: recording,
        );
        addTearDown(service.dispose);
        await service.initialize();

        final manager = service.subagentManager!;
        // The prompt now carries the own mailbox address.
        expect(service.systemPromptForTest, contains('## Agent messaging'));
        expect(
          service.systemPromptForTest,
          contains(manager.mailboxOf('main')),
        );

        // Mail arrives while the agent idles: the watcher (3s tick) starts
        // a run without any user input.
        await manager.enqueueMessage(
          'main',
          SubagentMessage(
            fromId: 'a1',
            text: 'wake up, app',
            sentAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
        for (var i = 0; i < 400 && contexts.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(contexts, isNotEmpty);
        final seen = contexts.first.messages
            .whereType<UserMessage>()
            .map((m) => m.content)
            .join('\n');
        expect(seen, contains('wake up, app'));
      },
    );

    test('durable memory facts join the composed system prompt', () async {
      final env = MemoryExecutionEnv(cwd: '/');
      // Seed a fact through the same store the service's controller reads
      // (project scope = <cwd>/.fah/memory).
      await MemoryController(
        env: env,
      ).add(text: 'the user prefers ADHD-style short answers');
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'test-model',
          baseUrl: 'https://example.test',
          apiKey: 'test-key',
        ),
        env: env,
        streamFunction: _singleTextResponse('ok'),
      );
      addTearDown(service.dispose);
      await service.initialize();

      // The memory section refreshes asynchronously after create.
      var prompt = '';
      for (var i = 0; i < 100; i++) {
        prompt = service.systemPromptForTest;
        if (prompt.contains('ADHD-style short answers')) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(prompt, contains('<memory>'));
      expect(prompt, contains('ADHD-style short answers'));
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
      // The new session is lazy; materialise it so it appears in the list.
      await service.sendText('second');
      await service.waitForIdle();
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
          systemPrompt: 'You are Fa.',
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
      // Materialise the new lazy session so both sessions appear on disk.
      await service.sendText('second');
      await service.waitForIdle();
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
      // The fresh session is lazy; materialise it to verify it replaces the
      // deleted one on disk.
      await service.sendText('fresh start');
      await service.waitForIdle();
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

    test('the prompt carries the current date and timezone', () {
      final prompt = AgentService.effectiveSystemPromptForTest(config(), null);
      expect(prompt, contains('Current date and time:'));
      expect(prompt, contains('local device time, UTC'));
      expect(prompt, contains('time-relative reasoning'));
      final year = DateTime.now().year.toString();
      expect(prompt, contains(year));
    });
  });

  group('auto-compaction', () {
    test('webllm configs scale settings to the window minus the system '
        'prompt and tool instructions', () async {
      final env = MemoryExecutionEnv();
      final tools = builtinTools(env);
      final service = AgentService(
        agent: _createAgent(
          _singleTextResponse('ok'),
          tools: tools,
          provider: webLlmProviderKind,
          contextWindow: 8192,
        ),
        env: env,
        sessionsRoot: '/sessions',
      );

      // The conversation window is the model window minus the system prompt
      // AND the prompt-tools instruction block the WebLLM stream function
      // appends — the engine counts all of it.
      final overhead = estimateTokens(
        UserMessage.text(
          'You are Fa.\n\n${promptToolInstructions(service.toolsForTest)}',
        ),
      );
      final expected = CompactionSettings.forWindow(8192 - overhead);
      final settings = service.compactionSettings;
      expect(settings.enabled, isTrue);
      expect(settings.reserveTokens, expected.reserveTokens);
      expect(settings.keepRecentTokens, expected.keepRecentTokens);
      // The overhead is real: sizing against the bare window would give the
      // quarter/half of 8192 instead.
      expect(overhead, greaterThan(1000));
      expect(settings.reserveTokens, lessThan(8192 ~/ 4));
    });

    test('hosted configs keep pi defaults (128k window)', () async {
      final service = AgentService(
        agent: _createAgent(_singleTextResponse('ok'), contextWindow: 128000),
        env: MemoryExecutionEnv(),
        sessionsRoot: '/sessions',
      );
      expect(service.compactionSettings.reserveTokens, 16384);
      expect(service.compactionSettings.keepRecentTokens, 20000);
    });

    test('over-window guard: the chat auto-compacts and continues the '
        'interrupted turn', () async {
      // Window 8192: reserve 2048 (trigger 6144), keep 2048. A tool call
      // returns ~8500 tokens of output mid-run → the loop's guard refuses
      // the second request. The service must then compact and CONTINUE
      // the turn on its own — once — instead of idling with an error.
      var streamCalls = 0;
      AssistantMessageEventStream hugeToolThenText(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        streamCalls++;
        final stream = AssistantMessageEventStream();
        if (streamCalls == 1) {
          stream.push(
            DoneEvent(
              reason: StopReason.toolUse,
              message: AssistantMessage(
                content: [
                  ToolCall(
                    id: 'tc-1',
                    name: 'echo',
                    arguments: const {'x': 'go'},
                  ),
                ],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage.zero,
                stopReason: StopReason.toolUse,
                timestamp: DateTime.now(),
              ),
            ),
          );
        } else {
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: AssistantMessage(
                content: [TextContent(text: 'continued')],
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

      final echoTool = AgentTool(
        name: 'echo',
        description: 'echo',
        parameters: const {
          'type': 'object',
          'properties': {
            'x': {'type': 'string'},
          },
          'required': ['x'],
        },
        execute: (arguments, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('y' * 34000),
      );
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(
          hugeToolThenText,
          contextWindow: 8192,
          systemPrompt: '',
          tools: [echoTool],
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      await service.sendText('go');
      await service.waitForIdle();

      // The turn continued to the final answer on its own.
      expect(service.messages.last.content, 'continued');
      expect(streamCalls, 2);
      expect(service.error, isNull);
      // The transcript was compacted: the huge tool result is gone.
      expect(
        service.messages.map((m) => m.content).join('\n'),
        isNot(contains('y' * 500)),
      );
      // Exactly one continuation: no trim→continue loop.
      expect(service.messages.where((m) => m.content == 'continued').length, 1);
    });

    test('compacts the transcript once it crosses the scaled threshold, and '
        'the chat keeps working', () async {
      // Window 512 (no on-device overhead here): reserve 128, keep 256,
      // trigger at 384 transcript tokens.
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _createAgent(
          _singleTextResponse('reply'),
          contextWindow: 512,
          systemPrompt: '',
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      await service.initialize();

      // Three 600-char turns: ~152, ~304, ~456 transcript tokens.
      await service.sendText('x' * 600);
      await service.waitForIdle();
      await service.sendText('y' * 600);
      await service.waitForIdle();
      expect(service.messages, hasLength(4));

      await service.sendText('z' * 600);
      await service.waitForIdle();

      // The first turn was summarized; the kept region starts at turn 2.
      expect(service.messages, hasLength(5));
      expect(
        service.messages.first.content,
        contains('compacted into the following summary'),
      );
      expect(service.messages.first.content, contains('reply'));
      expect(service.error, isNull);

      // A post-compaction turn runs normally against the rebuilt context.
      await service.sendText('next');
      await service.waitForIdle();
      expect(service.error, isNull);
      expect(service.messages.last.content, 'reply');
    });

    test(
      'does not compact while the whole transcript fits the kept region',
      () async {
        // Degenerate window 300: trigger at 172, but the kept region is 256 —
        // a ~200-token transcript crosses the trigger yet compaction could not
        // drop anything, so it must not run.
        final env = MemoryExecutionEnv();
        final service = AgentService(
          agent: _createAgent(
            _singleTextResponse('reply'),
            contextWindow: 300,
            systemPrompt: '',
          ),
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        await service.sendText('x' * 800);
        await service.waitForIdle();

        expect(service.messages, hasLength(2));
        expect(
          service.messages.first.content,
          isNot(contains('compacted into the following summary')),
        );
      },
    );

    test(
      'a failing summary call stays silent and never fakes a summary',
      () async {
        // Chat answers normally; the compaction summary call (recognizable by
        // its fixed system prompt) fails — best effort must not surface the
        // error or corrupt history with an invented summary.
        flakySummarizer(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          if (context.systemPrompt == summarizationSystemPrompt) {
            return _errorStream('summary backend down')(model, context);
          }
          return _singleTextResponse('reply')(model, context);
        }

        final env = MemoryExecutionEnv();
        final service = AgentService(
          agent: _createAgent(
            flakySummarizer,
            contextWindow: 512,
            systemPrompt: '',
          ),
          env: env,
          sessionsRoot: '/sessions',
        );
        await service.initialize();

        for (final filler in ['x' * 600, 'y' * 600, 'z' * 600]) {
          await service.sendText(filler);
          await service.waitForIdle();
        }

        expect(service.error, isNull);
        final rendered = service.messages.map((m) => m.content).join('\n');
        expect(
          rendered,
          isNot(contains('compacted into the following summary')),
        );
        // The emergency local trim (it fires for this over-window
        // transcript) is honest and in-memory only: the marker names the
        // outage, and the session file keeps every record — the next
        // replay restores the full history.
        if (service.messages.any(
          (m) => m.content.startsWith('[context trimmed'),
        )) {
          final transcript = await _readAllFiles(env, '/sessions');
          for (final filler in ['x' * 600, 'y' * 600, 'z' * 600]) {
            expect(transcript, contains(filler));
          }
        } else {
          expect(service.messages, hasLength(6));
        }
      },
    );
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

/// A [Shell] that records its last options and returns an empty success.
final class _RecordingShell implements Shell {
  ShellExecOptions? lastOptions;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    lastOptions = options;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}
