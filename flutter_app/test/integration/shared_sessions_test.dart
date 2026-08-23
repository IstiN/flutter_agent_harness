// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for the shared session store: sessions are scoped to
/// their workspace folder, but any Fa host (CLI or macOS app) sharing the same
/// [sessionsRoot] can see every session regardless of which host created it.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/project_mount_env.dart';
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

AgentService _fakeAgentService(
  ExecutionEnv env, {
  required String sessionsRoot,
}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: sessionsRoot,
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

void main() {
  test('repo.list returns sessions across all workspace folders', () async {
    final fs = MemoryExecutionEnv();
    const sessionsRoot = '/shared/sessions';
    final repo = JsonlSessionRepo(fs: fs, sessionsRoot: sessionsRoot);

    final alpha = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/host/ai.m',
        id: 'alpha-id',
        metadata: const {'agent': 'fa'},
      ),
    );
    await alpha.appendSessionName('alpha');

    final beta = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/host/other',
        id: 'beta-id',
        metadata: const {'agent': 'fa'},
      ),
    );
    await beta.appendSessionName('beta');

    final all = await repo.list();
    expect(all, hasLength(2));
    expect(all.map((m) => m.id), containsAll(<String>['alpha-id', 'beta-id']));
  });

  test('macOS app sees a CLI session created in the same workspace', () async {
    // Both hosts share the same underlying filesystem (in the real app this
    // is the shared App Group container; here we simulate it with one env).
    final sharedFs = MemoryExecutionEnv();
    const sessionsRoot = '/shared/sessions';
    const hostCwd = '/host/ai.m';

    // CLI creates a session with the real host cwd.
    final cliRepo = JsonlSessionRepo(fs: sharedFs, sessionsRoot: sessionsRoot);
    final cliSession = await cliRepo.create(
      JsonlSessionCreateOptions(
        cwd: hostCwd,
        id: 'cli-session',
        metadata: const {'agent': 'fa'},
      ),
    );
    await cliSession.appendSessionName('from-cli');

    // macOS app mounts the same host directory and lists sessions.
    final mountEnv = ProjectMountEnv(sharedFs)..mountedRoot = hostCwd;
    final service = _fakeAgentService(mountEnv, sessionsRoot: sessionsRoot);

    final appSessions = await service.listSessions();
    expect(appSessions, hasLength(1));
    expect(appSessions.single.id, 'cli-session');
  });

  test('CLI sees a macOS app session created in the same workspace', () async {
    final sharedFs = MemoryExecutionEnv();
    const sessionsRoot = '/shared/sessions';
    const hostCwd = '/host/ai.m';

    // macOS app creates a session while mounted to the host directory.
    final mountEnv = ProjectMountEnv(sharedFs)..mountedRoot = hostCwd;
    final appService = _fakeAgentService(mountEnv, sessionsRoot: sessionsRoot);
    await appService.initialize();
    await appService.sendText('hello from app');
    await appService.waitForIdle();

    // CLI lists sessions with the same host cwd.
    final cliRepo = JsonlSessionRepo(fs: sharedFs, sessionsRoot: sessionsRoot);
    final cliSessions = await cliRepo.list(cwd: hostCwd);
    expect(cliSessions, hasLength(1));
  });
}
