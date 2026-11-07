@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/subagent_parent_resolver.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late LocalExecutionEnv env;
  late FlutterSessionManager manager;
  late JsonlSessionRepo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fah_relink_test');
    env = LocalExecutionEnv(cwd: tmp.path);
    final sessionsRoot = '${tmp.path}/sessions';
    Directory(sessionsRoot).createSync(recursive: true);
    manager = FlutterSessionManager(
      env: env,
      sessionsRoot: sessionsRoot,
      // Keep the tail budget tiny so the test proves the bound, not the
      // default.
      parentResolver: SubagentParentResolver(maxTailBytes: 1 << 20),
    );
    repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('legacy children list immediately, then relink in the background '
      '(issues #426/#2053)', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'proj',
        metadata: const {'agent': 'fa', 'model': 'm'},
      ),
    );
    await parent.appendMessage(UserMessage.text('spawn some agents'));
    final parentMeta = await parent.getMetadata();
    final child = await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'proj',
        metadata: const {
          'agent': 'subagent',
          'id': 'aaaa11',
          'parent': '',
          'model': 'm',
        },
      ),
    );
    final childMeta = await child.getMetadata();
    final offscreen = await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'proj',
        metadata: const {
          'agent': 'subagent',
          'id': 'offscr',
          'parent': '',
          'model': 'm',
        },
      ),
    );
    final offscreenMeta = await offscreen.getMetadata();

    // The parent transcript's registry record — what hosts append at turn
    // boundaries naming every child session file they spawned.
    File(parentMeta.path).writeAsStringSync(
      '${jsonEncode({
        'type': 'custom',
        'id': 'reg1',
        'customType': 'subagent_registry',
        'data': [
          {'id': 'aaaa11', 'sessionId': childMeta.path},
        ],
      })}\n',
      mode: FileMode.append,
    );

    final listed = await manager.listPersistedSessions();
    final initial = listed.firstWhere((m) => m.id == childMeta.id);
    expect(
      subagentParentId(initial),
      isNull,
      reason: 'the legacy transcript scan must not block the first emission',
    );

    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
      readPersistedNames: false,
    );
    await adapter.load();
    await adapter.warmVisible({childMeta.id});
    final later = await manager.listPersistedSessions();
    final relinked = later.firstWhere((m) => m.id == childMeta.id);
    // The visible-row result lands in the listing's metadata — the exact
    // shape sessionTreeRows' grouping consumes.
    expect(isSubagentSession(relinked), isTrue);
    expect(subagentParentId(relinked), parentMeta.id);
    final untouched = later.firstWhere((m) => m.id == offscreenMeta.id);
    expect(
      subagentParentId(untouched),
      isNull,
      reason: 'offscreen legacy children never enter the resolver batch',
    );
  });

  test('fresh children with a real header parent list untouched', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'proj',
        metadata: const {'agent': 'fa', 'model': 'm'},
      ),
    );
    final parentMeta = await parent.getMetadata();
    await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'proj',
        metadata: {
          'agent': 'subagent',
          'id': 'bbbb22',
          'parent': parentMeta.id,
          'model': 'm',
        },
      ),
    );

    final listed = await manager.listPersistedSessions();
    // macOS listPersistedSessions merges the machine's other roots in —
    // assert on the test's own sessions, not the merged length.
    expect(listed, hasLength(greaterThanOrEqualTo(2)));
    // Nothing was rewritten: the header link passes through as stored.
    final child = listed.firstWhere(
      (m) => (m.metadata ?? const {})['id'] == 'bbbb22',
    );
    expect(subagentParentId(child), parentMeta.id);
  });
}
