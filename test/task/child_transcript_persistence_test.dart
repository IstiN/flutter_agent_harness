@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

void main() {
  test(
    'abort path still persists the partial transcript (crash resilience)',
    () async {
      // The design under test: the executor creates the session in the
      // background at spawn and flushes transcript increments per turn; the
      // finally-block flush persists whatever exists even on abort. Here we
      // verify the persistence primitives compose: a child session with a
      // partial transcript survives and stays openable.
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final manager = SubagentManager(parentSessionId: '');

      Future<dynamic> factory(String parentId, String childId) {
        return repo.create(
          JsonlSessionCreateOptions(
            cwd: '/work',
            metadata: {'agent': 'subagent', 'id': childId},
          ),
        );
      }

      final session = await factory('', 'a1');
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      final path = (await session.getMetadata()).path;
      await manager.attachSession('a1', path);

      // A mid-run flush writes two of the four messages (crash at turn 2).
      final messages = [
        UserMessage.text('turn 1'),
        UserMessage.text('turn 2'),
        UserMessage.text('turn 3'),
        UserMessage.text('turn 4'),
      ];
      for (var i = 0; i < 2; i++) {
        await session.appendMessage(messages[i]);
      }

      // The handle now points at the real file, and the partial transcript
      // is readable from it.
      final handle = manager['a1']!;
      final info = await env.fileInfo(handle.sessionId);
      expect(info.valueOrNull, isNotNull);

      final reopened = await repo.open(
        SessionMetadata(
          id: handle.sessionId,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          cwd: '/work',
          path: handle.sessionId,
        ),
      );
      final transcript = await reopened.buildContextMessages();
      expect(transcript.length, 2);

      // A later flush appends the rest (no duplicates).
      for (var i = 2; i < 4; i++) {
        await session.appendMessage(messages[i]);
      }
      final reopened2 = await repo.open(
        SessionMetadata(
          id: handle.sessionId,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          cwd: '/work',
          path: handle.sessionId,
        ),
      );
      final full = await reopened2.buildContextMessages();
      expect(full.length, 4);
    },
  );
}
