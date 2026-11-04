import 'dart:async';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentService _service(ExecutionEnv env) => AgentService(
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
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
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

/// A gated preview source: every read blocks on [gate] and serves
/// [results] by session id. Counts reads so tests can pin the cache.
final class _GatedPreviewSource implements LocalChatPreviewSource {
  _GatedPreviewSource(this.gate);

  final Completer<void> gate;
  final Map<String, String> results = {};
  int reads = 0;

  @override
  Future<String?> read(SessionMetadata metadata) async {
    reads++;
    await gate.future;
    return results[metadata.id];
  }
}

/// Waits (bounded) until [probe] returns non-null — the lazy background
/// fills repaint through manager notifies, not through the load future.
Future<void> _until(Future<bool> Function() probe, {int rounds = 400}) async {
  for (var i = 0; i < rounds; i++) {
    if (await probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition never settled');
}

void main() {
  test(
    'an unpersisted live placeholder is hidden until it has content',
    () async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        includeSharedSessionRoots: false,
      );
      final placeholder = _service(env);
      final conversation = _service(env)
        ..messages.add(FahChatMessage(role: 'user', content: 'Hello'));
      manager
        ..addSession('placeholder', placeholder)
        ..addSession('conversation', conversation);
      final adapter = LocalChatListAdapter(
        manager: manager,
        titleBuilder: (id, createdAt, isSubagent) => id,
      );

      final entries = await adapter.load();

      expect(entries.map((entry) => entry.id.value), ['conversation']);
      expect(entries.single.preview, 'Hello');
    },
  );

  test(
    'persisted sessions use real transcript previews and subagent metadata',
    () async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        includeSharedSessionRoots: false,
      );
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final parent = await repo.create(
        const JsonlSessionCreateOptions(id: 'parent', cwd: '/work'),
      );
      await parent.appendMessage(UserMessage.text('A real persisted preview'));
      await parent.appendSessionName('CLI parent');
      await repo.create(
        const JsonlSessionCreateOptions(
          id: 'child',
          cwd: '/work',
          metadata: {'agent': 'subagent', 'parent': 'parent'},
        ),
      );
      await repo.create(
        const JsonlSessionCreateOptions(id: 'empty', cwd: '/work'),
      );

      final adapter = LocalChatListAdapter(
        manager: manager,
        titleBuilder: (id, createdAt, isSubagent) => id,
      );
      final entries = await adapter.load();
      final byId = {for (final item in entries) item.id.value: item};

      // Issue #2053 AC4: JSONL names AND transcript previews left the
      // boot path — the first paint derives titles, subagent metadata
      // stays synchronous, previews ride the bounded background fill.
      expect(byId['parent']!.title, isNot('CLI parent'));
      expect(
        byId['parent']!.preview,
        isNull,
        reason: 'previews fill lazily; the first paint never blocks',
      );
      expect(byId['parent']!.folderName, 'work');
      expect(byId['parent']!.folderPath, '/work');
      expect(byId['child']!.parentId, 'parent');
      expect(byId['child']!.isSubagent, isTrue);
      expect(byId['empty']!.preview, isNull);

      // The lazy fills learn the session_info name and the transcript
      // preview (bounded, off the boot path); the next projection shows
      // both.
      await _until(() async {
        final refilled = {
          for (final item in await adapter.load()) item.id.value: item,
        };
        return refilled['parent']!.preview == 'A real persisted preview';
      });
      final persisted = await manager.listPersistedSessions();
      await manager.warmSessionNames(persisted);
      final refilled = {
        for (final item in await adapter.load()) item.id.value: item,
      };
      expect(refilled['parent']!.title, 'CLI parent');
      expect(refilled['parent']!.preview, 'A real persisted preview');
      expect(refilled['empty']!.preview, isNull);
    },
  );

  test('subagents prefer their persisted human task identity', () async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    );
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await repo.create(
      const JsonlSessionCreateOptions(
        id: '0198f2f5-90e5-7f35-8e30-bdb535d04b04',
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'parent': 'parent',
          'id': 'rail-all-local-pass',
        },
      ),
    );
    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (_, _, _) => 'Derived fallback title',
    );

    final entries = await adapter.load();

    expect(entries.single.title, 'rail-all-local-pass');
    expect(entries.single.isSubagent, isTrue);
  });

  test(
    'reload uses the fresh store instead of a pre-delete snapshot',
    () async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        includeSharedSessionRoots: false,
      );
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await repo.create(
        const JsonlSessionCreateOptions(id: 'deleted', cwd: '/work/project'),
      );
      await repo.create(
        const JsonlSessionCreateOptions(id: 'survivor', cwd: '/work/project'),
      );
      final adapter = LocalChatListAdapter(
        manager: manager,
        titleBuilder: (id, createdAt, isSubagent) => id,
      );
      expect(
        (await adapter.load()).map((entry) => entry.id.value),
        containsAll(<String>['deleted', 'survivor']),
      );

      await manager.deleteSession('deleted');
      final entries = await adapter.load();

      expect(
        entries.map((entry) => entry.id.value),
        isNot(contains('deleted')),
      );
      expect(entries.map((entry) => entry.id.value), contains('survivor'));
    },
  );

  test('previews fill off the first projection — rows emit before '
      'transcript reads land', () async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    );
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final parent = await repo.create(
      const JsonlSessionCreateOptions(id: 'parent', cwd: '/work'),
    );
    await parent.appendMessage(UserMessage.text('A real persisted preview'));

    final gate = Completer<void>();
    final reader = _GatedPreviewSource(gate)
      ..results['parent'] = 'A real persisted preview';
    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
      previewReader: reader,
    );

    // The live runtime: ~900 gated transcript reads must never gate the
    // first emission. The load resolves while the reads are still parked.
    final entries = await adapter.load().timeout(const Duration(seconds: 5));
    final byId = {for (final item in entries) item.id.value: item};
    expect(
      byId['parent']!.preview,
      isNull,
      reason: 'the first paint renders without previews',
    );
    expect(reader.reads, 1, reason: 'the background fill is kicked');

    gate.complete();
    await _until(() async {
      final refilled = {
        for (final item in await adapter.load()) item.id.value: item,
      };
      return refilled['parent']!.preview != null;
    });
    final refilled = {
      for (final item in await adapter.load()) item.id.value: item,
    };
    expect(refilled['parent']!.preview, 'A real persisted preview');
  });

  test('preview cache keys on the file stamp — warm reloads re-read '
      'nothing until the transcript grows', () async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    );
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final parent = await repo.create(
      const JsonlSessionCreateOptions(id: 'parent', cwd: '/work'),
    );
    await parent.appendMessage(UserMessage.text('First tail'));

    final reader = _GatedPreviewSource(Completer<void>()..complete())
      ..results['parent'] = 'First tail';
    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
      previewReader: reader,
    );

    await _until(() async {
      final entries = {
        for (final item in await adapter.load()) item.id.value: item,
      };
      return entries['parent']!.preview != null;
    });
    expect(reader.reads, 1);

    // Warm reloads: served from the stamp cache, zero extra reads.
    await adapter.load();
    await adapter.load();
    expect(reader.reads, 1, reason: 'the stamp cache serves warm boots');

    // The transcript grows: the stamp no longer matches → exactly one
    // re-read, and the preview catches up to the newest tail.
    await parent.appendMessage(UserMessage.text('Newer tail'));
    reader.results['parent'] = 'Newer tail';
    Future<String?> currentPreview() async => ({
      for (final item in await adapter.load()) item.id.value: item,
    })['parent']!.preview;
    await _until(() async => await currentPreview() == 'Newer tail');
    expect(reader.reads, 2, reason: 'only the grown file is re-read');
  });
}
