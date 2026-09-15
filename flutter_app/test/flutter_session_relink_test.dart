@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/subagent_parent_resolver.dart';
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

  test('listPersistedSessions relinks legacy children (header parent '
      '"") from the parent transcript registry (issue #426)', () async {
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
    final relinked = listed.firstWhere((m) => m.id == childMeta.id);
    // The listing's metadata now carries the resolved parent — the exact
    // shape sessionTreeRows' grouping consumes.
    expect(isSubagentSession(relinked), isTrue);
    expect(subagentParentId(relinked), parentMeta.id);
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
