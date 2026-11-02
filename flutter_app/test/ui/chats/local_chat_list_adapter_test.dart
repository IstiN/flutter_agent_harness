import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

      expect(byId['parent']!.title, 'CLI parent');
      expect(byId['parent']!.preview, 'A real persisted preview');
      expect(byId['parent']!.folderName, 'work');
      expect(byId['parent']!.folderPath, '/work');
      expect(byId['child']!.parentId, 'parent');
      expect(byId['child']!.isSubagent, isTrue);
      expect(byId['empty']!.preview, isNull);
    },
  );

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
}
