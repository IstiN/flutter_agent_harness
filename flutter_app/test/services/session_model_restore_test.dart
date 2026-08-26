import 'package:fa/services/agent_service.dart';
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

Agent _createAgent(String modelId) {
  return Agent(
    model: Model(
      id: modelId,
      api: 'openai-completions',
      provider: 'openai-completions',
      baseUrl: 'https://api.test/v1',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    streamFunction: _singleTextResponse('ok'),
    toolRegistry: ToolRegistry(const []),
  );
}

/// `AgentService.loadSession` restores the session's OWN model: the last
/// `model_change` record at the leaf (every provider/model switch in the
/// CLI and the app appends one). The default chat model only applies to
/// NEW sessions.
void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  AgentService service(String modelId) {
    return AgentService(
      agent: _createAgent(modelId),
      env: env,
      sessionsRoot: '/sessions',
    );
  }

  test('loadSession restores the effective model from model_change', () async {
    // Seed a service + session, then simulate a model switch by appending
    // a model_change record directly (what /model & reconfigure do).
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.open(meta);
    await session.appendModelChange(
      provider: 'openai-completions',
      modelId: 'session-model-x',
    );

    // A FRESH service with a different default model opens the session —
    // it must adopt the session's model, not keep its default.
    final opener = service('other-default');
    await opener.initialize();
    await opener.loadSession(meta);
    expect(
      opener.modelId,
      'session-model-x',
      reason: 'the session model_change model wins over the default',
    );
  });

  test('a cross-kind provider keeps the configured model (no crash)', () async {
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.open(meta);
    await session.appendModelChange(provider: 'anthropic', modelId: 'claude-x');

    final opener = service('my-default');
    await opener.initialize();
    await opener.loadSession(meta);
    // The provider kind does not match the connection — keep the default.
    expect(opener.modelId, 'my-default');
  });

  test('a session without model_change keeps the model it ran with', () async {
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;

    final opener = service('plain-default');
    await opener.initialize();
    await opener.loadSession(meta);
    // No model_change record, but the assistant messages carry the model
    // they were produced with — the session's own model still wins over
    // the opener's default.
    expect(opener.modelId, 'default-model');
  });

  test(
    'external appends to the session file reload into the transcript',
    () async {
      // The scenario: a `fa` CLI runs the SAME session while the app has it
      // open — its appends must appear without reopening the session.
      final seed = service('default-model');
      await seed.initialize();
      await seed.sendText('hello');
      await seed.waitForIdle();
      final meta = (await seed.listSessions()).single;

      final opener = service('default-model');
      await opener.initialize();
      await opener.loadSession(meta);
      final before = opener.messages.length;
      var revised = -1;
      opener.externalSessionRevision.addListener(() => revised++);

      // Let the watcher's FIRST tick establish its byte baseline before
      // the external append (the CLI would write much later in real usage).
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      // The CLI appends to the same session file (its own repo handle, the
      // way a real fa process writes) — a user turn plus an answer.
      final cliRepo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final cliSession = await cliRepo.open(meta);
      await cliSession.appendMessage(UserMessage.text('from the cli'));
      await cliSession.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'cli answer')],
          api: 'openai-completions',
          provider: 'openai-completions',
          model: 'default-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        ),
      );

      // The watcher polls every 2s; give it a couple of rounds.
      for (var i = 0; i < 40 && revised < 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        revised,
        greaterThanOrEqualTo(0),
        reason: 'external append bumped the revision',
      );
      expect(opener.messages.length, greaterThan(before));
      expect(
        opener.messages.any((m) => m.content.contains('from the cli')),
        isTrue,
        reason: 'the CLI-written user turn is visible',
      );
    },
  );
}
