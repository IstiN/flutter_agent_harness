// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #863: session delete must actually delete (and say so).
///
/// Covers the manager-level contract: no silent no-op for unresolvable ids
/// (AC2), every attempt logged as `[fah][sessions] delete` with id + outcome
/// (AC4), success verified against a fresh repo listing and hosts notified
/// so lists rebuild from the source of truth (AC3, AC1), and an active run
/// at delete time leaves no orphan (E2).
library;

import 'dart:async';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter/foundation.dart';
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

/// A provider stream that never completes until cancelled — an active run
/// at delete time (issue #863 E2).
StreamFunction _hungResponse() {
  return (model, context, {cancelToken}) {
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
  };
}

AgentService _service(ExecutionEnv env, {StreamFunction? stream}) {
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
      streamFunction: stream ?? _singleTextResponse('ok'),
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

/// A hosted (extension panel / relay shell) service: its sessions live in
/// the service worker's storage, exposed only through [listSessions] —
/// [liveSessionId] non-null is what flips the manager onto the hosted
/// delete authority (issue #863 PR review).
final class _HostedService extends AgentService {
  _HostedService({
    required super.agent,
    required super.env,
    required super.sessionsRoot,
    required super.config,
  });

  @override
  String? get liveSessionId => 'sw-live-1';

  List<SessionMetadata> rows = const [];

  @override
  Future<List<SessionMetadata>> listSessions() async => rows;
}

AgentService _hostedService(ExecutionEnv env, List<SessionMetadata> rows) {
  return _HostedService(
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
  )..rows = rows;
}

/// Swallows debugPrint into a list so the `[fah][sessions] delete` log
/// contract (AC4) is assertable. Restore via [restoreLogs].
List<String> captureLogs() {
  final lines = <String>[];
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  return lines;
}

void restoreLogs() {
  debugPrint = debugPrintThrottled;
}

void main() {
  late MemoryExecutionEnv env;
  late FlutterSessionManager manager;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv();
    manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    );
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  tearDown(restoreLogs);

  Future<SessionMetadata> persistSession(String id, {String? userText}) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(
        id: id,
        cwd: 'test',
        metadata: const {'agent': 'fa', 'model': 'test-model'},
      ),
    );
    if (userText != null) {
      await session.appendMessage(UserMessage.text(userText));
    }
    return session.getMetadata();
  }

  /// Polls until the session id surfaces in the repo listing (the service
  /// materialises its file lazily on the first persist).
  Future<SessionMetadata> waitForSession(String id) async {
    for (var i = 0; i < 500; i++) {
      final hit = (await repo.list()).where((m) => m.id == id).toList();
      if (hit.isNotEmpty) return hit.single;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('session $id never materialised on disk');
  }

  group('AC2: an unresolvable id never passes silently', () {
    test('delete of a stale id throws the named failure and logs it', () async {
      final logs = captureLogs();

      await expectLater(
        manager.deleteSession('ghost0001-dead'),
        throwsA(isA<SessionDeleteException>()),
      );

      expect(
        logs,
        everyElement(
          allOf(contains('[fah][sessions] delete'), contains('ghost0001-dead')),
        ),
      );
      expect(logs.join('\n'), contains('outcome=attempt'));
      expect(logs.join('\n'), contains('outcome=not-found'));
    });

    test(
      'the stale-row failure still notifies so hosts resync the list',
      () async {
        var notified = 0;
        manager.addListener(() => notified++);

        await expectLater(
          manager.deleteSession('ghost0002-dead'),
          throwsA(isA<SessionDeleteException>()),
        );

        expect(notified, greaterThan(0));
      },
    );
  });

  group('AC4: every delete attempt logs id + outcome', () {
    test('the persisted path logs attempt and ok', () async {
      final metadata = await persistSession(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
        userText: 'hi',
      );
      final logs = captureLogs();

      await manager.deleteSession(metadata.id);

      expect(
        logs,
        everyElement(
          allOf(contains('[fah][sessions] delete'), contains(metadata.id)),
        ),
      );
      expect(logs.join('\n'), contains('outcome=attempt'));
      expect(logs.join('\n'), contains('outcome=ok'));
    });

    test('the live (closed) path logs attempt and ok', () async {
      final metadata = await persistSession(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',
        userText: 'live',
      );
      manager.addSession(metadata.id, _service(env));
      final logs = captureLogs();

      await manager.deleteSession(metadata.id);

      expect(logs.join('\n'), contains('outcome=attempt'));
      expect(logs.join('\n'), contains('outcome=ok'));
    });

    test('a failing repo delete logs outcome=failed and rethrows', () async {
      final metadata = await persistSession(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3',
        userText: 'hi',
      );
      // A fresh foreign presence row refuses the delete (liveSession guard).
      final presence = FileSessionPresenceStore(env: env, root: '/sessions');
      await presence.register(metadata.id, pid: 9999);
      final logs = captureLogs();

      await expectLater(
        manager.deleteSession(metadata.id),
        throwsA(isA<SessionException>()),
      );

      expect(logs.join('\n'), contains('outcome=failed'));
    });
  });

  group('AC1 + AC3: success verified against the source of truth', () {
    test('the file is gone and a fresh listing drops the id', () async {
      final deleted = await persistSession(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa4',
        userText: 'bye',
      );
      final survivor = await persistSession(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa5',
        userText: 'stay',
      );

      await manager.deleteSession(deleted.id);

      expect((await env.exists(deleted.path)).valueOrNull, isFalse);
      final listed = await manager.listPersistedSessions();
      expect(listed.map((m) => m.id), isNot(contains(deleted.id)));
      expect(listed.map((m) => m.id), contains(survivor.id));
    });

    test('hosts are notified to rebuild the list after the delete', () async {
      final metadata = await persistSession(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa6',
        userText: 'hi',
      );
      var notified = 0;
      manager.addListener(() => notified++);

      await manager.deleteSession(metadata.id);

      expect(notified, greaterThan(0));
    });
  });

  group('E2: delete while a run is active in the session', () {
    test('the file is removed after the run settles and stays gone', () async {
      final service = _service(env, stream: _hungResponse());
      await service.initialize();
      final id = service.currentSessionId!;
      manager.addSession(id, service);

      unawaited(service.sendText('delete me mid-run'));
      final metadata = await waitForSession(id);
      expect(service.messages.single.content, 'delete me mid-run');

      await manager.deleteSession(id);

      // The aborted run's final persist settled BEFORE the delete (E2):
      // the file is gone and nothing recreates it afterwards.
      await service.waitForIdle();
      expect((await env.exists(metadata.path)).valueOrNull, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await repo.list(), isEmpty);
    });
  });

  group('PR review fixes: honest failure contracts on every delete path', () {
    test(
      'a failing live-path delete notifies hosts BEFORE rethrowing',
      () async {
        final metadata = await persistSession(
          'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa7',
          userText: 'live',
        );
        manager.addSession(metadata.id, _service(env));
        // A fresh foreign presence row refuses the delete (liveSession guard).
        final presence = FileSessionPresenceStore(env: env, root: '/sessions');
        await presence.register(metadata.id, pid: 9999);
        var notified = 0;
        manager.addListener(() => notified++);
        final logs = captureLogs();

        await expectLater(
          manager.deleteSession(metadata.id),
          throwsA(isA<SessionException>()),
        );

        // The slot is closed regardless — hosts must resync around the
        // failure, exactly like the not-found branch.
        expect(notified, greaterThan(0));
        expect(logs.join('\n'), contains('outcome=failed'));
      },
    );

    test(
      'hosted session: verification goes through the host service listing '
      'and a still-listed id is a named failure, never a silent ok',
      () async {
        final hosted = _hostedService(env, [
          SessionMetadata(
            id: 'sw-archived-1',
            createdAt: DateTime(2026),
            cwd: 'test',
            path: '/session-sw-archived-1.jsonl',
            metadata: const {'archived': true},
          ),
        ]);
        // Any active hosted slot flips the manager into hosted authority.
        manager.addSession('local-slot', hosted);
        var notified = 0;
        manager.addListener(() => notified++);
        final logs = captureLogs();

        await expectLater(
          manager.deleteSession('sw-archived-1'),
          throwsA(
            isA<SessionDeleteException>().having(
              (e) => e.reason,
              'reason',
              contains('still in the session store'),
            ),
          ),
        );

        // The local listing is empty on hosted surfaces — a stale local
        // check would have passed (or claimed not-found). The failure must
        // come from the host authority instead.
        expect(logs.join('\n'), contains('outcome=failed'));
        expect(logs.join('\n'), isNot(contains('outcome=ok')));
        expect(logs.join('\n'), isNot(contains('outcome=not-found')));
        expect(notified, greaterThan(0));
      },
    );

    test('hosted live session: the host still listing it after close is a '
        'named failure, not outcome=ok', () async {
      final hosted = _hostedService(env, [
        SessionMetadata(
          id: 'sw-live-1',
          createdAt: DateTime(2026),
          cwd: 'test',
          path: '/session-sw-live-1.jsonl',
        ),
      ]);
      manager.addSession('sw-live-1', hosted);
      var notified = 0;
      manager.addListener(() => notified++);
      final logs = captureLogs();

      await expectLater(
        manager.deleteSession('sw-live-1'),
        throwsA(
          isA<SessionDeleteException>().having(
            (e) => e.reason,
            'reason',
            contains('still in the session store'),
          ),
        ),
      );

      expect(logs.join('\n'), contains('outcome=failed'));
      expect(logs.join('\n'), isNot(contains('outcome=ok')));
      expect(notified, greaterThan(0));
    });
  });
}
