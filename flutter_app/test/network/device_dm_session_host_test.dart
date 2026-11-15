// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/device_dm_session_host.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _reply(String text) => (model, context, {cancelToken}) {
  final stream = AssistantMessageEventStream();
  stream.push(
    DoneEvent(
      reason: StopReason.stop,
      message: AssistantMessage(
        content: [TextContent(text: text)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      ),
    ),
  );
  stream.end();
  return stream;
};

Future<AgentService> _service(MemoryExecutionEnv env) => AgentService.create(
  config: AgentConfig(
    providerKind: 'openai-completions',
    modelId: 'test-model',
    baseUrl: 'https://example.test',
    apiKey: 'test-key',
  ),
  env: env,
  sessionsRoot: '/sessions',
  streamFunction: _reply('woke assistant'),
  watchExternalSessions: false,
);

void main() {
  test(
    'offline DM target opens from disk before the user turn and reply',
    () async {
      final env = MemoryExecutionEnv(cwd: '/');
      final offline = await _service(env);
      await offline.initialize();
      await offline.sendText('persist me');
      await offline.waitForIdle();
      final offlineId = offline.currentSessionId!;
      offline.dispose();

      final template = await _service(env);
      addTearDown(template.dispose);
      await template.initialize();
      final sessions = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        includeSharedSessionRoots: false,
      )..addSession(template.currentSessionId!, template);
      final host = FlutterDeviceDmSessionHost(sessions);

      final reply = await host.deliverUserText(
        sessionId: offlineId,
        text: 'wake up',
      );

      expect(reply, 'woke assistant');
      final opened = sessions.sessions.singleWhere(
        (session) => session.id == offlineId,
      );
      expect(
        opened.service.messages.map((row) => row.content),
        contains('wake up'),
      );
      expect(sessions.activeId, offlineId);

      final activeReply = await host.deliverUserText(text: 'active follow up');
      expect(activeReply, 'woke assistant');
      expect(
        opened.service.messages.map((row) => row.content),
        contains('active follow up'),
      );
      opened.service.dispose();
    },
  );
}
