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
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

final _config = AgentConfig(
  providerKind: 'test',
  modelId: 'test-model',
  baseUrl: 'https://example.com',
  apiKey: '',
);

/// Rewrites the session file header so the session looks created yesterday.
Future<void> _ageSession(ExecutionEnv env, SessionMetadata metadata) async {
  final content = (await env.readTextFile(metadata.path)).getOrThrow();
  final lines = content.split('\n');
  final header = jsonDecode(lines.first) as Map<String, dynamic>;
  header['timestamp'] = DateTime.now()
      .subtract(const Duration(days: 1))
      .toIso8601String();
  lines[0] = jsonEncode(header);
  (await env.writeFile(metadata.path, lines.join('\n'))).getOrThrow();
}

Future<SessionMetadata> _persistSession(
  JsonlSessionRepo repo, {
  String? userText,
}) async {
  final session = await repo.create(
    JsonlSessionCreateOptions(
      cwd: 'test',
      metadata: const {'agent': 'fa', 'model': 'test-model'},
    ),
  );
  if (userText != null) {
    await session.appendMessage(UserMessage.text(userText));
  }
  return session.getMetadata();
}

void main() {
  group('FlutterSessionManager.createOrResumeSession', () {
    late MemoryExecutionEnv env;
    late JsonlSessionRepo repo;
    late FlutterSessionManager manager;

    setUp(() {
      env = MemoryExecutionEnv();
      repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    });

    Future<FlutterManagedSession> boot() {
      return manager.createOrResumeSession(
        config: _config,
        createFactory: () async => _fakeService(env),
        openFactory: () async => _fakeService(env),
      );
    }

    test('empty store creates a new session', () async {
      final result = await boot();

      expect(manager.sessions.map((s) => s.id), [result.id]);
      expect(manager.activeId, result.id);
      // The id is allocated eagerly, but the session file materialises
      // only on the first persist — an untouched session never hits disk.
      expect(result.id, isNotEmpty);
      expect(await repo.list(), isEmpty);
    });

    test(
      'closing an untouched session deletes its file; a used one stays',
      () async {
        final first = await boot();
        final second = await manager.createSession(
          config: _config,
          serviceFactory: () async => _fakeService(env),
        );
        // No files yet: both sessions are untouched.
        expect(await repo.list(), isEmpty);

        // The second session gets real content; the first stays untouched.
        await second.service.sendText('hi');
        await second.service.waitForIdle();
        expect(await repo.list(), hasLength(1));

        await manager.closeSession(first.id);
        expect(await repo.list(), hasLength(1));

        await manager.closeSession(second.id);
        final stored = await repo.list();
        expect(stored, hasLength(1));
        expect(stored.single.id, second.id);
      },
    );

    test('newest session from today with user messages is resumed and no '
        'new session file is created', () async {
      final existing = await _persistSession(repo, userText: 'earlier chat');

      final result = await boot();

      expect(result.id, existing.id);
      expect(manager.activeId, existing.id);
      expect(await repo.list(), hasLength(1));
      // The persisted transcript was loaded into the resumed service.
      expect(result.service.messages.single.role, 'user');
      expect(result.service.messages.single.content, 'earlier chat');
    });

    test('newest session from today, still empty, is resumed', () async {
      final existing = await _persistSession(repo);

      final result = await boot();

      expect(result.id, existing.id);
      expect(await repo.list(), hasLength(1));
      expect(result.service.messages, isEmpty);
    });

    test('newest session older than today with user messages creates a '
        'new session', () async {
      final existing = await _persistSession(repo, userText: 'old chat');
      await _ageSession(env, existing);

      final result = await boot();

      expect(result.id, isNot(existing.id));
      expect(manager.activeId, result.id);
      // Only the old session is on disk — the fresh one materialises its
      // file on the first persist.
      expect(await repo.list(), hasLength(1));
      expect(result.service.messages, isEmpty);
    });

    test('newest session older than today, still empty, is resumed', () async {
      final existing = await _persistSession(repo);
      await _ageSession(env, existing);

      final result = await boot();

      expect(result.id, existing.id);
      expect(await repo.list(), hasLength(1));
      expect(result.service.messages, isEmpty);
    });

    test(
      'a session file with corrupt lines loads with the junk quarantined',
      () async {
        final existing = await _persistSession(repo, userText: 'earlier chat');
        // Corrupt the file: the header stays readable (so the session is
        // listed and picked for resume) but entry lines are no longer valid
        // JSON. Since the quarantine-on-open heal (serialized writers +
        // torn-line sidecar) a malformed line at ANY position is dropped
        // into the .corrupt sidecar — the session still loads, and the
        // fallback-to-new-session path is reserved for unreadable files
        // (covered by the storage quarantine tests).
        (await env.appendFile(
          existing.path,
          'this is not json\n',
        )).getOrThrow();
        (await env.appendFile(
          existing.path,
          '{"broken": true}\n',
        )).getOrThrow();

        final result = await boot();

        // The corrupt file still resumes — its readable records survive.
        expect(result.id, existing.id);
        expect(manager.activeId, existing.id);
        expect(
          result.service.messages.map((m) => m.content),
          contains('earlier chat'),
        );
        expect(await repo.list(), hasLength(1));
      },
    );

    test('boot resumes the last ACTIVE session, not the newest file', () async {
      final older = await _persistSession(repo, userText: 'the real work');
      await _persistSession(repo, userText: 'a later empty-ish chat');
      // The user last worked in the OLDER session.
      (await env.writeFile(
        '/sessions/last_active_session.json',
        '{"version":1,"id":"${older.id}"}',
      )).getOrThrow();

      final result = await boot();

      expect(result.id, older.id);
      expect(manager.activeId, older.id);
      expect(result.service.messages.single.content, 'the real work');
    });

    test('switching sessions persists the pick for the next boot', () async {
      final older = await _persistSession(repo, userText: 'the real work');
      // First boot: mints a fresh session and remembers it.
      await boot();
      // The user then opens the older session — that choice must stick.
      await manager.openSession(
        older,
        config: _config,
        serviceFactory: () async {
          return _fakeService(env);
        },
      );

      // Second boot on a fresh manager (same env): lands on the older one.
      final manager2 = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      final result = await manager2.createOrResumeSession(
        config: _config,
        createFactory: () async => _fakeService(env),
        openFactory: () async => _fakeService(env),
      );

      expect(result.id, older.id);
      expect(manager2.activeId, older.id);
    });
  });
}
