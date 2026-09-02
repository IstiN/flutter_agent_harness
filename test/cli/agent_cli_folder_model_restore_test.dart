import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Per-folder model memory across session switches: the boot applies the
/// LAUNCH folder's saved triple, but a session opened via `--session` (or
/// the /sessions picker) can live in a DIFFERENT folder — its own saved
/// model must win there (user report: a z.ai session reopened as copilot).
void main() {
  late MemoryExecutionEnv env;
  final ios = <FakeCliIO>[];

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    ios.clear();
  });

  tearDown(() async {
    for (final io in ios) {
      await io.close();
    }
  });

  FakeCliIO freshIo() {
    final io = FakeCliIO();
    ios.add(io);
    return io;
  }

  AgentCli cliFactory({required String sessionName, String? modelId}) {
    return AgentCli(
      config: AgentCliConfig(
        model: Model(
          id: modelId ?? 'start-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        sessionName: sessionName,
      ),
      io: freshIo(),
      streamFunction: _singleTextResponse('ok'),
    );
  }

  test(
    'resuming a session applies that folder’s saved model triple',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      // Boot 1: create the session in /work on the launch default.
      final first = cliFactory(sessionName: 'resume-me');
      final firstIo = ios.single;
      final run1 = first.run();
      firstIo.sendLine('hi');
      // A message persists the session; an empty one is deleted on switch.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      firstIo.sendLine('/exit');
      await run1;

      // The folder saves a different provider/model (as a /model switch
      // would): the zai catalog kind keeps the test network-free.
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'zai',
        modelId: 'glm-5.3-flash',
        baseUrl: null,
      );

      // Boot 2: same session, fresh process — the saved triple must win.
      final second = cliFactory(
        sessionName: 'resume-me',
        modelId: 'other-model',
      );
      final secondIo = ios.last;
      final run2 = second.run();
      secondIo.sendLine('/exit');
      await run2;

      expect(second.agent.state.model.id, 'glm-5.3-flash');
      expect(second.providerKind, 'zai');
      expect(
        secondIo.out.toString(),
        contains('restored glm-5.3-flash (zai) from this folder'),
      );
    },
  );

  test(
    'an explicit launch pin disables the folder restore',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final first = cliFactory(sessionName: 'pinned');
      final run1 = first.run();
      ios.single.sendLine('hi');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ios.single.sendLine('/exit');
      await run1;

      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'zai',
        modelId: 'glm-5.3-flash',
        baseUrl: null,
      );

      final second = AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'pinned-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'pinned',
          // --provider/--model on the launch command line.
          folderModelStateApplies: false,
        ),
        io: freshIo(),
        streamFunction: _singleTextResponse('ok'),
      );
      final run2 = second.run();
      ios.last.sendLine('/exit');
      await run2;

      expect(second.agent.state.model.id, 'pinned-model');
    },
  );
}

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
