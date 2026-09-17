@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

const _iso = '2026-01-01T00:00:00.000Z';

String _header(String id) =>
    '{"type":"session","version":3,"id":"$id","timestamp":"$_iso",'
    '"cwd":"/work"}\n';

String _userMessage(String id, String text) =>
    '{"type":"message","id":"$id","parentId":null,"timestamp":"$_iso",'
    '"message":{"role":"user","content":[{"type":"text","text":"$text"}]},'
    '"attachments":[]}\n';

Agent _createAgent() => Agent(
  model: Model(
    id: 'test-model',
    api: 'test-api',
    provider: 'test',
    baseUrl: 'https://example.com',
    contextWindow: 100000,
    maxTokens: 4096,
  ),
  systemPrompt: 'You are Fa.',
  streamFunction: (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: [TextContent(text: 'ok')],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime(2026),
        ),
      ),
    );
    stream.end();
    return stream;
  },
  toolRegistry: ToolRegistry(const []),
);

AgentConfig get _config => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);

void main() {
  late Directory tmp;
  late LocalExecutionEnv env;
  late String sessionsRoot;
  late JsonlSessionRepo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fah_pre_cache_test');
    env = LocalExecutionEnv(cwd: tmp.path);
    sessionsRoot = '${tmp.path}/sessions';
    Directory(sessionsRoot).createSync(recursive: true);
    repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<SessionMetadata> seed(String id) async {
    await File(
      '$sessionsRoot/$id.jsonl',
    ).writeAsString(_header(id) + _userMessage('${id}_1', 'hello from $id'));
    return (await repo.list()).where((m) => m.id == id).single;
  }

  FlutterSessionManager newManager() =>
      FlutterSessionManager(env: env, sessionsRoot: sessionsRoot, repo: repo);

  test('pre-caches a persisted session without making it active', () async {
    final meta = await seed('target');
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: sessionsRoot,
      repo: repo,
    );
    final services = <AgentService>[];
    await manager.preCacheSession(
      meta,
      config: _config,
      serviceFactory: () async {
        final service = AgentService(
          agent: _createAgent(),
          env: env,
          sessionsRoot: sessionsRoot,
          repo: repo,
          watchExternalSessions: false,
        );
        services.add(service);
        await service.initialize();
        return service;
      },
    );
    for (final service in services) {
      addTearDown(service.dispose);
    }
    expect(manager.sessions.map((s) => s.id), contains('target'));
    expect(manager.activeId, isNull);

    // A second pre-cache is a no-op — the session is already managed.
    await manager.preCacheSession(
      meta,
      config: _config,
      serviceFactory: () => throw StateError('must not run twice'),
    );
    expect(manager.sessions, hasLength(1));
  });

  test('already-managed ids skip before the factory runs', () async {
    final meta = await seed('live');
    final manager = newManager();
    final service = AgentService(
      agent: _createAgent(),
      env: env,
      sessionsRoot: sessionsRoot,
      repo: repo,
      watchExternalSessions: false,
    );
    addTearDown(service.dispose);
    manager.addSession('live', service);
    await manager.preCacheSession(
      meta,
      config: _config,
      serviceFactory: () => throw StateError('must not run'),
    );
    expect(manager.activeId, 'live');
  });

  test('over-budget sessions never pre-cache', () async {
    final meta = await seed('giant');
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: sessionsRoot,
      repo: repo,
      maxSessionLoadBytes: 8,
    );
    await manager.preCacheSession(
      meta,
      config: _config,
      serviceFactory: () => throw StateError('must not run'),
    );
    expect(manager.sessions, isEmpty);
  });

  test('in-flight duplicates collapse; failures clear the slot', () async {
    final meta = await seed('speculative');
    final manager = newManager();
    var factoryCalls = 0;
    final gate = Completer<AgentService>();
    final first = manager.preCacheSession(
      meta,
      config: _config,
      // A failing loader: the whole pre-cache degrades to a no-op.
      serviceFactory: () async {
        factoryCalls++;
        return gate.future;
      },
    );
    // The duplicate call must be absorbed by the in-flight guard.
    await manager.preCacheSession(
      meta,
      config: _config,
      serviceFactory: () async {
        factoryCalls++;
        return gate.future;
      },
    );
    expect(factoryCalls, 1);

    final service = AgentService(
      agent: _createAgent(),
      env: env,
      sessionsRoot: sessionsRoot,
      repo: repo,
      watchExternalSessions: false,
    );
    addTearDown(service.dispose);
    await service.initialize();
    // Load throws (target file disappears) → invisible failure.
    await File(meta.path).delete();
    gate.complete(service);
    await first;
    expect(manager.sessions, isEmpty);

    // The in-flight slot is free again — a retry reaches the factory.
    await manager.preCacheSession(
      meta,
      config: _config,
      serviceFactory: () => throw StateError('retry reached the factory'),
    );
    expect(factoryCalls, 1);
  });
}
