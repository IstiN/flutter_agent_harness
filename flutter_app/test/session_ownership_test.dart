// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
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

AgentService _fakeService(ExecutionEnv env) {
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
    sessionsRoot: '/sessions',
    config: _config,
  );
}

final AgentConfig _config = AgentConfig(
  providerKind: 'test',
  modelId: 'test-model',
  baseUrl: 'https://example.com',
  apiKey: '',
);

/// 14:32 wall-clock: fresh leases; stale ones age the file instead.
final DateTime _now = DateTime(2026, 9, 15, 14, 32);

void main() {
  late MemoryExecutionEnv env;
  late FileSessionLeaseStore store;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    store = FileSessionLeaseStore(env: env, now: () => _now);
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  FlutterSessionManager manager({FileSessionLeaseStore? lease}) =>
      FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        leaseStore: lease,
      );

  Future<SessionMetadata> persisted(String name) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendSessionName(name);
    return session.getMetadata();
  }

  Future<void> seedLease(
    String sessionPath, {
    String host = 'cli',
    int pid = 999,
    String bootId = 'owner-boot',
  }) async {
    await env.writeFile(
      store.sidecarPath(sessionPath),
      const JsonEncoder.withIndent(' ').convert({
        'host': host,
        'sessionId': 'whatever',
        'pid': pid,
        'bootId': bootId,
        'heartbeatAt': _now.toUtc().toIso8601String(),
        'acquiredAt': _now.toUtc().toIso8601String(),
      }),
    );
  }

  test(
    'AC4: a free session is acquired on open-for-drive and released on close',
    () async {
      final meta = await persisted('free');
      final mgr = manager(lease: store);
      await mgr.openSession(
        meta,
        config: _config,
        serviceFactory: () async => _fakeService(env),
      );
      final live = await store.inspect(meta.path);
      expect(live.state, LeaseState.live);
      expect(live.lease!.host, 'app');
      expect(live.lease!.bootId, isNot('owner-boot'));

      await mgr.closeSession(meta.id);
      expect((await store.inspect(meta.path)).state, LeaseState.free);
    },
  );

  test(
    'AC2/AC6: a live lease refuses the drive-open BEFORE any second '
    'writer exists (SessionDrivenElsewhereException, factory never runs)',
    () async {
      final meta = await persisted('owned');
      await seedLease(meta.path);
      final bytesBefore = (await env.readTextFile(meta.path)).valueOrNull;
      var factoryCalls = 0;
      final mgr = manager(lease: store);

      await expectLater(
        mgr.openSession(
          meta,
          config: _config,
          serviceFactory: () async {
            factoryCalls++;
            return _fakeService(env);
          },
        ),
        throwsA(isA<SessionDrivenElsewhereException>()),
      );
      expect(factoryCalls, 0, reason: 'no AgentService, no second writer');
      expect((await env.readTextFile(meta.path)).valueOrNull, bytesBefore);
      final still = await store.inspect(meta.path);
      expect(still.state, LeaseState.live);
      expect(still.lease!.bootId, 'owner-boot');
      expect(still.lease!.pid, 999);
    },
  );

  test('AC7: an expired lease is re-acquired fresh for the app', () async {
    final meta = await persisted('deadowner');
    await seedLease(meta.path);
    env.setMtime(
      store.sidecarPath(meta.path),
      _now.subtract(const Duration(seconds: 20)).millisecondsSinceEpoch,
    );
    final mgr = manager(lease: store);
    await mgr.openSession(
      meta,
      config: _config,
      serviceFactory: () async => _fakeService(env),
    );
    final fresh = await store.inspect(meta.path);
    expect(fresh.state, LeaseState.live);
    expect(fresh.lease!.host, 'app');
    expect(fresh.lease!.bootId, isNot('owner-boot'));
    await mgr.closeSession(meta.id);
  });

  test(
    'AC2: the app viewer composer mails the owner with Fa.app attribution',
    () async {
      final meta = await persisted('owned');
      final fabric = FileMessagingRepository(
        env: env,
        root: '/sessions/--work--/messages',
      );
      final channel = FileSessionInputChannel(repository: fabric);
      await channel.send(meta.id, 'hello from the viewer');

      final mail = await fabric.peek('${meta.id}/main');
      expect(mail, hasLength(1));
      expect(mail.single.fromId, 'Fa.app user');
      expect(mail.single.kind, AgentMessageKind.user);
      expect(mail.single.text, 'hello from the viewer');
    },
  );

  test('AC8: no lease store — a live sidecar does NOT block the open '
      '(legacy behavior byte-identical)', () async {
    final meta = await persisted('legacy');
    await seedLease(meta.path);
    final mgr = manager();
    final managed = await mgr.openSession(
      meta,
      config: _config,
      serviceFactory: () async => _fakeService(env),
    );
    expect(managed.id, meta.id);
    expect(mgr.activeId, meta.id);
  });
}
