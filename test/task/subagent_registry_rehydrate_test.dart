import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';

/// Issue #488 AC2: a parent restart must not orphan its children.
///
/// The registry snapshot rides the parent session as `subagent_registry`
/// custom records — side leaves the windowed boot open never
/// materializes into `getEntries()`, so the old snapshot source silently
/// loaded an EMPTY registry on every restart ("no subagent with id" for
/// every pre-restart child whose JSONL still exists).
/// [subagentRegistryRows] reads the snapshot by raw file scan AND adopts
/// child transcripts whose header names this parent but whose row never
/// reached a snapshot (a kill between spawn and persist), so `task_send`
/// addresses them again.
void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  /// Builds the restart world: a parent session with a registry snapshot
  /// naming one child, plus a second child that exists ONLY as a
  /// transcript (its snapshot write was lost to a kill).
  Future<({Session parent, String orphanPath})> buildParentSession() async {
    final parent = await repo.create(
      const JsonlSessionCreateOptions(cwd: '/work'),
    );
    final parentMeta = await parent.getMetadata();
    // A child the LAST snapshot knows: its row survives the restart.
    await parent.appendCustomEntry(
      customType: subagentRegistryRecordType,
      data: [
        {
          'id': 'registered-one',
          'name': 'registered-one',
          'agentType': 'task',
          'sessionId': '/sessions/--work--/registered-one.jsonl',
          'createdAt': '2026-09-16T10:00:00.000Z',
          'task': 'first batch',
          'status': 'completed',
        },
      ],
    );
    // The orphan: a real child transcript whose registry write was lost.
    final orphan = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'fix467',
          'parent': parentMeta.id,
          'model': 'test-model',
        },
      ),
    );
    await orphan.appendMessage(UserMessage.text('child work'));
    return (parent: parent, orphanPath: (await orphan.getMetadata()).path);
  }

  test(
    'AC: after a parent restart the registry sees the snapshot rows AND '
    'the transcript-only child, and task_send addresses it',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (:parent, :orphanPath) = await buildParentSession();
      // The windowed boot open (the CLI resume path) drops side-leaf
      // custom records — the restart shape this fix exists for.
      final parentMeta = await parent.getMetadata();
      final booted = await repo.open(parentMeta, windowed: true);

      final manager = SubagentManager(
        parentSessionId: parentMeta.id,
        source: () async => subagentRegistryRows(
          repo: repo,
          parent: await booted.getMetadata(),
        ),
      );
      await manager.rehydrate();

      // The snapshot row loaded THROUGH THE RAW SCAN (getEntries() would
      // have lost it).
      expect(manager['registered-one'], isNotNull);
      // The transcript-only child was adopted from the sessions tree,
      // onto its REAL session path so a resume continues that file.
      final adopted = manager['fix467'];
      expect(adopted, isNotNull, reason: 'no "no subagent with id" restarts');
      expect(adopted!.status, SubagentStatus.completed);
      expect(adopted.sessionId, orphanPath);

      // AC literal: task_send reaches the pre-restart child id.
      final resumed = <String>[];
      final tools = subagentMonitoringTools(
        manager: manager,
        readMessages: jsonlChildMessageReader(env),
        resumeChild: (id, message) async {
          resumed.add(id);
        },
      );
      final send = tools.firstWhere((tool) => tool.name == 'task_send');
      final result = await send.execute(
        {'id': 'fix467', 'message': 'you there?'},
        null,
        null,
      );
      final text = [
        for (final block in result.content)
          if (block is TextContent) block.text,
      ].join();
      expect(text, isNot(contains('no subagent with id')));
      expect(resumed, contains('fix467'));
    },
  );

  test(
    'adoption never resurrects another session\'s children or the parent '
    'itself',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (:parent, orphanPath: _) = await buildParentSession();
      final parentMeta = await parent.getMetadata();
      // A child of a DIFFERENT parent must not be adopted.
      await repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {
            'agent': 'subagent',
            'id': 'foreign',
            'parent': 'some-other-session',
            'model': 'test-model',
          },
        ),
      );

      final manager = SubagentManager(
        parentSessionId: parentMeta.id,
        source: () => subagentRegistryRows(repo: repo, parent: parentMeta),
      );
      await manager.rehydrate();

      expect(manager['fix467'], isNotNull);
      expect(manager['foreign'], isNull);
      expect(
        manager.handles.map((handle) => handle.id),
        isNot(contains(parentMeta.id)),
        reason: 'the parent is never its own subagent',
      );
    },
  );
}
